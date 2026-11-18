# shellcheck shell=bash
# tools/sast-gate.sh — SAST Gate Pass/Break Recap.
#
# For the groups you name: every pipeline in the period that ran the SAST gate job
# (e.g. sast:gate) → PASSED or BREAK, why it broke, how long the job took, how many
# gate jobs ran at once — plus a crosscheck: projects in the group vs read, repos
# that ran the gate, and pipelines on the same branches without it.
#
# GitLab APIs used (all read-only, scope read_api, token required):
#   GET /groups/:id/projects?include_subgroups=true        projects per group
#   GET /projects/:id/jobs                                 gate jobs (newest first, stops at the period start)
#   GET /projects/:id/pipelines?updated_after=…            every pipeline in the period (crosscheck)
#
# Analysis lives in tools/sast-gate.jq, the copy-paste recap in tools/sast-gate-recap.jq.
# Group lists, period and timezone helpers are shared with the SAST Gate Capacity Planner.

TOOL_SG_NAME="SAST Gate Pass/Break Recap"

sg_defaults() {
  SG_PROFILE=""
  SC_GROUPS=()            # "group<TAB>label<TAB>path1|path2" (see _sc_add_groups)
  SG_JOBS="sast:gate"
  SG_BRANCHES="dev,develop,development,main,master"
  SG_ALL_BRANCHES=0
  SG_DAYS=7
  SG_HOURS=""
  SG_SINCE=""
  SG_UNTIL=""
  SG_GSINCE=""            # "LABEL=YYYY-MM-DD HH:MM, …" — a later start for some groups (e.g. their go-live)
  SC_TZ=""
  SC_INCLUDE_ARCHIVED=0
  SG_WORKERS=6
  SG_OUT=""
  SG_RECAP=0
  SG_ROWS=15
}

_sg_icon() {
  case "$1" in
    PASSED) printf '%s✔%s' "$CG" "$RST" ;;
    BREAK) printf '%s✖%s' "$CR" "$RST" ;;
    WARN) printf '%s▲%s' "$CY" "$RST" ;;
    NO_SAST) printf '%s○%s' "$CY" "$RST" ;;
    *) printf '%s–%s' "$DIM" "$RST" ;;
  esac
}

# "YYYY-MM-DD[ HH:MM[:SS]]" or "HH:MM" (= today), in the --tz offset → epoch seconds (empty when invalid)
_sg_time() {
  jq -nr --arg s "$1" --argjson o "$SC_OFF" '
    ($s | gsub("^\\s+|\\s+$"; "") | sub("T"; " ")) as $s
    | (if ($s | test("^[0-9]{1,2}:[0-9]{2}$")) then (((now + $o) | todate | .[:10]) + " " + $s) else $s end)
    | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})(?: (?<h>[0-9]{1,2}):(?<m>[0-9]{2})(?::(?<x>[0-9]{2}))?)?$")
    | ((.d + "T00:00:00Z") | fromdateiso8601) + ((.h // "0") | tonumber) * 3600 + ((.m // "0") | tonumber) * 60
      + ((.x // "0") | tonumber) - $o' 2>/dev/null
}

_sg_fmt() { jq -nr --argjson t "$1" --argjson o "$SC_OFF" '($t + $o) | floor | todate | .[:16] | sub("T"; " ")'; }

_sg_compute_period() {
  local now
  _sc_parse_tz "$SC_TZ" || { ui_err "Invalid --tz: $SC_TZ (use e.g. +07:00)"; return 1; }
  now=$(date +%s)
  if [ -n "$SG_UNTIL" ]; then
    SG_END=$(_sg_time "$SG_UNTIL")
    [ -n "$SG_END" ] || { ui_err "Invalid --until: $SG_UNTIL (use YYYY-MM-DD HH:MM)"; return 1; }
    # a bare date means "up to the end of that day"
    case "$SG_UNTIL" in *:*) ;; *) SG_END=$((SG_END + 86400)) ;; esac
    [ "$SG_END" -gt "$now" ] && SG_END=$now
  else
    SG_END=$now
  fi
  if [ -n "$SG_SINCE" ]; then
    SG_START=$(_sg_time "$SG_SINCE")
    [ -n "$SG_START" ] || { ui_err "Invalid --since: $SG_SINCE (use YYYY-MM-DD HH:MM)"; return 1; }
  elif [ -n "$SG_HOURS" ]; then
    SG_START=$((SG_END - SG_HOURS * 3600))
  else
    SG_START=$((SG_END - SG_DAYS * 86400))
  fi
  [ "$SG_START" -lt "$SG_END" ] || { ui_err "The period start must be before its end."; return 1; }
  SG_FROM_LABEL=$(_sg_fmt "$SG_START"); SG_TO_LABEL=$(_sg_fmt "$SG_END")
  SG_JOB_RE=$(_sc_glob_re "$SG_JOBS")
  [ -n "$SG_JOB_RE" ] || { ui_err "Enter at least one job name."; return 1; }
  if [ "$SG_ALL_BRANCHES" = 1 ]; then
    SG_BRANCHES_JSON=null
  else
    SG_BRANCHES_JSON=$(printf '%s\n' "$SG_BRANCHES" | tr ',' '\n' | while IFS= read -r b; do _sc_trim "$b"; echo; done |
      sed '/^$/d' | jq -R . | jq -sc .)
  fi
  export SG_END SG_JOB_RE SC_JQ_TS
}

# _sg_group_start LABEL → epoch of a later start given with --group-since, or the period start
_sg_group_start() {
  local item l t e
  while IFS= read -r item; do
    item=$(_sc_trim "$item"); [ -z "$item" ] && continue
    l=$(_sc_trim "${item%%=*}"); t=$(_sc_trim "${item#*=}")
    [ "$l" = "$1" ] || continue
    e=$(_sg_time "$t")
    [ -n "$e" ] && [ "$e" -gt "$SG_START" ] && { printf '%s' "$e"; return; }
  done < <(printf '%s\n' "$SG_GSINCE" | tr ',' '\n')
  printf '%s' "$SG_START"
}

_sg_check_gsince() { # every LABEL in --group-since must be a group, every time must parse
  local item l t g ok
  while IFS= read -r item; do
    item=$(_sc_trim "$item"); [ -z "$item" ] && continue
    case "$item" in *=*) ;; *) ui_err "--group-since: '$item' should be LABEL=YYYY-MM-DD HH:MM"; return 1 ;; esac
    l=$(_sc_trim "${item%%=*}"); t=$(_sc_trim "${item#*=}")
    ok=0
    for g in "${SC_GROUPS[@]}"; do [ "$(printf '%s' "$g" | cut -f2)" = "$l" ] && ok=1; done
    [ "$ok" = 1 ] || { ui_err "--group-since: no group labelled '$l'"; return 1; }
    [ -n "$(_sg_time "$t")" ] || { ui_err "--group-since: invalid time '$t' for $l (use YYYY-MM-DD HH:MM)"; return 1; }
  done < <(printf '%s\n' "$SG_GSINCE" | tr ',' '\n')
  return 0
}

