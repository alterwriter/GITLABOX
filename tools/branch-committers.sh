# shellcheck shell=bash
# tools/branch-committers.sh — list branch per repo + jumlah committer unik,
# diurutin dari committer terbanyak ke paling sedikit. Export JSON / CSV.
#
# API GitLab yang dipakai (semua read-only, scope read_api):
#   GET /projects/:id                                   resolve path → ID
#   GET /groups/:id/projects?include_subgroups=true     kalau input group:...
#   GET /projects/:id/repository/branches               daftar branch
#   GET /projects/:id/repository/commits?ref_name=BR    commit per branch
#                                                       (opsional &since=ISO8601)
# Committer unik = dihitung dari email (lowercase) author/committer tiap commit.

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

# Hasil per branch (dijalanin worker). Input: branches.json, --slurpfile c commits.
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
    ui_err "Belum ada profile GitLab. Jalanin: ./gitlabbox.sh setup"
    ui_hint "Atau buat CI: export GITLAB_URL=https://gitlab.example.com GITLAB_TOKEN=glpat-xxx"
    return 1
  fi
  if ! use_profile "$BC_PROFILE"; then
    ui_err "Profile '$BC_PROFILE' gak ketemu. Cek: ./gitlabbox.sh profiles"
    return 1
  fi
  BC_BASE_HOST="$GLB_HOST"
}

bc_bind_profile() { # bc_bind_profile HOST → aktifin profile yang cocok
  local host="$1" p="$BC_PROFILE"
  BC_BIND_ERR=
  if [ -n "$host" ] && [ "$host" != "$BC_BASE_HOST" ]; then
    if ! p=$(cfg_find_by_host "$host"); then
      BC_BIND_ERR="Host '$host' belum punya profile — tambahin via ./gitlabbox.sh setup"
      return 1
    fi
  fi
  [ "$GLB_PROFILE" = "$p" ] && return 0
  use_profile "$p" || { BC_BIND_ERR="Profile '$p' gak valid"; return 1; }
}

