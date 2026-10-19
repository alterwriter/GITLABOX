# shellcheck shell=bash
# tools/branch-committers.sh — list branches per repo + unique committer count,
# sorted from most committers to fewest. Exports JSON / CSV.
#
# GitLab APIs used (all read-only, scope read_api):
#   GET /projects/:id                                   resolve path → ID
#   GET /groups/:id/projects?include_subgroups=true     for group:... input
#   GET /projects                                       for account:... input
#   GET /projects/:id/repository/branches               list branches
#   GET /projects/:id/repository/commits?ref_name=BR    commits per branch
#                                                       (optional &since=ISO8601)
# Unique committers = counted by (lowercased) author/committer email of each commit.

TOOL_BC_NAME="Branch & Committer Report"

bc_defaults() {
  BC_PROFILE=""
  BC_TARGETS=()
  BC_SINCE_DAYS=0
  BC_MAX_COMMITS=5000
  BC_IDENTITY=author
  BC_FILTER=""
  BC_REPO_FILTER=""
  BC_INCLUDE_ARCHIVED=0
  BC_FORMAT=json
  BC_OUT=""
  BC_WORKERS=6
  BC_TOP=5
  BC_ROWS=10
}

BC_JQ_KEY='def ckey: ((.email // "") | ascii_downcase) as $e
  | if $e == "" then "name:" + ((.name // "") | ascii_downcase) else $e end;'

# Per-branch result (run by the worker). Input: branches.json, --slurpfile c commits.
BC_JQ_BRANCH="$BC_JQ_KEY"'
def who: if $ident == "committer"
  then {name: (.committer_name // ""), email: (.committer_email // "")}
  else {name: (.author_name // ""), email: (.author_email // "")} end;
.[$i] as $b
| (($c[0] // []) | map(who)) as $people
| ($people | group_by(ckey)
    | map({name: .[0].name, email: .[0].email, commits: length})
    | sort_by(-.commits, .name)) as $committers
| {
    name: $b.name,
    committer_count: ($committers | length),
    commit_count: ($people | length),
    truncated: ($trunc == 1),
    default: ($b.default // false),
    protected: ($b.protected // false),
    merged: ($b.merged // false),
    last_commit_at: $b.commit.committed_date,
    last_commit_author: $b.commit.author_name,
    last_commit_sha: $b.commit.short_id,
    web_url: $b.web_url,
    top_committers: $committers[:$top],
    committers: $committers,
    error: null
  }'

_bc_is_int() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

_bc_tilde() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

# ---------- profile binding per repo ----------
bc_prepare_profile() {
  BC_PROFILE=$(cfg_resolve_name "$BC_PROFILE")
  if [ -z "$BC_PROFILE" ]; then
    ui_err "No GitLab profile yet. Run: ./gitlabbox.sh setup"
    ui_hint "Or for CI: export GITLAB_URL=https://gitlab.example.com GITLAB_TOKEN=glpat-xxx"
    return 1
  fi
  if ! use_profile "$BC_PROFILE"; then
    ui_err "Profile '$BC_PROFILE' not found. Check: ./gitlabbox.sh profiles"
    return 1
  fi
  BC_BASE_HOST="$GLB_HOST"
}

bc_bind_profile() { # bc_bind_profile HOST → activate the matching profile
  local host="$1" p="$BC_PROFILE"
  BC_BIND_ERR=
  if [ -n "$host" ] && [ "$host" != "$BC_BASE_HOST" ]; then
    if ! p=$(cfg_find_by_host "$host"); then
      BC_BIND_ERR="Host '$host' has no profile yet — add one via ./gitlabbox.sh setup"
      return 1
    fi
  fi
  [ "$GLB_PROFILE" = "$p" ] && return 0
  use_profile "$p" || { BC_BIND_ERR="Profile '$p' is invalid"; return 1; }
}

_bc_strip_prefix() { # self-hosted URL under a sub-path (https://host/gitlab/...)
  local p="$1" pre="${GLB_URL_PATH#/}"
  if [ -n "$pre" ] && [ -n "$2" ]; then
    case "$p" in "$pre"/*) p="${p#"$pre"/}" ;; esac
  fi
  printf '%s' "$p"
}

# ---------- target expansion (group/account → projects) ----------
_bc_add() { # _bc_add HOST PATH ERR
  local key="$1|$2"
  [ "$1" = "$BC_BASE_HOST" ] && key="|$2"   # gitlab.com/a/b == a/b
  case "$BC_SEEN" in *"|$key|"*) return 0 ;; esac
  BC_SEEN="$BC_SEEN$key|"
  BC_T_HOST+=("$1"); BC_T_PATH+=("$2"); BC_T_ERR+=("$3")
}

# stdin: text lines → prints those matching any glob (comma-separated). Empty pattern = all.
_bc_glob_lines() {
  local pats=() pat line
  while IFS= read -r pat; do
    pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
    [ -n "$pat" ] && pats+=("$pat")
  done < <(printf '%s\n' "$1" | tr ',' '\n')
  while IFS= read -r line; do
    [ "${#pats[@]}" -eq 0 ] && { printf '%s\n' "$line"; continue; }
    for pat in "${pats[@]}"; do
      # shellcheck disable=SC2053
      if [[ $line == $pat ]]; then printf '%s\n' "$line"; break; fi
    done
  done
}

# Account scope → /projects query
BC_ACCOUNT_SCOPES="member owned reporter developer maintainer all"
_bc_account_query() {
  case "$1" in
    member) printf 'membership=true' ;;
    owned) printf 'owned=true' ;;
    reporter) printf 'membership=true&min_access_level=20' ;;
    developer) printf 'membership=true&min_access_level=30' ;;
    maintainer) printf 'membership=true&min_access_level=40' ;;
    all) printf '' ;;
    *) return 1 ;;
  esac
}

# bc_fetch_projects group|account ARG OUT_TXT
#   fetches the project list (using the active profile) → one path_with_namespace per line,
#   already filtered by BC_REPO_FILTER. Sets BC_LIST_TOTAL (before filtering) & BC_ACCOUNT_USER.
bc_fetch_projects() {
  local kind="$1" arg="$2" out="$3" raw="$3.raw" path q arch="&archived=false"
  [ "$BC_INCLUDE_ARCHIVED" = 1 ] && arch=""
  if [ "$kind" = group ]; then
    path="/groups/$(_uri "$arg")/projects?include_subgroups=true&simple=true&order_by=path&sort=asc$arch"
  else
    if [ -z "$GLB_HDR" ]; then API_ERROR="Account mode needs a token — without one there is no 'account' to look up."; return 1; fi
    if ! q=$(_bc_account_query "$arg"); then API_ERROR="Unknown scope '$arg'. Choices: $BC_ACCOUNT_SCOPES"; return 1; fi
    if [ "$arg" = all ] && [ "$GLB_HOST" = gitlab.com ]; then
      API_ERROR="Scope 'all' on gitlab.com means every public repo in the world. Use 'member'."; return 1
    fi
    api_get "/user" "$raw.user" || return 1
    BC_ACCOUNT_USER=$(jq -r '"@" + .username' "$raw.user")
    path="/projects?simple=true&order_by=path&sort=asc$arch"
    [ -n "$q" ] && path="$path&$q"
  fi
  api_get_all "$path" "$raw" 0 "$BC_WORK/list.count" || return 1
  BC_LIST_TOTAL=$(jq 'length' "$raw")
  jq -r '.[].path_with_namespace' "$raw" | _bc_glob_lines "$BC_REPO_FILTER" >"$out"
  rm -f "$raw" "$raw.user" "$BC_WORK/list.count"
}

bc_expand_targets() {
  local t arg label n p list="$BC_WORK/list.txt"
  BC_T_HOST=(); BC_T_PATH=(); BC_T_ERR=(); BC_SEEN="|"
  for t in "${BC_TARGETS[@]}"; do
    if ! parse_target "$t"; then ui_warn "Skipped, invalid input: $t"; continue; fi
    [ "$T_KIND" = project ] && { _bc_add "$T_HOST" "$T_PATH" ""; continue; }
    case "$BC_SEEN" in *"|@$T_KIND:$T_PATH@${T_HOST:-$BC_BASE_HOST}|"*) continue ;; esac
    BC_SEEN="$BC_SEEN@$T_KIND:$T_PATH@${T_HOST:-$BC_BASE_HOST}|"
    if ! bc_bind_profile "$T_HOST"; then
      _bc_add "$T_HOST" "$T_KIND:$T_PATH" "$BC_BIND_ERR"; continue
    fi
    if [ "$T_KIND" = group ]; then
      arg=$(_bc_strip_prefix "$T_PATH" "$T_HOST"); label="group ${B}$arg${RST}"
    else
      arg="$T_PATH"; label="projects your account can access ${DIM}(scope: $arg · $GLB_HOST)${RST}"
    fi
    ui_spin_start "Looking up all $label" "$BC_WORK/list.count"
    if bc_fetch_projects "$T_KIND" "$arg" "$list"; then
      n=$(sed -n '$=' "$list"); n=${n:-0}
      [ "$T_KIND" = account ] && label="Account ${B}$BC_ACCOUNT_USER${RST} ${DIM}(scope: $arg · $GLB_HOST)${RST}"
      if [ -n "$BC_REPO_FILTER" ]; then
        ui_spin_stop 0 "$label: $BC_LIST_TOTAL projects → ${B}$n${RST} match filter ${CC}$BC_REPO_FILTER${RST}"
      else
        ui_spin_stop 0 "$label: ${B}$n${RST} projects"
      fi
      while IFS= read -r p; do _bc_add "$T_HOST" "$p" ""; done <"$list"
    else
      ui_spin_stop 1 "$T_KIND:$arg — $API_ERROR"
      _bc_add "$T_HOST" "$T_KIND:$arg" "$API_ERROR"
    fi
    rm -f "$BC_WORK/list.count"
  done
}

# ---------- worker (one process per branch, run in parallel via xargs -P) ----------
bc_worker() {
  local i="$1" name path out cf
  out="$BC_RDIR/b/$(printf '%05d' "$i").json"
  cf="$BC_RDIR/c.$i.json"
  name=$(jq -r --argjson i "$i" '.[$i].name' "$BC_RDIR/branches.json")
  path="/projects/$BC_PID/repository/commits?ref_name=$(_uri "$name")"
  [ -n "$BC_SINCE" ] && path="$path&since=$(_uri "$BC_SINCE")"
  if api_get_all "$path" "$cf" "$BC_MAX_COMMITS"; then
    jq --argjson i "$i" --arg ident "$BC_IDENTITY" --argjson top "$BC_TOP" \
      --argjson trunc "$API_TRUNCATED" --slurpfile c "$cf" "$BC_JQ_BRANCH" \
      "$BC_RDIR/branches.json" >"$out"
  else
    jq -n --arg n "$name" --arg e "$API_ERROR" \
      '{name: $n, committer_count: 0, commit_count: 0, committers: [], top_committers: [], error: $e}' >"$out"
  fi
  rm -f "$cf" "$cf.hdr" "$cf.err"
  printf '%s\n' "$i" >>"$BC_RDIR/done"
}

# ---------- scan one repo ----------
_bc_repo_error() { # FILE INPUT ERR
  jq -n --arg in "$2" --arg e "$3" --arg gl "${GLB_URL:-}" \
    '{input: $in, project: $in, gitlab_url: $gl, branch_count_total: 0, branch_count_analyzed: 0,
      unique_committers: 0, branches: [], error: $e}' >"$1"
}

bc_scan_repo() {
  local idx="$1" host="${BC_T_HOST[$1]}" path="${BC_T_PATH[$1]}" err="${BC_T_ERR[$1]}"
  local rdir="$BC_WORK/r$idx" out pid pname defb total n xpid d t0=$SECONDS files nerr uniq vis
  out="$BC_WORK/repos/$(printf '%05d' "$idx").json"
  mkdir -p "$rdir/b"

  printf '\n  %s[%d/%d]%s %s%s%s\n' "$DIM" $((idx + 1)) "$BC_N" "$RST" "$B" "$path" "$RST" >&2

  if [ -n "$err" ]; then ui_err "$err"; _bc_repo_error "$out" "$path" "$err"; return 1; fi
  if ! bc_bind_profile "$host"; then ui_err "$BC_BIND_ERR"; _bc_repo_error "$out" "$path" "$BC_BIND_ERR"; return 1; fi
  path=$(_bc_strip_prefix "$path" "$host")

  ui_spin_start "Resolve project"
  if ! api_get "/projects/$(_uri "$path")" "$rdir/project.json"; then
    ui_spin_stop 1 "Cannot access project: $API_ERROR"
    _bc_repo_error "$out" "$path" "$API_ERROR"; return 1
  fi
  pid=$(jq -r '.id' "$rdir/project.json")
  pname=$(jq -r '.path_with_namespace' "$rdir/project.json")
  defb=$(jq -r '.default_branch // "-"' "$rdir/project.json")
  vis=$(jq -r '.visibility // "-"' "$rdir/project.json")
  ui_spin_stop 0 "Project ${B}$pname${RST} ${DIM}· id $pid · $vis · default: $defb · $GLB_HOST${RST}"

  ui_spin_start "Fetching branch list" "$rdir/count"
  if ! api_get_all "/projects/$pid/repository/branches" "$rdir/branches_all.json" 0 "$rdir/count"; then
    ui_spin_stop 1 "Failed to fetch branches: $API_ERROR"
    _bc_repo_error "$out" "$pname" "$API_ERROR"; return 1
  fi
  total=$(jq 'length' "$rdir/branches_all.json")
  if [ -n "$BC_FILTER" ]; then
    _bc_filter_branches "$rdir/branches_all.json" "$rdir/branches.json"
  else
    cp "$rdir/branches_all.json" "$rdir/branches.json"
  fi
  n=$(jq 'length' "$rdir/branches.json")
  if [ -n "$BC_FILTER" ]; then
    ui_spin_stop 0 "$n of $total branches match filter ${CC}$BC_FILTER${RST}"
  else
    ui_spin_stop 0 "$total branches found"
  fi

  if [ "$n" -gt 0 ]; then
    export BC_RDIR="$rdir" BC_PID="$pid" BC_SINCE BC_MAX_COMMITS BC_IDENTITY BC_TOP GLB_TIMEOUT GLB_VERSION
    : >"$rdir/done"
    cursor_hide
    seq 0 $((n - 1)) | xargs -P "$BC_WORKERS" -n 1 "$GLB_SELF" __bc_branch 2>>"$rdir/worker.log" &
    xpid=$!
    BC_XARGS_PID=$xpid
    while kill -0 "$xpid" 2>/dev/null; do
      d=$(wc -l <"$rdir/done" | tr -d ' ')
      ui_progress "$d" "$n" "counting committers per branch ${DIM}($BC_WORKERS workers)${RST}"
      sleep 0.15
    done
    wait "$xpid"
    BC_XARGS_PID=
    ui_progress_end
    cursor_show
  fi

  shopt -s nullglob
  files=("$rdir"/b/*.json)
  shopt -u nullglob
  cat "${files[@]}" /dev/null | jq -s --slurpfile p "$rdir/project.json" --argjson total "$total" \
    --arg gl "$GLB_URL" --arg prof "$GLB_PROFILE" --arg in "${BC_T_PATH[$idx]}" "$BC_JQ_KEY"'
    sort_by(-(.committer_count // 0), -(.commit_count // 0), .name) as $br
    | $p[0] as $p
    | {
        input: $in, project: $p.path_with_namespace, id: $p.id, name: $p.name,
        web_url: $p.web_url, default_branch: $p.default_branch, visibility: $p.visibility,
        archived: ($p.archived // false), gitlab_url: $gl, profile: $prof,
        branch_count_total: $total, branch_count_analyzed: ($br | length),
        branches_failed: ([$br[] | select(.error != null)] | length),
        unique_committers: ([$br[].committers[]? | ckey] | unique | length),
        branches: $br, error: null
      }' >"$out"

  nerr=$(jq '.branches_failed' "$out")
  uniq=$(jq '.unique_committers' "$out")
  ui_ok "$n branches analyzed · ${B}$uniq${RST} unique committers (across all branches) · $(ui_duration $((SECONDS - t0)))"
  [ "$nerr" -gt 0 ] && ui_warn "$nerr branches could not be read (see the error field in the report)"
  [ "$n" -gt 0 ] && bc_print_repo_table "$out" "$BC_ROWS"
  rm -rf "$rdir"
  return 0
}

_bc_filter_branches() { # IN OUT — bash glob filter, comma-separated: "main,release/*"
  local in="$1" out="$2" keep="$BC_WORK/keep.txt"
  jq -r '.[].name' "$in" | _bc_glob_lines "$BC_FILTER" >"$keep"
  jq --rawfile k "$keep" '($k | split("\n") | map(select(. != "")) | map({(.): true}) | add // {}) as $s
    | map(select($s[.name]))' "$in" >"$out"
}

# ---------- table rendering ----------
# stdin: lines "label␟committers␟commits␟truncated␟last␟default␟protected␟merged␟top␟error"
_bc_table() { # _bc_table MAX_COMMITTERS "HEADER_LABEL" LABEL_WIDTH
  local max="$1" head="$2" lw="${3:-38}" i=0 label cc cm tr last d p m top err lbl flags
  printf '  %s%3s  %s%*s  %-19s  %8s  %-10s  %-5s  %s%s\n' "$DIM" "#" "$head" $((lw - ${#head})) "" "COMMITTERS" \
    "COMMITS" "LAST" "FLAGS" "TOP COMMITTER" "$RST" >&2
  while IFS=$'\x1f' read -r label cc cm tr last d p m top err; do
    i=$((i + 1))
    lbl="$label"
    [ "${#lbl}" -gt "$lw" ] && lbl="${lbl:0:$((lw - 1))}…"
    if [ -n "$err" ]; then
      printf '  %3d  %s%*s  %s✖ %s%s\n' "$i" "$lbl" $((lw - ${#lbl})) "" "$CR" "${err:0:70}" "$RST" >&2
      continue
    fi
    [ "$tr" = true ] && cm="${cm}+"
    flags="$([ "$d" = true ] && printf '%sD%s' "$CG" "$RST" || printf '%s·%s' "$DIM" "$RST")"
    flags="$flags $([ "$p" = true ] && printf '%sP%s' "$CY" "$RST" || printf '%s·%s' "$DIM" "$RST")"
    flags="$flags $([ "$m" = true ] && printf '%sM%s' "$CP" "$RST" || printf '%s·%s' "$DIM" "$RST")"
    printf '  %s%3d%s  %s%*s  %s %4s  %8s  %-10s  %s  %s%s%s\n' "$DIM" "$i" "$RST" "$lbl" $((lw - ${#lbl})) "" \
      "$(ui_minibar "$cc" "$max" 14)" "$cc" "$cm" "${last:-—}" "$flags" "$DIM" "$top" "$RST" >&2
  done
}

_BC_JQ_ROW='[ $label, (.committer_count // 0), (.commit_count // 0), (.truncated // false),
  ((.last_commit_at // "")[:10]), (.default // false), (.protected // false), (.merged // false),
  ((.top_committers // [])[0] | if . then "\(.name) (\(.commits))" else "-" end), (.error // "") ]
  | map(tostring) | join("\u001f")'

bc_print_repo_table() { # FILE ROWS
  local f="$1" rows="${2:-10}" max total
  max=$(jq '[.branches[].committer_count // 0] | max // 0' "$f")
  total=$(jq '.branches | length' "$f")
  ui_nl
  jq -r --argjson n "$rows" ".branches[:\$n][] | .name as \$label | $_BC_JQ_ROW" "$f" | _bc_table "$max" "BRANCH" 38
  [ "$total" -gt "$rows" ] && ui_hint "… +$((total - rows)) more branches (full list in the report file)"
  return 0
}

bc_print_leaderboard() { # REPORT_FILE
  local f="$1" max
  [ "$(jq '[.repositories[] | select(.error == null)] | length' "$f")" -gt 1 ] || return 0
  max=$(jq '[.repositories[].branches[].committer_count // 0] | max // 0' "$f")
  ui_title "Top 10 busiest branches (all repos)"
  ui_nl
  jq -r "[.repositories[] | .project as \$p | .branches[] | select(.error == null) | . + {label: (\$p + \" › \" + .name)}]
    | sort_by(-.committer_count, -.commit_count) | .[:10][] | .label as \$label | $_BC_JQ_ROW" "$f" |
    _bc_table "$max" "REPO › BRANCH" 52
}

bc_legend() {
  ui_hint "FLAGS: ${CG}D${RST}${DIM}=default  ${CY}P${RST}${DIM}=protected  ${CP}M${RST}${DIM}=merged · COMMITS '+' = capped by --max-commits"
}

# ---------- run ----------
_bc_out_paths() {
  local slug ts dir=""
  ts=$(date +%Y%m%d-%H%M%S)
  if [ "$BC_N" -eq 1 ]; then
    slug=$(printf '%s' "${BC_T_PATH[0]}" | tr '/' '_' | tr -c 'A-Za-z0-9_.-' '-')
  else
    slug="bulk-${BC_N}repos"
  fi
  BC_OUT_JSON=""; BC_OUT_CSV=""
  case "$BC_OUT" in
    -) return 0 ;;
    *.json | *.csv) dir=$(dirname "$BC_OUT"); BC_OUT_JSON="${BC_OUT%.*}.json"; BC_OUT_CSV="${BC_OUT%.*}.csv" ;;
    "") dir="$GLB_ROOT/reports" ;;
    *) dir="${BC_OUT%/}" ;;
  esac
  mkdir -p "$dir" || return 1
  [ -z "$BC_OUT_JSON" ] && BC_OUT_JSON="$dir/branch-committers_${slug}_${ts}.json"
  [ -z "$BC_OUT_CSV" ] && BC_OUT_CSV="$dir/branch-committers_${slug}_${ts}.csv"
  return 0
}

bc_to_csv() { # REPORT_JSON
  jq -r '
    ["project","branch","committer_count","commit_count","is_default","protected","merged",
     "last_commit_at","last_commit_author","truncated","top_committers","branch_url","gitlab_url","error"],
    (.repositories[] as $r
      | if ($r.branches | length) == 0 then
          [$r.project, null, null, null, null, null, null, null, null, null, null, $r.web_url,
           $r.gitlab_url, ($r.error // "no matching branches")]
        else
          $r.branches[] | [$r.project, .name, .committer_count, .commit_count, .default, .protected,
            .merged, .last_commit_at, .last_commit_author, .truncated,
            ((.top_committers // []) | map("\(.name) <\(.email)> (\(.commits))") | join("; ")),
            .web_url, $r.gitlab_url, .error]
        end)
    | @csv' "$1"
}

bc_run() {
  local i t0=$SECONDS report ok fail nbr dur lines=() rc=0
  BC_WORK="$GLB_TMP/bc"
  rm -rf "$BC_WORK"; mkdir -p "$BC_WORK/repos"
  BC_SINCE=""
  [ "$BC_SINCE_DAYS" -gt 0 ] && BC_SINCE=$(jq -nr --argjson d "$BC_SINCE_DAYS" 'now - ($d * 86400) | floor | todate')

  ui_title "Scanning" "profile: $GLB_PROFILE · $GLB_URL"
  bc_expand_targets
  BC_N=${#BC_T_PATH[@]}
  if [ "$BC_N" -eq 0 ]; then ui_err "No valid repos to scan."; return 1; fi

  for ((i = 0; i < BC_N; i++)); do
    bc_scan_repo "$i"
  done

  dur=$((SECONDS - t0))
  report="$BC_WORK/report.json"
  cat "$BC_WORK"/repos/*.json | jq -s --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ver "$GLB_VERSION" \
    --arg since "$BC_SINCE" --argjson days "$BC_SINCE_DAYS" --argjson max "$BC_MAX_COMMITS" \
    --arg ident "$BC_IDENTITY" --arg filter "$BC_FILTER" --argjson dur "$dur" \
    --arg rfilter "$BC_REPO_FILTER" --arg arch "$BC_INCLUDE_ARCHIVED" '
    {
      tool: "branch-committers", gitlabbox_version: $ver, generated_at: $gen, duration_seconds: $dur,
      options: {
        since: (if $since == "" then null else $since end),
        since_days: (if $days > 0 then $days else null end),
        max_commits_per_branch: (if $max > 0 then $max else null end),
        identity: $ident,
        branch_filter: (if $filter == "" then null else $filter end),
        repo_filter: (if $rfilter == "" then null else $rfilter end),
        include_archived: ($arch == "1")
      },
      summary: {
        repos_total: length,
        repos_ok: (map(select(.error == null)) | length),
        repos_failed: (map(select(.error != null)) | length),
        branches_analyzed: (map(.branch_count_analyzed // 0) | add // 0)
      },
      repositories: .
    }' >"$report"

  _bc_out_paths || { ui_err "Cannot create the output folder."; return 1; }
  if [ "$BC_OUT" = - ]; then
    if [ "$BC_FORMAT" = csv ]; then bc_to_csv "$report"; else jq . "$report"; fi
  else
    case "$BC_FORMAT" in json | both) jq . "$report" >"$BC_OUT_JSON" ;; esac
    case "$BC_FORMAT" in csv | both) bc_to_csv "$report" >"$BC_OUT_CSV" ;; esac
  fi

  bc_print_leaderboard "$report"
  ui_nl
  bc_legend

  ok=$(jq '.summary.repos_ok' "$report"); fail=$(jq '.summary.repos_failed' "$report")
  nbr=$(jq '.summary.branches_analyzed' "$report")
  lines+=("${DIM}Repos   ${RST} ${CG}$ok succeeded${RST}$([ "$fail" -gt 0 ] && printf ' · %s%s failed%s' "$CR" "$fail" "$RST")")
  lines+=("${DIM}Branches${RST} $nbr analyzed")
  lines+=("${DIM}Range   ${RST} $([ -n "$BC_SINCE" ] && printf 'since %s (%s days)' "${BC_SINCE:0:10}" "$BC_SINCE_DAYS" || printf 'full history')")
  lines+=("${DIM}Duration${RST} $(ui_duration "$dur")")
  if [ "$BC_OUT" != - ]; then
    case "$BC_FORMAT" in json | both) lines+=("${DIM}JSON    ${RST} ${CC}${BC_OUT_JSON#"$PWD"/}${RST}") ;; esac
    case "$BC_FORMAT" in csv | both) lines+=("${DIM}CSV     ${RST} ${CC}${BC_OUT_CSV#"$PWD"/}${RST}") ;; esac
  fi
  ui_nl
  ui_box "Report ready" "${lines[@]}"
  if [ "$fail" -gt 0 ]; then
    ui_nl
    jq -r '.repositories[] | select(.error != null) | "\(.project)\u001f\(.error)"' "$report" |
      while IFS=$'\x1f' read -r p e; do ui_err "$p ${DIM}— $e${RST}"; done
    rc=3; [ "$ok" -eq 0 ] && rc=1
  fi
  BC_LAST_REPORT="$BC_OUT_JSON"
  return "$rc"
}

# ---------- view saved reports ----------
bc_view_report() { # FILE
  local f="$1" n i
  n=$(jq '.repositories | length' "$f")
  ui_title "$(basename "$f")" "generated $(jq -r '.generated_at' "$f") · $(jq -r '.summary.repos_ok' "$f") repos · $(jq -r '.summary.branches_analyzed' "$f") branches"
  for ((i = 0; i < n; i++)); do
    jq ".repositories[$i]" "$f" >"$GLB_TMP/view.json"
    printf '\n  %s[%d/%d]%s %s%s%s %s%s%s\n' "$DIM" $((i + 1)) "$n" "$RST" "$B" "$(jq -r '.project' "$GLB_TMP/view.json")" "$RST" \
      "$DIM" "$(jq -r 'if .error then "" else "· \(.branch_count_analyzed) branches · \(.unique_committers) unique committers" end' "$GLB_TMP/view.json")" "$RST" >&2
    if [ "$(jq -r '.error // empty' "$GLB_TMP/view.json")" != "" ]; then
      ui_err "$(jq -r '.error' "$GLB_TMP/view.json")"
    else
      bc_print_repo_table "$GLB_TMP/view.json" 10
    fi
  done
  bc_print_leaderboard "$f"
  ui_nl
  bc_legend
}

reports_browse() {
  local files=() labels=() f k
  while IFS= read -r f; do files+=("$f"); done < <(ls -t "$GLB_ROOT"/reports/*.json 2>/dev/null | head -15)
  if [ "${#files[@]}" -eq 0 ]; then ui_warn "No reports yet in $GLB_ROOT/reports"; return; fi
  for f in "${files[@]}"; do
    labels+=("$(basename "$f") $DIM· $(jq -r '"\(.summary.repos_total) repos · \(.summary.branches_analyzed) branches"' "$f" 2>/dev/null)$RST")
  done
  ui_select k "Choose a report" "${labels[@]}" || return
  bc_view_report "${files[$k]}"
}

# ---------- interactive mode ----------
_bc_preview_list() { # FILE — show at most the first 8 lines
  local f="$1" n
  n=$(sed -n '$=' "$f"); n=${n:-0}
  head -8 "$f" | while IFS= read -r line; do ui_hint "• $line"; done
  [ "$n" -gt 8 ] && ui_hint "… +$((n - 8)) more"
  return 0
}

# Pick account scope → fetch repo list → (optional) filter → BC_TARGETS becomes a list of paths.
_bc_pick_account() {
  local k v n scope opts=() scopes=() hints=() all cur
  if [ -z "$GLB_HDR" ]; then
    ui_err "Profile '$GLB_PROFILE' has no token — account mode needs one."
    ui_hint "Add a token via Manage profiles → Change token."
    return 1
  fi
  opts+=("Everything I'm a member of (recommended)"); scopes+=(member)
  hints+=("Direct or via a group — same as 'Your projects' in the GitLab UI")
  opts+=("Only projects I own"); scopes+=(owned)
  hints+=("Projects in your personal namespace / that you own")
  opts+=("Role Developer or higher"); scopes+=(developer)
  hints+=("Skips projects where you are only Guest / Reporter")
  opts+=("Role Maintainer or higher"); scopes+=(maintainer)
  hints+=("Projects you can manage")
  if [ "$GLB_HOST" != gitlab.com ]; then
    opts+=("Everything visible on this instance"); scopes+=(all)
    hints+=("Includes internal/public projects you are not a member of — can be thousands")
  fi
  ui_nl
  UI_HINTS=("${hints[@]}")
  ui_select k "Account repo scope" "${opts[@]}" || return 1
  scope="${scopes[$k]}"
  BC_INCLUDE_ARCHIVED=0
  ui_confirm "Include archived projects?" n && BC_INCLUDE_ARCHIVED=1

  BC_WORK="$GLB_TMP/bc"; mkdir -p "$BC_WORK"
  all="$BC_WORK/acct_all.txt"; cur="$BC_WORK/acct.txt"
  BC_REPO_FILTER=""
  ui_spin_start "Looking up all projects your account can access" "$BC_WORK/list.count"
  if ! bc_fetch_projects account "$scope" "$all"; then
    ui_spin_stop 1 "$API_ERROR"; return 1
  fi
  ui_spin_stop 0 "Account ${B}$BC_ACCOUNT_USER${RST}: ${B}$BC_LIST_TOTAL${RST} projects ${DIM}(scope: $scope · $GLB_HOST)${RST}"
  if [ "$BC_LIST_TOTAL" -eq 0 ]; then ui_warn "No projects in this scope."; return 1; fi
  cp "$all" "$cur"

  while :; do
    n=$(sed -n '$=' "$cur"); n=${n:-0}
    _bc_preview_list "$cur"
    [ "$n" -gt 50 ] && ui_warn "$n repos is a lot — tip: use a 90-day range / branch filter to speed things up."
    UI_HINTS=("" "Comma-separated globs, e.g. backend/*,*-service,my-team/*" "")
    ui_select k "Continue?" "▶  Scan $([ "$n" = 1 ] && printf 'this project' || printf 'these %s projects' "$n")" \
      "🔍 Filter by repo name" "←  Cancel" || return 1
    case "$k" in
      0) [ "$n" -gt 0 ] && break; ui_warn "0 projects — change the filter first." ;;
      1)
        ui_input v "Repo filter (glob, empty = all)" "$BC_REPO_FILTER"
        BC_REPO_FILTER="$v"
        _bc_glob_lines "$v" <"$all" >"$cur"
        n=$(sed -n '$=' "$cur"); n=${n:-0}
        ui_ok "$n of $BC_LIST_TOTAL projects match"
        ;;
      2) return 1 ;;
    esac
  done

  BC_TARGETS=()
  while IFS= read -r v; do BC_TARGETS+=("$v"); done <"$cur"
  BC_ACCOUNT_LABEL="account $BC_ACCOUNT_USER · scope $scope · ${#BC_TARGETS[@]} projects"
  [ -n "$BC_REPO_FILTER" ] && BC_ACCOUNT_LABEL="$BC_ACCOUNT_LABEL (filter '$BC_REPO_FILTER')"
  return 0
}

bc_interactive() {
  local k v line src_label win_label adv_label
  bc_defaults
  ui_title "$TOOL_BC_NAME" "List branches per repo, sorted from most committers → fewest."
  ui_nl

  if [ -z "$(cfg_resolve_name "")" ] && [ "$(cfg_count)" = 0 ]; then
    ui_warn "No GitLab connection yet."
    ui_confirm "Set up a connection now?" y || return
    setup_wizard || return
    ui_nl
  fi
  pick_profile "Which connection?" include_env || return
  BC_PROFILE="$PICKED_PROFILE"
  bc_prepare_profile || return

  # repo source
  UI_HINTS=("Type a path (group/project), ID, or URL — several allowed, comma/space separated"
    "Auto-detect every repo your token can access (member / owner / minimum role)"
    ".txt file, one repo per line. Mix URLs/paths/IDs freely, '#' for comments"
    "Auto-detect every project in one group + its subgroups")
  ui_select k "Where do the repos come from?" "Type them in (single / several)" "All repos my account can access" \
    "Bulk from a .txt file" "Every project in a group" || return
  # index 1 = account mode; shift the rest so the case below stays 0/1/2
  if [ "$k" = 1 ]; then
    _bc_pick_account || return
    src_label="$BC_ACCOUNT_LABEL"
    k=-1
  elif [ "$k" -gt 1 ]; then
    k=$((k - 1))
  fi
  case "$k" in
    0)
      while :; do
        ui_input v "Repo" "" plain
        [ -n "$v" ] && break
        ui_hint "e.g. my-group/my-app  or  https://$GLB_HOST/my-group/my-app"
      done
      while IFS= read -r line; do BC_TARGETS+=("$line"); done < <(split_targets "$v")
      src_label="${#BC_TARGETS[@]} repos (manual)"
      ;;
    1)
      while :; do
        ui_input v ".txt file path" "$GLB_ROOT/repos.txt" path
        if [ ! -f "$v" ]; then ui_warn "File '$v' not found. ${DIM}(Tab to autocomplete)${RST}"; continue; fi
        BC_TARGETS=()
        while IFS= read -r line; do BC_TARGETS+=("$line"); done < <(read_targets_file "$v")
        [ "${#BC_TARGETS[@]}" -gt 0 ] && break
        ui_warn "The file is empty (or contains only comments)."
      done
      ui_ok "${#BC_TARGETS[@]} lines read:"
      printf '%s\n' "${BC_TARGETS[@]}" | head -5 | while IFS= read -r line; do ui_hint "• $line"; done
      [ "${#BC_TARGETS[@]}" -gt 5 ] && ui_hint "… +$((${#BC_TARGETS[@]} - 5)) more"
      src_label="$(basename "$v") (${#BC_TARGETS[@]} lines)"
      ;;
    2)
      while :; do
        ui_input v "Group path" "" plain
        [ -n "$v" ] && break
      done
      parse_target "$v" && v="$T_PATH"
      BC_TARGETS=("group:$v")
      src_label="group $v (+subgroups)"
      ;;
  esac

  # time range
  ui_nl
  UI_HINTS=("Most accurate, but slow for big repos" "" "Recommended for routine audits" "" "" "")
  ui_select k "Count commits since when?" "Full history" "Last 30 days" "Last 90 days" \
    "Last 180 days" "Last year" "Custom (number of days)" || return
  case "$k" in
    0) BC_SINCE_DAYS=0 ;; 1) BC_SINCE_DAYS=30 ;; 2) BC_SINCE_DAYS=90 ;; 3) BC_SINCE_DAYS=180 ;; 4) BC_SINCE_DAYS=365 ;;
    5) while :; do ui_input v "How many days back" "60"; _bc_is_int "$v" && break; done; BC_SINCE_DAYS=$v ;;
  esac
  win_label="full history"; [ "$BC_SINCE_DAYS" -gt 0 ] && win_label="last $BC_SINCE_DAYS days"

  # advanced options
  UI_HINTS=("all branches · author identity · max $BC_MAX_COMMITS commits/branch · $BC_WORKERS workers"
    "Branch filter, author vs committer, commit cap, worker count")
  ui_select k "Advanced options" "Use defaults (recommended)" "Customize" || return
  if [ "$k" = 1 ]; then
    ui_hint "Glob filter, comma-separated. E.g. main,develop,release/*  (empty = all)"
    ui_input BC_FILTER "Branch filter" ""
    UI_HINTS=("Whoever wrote the code (usually what people mean by 'committer')"
      "Whoever committed/applied it (differs after rebase, cherry-pick, merge via UI)")
    ui_select k "Count by" "Author" "Committer" || return
    BC_IDENTITY=author; [ "$k" = 1 ] && BC_IDENTITY=committer
    UI_SELECT_DEFAULT=1
    UI_HINTS=("Fast, fine for short-lived branches" "Balanced (default)" "For monorepos / long histories" "Can be very slow + many API requests")
    ui_select k "Commit cap per branch" "1,000" "5,000" "20,000" "No limit" || return
    case "$k" in 0) BC_MAX_COMMITS=1000 ;; 1) BC_MAX_COMMITS=5000 ;; 2) BC_MAX_COMMITS=20000 ;; 3) BC_MAX_COMMITS=0 ;; esac
    while :; do ui_input v "Parallel workers" "$BC_WORKERS"; _bc_is_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le 32 ] && break; ui_warn "Enter 1–32"; done
    BC_WORKERS=$v
  fi
  adv_label="$BC_IDENTITY · max $([ "$BC_MAX_COMMITS" -gt 0 ] && printf '%s' "$BC_MAX_COMMITS" || printf '∞') commits/branch · $BC_WORKERS workers"
  [ -n "$BC_FILTER" ] && adv_label="filter '$BC_FILTER' · $adv_label"

  # format & output
  ui_nl
  UI_HINTS=("Complete: every committer per branch, nested per repo" "Flat, one row per branch — great for Excel/Sheets" "Both")
  ui_select k "Report format" "JSON" "CSV" "JSON + CSV" || return
  case "$k" in 0) BC_FORMAT=json ;; 1) BC_FORMAT=csv ;; 2) BC_FORMAT=both ;; esac
  ui_input BC_OUT "Output folder" "$GLB_ROOT/reports" path

  # summary
  ui_nl
  ui_box "Ready to run" \
    "${DIM}Connect ${RST} $(profile_label "$BC_PROFILE")" \
    "${DIM}Repos   ${RST} $src_label" \
    "${DIM}Range   ${RST} $win_label" \
    "${DIM}Options ${RST} $adv_label" \
    "${DIM}Output  ${RST} $(printf '%s' "$BC_FORMAT" | tr '[:lower:]' '[:upper:]') → $(_bc_tilde "$BC_OUT")"
  ui_nl
  UI_HINTS=("" "Answer all questions again" "Back to the main menu")
  ui_select k "Go?" "🚀 Run it!" "✏️  Start over" "✖  Cancel" || return
  case "$k" in
    1) bc_interactive; return ;;
    2) return ;;
  esac

  bc_run
  ui_nl
  UI_HINTS=("" "Open in Finder / file manager" "")
  ui_select k "Next?" "← Back to the main menu" "📂 Open the report folder" "Quit" || return
  case "$k" in
    1) if command -v open >/dev/null; then open "$(dirname "${BC_LAST_REPORT:-$BC_OUT_CSV}")"; else xdg-open "$(dirname "${BC_LAST_REPORT:-$BC_OUT_CSV}")" >/dev/null 2>&1; fi ;;
    2) exit 0 ;;
  esac
}

# ---------- flag mode / CLI (for scripts & CI) ----------
bc_usage() {
  cat >&2 <<EOF

  ${B}gitlabbox.sh branches${RST} — $TOOL_BC_NAME

  ${B}Repo sources${RST} (can be mixed & repeated)
    -r, --repo REPO          path / ID / URL. Several allowed: -r a/b -r c/d or "a/b,c/d"
    -f, --file FILE          .txt file, one repo per line (# = comment, group:xxx = a whole group)
    -g, --group GROUP        every project in the group + subgroups
    -a, --account SCOPE      every project your account/token can access. SCOPE:
                               member (direct / via group) · owned · reporter
                               developer · maintainer (minimum role) · all (self-hosted only)
        --mine               shorthand for --account member
        --repo-filter GLOB   filter group/account results, comma-separated. e.g. 'backend/*,*-svc'
        --include-archived   include archived projects (skipped by default)

  ${B}Connection${RST}
    -p, --profile NAME       profile from 'gitlabbox.sh setup' (default: the default profile)
                             without config: uses env GITLAB_URL + GITLAB_TOKEN

  ${B}Analysis${RST}
    -d, --since-days N       only count commits from the last N days (default: full history)
        --all-history        force full history
    -m, --max-commits N      max commits read per branch (default 5000, 0 = no limit)
    -b, --branch-filter GLOB branch name filter, comma-separated. e.g. 'main,release/*'
        --identity WHO       author (default) | committer
    -w, --workers N          parallel requests per repo (default 6)
        --top N              top committers per branch in the report (default 5)

  ${B}Output${RST}
    -F, --format FMT         json (default) | csv | both
    -o, --out PATH           folder, file name (.json/.csv), or '-' for stdout
        --rows N             table rows per repo on screen (default 10)

  ${B}Examples${RST}
    ./gitlabbox.sh branches -r my-group/my-app
    ./gitlabbox.sh branches -f repos.txt -d 90 -F both
    ./gitlabbox.sh branches -g my-org/backend -b 'main,release/*' -o reports/
    ./gitlabbox.sh branches --mine -d 90 -F both
    ./gitlabbox.sh branches -a developer --repo-filter 'payments/*' -p work
    GITLAB_URL=https://gitlab.example.com GITLAB_TOKEN=\$TOKEN ./gitlabbox.sh branches -r 123 -o - | jq .summary

  ${DIM}Exit codes: 0 all succeeded · 3 some repos failed · 1 total failure / input error${RST}

EOF
}

bc_cli() {
  local line
  bc_defaults
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
    esac
    case "$1" in
      -h | --help) bc_usage; return 0 ;;
      -p | --profile) BC_PROFILE="$2"; shift 2 ;;
      -r | --repo)
        while IFS= read -r line; do BC_TARGETS+=("$line"); done < <(split_targets "$2"); shift 2 ;;
      -f | --file)
        [ -f "$2" ] || { ui_err "File '$2' not found."; return 1; }
        while IFS= read -r line; do BC_TARGETS+=("$line"); done < <(read_targets_file "$2"); shift 2 ;;
      -g | --group) BC_TARGETS+=("group:$2"); shift 2 ;;
      -a | --account)
        case " $BC_ACCOUNT_SCOPES " in *" $2 "*) ;; *) ui_err "--account: $BC_ACCOUNT_SCOPES"; return 1 ;; esac
        BC_TARGETS+=("account:$2"); shift 2 ;;
      --mine) BC_TARGETS+=("account:member"); shift ;;
      --repo-filter) BC_REPO_FILTER="$2"; shift 2 ;;
      --include-archived) BC_INCLUDE_ARCHIVED=1; shift ;;
      -d | --since-days) _bc_is_int "$2" || { ui_err "--since-days must be a number"; return 1; }; BC_SINCE_DAYS="$2"; shift 2 ;;
      --all-history) BC_SINCE_DAYS=0; shift ;;
      -m | --max-commits) _bc_is_int "$2" || { ui_err "--max-commits must be a number"; return 1; }; BC_MAX_COMMITS="$2"; shift 2 ;;
      -b | --branch-filter) BC_FILTER="$2"; shift 2 ;;
      --identity)
        case "$2" in author | committer) BC_IDENTITY="$2" ;; *) ui_err "--identity: author | committer"; return 1 ;; esac
        shift 2 ;;
      -w | --workers) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--workers must be at least 1"; return 1; }; BC_WORKERS="$2"; shift 2 ;;
      --top) _bc_is_int "$2" || { ui_err "--top must be a number"; return 1; }; BC_TOP="$2"; shift 2 ;;
      --rows) _bc_is_int "$2" || { ui_err "--rows must be a number"; return 1; }; BC_ROWS="$2"; shift 2 ;;
      -F | --format)
        case "$2" in json | csv | both) BC_FORMAT="$2" ;; *) ui_err "--format: json | csv | both"; return 1 ;; esac
        shift 2 ;;
      -o | --out) BC_OUT="$2"; shift 2 ;;
      -*) ui_err "Unknown option: $1"; bc_usage; return 1 ;;
      *) BC_TARGETS+=("$1"); shift ;;
    esac
  done
  if [ "${#BC_TARGETS[@]}" -eq 0 ]; then
    ui_err "No repos given. Use -r, -f, -g, or -a."
    bc_usage
    return 1
  fi
  if [ "$BC_OUT" = - ] && [ "$BC_FORMAT" = both ]; then ui_err "-o - supports a single format only (json or csv)."; return 1; fi
  bc_prepare_profile || return 1
  bc_run
}