# ---------- worker: one process per project ----------
# _sg_since PATH OUT KIND → appends gate jobs (KIND=jobs) or pipelines (KIND=pipes) created in
#   [SG_GSTART, SG_END); the API returns newest first, so it stops at the first page older than the start
_sg_since() {
  local path="$1" out="$2" kind="$3" page=1 pf="$2.page" n oldest sep='?'
  case "$path" in *\?*) sep='&' ;; esac
  while :; do
    api_get "${path}${sep}per_page=100&page=${page}" "$pf" || { rm -f "$pf" "$pf.hdr" "$pf.err"; return 1; }
    jq -c --arg k "$kind" --arg g "$SG_G" --arg pp "$SG_P" --argjson pid "$SG_PID" --argjson s "$SG_GSTART" \
      --argjson e "$SG_END" --arg re "$SG_JOB_RE" "$SC_JQ_TS"'
      .[] | (.created_at | ts) as $t | select($t != null and $t >= $s and $t < $e)
      | if $k == "jobs" then
          select((.name // "") | test($re; "i"))
          | {g: $g, project: $pp, pid: $pid, id, name, status, stage, allow_failure: (.allow_failure // false),
             failure_reason: (.failure_reason // null), created: $t, started: (.started_at | ts), finished: (.finished_at | ts),
             duration: (.duration // null), queued: (.queued_duration // null), runner: (.runner.id // null),
             user: (.user.username // null), ref, pipeline: .pipeline.id, pipeline_source: (.pipeline.source // null),
             sha: ((.pipeline.sha // .commit.id // "") | .[:8]), commit: (.commit.title // null), web_url}
        else
          {g: $g, project: $pp, pid: $pid, id, status, ref, source: (.source // null), created: $t,
           sha: ((.sha // "") | .[:8]), web_url}
        end' "$pf" >>"$out"
    n=$(jq 'length' "$pf")
    oldest=$(jq "$SC_JQ_TS"'[.[].created_at | ts] | min // 0 | floor' "$pf")
    [ "$n" -lt 100 ] && break
    [ "$oldest" -lt "$SG_GSTART" ] && break
    [ -z "$API_NEXT_PAGE" ] && break
    page="$API_NEXT_PAGE"
  done
  rm -f "$pf" "$pf.hdr" "$pf.err"
  return 0
}

sg_worker() {
  local i="$1" p base iso
  p=$(jq -c --argjson i "$i" '.[$i]' "$SG_GDIR/projects.json")
  SG_G=$(printf '%s' "$p" | jq -r '.g'); SG_P=$(printf '%s' "$p" | jq -r '.path'); SG_PID=$(printf '%s' "$p" | jq -r '.id')
  base="$SG_GDIR/p/$(printf '%05d' "$i")"
  iso=$(jq -nr --argjson t "$SG_GSTART" '$t | todate')
  : >"$base.jobs"; : >"$base.pipes"
  if ! _sg_since "/projects/$SG_PID/jobs" "$base.jobs" jobs; then
    jq -nc --arg g "$SG_G" --arg p "$SG_P" --argjson pid "$SG_PID" --arg e "jobs: $API_ERROR" \
      '{g: $g, project: $p, pid: $pid, error: $e}' >"$base.error"
  elif ! _sg_since "/projects/$SG_PID/pipelines?updated_after=$(_uri "$iso")&order_by=id&sort=desc" "$base.pipes" pipes; then
    jq -nc --arg g "$SG_G" --arg p "$SG_P" --argjson pid "$SG_PID" --arg e "pipelines: $API_ERROR" \
      '{g: $g, project: $p, pid: $pid, error: $e}' >"$base.error"
  fi
  printf '%s\n' "$i" >>"$SG_GDIR/done"
}

# ---------- collection for one group ----------
sg_collect_group() {
  local gi="$1" name path gdir total cand xpid d arch="&archived=false" gpth perr="" np nj nb
  local paths=()
  name=$(printf '%s' "${SC_GROUPS[$gi]}" | cut -f2)
  path=$(printf '%s' "${SC_GROUPS[$gi]}" | cut -f3)
  while IFS= read -r gpth; do paths+=("$gpth"); done < <(printf '%s\n' "$path" | tr '|' '\n')
  np=${#paths[@]}
  path=$(printf '%s' "$path" | sed 's/|/, /g')
  gdir="$SG_WORK/g$gi"
  mkdir -p "$gdir/p"
  [ "$SC_INCLUDE_ARCHIVED" = 1 ] && arch=""
  SG_GSTART=$(_sg_group_start "$name")

  printf '\n  %s[%d/%d]%s %s%s%s %s(%s%s)%s\n' "$DIM" $((gi + 1)) "${#SC_GROUPS[@]}" "$RST" "$B" "$name" "$RST" \
    "$DIM" "$path" "$([ "$SG_GSTART" != "$SG_START" ] && printf ' · since %s' "$(_sg_fmt "$SG_GSTART")")" "$RST" >&2

  ui_spin_start "Listing projects$([ "$np" -gt 1 ] && printf ' (%s locations)' "$np")" "$gdir/count"
  : >"$gdir/all.jsonl"
  for gpth in "${paths[@]}"; do
    if api_get_all "/groups/$(_uri "$gpth")/projects?include_subgroups=true&with_shared=false&simple=true$arch" "$gdir/one.json" 0 "$gdir/count"; then
      jq -c '.[]' "$gdir/one.json" >>"$gdir/all.jsonl"
    else
      perr="$gpth: $API_ERROR"; break
    fi
  done
  jq -s 'unique_by(.id)' "$gdir/all.jsonl" >"$gdir/all.json"
  if [ -n "$perr" ]; then
    ui_spin_stop 1 "Cannot list projects: $perr"
    jq -nc --arg n "$name" --arg p "$path" --arg e "$perr" --argjson s "$SG_GSTART" \
      '{name: $n, path: $p, start: $s, projects_total: 0, projects_candidate: 0, error: $e}' >>"$SG_WORK/groups.jsonl"
    return 1
  fi
  # only projects with activity since the start can have a pipeline in the period
  jq -c --arg g "$name" --argjson s "$SG_GSTART" "$SC_JQ_TS"'
    .[] | {g: $g, id, path: .path_with_namespace, web_url,
           candidate: (.last_activity_at != null and (.last_activity_at | ts) >= ($s - 86400))}' \
    "$gdir/all.json" >>"$SG_WORK/projects.jsonl"
  jq --arg g "$name" --argjson s "$SG_GSTART" "$SC_JQ_TS"'
    map(select(.last_activity_at != null and (.last_activity_at | ts) >= ($s - 86400))
        | {g: $g, id, path: .path_with_namespace})' "$gdir/all.json" >"$gdir/projects.json"
  total=$(jq 'length' "$gdir/all.json")
  cand=$(jq 'length' "$gdir/projects.json")
  ui_spin_stop 0 "$total projects · ${B}$cand${RST} with activity since $(_sg_fmt "$SG_GSTART")"

  if [ "$cand" -gt 0 ]; then
    export SG_GDIR="$gdir" SG_GSTART
    : >"$gdir/done"
    cursor_hide
    seq 0 $((cand - 1)) | xargs -P "$SG_WORKERS" -n 1 "$GLB_SELF" __sg_project 2>>"$gdir/worker.log" &
    xpid=$!
    BC_XARGS_PID=$xpid
    while kill -0 "$xpid" 2>/dev/null; do
      d=$(wc -l <"$gdir/done" | tr -d ' ')
      ui_progress "$d" "$cand" "gate jobs + pipelines ${DIM}($SG_WORKERS workers)${RST}"
      sleep 0.15
    done
    wait "$xpid"
    BC_XARGS_PID=
    ui_progress_end
    cursor_show
  fi

  shopt -s nullglob
  local jbf=("$gdir"/p/*.jobs) plf=("$gdir"/p/*.pipes) erf=("$gdir"/p/*.error)
  shopt -u nullglob
  cat "${jbf[@]}" /dev/null >>"$SG_WORK/jobs.jsonl"
  cat "${plf[@]}" /dev/null >>"$SG_WORK/pipes.jsonl"
  cat "${erf[@]}" /dev/null >>"$SG_WORK/errs.jsonl"
  nj=$(cat "${jbf[@]}" /dev/null | sed -n '$=')
  nb=$(cat "${plf[@]}" /dev/null | sed -n '$=')
  ui_ok "${nj:-0} gate jobs · ${nb:-0} pipelines read ${DIM}(every branch; filtered in the analysis)${RST}"
  [ "${#erf[@]}" -gt 0 ] && ui_warn "${#erf[@]} projects had read errors (first: $(jq -r '"\(.project): \(.error)"' "${erf[0]}"))"
  jq -nc --arg n "$name" --arg p "$path" --argjson t "$total" --argjson c "$cand" --argjson s "$SG_GSTART" \
    '{name: $n, path: $p, start: $s, projects_total: $t, projects_candidate: $c, error: null}' >>"$SG_WORK/groups.jsonl"
  return 0
}

# ---------- run ----------
_sg_scope() { _sc_scope; }

sg_run() {
  local i t0=$SECONDS r outdir P
  if [ -z "$GLB_HDR" ]; then
    ui_err "Profile '$GLB_PROFILE' has no token. This tool needs a PAT with read_api (Reporter on every group)."
    return 1
  fi
  _sg_compute_period || return 1
  _sg_check_gsince || return 1
  SG_WORK="$GLB_TMP/sg"
  rm -rf "$SG_WORK"; mkdir -p "$SG_WORK"
  for f in jobs pipes groups projects errs; do : >"$SG_WORK/$f.jsonl"; done
  export SG_WORK GLB_TIMEOUT GLB_VERSION

  ui_title "Collecting SAST gate pipelines" "$SG_FROM_LABEL → $SG_TO_LABEL (UTC$SC_OFFSTR) · jobs: $SG_JOBS · branches: $([ "$SG_ALL_BRANCHES" = 1 ] && echo all || echo "$SG_BRANCHES + MR pipelines") · $GLB_URL"
  for ((i = 0; i < ${#SC_GROUPS[@]}; i++)); do
    sg_collect_group "$i"
  done

  ui_nl
  ui_spin_start "Analyzing"
  for f in jobs pipes groups projects errs; do jq -s . "$SG_WORK/$f.jsonl" >"$SG_WORK/$f.json"; done
  P=$(jq -nc --argjson s "$SG_START" --argjson e "$SG_END" --argjson o "$SC_OFF" --arg os "$SC_OFFSTR" \
    --argjson br "$SG_BRANCHES_JSON" '{start: $s, end: $e, off: $o, offstr: $os, branches: $br}')
  r="$SG_WORK/report.json"
  if ! jq -n --argjson P "$P" --slurpfile jobs "$SG_WORK/jobs.json" --slurpfile pipes "$SG_WORK/pipes.json" \
    --slurpfile groups "$SG_WORK/groups.json" --slurpfile projects "$SG_WORK/projects.json" \
    --slurpfile errs "$SG_WORK/errs.json" -f "$GLB_ROOT/tools/sast-gate.jq" >"$r.tmp" 2>"$SG_WORK/analyze.err"; then
    ui_spin_stop 1 "Analysis failed: $(head -c 300 "$SG_WORK/analyze.err")"
    return 1
  fi
  jq --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ver "$GLB_VERSION" --arg gl "$GLB_URL" --arg prof "$GLB_PROFILE" \
    --arg f "$SG_FROM_LABEL" --arg t "$SG_TO_LABEL" --argjson h "$(((SG_END - SG_START + 1800) / 3600))" \
    --argjson dur "$((SECONDS - t0))" --arg jobs "$SG_JOBS" --arg os "$SC_OFFSTR" \
    --arg br "$([ "$SG_ALL_BRANCHES" = 1 ] && echo "all branches" || echo "$SG_BRANCHES + MR pipelines")" \
    --argjson ia "$([ "$SC_INCLUDE_ARCHIVED" = 1 ] && echo true || echo false)" '
    {tool: "sast-gate", gitlabbox_version: $ver, generated_at: $gen, duration_seconds: $dur, gitlab_url: $gl, profile: $prof,
     options: {jobs: ($jobs | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))), branches: $br, tz: $os,
               include_archived: $ia},
     period: {from: $f, to: $t, hours: $h}} + .' "$r.tmp" >"$r"
  ui_spin_stop 0 "Analysis done"

  outdir="${SG_OUT:-$GLB_ROOT/reports}"
  if [ "$outdir" != - ]; then
    outdir=$(make_report_dir "$outdir" sast-gate "$(_sg_scope)") || { ui_err "Cannot create a report folder in $outdir"; return 1; }
    jq . "$r" >"$outdir/report.json"
    sg_to_csv "$r" >"$outdir/report.csv"
    sg_pipelines_csv "$r" >"$outdir/pipelines.csv"
    jq -r -f "$GLB_ROOT/tools/sast-gate-recap.jq" "$r" >"$outdir/recap.md"
  else
    jq . "$r"
  fi

  sg_print_results "$r"
  sg_summary_box "$r" "$([ "$outdir" != - ] && printf '%s' "$outdir")"
  [ "$SG_RECAP" = 1 ] && { ui_nl; jq -r -f "$GLB_ROOT/tools/sast-gate-recap.jq" "$r"; }
  SG_LAST_DIR="$outdir"
  [ "$(jq '(.groups | map(select(.error != null)) | length) + (.failed_reads | length)' "$r")" -eq 0 ] || return 3
}

# ---------- outputs ----------
sg_to_csv() { # REPORT_JSON → one row per group + TOTAL
  jq -r '
    def row($n; $p; $s; $x): [$n, $p, $s, $x.projects_total, $x.projects_read, $x.repos_ran, $x.repos_no_sast, $x.repos_idle,
      $x.pipelines, $x.gate_pipelines, $x.passed, $x.break, $x.break_script, $x.break_infra, $x.warn, $x.canceled,
      $x.skipped, $x.running, $x.recovered, $x.pass_rate, $x.break_rate, $x.no_sast_pipelines, $x.jobs,
      $x.avg_duration_s, $x.p95_duration_s, $x.max_duration_s, $x.queue_avg_s, $x.queue_p95_s, $x.queue_max_s,
      $x.runner_peak.peak, $x.runner_peak.at];
    ["group","path","since","projects","projects_read","repos_ran_sast","repos_no_sast","repos_no_pipeline",
     "pipelines","gate_pipelines","passed","break","break_blocked","break_infra","failed_allowed","canceled",
     "skipped","running","passed_after_retry","pass_rate_pct","break_rate_pct","pipelines_without_sast","gate_jobs",
     "avg_job_s","p95_job_s","max_job_s","avg_queue_s","p95_queue_s","max_queue_s","runner_peak","runner_peak_at"],
    (.groups[] | row(.name; .path; .start; .)),
    row("TOTAL"; ""; .period.from; .totals)
    | @csv' "$1"
}

sg_pipelines_csv() { # REPORT_JSON → one row per pipeline
  jq -r '
    ["group","project","pipeline_id","created_at","branch","source","result","break_type","failure_reason","gate_jobs",
     "job_s","queue_s","retries","passed_after_retry","user","commit","sha","pipeline_status","pipeline_url","job_url"],
    (.pipelines[] | [.g, .project, .pipeline, .created_at, .ref, .source, .result, .break_type, .failure_reason,
      ((.jobs // []) | map("\(.name) (\(.status))") | join(" | ")), .duration_s, .queued_s, .retries, .recovered,
      .user, .commit, .sha, .pipeline_status, .pipeline_url, .job_url])
    | @csv' "$1"
}

_sg_num() { [ "$1" = null ] && printf '—' || printf '%s' "$1"; }
_sg_dur() { [ "$1" = null ] && printf '—' || ui_duration "${1%.*}"; }

sg_print_results() { # REPORT_JSON
  local f="$1" g tp rd ran ns gp pa br bp wa ot ad pd pk n
  ui_title "Per group" "gate pipelines = pipelines that ran $(jq -r '.options.jobs | join(", ")' "$f") · break % = break ÷ (passed + break + failed-allowed)"
  ui_nl
  printf '  %s%-16s %8s %6s %7s %8s %7s %7s %6s %6s %6s %8s %8s %6s%s\n' "$DIM" "GROUP" "PROJECTS" "RAN" "NO SAST" \
    "GATE PL" "PASSED" "BREAK" "BREAK%" "WARN" "OTHER" "AVG JOB" "P95 JOB" "PEAK" "$RST" >&2
  jq -r '(.groups[] | [.name, .projects_total, .repos_ran, .repos_no_sast, .gate_pipelines, .passed, .break,
           .break_rate, .warn, .other, .avg_duration_s, .p95_duration_s, .runner_peak.peak, (.error // "")]),
         (if (.groups | length) > 1 then .totals | ["TOTAL", .projects_total, .repos_ran, .repos_no_sast, .gate_pipelines,
           .passed, .break, .break_rate, .warn, .other, .avg_duration_s, .p95_duration_s, .runner_peak.peak, ""] else empty end)
         | map(tostring) | join("\u001f")' "$f" |
    while IFS=$'\x1f' read -r g tp ran ns gp pa br bp wa ot ad pd pk rd; do
      if [ -n "$rd" ]; then
        printf '  %-16s %s✖ not read: %s%s\n' "${g:0:16}" "$CR" "${rd:0:90}" "$RST" >&2; continue
      fi
      [ "$g" = TOTAL ] && printf '  %s%s%s\n' "$DIM" "$(ui_repeat ─ 118)" "$RST" >&2
      printf '  %-16s %8s %6s %7s %8s %s%7s%s %s%7s%s %6s %6s %6s %8s %8s %6s\n' "${g:0:16}" "$tp" "$ran" "$ns" "$gp" \
        "$CG" "$pa" "$RST" "$([ "$br" -gt 0 ] && printf '%s' "$CR")" "$br" "$RST" "$(_sg_num "$bp")" "$wa" "$ot" \
        "$(_sg_dur "$ad")" "$(_sg_dur "$pd")" "$pk" >&2
    done

  n=$(jq '.daily | length' "$f")
  if [ "$n" -gt 1 ]; then
    ui_title "Per day" "all groups"
    ui_nl
    printf '  %s%-10s %8s %7s %7s %7s %6s  %s%s\n' "$DIM" "DATE" "GATE PL" "PASSED" "BREAK" "BREAK%" "WARN" "" "$RST" >&2
    jq -r '(.daily | max_by(.gate_pipelines) | .gate_pipelines) as $m | .daily[-31:][]
      | [.date, .gate_pipelines, .passed, .break, .break_rate, .warn, $m] | map(tostring) | join("\u001f")' "$f" |
      while IFS=$'\x1f' read -r d gp pa br bp wa mx; do
        printf '  %-10s %8s %7s %s%7s%s %7s %6s  %s\n' "$d" "$gp" "$pa" "$([ "$br" -gt 0 ] && printf '%s' "$CR")" "$br" "$RST" \
          "$(_sg_num "$bp")" "$wa" "$(ui_minibar "$gp" "$mx" 20)" >&2
      done
    [ "$n" -gt 31 ] && ui_hint "last 31 of $n days shown · every day is in report.json"
  fi

  if [ "$(jq '.top_break_repos | length' "$f")" -gt 0 ]; then
    ui_title "Most breaks" "repos with the most BREAK pipelines"
    ui_nl
    jq -r '.top_break_repos[] | [.break, .gate_pipelines, .break_rate, .g, .project] | map(tostring) | join("\u001f")' "$f" |
      while IFS=$'\x1f' read -r br gp bp g p; do
        [ "${#p}" -gt 60 ] && p="…${p: -59}"
        printf '  %s✖%s %4s of %-4s %s(%s%%)%s  %-60s %s%s%s\n' "$CR" "$RST" "$br" "$gp" "$DIM" "$bp" "$RST" "$p" "$DIM" "$g" "$RST" >&2
      done
    [ "$(jq '.failure_reasons | length' "$f")" -gt 0 ] &&
      ui_hint "Why: $(jq -r '.failure_reasons | map("\(.reason) \(.count)") | join(" · ")' "$f")  ${DIM}(script_failure = the gate blocked it)${RST}"
    [ "$(jq '.top_break_branches | length' "$f")" -gt 0 ] &&
      ui_hint "Branches: $(jq -r '.top_break_branches | map("\(.ref) \(.break)") | join(" · ")' "$f")"
  fi

  n=$(jq '[.repositories[] | select(.status == "NO_SAST")] | length' "$f")
  if [ "$n" -gt 0 ]; then
    ui_title "Crosscheck — pipelines without the gate" "these repos ran pipelines on the tracked branches, but none had a matching job"
    ui_nl
    jq -r --argjson m "$SG_ROWS" '[.repositories[] | select(.status == "NO_SAST")] | .[:$m][]
      | [.no_sast_pipelines, .project, .g] | map(tostring) | join("\u001f")' "$f" |
      while IFS=$'\x1f' read -r c p g; do
        [ "${#p}" -gt 60 ] && p="…${p: -59}"
        printf '  %s %4s pipelines  %-60s %s%s%s\n' "$(_sg_icon NO_SAST)" "$c" "$p" "$DIM" "$g" "$RST" >&2
      done
    [ "$n" -gt "$SG_ROWS" ] && ui_hint "… $((n - SG_ROWS)) more in pipelines.csv (result NO_SAST)"
  fi
  if [ "$(jq '.failed_reads | length' "$f")" -gt 0 ]; then
    ui_nl
    jq -r '.failed_reads[:5][] | "\(.project): \(.error)"' "$f" | while IFS= read -r l; do ui_err "$l"; done
    [ "$(jq '.failed_reads | length' "$f")" -gt 5 ] && ui_hint "… every read error is in report.json (failed_reads)"
  fi
}

sg_summary_box() { # REPORT_JSON [DIR]
  local f="$1" lines=() t
  t=$(jq -c '.totals' "$f")
  _t() { printf '%s' "$t" | jq -r "$1"; }
  lines+=("${DIM}Period    ${RST} $(jq -r '"\(.period.from) → \(.period.to) (UTC\(.options.tz))"' "$f")")
  lines+=("${DIM}Groups    ${RST} $(jq -r '.groups | map(.name) | join(", ")' "$f")")
  lines+=("${DIM}Jobs      ${RST} $(jq -r '.options.jobs | join(", ")' "$f") ${DIM}· $(jq -r '.options.branches' "$f")${RST}")
  lines+=("${DIM}Pipelines ${RST} ${B}$(_t .gate_pipelines)${RST} ran the gate ${DIM}(of $(_t .pipelines) on these branches)${RST}")
  lines+=("$(_sg_icon PASSED) ${DIM}Passed  ${RST} $(_t .passed) ${DIM}($(_t '.pass_rate // "—"')%)$([ "$(_t .recovered)" -gt 0 ] && printf ' · %s after a retry' "$(_t .recovered)")${RST}")
  lines+=("$(_sg_icon BREAK) ${DIM}Break   ${RST} $(_t .break) ${DIM}($(_t '.break_rate // "—"')%) · $(_t .break_script) blocked by the gate · $(_t .break_infra) runner / timeout${RST}")
  [ "$(_t .warn)" -gt 0 ] && lines+=("$(_sg_icon WARN) ${DIM}Allowed ${RST} $(_t .warn) ${DIM}(failed, allow_failure)${RST}")
  [ "$(_t .other)" -gt 0 ] && lines+=("$(_sg_icon OTHER) ${DIM}Other   ${RST} $(_t .other) ${DIM}($(_t .canceled) canceled · $(_t .skipped) skipped/manual · $(_t .running) running)${RST}")
  [ "$(_t .jobs)" -gt 0 ] && lines+=("${DIM}Job time  ${RST} avg $(_sg_dur "$(_t .avg_duration_s)") · p95 $(_sg_dur "$(_t .p95_duration_s)") · max $(_sg_dur "$(_t .max_duration_s)") ${DIM}· queue avg $(_sg_dur "$(_t .queue_avg_s)") · p95 $(_sg_dur "$(_t .queue_p95_s)")${RST}")
  [ "$(_t .runner_peak.peak)" -gt 0 ] && lines+=("${DIM}Peak      ${RST} $(_t .runner_peak.peak) gate jobs at once ${DIM}($(_t .runner_peak.at))${RST}")
  lines+=("${DIM}Repos     ${RST} $(_t .projects_total) in the groups · $(_t .projects_read) read · ${B}$(_t .repos_ran)${RST} ran the gate · $(_t .repos_no_sast) without it · $(_t .repos_idle) no pipeline")
  [ "$(_t .repos_error)" -gt 0 ] && lines+=("${DIM}Errors    ${RST} ${CR}$(_t .repos_error) projects not read${RST}")
  [ "$(jq '.groups | map(select(.error != null)) | length' "$f")" -gt 0 ] &&
    lines+=("${DIM}Missing   ${RST} ${CR}$(jq -r '.groups | map(select(.error != null) | .name) | join(", ")' "$f") not read${RST}")
  lines+=("${DIM}Duration  ${RST} $(ui_duration "$(jq -r '.duration_seconds // 0' "$f")")")
  [ -n "$2" ] && lines+=("${DIM}Report    ${RST} ${CC}$(_bc_tilde "$2")/${RST} ${DIM}report.csv · pipelines.csv · recap.md · report.json${RST}")
  ui_nl
  ui_box "SAST gate recap" "${lines[@]}"
}

sg_view_report() { # REPORT_JSON
  ui_title "$(basename "$(dirname "$1")")" "generated $(jq -r '.generated_at' "$1")"
  SG_ROWS=15
  sg_print_results "$1"
  sg_summary_box "$1" "$(dirname "$1")"
}

# ---------- interactive ----------
sg_interactive() {
  local k v
  sg_defaults
  ui_title "$TOOL_SG_NAME" "How many pipelines passed or broke on the SAST gate, per group?"
  ui_nl
  if [ -z "$(cfg_resolve_name "")" ] && [ "$(cfg_count)" = 0 ]; then
    ui_warn "No GitLab connection yet."
    ui_confirm "Set up a connection now?" y || return
    setup_wizard || return
    ui_nl
  fi
  pick_profile "Which connection?" include_env || return
  SG_PROFILE="$PICKED_PROFILE"
  BC_PROFILE="$SG_PROFILE"
  bc_prepare_profile || return
  if [ -z "$GLB_HDR" ]; then
    ui_err "Profile '$GLB_PROFILE' has no token — this tool needs a PAT with read_api."
    ui_hint "Add one via Manage profiles → Change token."
    return
  fi

  ui_hint "Comma-separated LABEL=path/to/group or path/to/group. The same LABEL twice = one group in several locations."
  while :; do
    SC_GROUPS=()
    ui_input v "Groups" ""
    _sc_add_groups group "$v" || continue
    [ "${#SC_GROUPS[@]}" -gt 0 ] && break
    ui_warn "Enter at least one group."
  done
  ui_hint "Gate job names, comma-separated, case-insensitive, * = anything. E.g. sast:gate  ·  sast:gate,sast:pipeline-guard"
  while :; do ui_input SG_JOBS "Gate job names" "$SG_JOBS"; [ -n "$(_sc_glob_re "$SG_JOBS")" ] && break; done

  UI_HINTS=("Up to now" "Up to now" "Up to now" "e.g. the time the gate went live, up to now" "A start and an end")
  UI_SELECT_DEFAULT=1
  ui_select k "Period" "Last 24 hours" "Last 7 days (recommended)" "Last 30 days" "Since a date & time" "Custom range" || return
  case "$k" in
    0) SG_HOURS=24 ;;
    2) SG_DAYS=30 ;;
    3 | 4)
      ui_input SC_TZ "UTC offset" "$(date +%z)"
      _sc_parse_tz "$SC_TZ" || { SC_TZ=""; _sc_parse_tz ""; }
      while :; do ui_input SG_SINCE "From (YYYY-MM-DD HH:MM)" ""; [ -n "$(_sg_time "$SG_SINCE")" ] && break; ui_warn "Use YYYY-MM-DD HH:MM"; done
      if [ "$k" = 4 ]; then
        while :; do ui_input SG_UNTIL "To (YYYY-MM-DD HH:MM, empty = now)" ""; [ -z "$SG_UNTIL" ] || [ -n "$(_sg_time "$SG_UNTIL")" ] && break; ui_warn "Use YYYY-MM-DD HH:MM"; done
      fi ;;
  esac
  if [ "${#SC_GROUPS[@]}" -gt 1 ] && ui_confirm "Did some groups go live later (count them from their own start)?" n; then
    [ -n "$SC_TZ" ] || ui_input SC_TZ "UTC offset" "$(date +%z)"
    _sc_parse_tz "$SC_TZ" || { SC_TZ=""; _sc_parse_tz ""; }
    while :; do ui_input SG_GSINCE "LABEL=YYYY-MM-DD HH:MM, comma-separated" ""; _sg_check_gsince && break; done
  fi

  UI_HINTS=("$SG_BRANCHES + merge request pipelines" "Every branch and tag" "Type your own list")
  ui_select k "Branches" "Main branches (recommended)" "All branches" "Custom" || return
  case "$k" in
    1) SG_ALL_BRANCHES=1 ;;
    2) ui_input SG_BRANCHES "Branches (comma-separated)" "$SG_BRANCHES" ;;
  esac
  ui_confirm "Include archived projects?" n && SC_INCLUDE_ARCHIVED=1
  ui_input SG_OUT "Output folder" "$GLB_ROOT/reports" path

  ui_nl
  _sg_compute_period || return
  local glist="" g
  for g in "${SC_GROUPS[@]}"; do glist="${glist:+$glist, }$(printf '%s' "$g" | cut -f2)"; done
  ui_box "Ready to run" \
    "${DIM}Connect ${RST} $(profile_label "$SG_PROFILE")" \
    "${DIM}Groups  ${RST} $glist" \
    "${DIM}Jobs    ${RST} $SG_JOBS" \
    "${DIM}Period  ${RST} $SG_FROM_LABEL → $SG_TO_LABEL (UTC$SC_OFFSTR)${SG_GSINCE:+ ${DIM}· later start: $SG_GSINCE${RST}}" \
    "${DIM}Branches${RST} $([ "$SG_ALL_BRANCHES" = 1 ] && echo all || echo "$SG_BRANCHES + MR pipelines")" \
    "${DIM}Output  ${RST} $(_bc_tilde "$SG_OUT")"
  ui_nl
  UI_HINTS=("" "Answer all questions again" "Back to the main menu")
  ui_select k "Go?" "🚀 Run it!" "✏️  Start over" "✖  Cancel" || return
  case "$k" in 1) sg_interactive; return ;; 2) return ;; esac

  sg_run
  [ -d "${SG_LAST_DIR:-}" ] || return
  while :; do
    ui_nl
    UI_HINTS=("" "The text in recap.md, ready to paste into a chat" "Open in Finder / file manager" "")
    ui_select k "Next?" "← Back to the main menu" "📋 Show the recap text" "📂 Open the report folder" "Quit" || return
    case "$k" in
      0) return ;;
      1) ui_nl; cat "$SG_LAST_DIR/recap.md" >&2 ;;
      2) if command -v open >/dev/null; then open "$SG_LAST_DIR"; else xdg-open "$SG_LAST_DIR" >/dev/null 2>&1; fi ;;
      3) exit 0 ;;
    esac
  done
}

# ---------- flag mode ----------
sg_usage() {
  cat >&2 <<EOF

  ${B}gitlabbox.sh gate${RST} — $TOOL_SG_NAME

  ${B}Groups${RST} (comma-separated, repeatable; LABEL=path or just path; subgroup paths allowed)
    -g, --groups LIST          groups to recap (the same LABEL twice = one group in several locations)

  ${B}What counts${RST}
    -j, --jobs LIST            gate job names, comma-separated globs, case-insensitive (default: $SG_JOBS)
    -b, --branches LIST        branches (default: $SG_BRANCHES); merge request pipelines always count
        --all-branches         every branch and tag

  ${B}Period${RST} (default: the last 7 days up to now)
        --hours N              the last N hours
    -d, --days N               the last N days
        --since TIME           from TIME (YYYY-MM-DD HH:MM, or HH:MM = today)
        --until TIME           up to TIME (default: now; a bare date = end of that day)
        --group-since LIST     a later start for some groups: 'LABEL=YYYY-MM-DD HH:MM,…' (e.g. their go-live)
        --tz OFFSET            UTC offset for times and days (default: system, e.g. +07:00)

  ${B}Other${RST}
    -p, --profile NAME         profile with a PAT (read_api, Reporter on every group)
        --include-archived     include archived projects
    -w, --workers N            parallel projects (default 6)
    -o, --out DIR              parent folder (default: reports/) → DIR/<date>_sast-gate_<groups>/, or '-' for JSON on stdout
        --recap                also print the copy-paste recap (recap.md) on stdout

  ${B}Files${RST}
    report.csv      one row per group + TOTAL: passed, break, break %, job time, runner peak, repos ran / without the gate
    pipelines.csv   one row per pipeline: result (PASSED / BREAK / WARN / … / NO_SAST), why, job time, user, links
    recap.md        short text, ready to paste into a chat
    report.json     everything above + per day, per hour, per repo

  ${B}Examples${RST}
    ./gitlabbox.sh gate -g 'A=org/team-a,B=org/team-b' --hours 24
    ./gitlabbox.sh gate -g 'A=org/team-a,B=org/team-b' --since '2026-11-11 18:00' --group-since 'B=2026-11-17 09:00'
    ./gitlabbox.sh gate -g org/team-a -j 'sast:gate,sast:pipeline-guard' --days 30 --recap

  ${DIM}Exit codes: 0 report written · 1 error · 3 report written, but some groups or projects could not be read${RST}

EOF
}

sg_cli() {
  sg_defaults
  while [ $# -gt 0 ]; do
    case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;; esac
    case "$1" in
      -h | --help) sg_usage; return 0 ;;
      -p | --profile) SG_PROFILE="$2"; shift 2 ;;
      -g | --groups | --group) _sc_add_groups group "$2" || return 1; shift 2 ;;
      -j | --jobs) SG_JOBS="$2"; shift 2 ;;
      -b | --branches) SG_BRANCHES="$2"; shift 2 ;;
      --all-branches) SG_ALL_BRANCHES=1; shift ;;
      --hours) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--hours must be ≥ 1"; return 1; }; SG_HOURS="$2"; shift 2 ;;
      -d | --days) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--days must be ≥ 1"; return 1; }; SG_DAYS="$2"; shift 2 ;;
      --since) SG_SINCE="$2"; shift 2 ;;
      --until) SG_UNTIL="$2"; shift 2 ;;
      --group-since) SG_GSINCE="${SG_GSINCE:+$SG_GSINCE,}$2"; shift 2 ;;
      --tz) SC_TZ="$2"; shift 2 ;;
      --include-archived) SC_INCLUDE_ARCHIVED=1; shift ;;
      -w | --workers) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--workers must be ≥ 1"; return 1; }; SG_WORKERS="$2"; shift 2 ;;
      -o | --out) SG_OUT="$2"; shift 2 ;;
      --recap) SG_RECAP=1; shift ;;
      *) ui_err "Unknown option: $1"; sg_usage; return 1 ;;
    esac
  done
  if [ "${#SC_GROUPS[@]}" -eq 0 ]; then
    ui_err "No groups given. Use -g 'LABEL=path/to/group,…'."
    sg_usage
    return 1
  fi
  BC_PROFILE="$SG_PROFILE"
  bc_prepare_profile || return 1
  sg_run
}