_bc_strip_prefix() { # URL self-hosted di sub-path (https://host/gitlab/...)
  local p="$1" pre="${GLB_URL_PATH#/}"
  if [ -n "$pre" ] && [ -n "$2" ]; then
    case "$p" in "$pre"/*) p="${p#"$pre"/}" ;; esac
  fi
  printf '%s' "$p"
}

# ---------- expand target (group → project) ----------
_bc_add() { # _bc_add HOST PATH ERR
  local key="$1|$2"
  [ "$1" = "$BC_BASE_HOST" ] && key="|$2"   # gitlab.com/a/b == a/b
  case "$BC_SEEN" in *"|$key|"*) return 0 ;; esac
  BC_SEEN="$BC_SEEN$key|"
  BC_T_HOST+=("$1"); BC_T_PATH+=("$2"); BC_T_ERR+=("$3")
}

# stdin: baris teks → print yang match salah satu glob (pisah koma). Pola kosong = semua.
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

# Scope akun → query /projects
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
#   ambil daftar project (pakai profile aktif) → 1 path_with_namespace per baris,
#   udah difilter BC_REPO_FILTER. Set BC_LIST_TOTAL (sebelum filter) & BC_ACCOUNT_USER.
bc_fetch_projects() {
  local kind="$1" arg="$2" out="$3" raw="$3.raw" path q arch="&archived=false"
  [ "$BC_INCLUDE_ARCHIVED" = 1 ] && arch=""
  if [ "$kind" = group ]; then
    path="/groups/$(_uri "$arg")/projects?include_subgroups=true&simple=true&order_by=path&sort=asc$arch"
  else
    if [ -z "$GLB_HDR" ]; then API_ERROR="Mode akun butuh token — tanpa token gak ada 'akun' yang bisa dicek."; return 1; fi
    if ! q=$(_bc_account_query "$arg"); then API_ERROR="Scope '$arg' gak dikenal. Pilihan: $BC_ACCOUNT_SCOPES"; return 1; fi
    if [ "$arg" = all ] && [ "$GLB_HOST" = gitlab.com ]; then
      API_ERROR="Scope 'all' di gitlab.com = semua repo publik sedunia. Pakai 'member'."; return 1
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
    if ! parse_target "$t"; then ui_warn "Skip, input gak valid: $t"; continue; fi
    [ "$T_KIND" = project ] && { _bc_add "$T_HOST" "$T_PATH" ""; continue; }
    case "$BC_SEEN" in *"|@$T_KIND:$T_PATH@${T_HOST:-$BC_BASE_HOST}|"*) continue ;; esac
    BC_SEEN="$BC_SEEN@$T_KIND:$T_PATH@${T_HOST:-$BC_BASE_HOST}|"
    if ! bc_bind_profile "$T_HOST"; then
      _bc_add "$T_HOST" "$T_KIND:$T_PATH" "$BC_BIND_ERR"; continue
    fi
    if [ "$T_KIND" = group ]; then
      arg=$(_bc_strip_prefix "$T_PATH" "$T_HOST"); label="group ${B}$arg${RST}"
    else
      arg="$T_PATH"; label="project yang bisa diakses akun lu ${DIM}(scope: $arg · $GLB_HOST)${RST}"
    fi
    ui_spin_start "Nyari semua $label" "$BC_WORK/list.count"
    if bc_fetch_projects "$T_KIND" "$arg" "$list"; then
      n=$(sed -n '$=' "$list"); n=${n:-0}
      [ "$T_KIND" = account ] && label="Akun ${B}$BC_ACCOUNT_USER${RST} ${DIM}(scope: $arg · $GLB_HOST)${RST}"
      if [ -n "$BC_REPO_FILTER" ]; then
        ui_spin_stop 0 "$label: $BC_LIST_TOTAL project → ${B}$n${RST} cocok filter ${CC}$BC_REPO_FILTER${RST}"
      else
        ui_spin_stop 0 "$label: ${B}$n${RST} project"
      fi
      while IFS= read -r p; do _bc_add "$T_HOST" "$p" ""; done <"$list"
    else
      ui_spin_stop 1 "$T_KIND:$arg — $API_ERROR"
      _bc_add "$T_HOST" "$T_KIND:$arg" "$API_ERROR"
    fi
    rm -f "$BC_WORK/list.count"
  done
}

# ---------- worker (1 proses per branch, jalan paralel via xargs -P) ----------
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

# ---------- scan 1 repo ----------
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
    ui_spin_stop 1 "Project gagal diakses: $API_ERROR"
    _bc_repo_error "$out" "$path" "$API_ERROR"; return 1
  fi
  pid=$(jq -r '.id' "$rdir/project.json")
  pname=$(jq -r '.path_with_namespace' "$rdir/project.json")
  defb=$(jq -r '.default_branch // "-"' "$rdir/project.json")
  vis=$(jq -r '.visibility // "-"' "$rdir/project.json")
  ui_spin_stop 0 "Project ${B}$pname${RST} ${DIM}· id $pid · $vis · default: $defb · $GLB_HOST${RST}"

  ui_spin_start "Ngambil daftar branch" "$rdir/count"
  if ! api_get_all "/projects/$pid/repository/branches" "$rdir/branches_all.json" 0 "$rdir/count"; then
    ui_spin_stop 1 "Gagal ambil branch: $API_ERROR"
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
    ui_spin_stop 0 "$n dari $total branch cocok filter ${CC}$BC_FILTER${RST}"
  else
    ui_spin_stop 0 "$total branch ketemu"
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
      ui_progress "$d" "$n" "ngitung committer per branch ${DIM}($BC_WORKERS worker)${RST}"
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
  ui_ok "$n branch dianalisis · ${B}$uniq${RST} committer unik (gabungan semua branch) · $(ui_duration $((SECONDS - t0)))"
  [ "$nerr" -gt 0 ] && ui_warn "$nerr branch gagal dibaca (detail di kolom error report)"
  [ "$n" -gt 0 ] && bc_print_repo_table "$out" "$BC_ROWS"
  rm -rf "$rdir"
  return 0
}

_bc_filter_branches() { # IN OUT — filter pakai glob bash, pisah koma: "main,release/*"
  local in="$1" out="$2" keep="$BC_WORK/keep.txt"
  jq -r '.[].name' "$in" | _bc_glob_lines "$BC_FILTER" >"$keep"
  jq --rawfile k "$keep" '($k | split("\n") | map(select(. != "")) | map({(.): true}) | add // {}) as $s
    | map(select($s[.name]))' "$in" >"$out"
}

# ---------- tampilan tabel ----------
# stdin: baris "label␟committers␟commits␟truncated␟last␟default␟protected␟merged␟top␟error"
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
  [ "$total" -gt "$rows" ] && ui_hint "… +$((total - rows)) branch lagi (lengkapnya di file report)"
  return 0
}

bc_print_leaderboard() { # REPORT_FILE
  local f="$1" max
  [ "$(jq '[.repositories[] | select(.error == null)] | length' "$f")" -gt 1 ] || return 0
  max=$(jq '[.repositories[].branches[].committer_count // 0] | max // 0' "$f")
  ui_title "Top 10 branch paling rame (semua repo)"
  ui_nl
  jq -r "[.repositories[] | .project as \$p | .branches[] | select(.error == null) | . + {label: (\$p + \" › \" + .name)}]
    | sort_by(-.committer_count, -.commit_count) | .[:10][] | .label as \$label | $_BC_JQ_ROW" "$f" |
    _bc_table "$max" "REPO › BRANCH" 52
}

bc_legend() {
  ui_hint "FLAGS: ${CG}D${RST}${DIM}=default  ${CY}P${RST}${DIM}=protected  ${CP}M${RST}${DIM}=merged · COMMITS '+' = kepotong batas --max-commits"
}

# ---------- jalanin ----------
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
           $r.gitlab_url, ($r.error // "gak ada branch yang cocok")]
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
  if [ "$BC_N" -eq 0 ]; then ui_err "Gak ada repo valid buat discan."; return 1; fi

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

  _bc_out_paths || { ui_err "Gak bisa bikin folder output."; return 1; }
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
  lines+=("${DIM}Repo    ${RST} ${CG}$ok sukses${RST}$([ "$fail" -gt 0 ] && printf ' · %s%s gagal%s' "$CR" "$fail" "$RST")")
  lines+=("${DIM}Branch  ${RST} $nbr dianalisis")
  lines+=("${DIM}Rentang ${RST} $([ -n "$BC_SINCE" ] && printf 'sejak %s (%s hari)' "${BC_SINCE:0:10}" "$BC_SINCE_DAYS" || printf 'semua history')")
  lines+=("${DIM}Durasi  ${RST} $(ui_duration "$dur")")
  if [ "$BC_OUT" != - ]; then
    case "$BC_FORMAT" in json | both) lines+=("${DIM}JSON    ${RST} ${CC}${BC_OUT_JSON#"$PWD"/}${RST}") ;; esac
    case "$BC_FORMAT" in csv | both) lines+=("${DIM}CSV     ${RST} ${CC}${BC_OUT_CSV#"$PWD"/}${RST}") ;; esac
  fi
  ui_nl
  ui_box "Report siap" "${lines[@]}"
  if [ "$fail" -gt 0 ]; then
    ui_nl
    jq -r '.repositories[] | select(.error != null) | "\(.project)\u001f\(.error)"' "$report" |
      while IFS=$'\x1f' read -r p e; do ui_err "$p ${DIM}— $e${RST}"; done
    rc=3; [ "$ok" -eq 0 ] && rc=1
  fi
  BC_LAST_REPORT="$BC_OUT_JSON"
  return "$rc"
}

# ---------- lihat report tersimpan ----------
bc_view_report() { # FILE
  local f="$1" n i
  n=$(jq '.repositories | length' "$f")
  ui_title "$(basename "$f")" "dibuat $(jq -r '.generated_at' "$f") · $(jq -r '.summary.repos_ok' "$f") repo · $(jq -r '.summary.branches_analyzed' "$f") branch"
  for ((i = 0; i < n; i++)); do
    jq ".repositories[$i]" "$f" >"$GLB_TMP/view.json"
    printf '\n  %s[%d/%d]%s %s%s%s %s%s%s\n' "$DIM" $((i + 1)) "$n" "$RST" "$B" "$(jq -r '.project' "$GLB_TMP/view.json")" "$RST" \
      "$DIM" "$(jq -r 'if .error then "" else "· \(.branch_count_analyzed) branch · \(.unique_committers) committer unik" end' "$GLB_TMP/view.json")" "$RST" >&2
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
  if [ "${#files[@]}" -eq 0 ]; then ui_warn "Belum ada report di $GLB_ROOT/reports"; return; fi
  for f in "${files[@]}"; do
    labels+=("$(basename "$f") $DIM· $(jq -r '"\(.summary.repos_total) repo · \(.summary.branches_analyzed) branch"' "$f" 2>/dev/null)$RST")
  done
  ui_select k "Pilih report" "${labels[@]}" || return
  bc_view_report "${files[$k]}"
}

# ---------- mode interaktif ----------
_bc_preview_list() { # FILE — tampilin max 8 baris pertama
  local f="$1" n
  n=$(sed -n '$=' "$f"); n=${n:-0}
  head -8 "$f" | while IFS= read -r line; do ui_hint "• $line"; done
  [ "$n" -gt 8 ] && ui_hint "… +$((n - 8)) lagi"
  return 0
}

# Pilih scope akun → ambil daftar repo → (opsional) filter → BC_TARGETS jadi daftar path.
_bc_pick_account() {
  local k v n scope opts=() scopes=() hints=() all cur
  if [ -z "$GLB_HDR" ]; then
    ui_err "Profile '$GLB_PROFILE' gak pakai token — mode akun butuh token."
    ui_hint "Tambahin token lewat menu Kelola profile → Ganti token."
    return 1
  fi
  opts+=("Semua yang gw member (rekomendasi)"); scopes+=(member)
  hints+=("Member langsung atau lewat group — sama kayak 'Your projects' di UI GitLab")
  opts+=("Yang gw owner aja"); scopes+=(owned)
  hints+=("Project di namespace pribadi lu / yang lu owner")
  opts+=("Minimal role Developer"); scopes+=(developer)
  hints+=("Skip project yang lu cuma Guest / Reporter")
  opts+=("Minimal role Maintainer"); scopes+=(maintainer)
  hints+=("Project yang lu bisa manage")
  if [ "$GLB_HOST" != gitlab.com ]; then
    opts+=("Semua yang visible di instance ini"); scopes+=(all)
    hints+=("Termasuk project internal/public walau lu bukan member — bisa ribuan")
  fi
  ui_nl
  UI_HINTS=("${hints[@]}")
  ui_select k "Scope repo akun lu" "${opts[@]}" || return 1
  scope="${scopes[$k]}"
  BC_INCLUDE_ARCHIVED=0
  ui_confirm "Ikut sertain project yang di-archive?" n && BC_INCLUDE_ARCHIVED=1

  BC_WORK="$GLB_TMP/bc"; mkdir -p "$BC_WORK"
  all="$BC_WORK/acct_all.txt"; cur="$BC_WORK/acct.txt"
  BC_REPO_FILTER=""
  ui_spin_start "Nyari semua project yang bisa diakses akun lu" "$BC_WORK/list.count"
  if ! bc_fetch_projects account "$scope" "$all"; then
    ui_spin_stop 1 "$API_ERROR"; return 1
  fi
  ui_spin_stop 0 "Akun ${B}$BC_ACCOUNT_USER${RST}: ${B}$BC_LIST_TOTAL${RST} project ${DIM}(scope: $scope · $GLB_HOST)${RST}"
  if [ "$BC_LIST_TOTAL" -eq 0 ]; then ui_warn "Gak ada project di scope ini."; return 1; fi
  cp "$all" "$cur"

  while :; do
    n=$(sed -n '$=' "$cur"); n=${n:-0}
    _bc_preview_list "$cur"
    [ "$n" -gt 50 ] && ui_warn "$n repo itu banyak — saran: pakai rentang 90 hari / filter branch biar cepet."
    UI_HINTS=("" "Glob pisah koma, misal: backend/*,*-service,my-team/*" "")
    ui_select k "Lanjut?" "▶  Scan $n project ini" "🔍 Filter nama repo" "←  Batal" || return 1
    case "$k" in
      0) [ "$n" -gt 0 ] && break; ui_warn "0 project — ganti filter dulu." ;;
      1)
        ui_input v "Filter repo (glob, kosong = semua)" "$BC_REPO_FILTER"
        BC_REPO_FILTER="$v"
        _bc_glob_lines "$v" <"$all" >"$cur"
        n=$(sed -n '$=' "$cur"); n=${n:-0}
        ui_ok "$n dari $BC_LIST_TOTAL project cocok"
        ;;
      2) return 1 ;;
    esac
  done

  BC_TARGETS=()
  while IFS= read -r v; do BC_TARGETS+=("$v"); done <"$cur"
  BC_ACCOUNT_LABEL="akun $BC_ACCOUNT_USER · scope $scope · ${#BC_TARGETS[@]} project"
  [ -n "$BC_REPO_FILTER" ] && BC_ACCOUNT_LABEL="$BC_ACCOUNT_LABEL (filter '$BC_REPO_FILTER')"
  return 0
}

bc_interactive() {
  local k v line src_label win_label adv_label
  bc_defaults
  ui_title "$TOOL_BC_NAME" "List branch per repo, urut dari committer terbanyak → paling dikit."
  ui_nl

  if [ -z "$(cfg_resolve_name "")" ] && [ "$(cfg_count)" = 0 ]; then
    ui_warn "Belum ada koneksi GitLab."
    ui_confirm "Setup koneksi sekarang?" y || return
    setup_wizard || return
    ui_nl
  fi
  pick_profile "Pakai koneksi yang mana?" include_env || return
  BC_PROFILE="$PICKED_PROFILE"
  bc_prepare_profile || return

  # sumber repo
  UI_HINTS=("Ketik path (group/project), ID, atau URL — bisa beberapa, pisah koma/spasi"
    "Auto-detect semua repo yang token lu bisa akses (member / owner / role tertentu)"
    "File .txt, 1 repo per baris. Boleh campur URL/path/ID, '#' buat komentar"
    "Auto-detect semua project di 1 group + subgroup-nya")
  ui_select k "Repo-nya dari mana?" "Ketik langsung (single / beberapa)" "Semua repo yang bisa diakses akun gw" \
    "Bulk dari file .txt" "Semua project di group" || return
  # index 1 = mode akun; geser sisanya biar case di bawah tetep 0/1/2
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
        ui_hint "contoh: my-group/my-app  atau  https://$GLB_HOST/my-group/my-app"
      done
      while IFS= read -r line; do BC_TARGETS+=("$line"); done < <(split_targets "$v")
      src_label="${#BC_TARGETS[@]} repo (manual)"
      ;;
    1)
      while :; do
        ui_input v "Path file .txt" "$GLB_ROOT/repos.txt" path
        if [ ! -f "$v" ]; then ui_warn "File '$v' gak ketemu. ${DIM}(Tab buat autocomplete)${RST}"; continue; fi
        BC_TARGETS=()
        while IFS= read -r line; do BC_TARGETS+=("$line"); done < <(read_targets_file "$v")
        [ "${#BC_TARGETS[@]}" -gt 0 ] && break
        ui_warn "File-nya kosong (atau isinya komentar semua)."
      done
      ui_ok "${#BC_TARGETS[@]} baris kebaca:"
      printf '%s\n' "${BC_TARGETS[@]}" | head -5 | while IFS= read -r line; do ui_hint "• $line"; done
      [ "${#BC_TARGETS[@]}" -gt 5 ] && ui_hint "… +$((${#BC_TARGETS[@]} - 5)) lagi"
      src_label="$(basename "$v") (${#BC_TARGETS[@]} baris)"
      ;;
    2)
      while :; do
        ui_input v "Path group" "" plain
        [ -n "$v" ] && break
      done
      parse_target "$v" && v="$T_PATH"
      BC_TARGETS=("group:$v")
      src_label="group $v (+subgroup)"
      ;;
  esac

  # rentang waktu
  ui_nl
  UI_HINTS=("Paling akurat, tapi lama buat repo gede" "" "Rekomendasi buat audit rutin" "" "" "")
  ui_select k "Hitung commit dari kapan?" "Semua history" "30 hari terakhir" "90 hari terakhir" \
    "180 hari terakhir" "1 tahun terakhir" "Custom (jumlah hari)" || return
  case "$k" in
    0) BC_SINCE_DAYS=0 ;; 1) BC_SINCE_DAYS=30 ;; 2) BC_SINCE_DAYS=90 ;; 3) BC_SINCE_DAYS=180 ;; 4) BC_SINCE_DAYS=365 ;;
    5) while :; do ui_input v "Berapa hari ke belakang" "60"; _bc_is_int "$v" && break; done; BC_SINCE_DAYS=$v ;;
  esac
  win_label="semua history"; [ "$BC_SINCE_DAYS" -gt 0 ] && win_label="$BC_SINCE_DAYS hari terakhir"

  # opsi lanjutan
  UI_HINTS=("semua branch · identitas author · max $BC_MAX_COMMITS commit/branch · $BC_WORKERS worker"
    "Filter branch, author vs committer, batas commit, jumlah worker")
  ui_select k "Opsi lanjutan" "Pakai default (rekomendasi)" "Atur sendiri" || return
  if [ "$k" = 1 ]; then
    ui_hint "Filter pakai glob, pisah koma. Contoh: main,develop,release/*  (kosong = semua)"
    ui_input BC_FILTER "Filter branch" ""
    UI_HINTS=("Orang yang nulis kodenya (biasanya ini yang dimaksud 'committer')"
      "Orang yang nge-commit/apply (beda kalau rebase, cherry-pick, merge via UI)")
    ui_select k "Hitung berdasarkan" "Author" "Committer" || return
    BC_IDENTITY=author; [ "$k" = 1 ] && BC_IDENTITY=committer
    UI_SELECT_DEFAULT=1
    UI_HINTS=("Cepet, cocok buat branch pendek" "Seimbang (default)" "Buat repo monorepo / history panjang" "Bisa lama banget + boros request API")
    ui_select k "Batas commit per branch" "1.000" "5.000" "20.000" "Tanpa batas" || return
    case "$k" in 0) BC_MAX_COMMITS=1000 ;; 1) BC_MAX_COMMITS=5000 ;; 2) BC_MAX_COMMITS=20000 ;; 3) BC_MAX_COMMITS=0 ;; esac
    while :; do ui_input v "Jumlah worker paralel" "$BC_WORKERS"; _bc_is_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le 32 ] && break; ui_warn "Isi 1–32"; done
    BC_WORKERS=$v
  fi
  adv_label="$BC_IDENTITY · max $([ "$BC_MAX_COMMITS" -gt 0 ] && printf '%s' "$BC_MAX_COMMITS" || printf '∞') commit/branch · $BC_WORKERS worker"
  [ -n "$BC_FILTER" ] && adv_label="filter '$BC_FILTER' · $adv_label"

  # format & output
  ui_nl
  UI_HINTS=("Lengkap: semua committer per branch, nested per repo" "Flat 1 baris per branch, enak buat Excel/Sheets" "Dua-duanya")
  ui_select k "Format report" "JSON" "CSV" "JSON + CSV" || return
  case "$k" in 0) BC_FORMAT=json ;; 1) BC_FORMAT=csv ;; 2) BC_FORMAT=both ;; esac
  ui_input BC_OUT "Folder output" "$GLB_ROOT/reports" path

  # ringkasan
  ui_nl
  ui_box "Siap jalan" \
    "${DIM}Koneksi ${RST} $(profile_label "$BC_PROFILE")" \
    "${DIM}Repo    ${RST} $src_label" \
    "${DIM}Rentang ${RST} $win_label" \
    "${DIM}Opsi    ${RST} $adv_label" \
    "${DIM}Output  ${RST} $(printf '%s' "$BC_FORMAT" | tr '[:lower:]' '[:upper:]') → $(_bc_tilde "$BC_OUT")"
  ui_nl
  UI_HINTS=("" "Isi ulang semua pertanyaan" "Balik ke menu utama")
  ui_select k "Gas?" "🚀 Gas jalanin!" "✏️  Ulang dari awal" "✖  Batal" || return
  case "$k" in
    1) bc_interactive; return ;;
    2) return ;;
  esac

  bc_run
  ui_nl
  UI_HINTS=("" "Buka di Finder / file manager" "")
  ui_select k "Next?" "← Balik ke menu utama" "📂 Buka folder report" "Keluar" || return
  case "$k" in
    1) if command -v open >/dev/null; then open "$(dirname "${BC_LAST_REPORT:-$BC_OUT_CSV}")"; else xdg-open "$(dirname "${BC_LAST_REPORT:-$BC_OUT_CSV}")" >/dev/null 2>&1; fi ;;
    2) exit 0 ;;
  esac
}

# ---------- mode flag / CLI (buat script & CI) ----------
bc_usage() {
  cat >&2 <<EOF

  ${B}gitlabbox.sh branches${RST} — $TOOL_BC_NAME

  ${B}Sumber repo${RST} (bisa dicampur & diulang)
    -r, --repo REPO          path / ID / URL. Bisa beberapa: -r a/b -r c/d atau "a/b,c/d"
    -f, --file FILE          file .txt, 1 repo per baris (# = komentar, group:xxx = 1 group)
    -g, --group GROUP        semua project di group + subgroup
    -a, --account SCOPE      semua project yang bisa diakses akun/token lu. SCOPE:
                               member (member langsung / via group) · owned · reporter
                               developer · maintainer (role minimal) · all (self-hosted aja)
        --mine               singkatan --account member
        --repo-filter GLOB   saring hasil group/akun, pisah koma. contoh: 'backend/*,*-svc'
        --include-archived   ikut sertain project archived (default di-skip)

  ${B}Koneksi${RST}
    -p, --profile NAME       profile dari 'gitlabbox.sh setup' (default: profile default)
                             tanpa config: pakai env GITLAB_URL + GITLAB_TOKEN

  ${B}Analisis${RST}
    -d, --since-days N       cuma hitung commit N hari terakhir (default: semua history)
    -m, --max-commits N      batas commit dibaca per branch (default 5000, 0 = tanpa batas)
    -b, --branch-filter GLOB filter nama branch, pisah koma. contoh: 'main,release/*'
        --identity WHO       author (default) | committer
    -w, --workers N          request paralel per repo (default 6)
        --top N              jumlah top committer per branch di report (default 5)

  ${B}Output${RST}
    -F, --format FMT         json (default) | csv | both
    -o, --out PATH           folder, atau nama file (.json/.csv), atau '-' buat stdout
        --rows N             baris tabel per repo di layar (default 10)

  ${B}Contoh${RST}
    ./gitlabbox.sh branches -r my-group/my-app
    ./gitlabbox.sh branches -f repos.txt -d 90 -F both
    ./gitlabbox.sh branches -g my-org/backend -b 'main,release/*' -o reports/
    ./gitlabbox.sh branches --mine -d 90 -F both
    ./gitlabbox.sh branches -a developer --repo-filter 'payments/*' -p kantor
    GITLAB_URL=https://gitlab.example.com GITLAB_TOKEN=\$TOKEN ./gitlabbox.sh branches -r 123 -o - | jq .summary

  ${DIM}Exit code: 0 semua sukses · 3 sebagian repo gagal · 1 gagal total / error input${RST}

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
        [ -f "$2" ] || { ui_err "File '$2' gak ketemu."; return 1; }
        while IFS= read -r line; do BC_TARGETS+=("$line"); done < <(read_targets_file "$2"); shift 2 ;;
      -g | --group) BC_TARGETS+=("group:$2"); shift 2 ;;
      -a | --account)
        case " $BC_ACCOUNT_SCOPES " in *" $2 "*) ;; *) ui_err "--account: $BC_ACCOUNT_SCOPES"; return 1 ;; esac
        BC_TARGETS+=("account:$2"); shift 2 ;;
      --mine) BC_TARGETS+=("account:member"); shift ;;
      --repo-filter) BC_REPO_FILTER="$2"; shift 2 ;;
      --include-archived) BC_INCLUDE_ARCHIVED=1; shift ;;
      -d | --since-days) _bc_is_int "$2" || { ui_err "--since-days harus angka"; return 1; }; BC_SINCE_DAYS="$2"; shift 2 ;;
      --all-history) BC_SINCE_DAYS=0; shift ;;
      -m | --max-commits) _bc_is_int "$2" || { ui_err "--max-commits harus angka"; return 1; }; BC_MAX_COMMITS="$2"; shift 2 ;;
      -b | --branch-filter) BC_FILTER="$2"; shift 2 ;;
      --identity)
        case "$2" in author | committer) BC_IDENTITY="$2" ;; *) ui_err "--identity: author | committer"; return 1 ;; esac
        shift 2 ;;
      -w | --workers) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--workers minimal 1"; return 1; }; BC_WORKERS="$2"; shift 2 ;;
      --top) _bc_is_int "$2" || { ui_err "--top harus angka"; return 1; }; BC_TOP="$2"; shift 2 ;;
      --rows) _bc_is_int "$2" || { ui_err "--rows harus angka"; return 1; }; BC_ROWS="$2"; shift 2 ;;
      -F | --format)
        case "$2" in json | csv | both) BC_FORMAT="$2" ;; *) ui_err "--format: json | csv | both"; return 1 ;; esac
        shift 2 ;;
      -o | --out) BC_OUT="$2"; shift 2 ;;
      -*) ui_err "Opsi gak dikenal: $1"; bc_usage; return 1 ;;
      *) BC_TARGETS+=("$1"); shift ;;
    esac
  done
  if [ "${#BC_TARGETS[@]}" -eq 0 ]; then
    ui_err "Belum ada repo. Pakai -r, -f, atau -g."
    bc_usage
    return 1
  fi
  if [ "$BC_OUT" = - ] && [ "$BC_FORMAT" = both ]; then ui_err "-o - cuma bisa 1 format (json atau csv)."; return 1; fi
  bc_prepare_profile || return 1
  bc_run
}
