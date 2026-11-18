# shellcheck shell=bash
# tools/ci-jobs.sh — CI Job Detector.
#
# For every repo: is a job matching the names you give (e.g. sast:gate, *sast*)
# defined in its CI config, and did it run in the latest pipeline?
#
# GitLab APIs used (all read-only):
#   GET /projects/:id                                   default branch, CI enabled?
#   GET /projects/:id/ci/lint?include_jobs=true         merged config (includes expanded) → defined jobs
#   GET /projects/:id/pipelines?ref=REF&per_page=1      latest pipeline on the branch
#   GET /projects/:id/pipelines/:pid/jobs | /bridges    jobs (and trigger jobs) in that pipeline
#
# Repo input (single / several / .txt / groups / account) is shared with the
# Branch & Committer Report: BC_TARGETS → bc_expand_targets.

TOOL_CJ_NAME="CI Job Detector"

# Result order = how the table is sorted (what needs attention first).
CJ_RESULTS="MISSING NOT_RUN UNKNOWN NO_CI ERROR FOUND"

cj_defaults() {
  bc_defaults
  CJ_JOBS="*sast*"
  CJ_REF=""
  CJ_OUT=""
  CJ_WORKERS=6
  CJ_ROWS=60
}

_cj_icon() {
  case "$1" in
    FOUND) printf '%s✔%s' "$CG" "$RST" ;;
    NOT_RUN) printf '%s▲%s' "$CY" "$RST" ;;
    MISSING) printf '%s✖%s' "$CR" "$RST" ;;
    UNKNOWN) printf '%s?%s' "$CY" "$RST" ;;
    NO_CI) printf '%s–%s' "$DIM" "$RST" ;;
    *) printf '%s!%s' "$CR" "$RST" ;;
  esac
}

# ---------- worker (one process per repo, run in parallel via xargs -P) ----------
# Task line: IDX <tab> HOST <tab> PATH <tab> ERR. Writes $CJ_WORK/r/IDX.json.
_cj_record() { # OUT JSON_FIELDS — write one result
  jq -n "$2" "${@:3}" >"$1"
}

cj_worker() {
  local i="$1" line host path err out d pid defb ref cfg pl plid
  line=$(awk -F'\t' -v i="$i" '$1 == i' "$CJ_WORK/tasks.tsv")
  host=$(printf '%s' "$line" | cut -f2); path=$(printf '%s' "$line" | cut -f3); err=$(printf '%s' "$line" | cut -f4)
  path=$(_bc_strip_prefix "$path" "$host")
  out="$CJ_WORK/r/$(printf '%05d' "$i").json"
  d="$CJ_WORK/w$i"; mkdir -p "$d"

  if [ -n "$err" ]; then
    _cj_record "$out" '{project: $p, result: "ERROR", error: $e}' --arg p "$path" --arg e "$err"
    echo "$i" >>"$CJ_WORK/done"; return 0
  fi
  if ! api_get "/projects/$(_uri "$path")" "$d/project.json"; then
    _cj_record "$out" '{project: $p, result: "ERROR", error: $e}' --arg p "$path" --arg e "$API_ERROR"
    echo "$i" >>"$CJ_WORK/done"; return 0
  fi
  pid=$(jq -r '.id' "$d/project.json")
  defb=$(jq -r '.default_branch // empty' "$d/project.json")
  ref="${CJ_REF:-$defb}"

  # 1) defined: the merged CI config of the branch (includes / templates expanded)
  cfg=no_ci; : >"$d/lint.json"
  if [ "$(jq -r '.builds_access_level // (if .jobs_enabled == false then "disabled" else "enabled" end)' "$d/project.json")" = disabled ]; then
    cfg=disabled
  elif [ -z "$ref" ]; then
    cfg=empty
  elif api_get "/projects/$pid/ci/lint?include_jobs=true$([ -n "$CJ_REF" ] && printf '&content_ref=%s' "$(_uri "$CJ_REF")")" "$d/lint.json"; then
    cfg=$(jq -r '
      if (.merged_yaml // "") != "" or ((.jobs // []) | length) > 0 then "readable"
      elif ((.errors // []) | join(" ") | test("provide content|not found|does not exist|missing|empty"; "i")) then "no_ci"
      elif (.valid == false) then "invalid"
      else "no_ci" end' "$d/lint.json")
  else
    cfg=no_access
    [ "$API_STATUS" = 404 ] && cfg=unsupported
    printf '%s' "$API_ERROR" >"$d/lint.err"
  fi

  # 2) ran: jobs + trigger jobs of the latest pipeline on the branch
  : >"$d/jobs.json"; plid=""
  if [ -n "$ref" ] && api_get "/projects/$pid/pipelines?ref=$(_uri "$ref")&per_page=1&order_by=id&sort=desc" "$d/pl.json"; then
    plid=$(jq -r '.[0].id // empty' "$d/pl.json")
  fi
  if [ -n "$plid" ]; then
    api_get_all "/projects/$pid/pipelines/$plid/jobs" "$d/j.json" || echo '[]' >"$d/j.json"
    api_get_all "/projects/$pid/pipelines/$plid/bridges" "$d/b.json" || echo '[]' >"$d/b.json"
    jq -s 'add | map({name, status, stage})' "$d/j.json" "$d/b.json" >"$d/jobs.json"
  fi
  [ -s "$d/jobs.json" ] || echo '[]' >"$d/jobs.json"
  [ -s "$d/lint.json" ] || echo '{}' >"$d/lint.json"
  [ -n "$plid" ] && pl=$(jq -c '.[0] | {id, status, ref, created_at: (.created_at // null), web_url}' "$d/pl.json") || pl=null

  jq -n --slurpfile p "$d/project.json" --slurpfile l "$d/lint.json" --slurpfile j "$d/jobs.json" \
    --arg cfg "$cfg" --arg re "$CJ_JOB_RE" --arg ref "$ref" --argjson pl "$pl" \
    --arg lerr "$(cat "$d/lint.err" 2>/dev/null)" '
    def m: test($re; "i");
    def reserved: IN("stages", "variables", "include", "default", "workflow", "image", "services",
                     "before_script", "after_script", "cache", "types", "spec");
    $p[0] as $p | $l[0] as $l
    | (if $cfg != "readable" then null
       elif (($l.jobs // []) | length) > 0 then [$l.jobs[].name]
       else [($l.merged_yaml // "") | split("\n")[]
             | (capture("^(?<k>[^ #\\-][^\\n]*?):\\s*$") | .k)? | ltrimstr("\"") | rtrimstr("\"") | ltrimstr("'"'"'") | rtrimstr("'"'"'")
             | select(startswith(".") | not) | select(reserved | not)]
       end) as $all
    | (if $all == null then null else [$all[] | select(m)] | unique end) as $def
    | ([$j[0][] | select(.name | m)] | unique_by(.name)) as $ran
    | (if ($ran | length) > 0 then "FOUND"
       elif $def != null and ($def | length) > 0 then "NOT_RUN"
       elif $cfg == "readable" then "MISSING"
       elif IN($cfg; "no_ci", "disabled", "empty") and $pl == null then "NO_CI"
       else "UNKNOWN" end) as $res
    | {
        project: $p.path_with_namespace, id: $p.id, web_url: $p.web_url, default_branch: ($p.default_branch // null), ref: $ref,
        result: $res,
        defined: (if $def == null then null else ($def | length) > 0 end),
        defined_jobs: $def,
        config: $cfg,
        pipeline: $pl,
        ran_jobs: $ran,
        note: ({
          no_access: "CI config not readable (needs Developer on the project): \($lerr)",
          unsupported: "CI lint API not available on this GitLab",
          invalid: "CI config is invalid: \(($l.errors // []) | join("; "))",
          disabled: "CI/CD is disabled for this project",
          empty: "Empty repository (no default branch)"
        }[$cfg] // (if $res == "NOT_RUN" and $pl == null then "Defined, but no pipeline on \($ref) yet"
                    elif $res == "NOT_RUN" then "Defined, but not in the latest pipeline (skipped by rules?)"
                    elif $res == "FOUND" and $cfg == "readable" and ($def | length) == 0 then "Ran, but not in the config of \($ref) (added by a compliance / downstream config?)"
                    else null end)),
        error: null
      }' >"$out" 2>"$d/jq.err" ||
    _cj_record "$out" '{project: $p, result: "ERROR", error: ("parse: " + $e)}' --arg p "$path" --arg e "$(head -c 200 "$d/jq.err")"
  rm -rf "$d"
  echo "$i" >>"$CJ_WORK/done"
}

# ---------- run ----------
cj_run() {
  local t0=$SECONDS report outdir
  CJ_WORK="$GLB_TMP/cj"
  rm -rf "$CJ_WORK"; mkdir -p "$CJ_WORK/r"
  BC_WORK="$CJ_WORK"
  CJ_JOB_RE=$(_sc_glob_re "$CJ_JOBS")
  [ -n "$CJ_JOB_RE" ] || { ui_err "Enter at least one job name."; return 1; }

  ui_title "Detecting CI jobs" "jobs: $CJ_JOBS · branch: ${CJ_REF:-default branch} · profile: $GLB_PROFILE · $GLB_URL"
  bc_expand_targets
  BC_N=${#BC_T_PATH[@]}
  if [ "$BC_N" -eq 0 ]; then ui_err "No valid repos to check."; return 1; fi

  export CJ_WORK CJ_JOB_RE CJ_REF GLB_TIMEOUT GLB_VERSION
  bc_run_tasks "$CJ_WORK" __cj_project "$CJ_WORKERS" "repos checked"

  report="$CJ_WORK/report.json"
  cat "$CJ_WORK"/r/*.json | jq -s --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ver "$GLB_VERSION" --arg gl "$GLB_URL" \
    --arg jobs "$CJ_JOBS" --arg ref "$CJ_REF" --arg order "$CJ_RESULTS" --argjson dur "$((SECONDS - t0))" '
    ($order | split(" ") | to_entries | map({(.value): .key}) | add) as $o
    | {
        tool: "ci-jobs", gitlabbox_version: $ver, generated_at: $gen, duration_seconds: $dur, gitlab_url: $gl,
        options: {jobs: ($jobs | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))),
                  branch: (if $ref == "" then "default branch" else $ref end)},
        summary: ({repos_total: length}
          + (reduce ($order | split(" "))[] as $r ({}; .[$r | ascii_downcase] = 0))
          + (group_by(.result) | map({(.[0].result | ascii_downcase): length}) | add // {})),
        repositories: sort_by($o[.result], .project)
      }' >"$report"

  outdir="${CJ_OUT:-$GLB_ROOT/reports}"
  if [ "$outdir" != - ]; then
    outdir=$(make_report_dir "$outdir" ci-jobs "$(_bc_scope)") || { ui_err "Cannot create a report folder."; return 1; }
    jq . "$report" >"$outdir/report.json"
    cj_to_csv "$report" >"$outdir/report.csv"
  else
    jq . "$report"
  fi

  cj_print_table "$report"
  cj_summary_box "$report" "$([ "$outdir" != - ] && printf '%s' "$outdir")"
  CJ_LAST_DIR="$outdir"
  [ "$(jq '.summary.error' "$report")" -eq 0 ]
}

cj_to_csv() { # REPORT_JSON
  jq -r '
    ["project","result","defined","defined_jobs","ran_jobs","pipeline_id","pipeline_status","pipeline_at","branch","config","note","error","web_url"],
    (.repositories[] | [.project, .result,
      (if .defined == null then "unknown" elif .defined then "yes" else "no" end),
      ((.defined_jobs // []) | join(" | ")),
      ((.ran_jobs // []) | map("\(.name) (\(.status))") | join(" | ")),
      .pipeline.id, .pipeline.status, .pipeline.created_at, .ref, .config, .note, .error, .web_url])
    | @csv' "$1"
}

cj_print_table() { # REPORT_JSON
  local f="$1" n shown=0 r p jobs note
  n=$(jq '.repositories | length' "$f")
  ui_nl
  printf '  %s   %-52s %-8s %s%s\n' "$B" "PROJECT" "RESULT" "MATCHED JOBS" "$RST" >&2
  while IFS=$'\t' read -r r p jobs note; do
    shown=$((shown + 1))
    if [ "$shown" -gt "$CJ_ROWS" ]; then
      ui_hint "… $((n - CJ_ROWS)) more in report.csv"; break
    fi
    [ "${#p}" -gt 52 ] && p="…${p: -51}"
    printf '  %s %-52s %-8s %s%s%s\n' "$(_cj_icon "$r")" "$p" "$r" "$jobs" "${note:+  $DIM}" "$note$([ -n "$note" ] && printf '%s' "$RST")" >&2
  done < <(jq -r '.repositories[] | [.result, .project,
      ((if (.ran_jobs // []) | length > 0 then .ran_jobs | map("\(.name) (\(.status))")
        else (.defined_jobs // []) | map("\(.) (defined)") end) | join(", ") | if . == "" then "—" else . end),
      ((.note // .error // "") | .[:70])] | @tsv' "$f")
}

cj_summary_box() { # REPORT_JSON [DIR]
  local f="$1" lines=() checked
  checked=$(jq '.summary | .repos_total - .no_ci - .error' "$f")
  lines+=("${DIM}Jobs     ${RST} $(jq -r '.options.jobs | join(", ")' "$f") ${DIM}· branch: $(jq -r '.options.branch' "$f")${RST}")
  lines+=("${DIM}Repos    ${RST} $(jq -r '.summary.repos_total' "$f") checked")
  lines+=("$(_cj_icon FOUND) ${DIM}Found    ${RST} $(jq -r '.summary.found' "$f") ${DIM}(in the latest pipeline)${RST}")
  lines+=("$(_cj_icon NOT_RUN) ${DIM}Not run  ${RST} $(jq -r '.summary.not_run' "$f") ${DIM}(defined, not in the latest pipeline)${RST}")
  lines+=("$(_cj_icon MISSING) ${DIM}Missing  ${RST} $(jq -r '.summary.missing' "$f") ${DIM}(not defined, not run)${RST}")
  [ "$(jq '.summary.unknown' "$f")" -gt 0 ] && lines+=("$(_cj_icon UNKNOWN) ${DIM}Unknown  ${RST} $(jq -r '.summary.unknown' "$f") ${DIM}(config not readable, not seen in the pipeline)${RST}")
  lines+=("$(_cj_icon NO_CI) ${DIM}No CI    ${RST} $(jq -r '.summary.no_ci' "$f")")
  [ "$(jq '.summary.error' "$f")" -gt 0 ] && lines+=("$(_cj_icon ERROR) ${DIM}Errors   ${RST} $(jq -r '.summary.error' "$f")")
  [ "$checked" -gt 0 ] && lines+=("${DIM}Coverage ${RST} ${B}$(jq -r --argjson c "$checked" '.summary.found * 100 / $c | floor' "$f")%${RST} of $checked repos with CI run the job")
  lines+=("${DIM}Duration ${RST} $(ui_duration "$(jq -r '.duration_seconds // 0' "$f")")")
  [ -n "$2" ] && lines+=("${DIM}Report   ${RST} ${CC}$(_bc_tilde "$2")/report.csv${RST} ${DIM}+ report.json${RST}")
  ui_nl
  ui_box "CI job check" "${lines[@]}"
}

cj_view_report() { # REPORT_JSON
  ui_title "$(basename "$(dirname "$1")")" "generated $(jq -r '.generated_at' "$1")"
  cj_print_table "$1"
  cj_summary_box "$1" "$(dirname "$1")"
}

# ---------- interactive ----------
cj_interactive() {
  local k v
  cj_defaults
  ui_title "$TOOL_CJ_NAME" "Is a job like sast:gate defined in each repo's pipeline — and did it run?"
  ui_nl
  if [ "$(cfg_count)" -eq 0 ] && [ -z "${GITLAB_TOKEN:-}${GL_TOKEN:-}" ]; then
    ui_warn "No GitLab connection yet."
    ui_confirm "Set up a connection now?" y || return
    setup_wizard || return
    ui_nl
  fi
  pick_profile "Which connection?" include_env || return
  BC_PROFILE="$PICKED_PROFILE"
  bc_prepare_profile || return
  bc_pick_source || return

  ui_nl
  ui_hint "Job names, comma-separated, case-insensitive. * = anything. E.g. sast:gate  ·  *sast*  ·  sast:gate,semgrep-*"
  while :; do ui_input CJ_JOBS "Job names to look for" "$CJ_JOBS"; [ -n "$(_sc_glob_re "$CJ_JOBS")" ] && break; done
  UI_HINTS=("Config + latest pipeline of each repo's default branch" "e.g. main, develop — repos without it show NO_CI / UNKNOWN")
  ui_select k "Which branch?" "Default branch (recommended)" "A specific branch" || return
  [ "$k" = 1 ] && while :; do ui_input CJ_REF "Branch" "main"; [ -n "$CJ_REF" ] && break; done
  ui_input CJ_OUT "Output folder" "$GLB_ROOT/reports" path

  ui_nl
  ui_box "Ready to run" \
    "${DIM}Connect ${RST} $(profile_label "$BC_PROFILE")" \
    "${DIM}Repos   ${RST} $BC_SRC_LABEL" \
    "${DIM}Jobs    ${RST} $CJ_JOBS" \
    "${DIM}Branch  ${RST} ${CJ_REF:-default branch}" \
    "${DIM}Output  ${RST} $(_bc_tilde "$CJ_OUT")"
  ui_nl
  UI_HINTS=("" "Answer all questions again" "Back to the main menu")
  ui_select k "Go?" "🚀 Run it!" "✏️  Start over" "✖  Cancel" || return
  case "$k" in 1) cj_interactive; return ;; 2) return ;; esac

  cj_run
  ui_nl
  UI_HINTS=("" "Open in Finder / file manager" "")
  ui_select k "Next?" "← Back to the main menu" "📂 Open the report folder" "Quit" || return
  case "$k" in
    1) if command -v open >/dev/null; then open "$CJ_LAST_DIR"; else xdg-open "$CJ_LAST_DIR" >/dev/null 2>&1; fi ;;
    2) exit 0 ;;
  esac
}

# ---------- flag mode / CLI ----------
cj_usage() {
  cat >&2 <<EOF
${B}$TOOL_CJ_NAME${RST} — is a job (e.g. sast:gate) defined in each repo's CI, and did it run?

${B}Usage${RST}
  ./gitlabbox.sh cijobs [repo source] [options]

${B}Repo source${RST} (combinable, same as the Branch & Committer Report)
    -r, --repo LIST          path / ID / URL, comma-separated
    -f, --file FILE          .txt file, one repo per line (group:xxx = a whole group)
    -g, --group LIST         every project in these groups + subgroups (comma-separated)
    -a, --account SCOPE      every repo your account can access: member · owned · reporter · developer · maintainer · all
        --mine               = --account member
        --repo-filter GLOB   filter group/account results, e.g. 'backend/*,*-svc'
        --include-archived   include archived projects

${B}Options${RST}
    -j, --jobs LIST          job names to look for, comma-separated globs, case-insensitive (default: *sast*)
        --ref BRANCH         check this branch instead of each repo's default branch
    -p, --profile NAME       connection profile
    -w, --workers N          parallel repos (default 6)
    -o, --out DIR            parent folder (→ DIR/<date>_ci-jobs_<scope>/report.csv + report.json), or '-' for JSON on stdout

${B}Result per repo${RST}
    FOUND    a matching job is in the latest pipeline
    NOT_RUN  defined in the CI config, but not in the latest pipeline (skipped by rules, or no pipeline yet)
    MISSING  the CI config is readable and has no matching job
    UNKNOWN  the CI config is not readable (needs Developer) and the job was not seen in the pipeline
    NO_CI    no CI config / CI disabled / empty repository
    ERROR    project not accessible

${B}Examples${RST}
    ./gitlabbox.sh cijobs -g my-org/backend -j 'sast:gate'
    ./gitlabbox.sh cijobs --mine -j 'sast:gate,*sast*' --repo-filter 'my-team/*'
    ./gitlabbox.sh cijobs -f repos.txt -o - | jq '.repositories[] | select(.result == "MISSING") | .project'

Exit code: 0 = ok · 3 = some repos could not be read.
EOF
}

cj_cli() {
  cj_defaults
  while [ $# -gt 0 ]; do
    case "$1" in
      --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
    esac
    bc_source_opt "$@"
    case $? in 0) shift "$BC_OPT_SHIFT"; continue ;; 2) return 1 ;; esac
    case "$1" in
      -h | --help) cj_usage; return 0 ;;
      -p | --profile) BC_PROFILE="$2"; shift 2 ;;
      -j | --jobs) CJ_JOBS="$2"; shift 2 ;;
      --ref) CJ_REF="$2"; shift 2 ;;
      -w | --workers) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--workers must be at least 1"; return 1; }; CJ_WORKERS="$2"; shift 2 ;;
      -o | --out) CJ_OUT="$2"; shift 2 ;;
      -*) ui_err "Unknown option: $1"; cj_usage; return 1 ;;
      *) BC_TARGETS+=("$1"); shift ;;
    esac
  done
  if [ "${#BC_TARGETS[@]}" -eq 0 ]; then ui_err "No repos given."; cj_usage; return 1; fi
  bc_prepare_profile || return 1
  cj_run || return 3
}
