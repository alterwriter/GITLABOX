# shellcheck shell=bash
# tools/job-resources.sh — Job Resource Estimator.
#
# For the groups / repos you name: every run of the jobs you name (e.g. sast:gate, or * for all) → how long it
# ran, which runner and executor took it, how many ran at once, and the CPU / memory that load needs.
#
# GitLab does not record CPU or memory per job, so the size of one run comes from (first match wins):
#   1. a --size 'JOB=CPU/MEM' rule you give
#   2. a GLB_RES line in a log of that job, printed by the calibration snippet (--snippet)
#   3. KUBERNETES_CPU_REQUEST / KUBERNETES_MEMORY_REQUEST (or *_LIMIT) in the project's CI config
#   4. the default --size (1 vCPU / 2 GiB)
# Runs at once (from each run's start and finish) × size → CPU / memory needed at the peak, per runner and in total.
#
# GitLab APIs used (all read-only, scope read_api, token required):
#   GET /groups/:id/projects?include_subgroups=true        projects per group
#   GET /projects/:id                                      a single repo (--repos)
#   GET /projects/:id/jobs                                 jobs (newest first, stops at the period start)
#   GET /projects/:id/jobs/:job_id/trace                   the first KB of a few logs: executor, image, runner, GLB_RES
#   GET /projects/:id/ci/lint                              merged CI config → KUBERNETES_* variables (Developer)
#
# Analysis lives in tools/job-resources.jq. Group lists, period and timezone helpers are shared with the
# SAST Gate Capacity Planner and the SAST Gate Pass/Break Recap.

TOOL_JR_NAME="Job Resource Estimator"

jr_defaults() {
  JR_PROFILE=""
  SC_GROUPS=()            # "group|repo<TAB>label<TAB>path1|path2" (see _sc_add_groups)
  JR_JOBS="*"
  JR_DAYS=7
  JR_HOURS=""
  JR_SINCE=""
  JR_UNTIL=""
  SC_TZ=""
  JR_SIZE="1/2"           # default CPU/MEM per run, plus optional 'JOB=CPU/MEM' rules
  JR_SCALE=1
  JR_HEADROOM=20
  JR_SAMPLES=2            # logs read per job name per project (0 = none)
  JR_LOG_KB=64
  JR_CI=1
  SC_INCLUDE_ARCHIVED=0
  JR_WORKERS=6
  JR_OUT=""
  JR_ROWS=15
}

# job log (first KB) → executor, image, runner, and the GLB_RES line of the calibration snippet
JR_JQ_LOG='
  gsub("\u001b\\[[0-9;]*[A-Za-z]"; "") | gsub("section_(start|end):[0-9]+:[^\r\n]*\r"; "") | gsub("\r"; "\n")
  | split("\n") as $L
  | def cap($re): (first($L[] | capture($re)) | .x) // null;
  {id: $id, error: null,
   executor: cap("Preparing the \"(?<x>[^\"]+)\" executor"),
   image: cap("executor with image (?<x>[^ ]+)"),
   namespace: cap("Using Kubernetes namespace: (?<x>[^ ]+)"),
   runner_version: cap("Running with gitlab-runner (?<x>[^ ]+)"),
   runner_name: cap("^\\s+on (?<x>.+) [A-Za-z0-9_-]+(, system ID: .*)?$"),
   res: ((first($L[] | capture("^GLB_RES (?<x>cpu_usec=[0-9]+.*)$")) | .x
          | [scan("([a-z_]+)=([^ ]+)")] | map({key: .[0], value: .[1]}) | from_entries) // null)}'

# merged CI config → KUBERNETES_{CPU,MEMORY}_{REQUEST,LIMIT}, global (top-level variables:) and per job
JR_JQ_CI='
  def unq: gsub("^\\s+|\\s+$"; "") | gsub("\\s+#.*$"; "") | gsub("^[\"'"'"']|[\"'"'"']$"; "");
  def put($k; $v): if .cur == "variables" then .g[$k] = $v elif .cur != null then .j[.cur][$k] = $v else . end;
  (.merged_yaml // "") | split("\n")
  | reduce .[] as $l ({cur: null, pend: null, g: {}, j: {}};
      if ($l | test("^[^\\s#-]")) then
        .cur = ((($l | capture("^(?<k>\"[^\"]*\"|'"'"'[^'"'"']*'"'"'|\\S.*?):(\\s|$)")) | .k | unq) // null) | .pend = null
      elif ($l | test("^\\s+KUBERNETES_(CPU|MEMORY)_(REQUEST|LIMIT)\\s*:")) then
        ($l | capture("^\\s+(?<k>KUBERNETES_(CPU|MEMORY)_(REQUEST|LIMIT))\\s*:\\s*(?<v>.*)$")) as $m
        | ($m.v | unq) as $v
        | if $v == "" then .pend = $m.k else .pend = null | put($m.k; $v) end
      elif .pend != null and ($l | test("^\\s+value\\s*:")) then
        put(.pend; ($l | capture("value\\s*:\\s*(?<v>.*)$") | .v | unq)) | .pend = null
      else . end)
  | {pid: $pid, readable: true, error: null, global: .g, jobs: (.j | with_entries(select(.key | startswith(".") | not)))}'

jr_snippet() {
  cat <<'EOF'
# Calibration for the Job Resource Estimator (gitlabbox.sh resources).
# Use it in a SANDBOX repo, not in the real template: copy or include the job there and add this after_script.
# Every run then prints one GLB_RES line at the end of its log; add the sandbox repo with -r and the tool
# reads the real CPU and memory of that job from it.
sast:gate:                      # ← the name of the job you want to measure
  after_script:
    - |
      cg=/sys/fs/cgroup
      if [ -f $cg/cpu.stat ]; then   # cgroup v2
        cpu=$(awk '/^usage_usec/ {print $2}' $cg/cpu.stat)
        mem=$(cat $cg/memory.peak 2>/dev/null || cat $cg/memory.current)
        lim=$(cat $cg/memory.max); cq=$(tr ' ' / < $cg/cpu.max)
      else                           # cgroup v1
        cpu=$(( $(cat $cg/cpuacct/cpuacct.usage) / 1000 ))
        mem=$(cat $cg/memory/memory.max_usage_in_bytes)
        lim=$(cat $cg/memory/memory.limit_in_bytes)
        cq="$(cat $cg/cpu/cpu.cfs_quota_us)/$(cat $cg/cpu/cpu.cfs_period_us)"
      fi
      echo "GLB_RES cpu_usec=$cpu mem_peak=$mem mem_limit=$lim cpu_max=$cq nproc=$(nproc 2>/dev/null || echo 0)"
EOF
}

# "1/2" or "0.5/512Mi" → ok; CPU = cores or millicores (500m), MEM = GiB or a unit (512Mi, 2G, 2Gi)
_jr_size_ok() {
  printf '%s' "$1" | grep -Eq '^[0-9]+(\.[0-9]+)?m?/[0-9]+(\.[0-9]+)?([KkMmGgTt]i?[Bb]?)?$'
}

# --size LIST → JR_SIZE_JSON {size: {cpu, mem}, rules: [{glob, re, cpu, mem}]}
_jr_parse_sizes() {
  local item glob sz def="1/2" rules="[]" re
  while IFS= read -r item; do
    item=$(_sc_trim "$item"); [ -z "$item" ] && continue
    case "$item" in
      *=*) glob=$(_sc_trim "${item%%=*}"); sz=$(_sc_trim "${item#*=}") ;;
      *) glob=""; sz="$item" ;;
    esac
    sz=$(printf '%s' "$sz" | tr -d ' ')
    _jr_size_ok "$sz" || { ui_err "--size: '$item' should be CPU/MEM, e.g. 1/2 · 0.5/512Mi · sast:gate=2/4"; return 1; }
    if [ -z "$glob" ]; then def="$sz"; continue; fi
    re=$(_sc_glob_re "$glob")
    rules=$(jq -c --arg g "$glob" --arg re "$re" --arg c "${sz%%/*}" --arg m "${sz#*/}" '. + [{glob: $g, re: $re, cpu: $c, mem: $m}]' <<<"$rules")
  done < <(printf '%s\n' "$1" | tr ',' '\n')
  JR_SIZE_JSON=$(jq -nc --arg c "${def%%/*}" --arg m "${def#*/}" --argjson r "$rules" '{size: {cpu: $c, mem: $m}, rules: $r}')
}

_jr_compute_period() {
  local now
  _sc_parse_tz "$SC_TZ" || { ui_err "Invalid --tz: $SC_TZ (use e.g. +07:00)"; return 1; }
  now=$(date +%s)
  JR_END=$now
  if [ -n "$JR_UNTIL" ]; then
    JR_END=$(_sg_time "$JR_UNTIL")
    [ -n "$JR_END" ] || { ui_err "Invalid --until: $JR_UNTIL (use YYYY-MM-DD HH:MM)"; return 1; }
    case "$JR_UNTIL" in *:*) ;; *) JR_END=$((JR_END + 86400)) ;; esac
    [ "$JR_END" -gt "$now" ] && JR_END=$now
  fi
  if [ -n "$JR_SINCE" ]; then
    JR_START=$(_sg_time "$JR_SINCE")
    [ -n "$JR_START" ] || { ui_err "Invalid --since: $JR_SINCE (use YYYY-MM-DD HH:MM)"; return 1; }
  elif [ -n "$JR_HOURS" ]; then
    JR_START=$((JR_END - JR_HOURS * 3600))
  else
    JR_START=$((JR_END - JR_DAYS * 86400))
  fi
  [ "$JR_START" -lt "$JR_END" ] || { ui_err "The period start must be before its end."; return 1; }
  JR_FROM_LABEL=$(_sg_fmt "$JR_START"); JR_TO_LABEL=$(_sg_fmt "$JR_END")
  JR_JOB_RE=$(_sc_glob_re "$JR_JOBS")
  [ -n "$JR_JOB_RE" ] || { ui_err "Enter at least one job name (or * for every job)."; return 1; }
  _jr_parse_sizes "$JR_SIZE" || return 1
  _sc_is_num "$JR_SCALE" && [ "$(jq -n --arg s "$JR_SCALE" '$s | tonumber > 0')" = true ] ||
    { ui_err "--scale must be a number > 0 (e.g. 1.5)"; return 1; }
  export JR_START JR_END JR_JOB_RE SC_JQ_TS JR_SAMPLES JR_LOG_KB JR_CI JR_JQ_LOG JR_JQ_CI
}

# ---------- worker: one process per project ----------
# _jr_jobs PID OUT → matching jobs created in [JR_START, JR_END); newest first, stops at the first page older than the start
_jr_jobs() {
  local out="$2" page=1 pf="$2.page" n oldest
  while :; do
    api_get "/projects/$1/jobs?per_page=100&page=${page}" "$pf" || { rm -f "$pf" "$pf.hdr" "$pf.err"; return 1; }
    jq -c --arg g "$JR_G" --arg pp "$JR_P" --argjson pid "$JR_PID" --argjson s "$JR_START" --argjson e "$JR_END" \
      --arg re "$JR_JOB_RE" "$SC_JQ_TS"'
      .[] | (.created_at | ts) as $t | select($t != null and $t >= $s and $t < $e) | select((.name // "") | test($re; "i"))
      | {g: $g, project: $pp, pid: $pid, id, name, stage, status, ref, created: $t, started: (.started_at | ts),
         finished: (.finished_at | ts), duration: (.duration // null), queued: (.queued_duration // null),
         runner: (if .runner then .runner | {id, description, name, runner_type, is_shared} else {id: null} end),
         tags: (.tag_list // []), pipeline: (.pipeline.id // null), web_url}' "$pf" >>"$out"
    n=$(jq 'length' "$pf")
    oldest=$(jq "$SC_JQ_TS"'[.[].created_at | ts] | min // 0 | floor' "$pf")
    [ "$n" -lt 100 ] && break
    [ "$oldest" -lt "$JR_START" ] && break
    [ -z "$API_NEXT_PAGE" ] && break
    page="$API_NEXT_PAGE"
  done
  rm -f "$pf" "$pf.hdr" "$pf.err"
  return 0
}

jr_worker() {
  local i="$1" p base id
  p=$(jq -c --argjson i "$i" '.[$i]' "$JR_GDIR/projects.json")
  JR_G=$(printf '%s' "$p" | jq -r '.g'); JR_P=$(printf '%s' "$p" | jq -r '.path'); JR_PID=$(printf '%s' "$p" | jq -r '.id')
  base="$JR_GDIR/p/$(printf '%05d' "$i")"
  : >"$base.jobs"; : >"$base.logs"
  if ! _jr_jobs "$JR_PID" "$base.jobs"; then
    jq -nc --arg g "$JR_G" --arg p "$JR_P" --argjson pid "$JR_PID" --arg e "jobs: $API_ERROR" \
      '{g: $g, project: $p, pid: $pid, error: $e}' >"$base.error"
    printf '%s\n' "$i" >>"$JR_GDIR/done"
    return
  fi
  if [ -s "$base.jobs" ]; then
    # a few logs per job name: the newest run of each runner first, then the newest runs
    if [ "$JR_SAMPLES" -gt 0 ]; then
      jq -rs --argjson n "$JR_SAMPLES" '
        map(select(.started != null)) | group_by(.name)[] | sort_by(-.id)
        | reduce ((unique_by(.runner.id) | sort_by(-.id)) + .)[] as $j ([]; if any(.[]; .id == $j.id) then . else . + [$j] end)
        | .[:$n][] | .id' "$base.jobs" | while IFS= read -r id; do
        if api_get_head "/projects/$JR_PID/jobs/$id/trace" "$base.log" $((JR_LOG_KB * 1024)); then
          jq -Rsc --argjson id "$id" "$JR_JQ_LOG" "$base.log" >>"$base.logs" 2>/dev/null ||
            jq -nc --argjson id "$id" '{id: $id, error: "log could not be parsed"}' >>"$base.logs"
        else
          jq -nc --argjson id "$id" --arg e "$API_ERROR" '{id: $id, error: $e}' >>"$base.logs"
        fi
      done
      rm -f "$base.log" "$base.log.err"
    fi
    if [ "$JR_CI" = 1 ]; then
      if api_get "/projects/$JR_PID/ci/lint" "$base.lint"; then
        jq -c --argjson pid "$JR_PID" "$JR_JQ_CI" "$base.lint" >"$base.ci" 2>/dev/null ||
          jq -nc --argjson pid "$JR_PID" '{pid: $pid, readable: true, error: null, global: {}, jobs: {}}' >"$base.ci"
      else
        jq -nc --argjson pid "$JR_PID" --arg e "$API_ERROR" '{pid: $pid, readable: false, error: $e, global: {}, jobs: {}}' >"$base.ci"
      fi
      rm -f "$base.lint" "$base.lint.hdr" "$base.lint.err"
    fi
  fi
  printf '%s\n' "$i" >>"$JR_GDIR/done"
}

# ---------- collection for one group (or one set of repos) ----------
jr_collect_group() {
  local gi="$1" kind name path gdir total cand xpid d arch="&archived=false" gpth perr="" np nj nl
  local paths=()
  kind=$(printf '%s' "${SC_GROUPS[$gi]}" | cut -f1)
  name=$(printf '%s' "${SC_GROUPS[$gi]}" | cut -f2)
  path=$(printf '%s' "${SC_GROUPS[$gi]}" | cut -f3)
  while IFS= read -r gpth; do paths+=("$gpth"); done < <(printf '%s\n' "$path" | tr '|' '\n')
  np=${#paths[@]}
  path=$(printf '%s' "$path" | sed 's/|/, /g')
  gdir="$JR_WORK/g$gi"
  mkdir -p "$gdir/p"
  [ "$SC_INCLUDE_ARCHIVED" = 1 ] && arch=""

  printf '\n  %s[%d/%d]%s %s%s%s %s(%s%s)%s\n' "$DIM" $((gi + 1)) "${#SC_GROUPS[@]}" "$RST" "$B" "$name" "$RST" \
    "$DIM" "$([ "$kind" = repo ] && printf 'repos: ')" "$path" "$RST" >&2

  ui_spin_start "Listing projects$([ "$np" -gt 1 ] && printf ' (%s locations)' "$np")" "$gdir/count"
  : >"$gdir/all.jsonl"
  for gpth in "${paths[@]}"; do
    if [ "$kind" = repo ]; then
      if api_get "/projects/$(_uri "$gpth")" "$gdir/one.json"; then jq -c . "$gdir/one.json" >>"$gdir/all.jsonl"
      else perr="$gpth: $API_ERROR"; break; fi
    elif api_get_all "/groups/$(_uri "$gpth")/projects?include_subgroups=true&with_shared=false&simple=true$arch" "$gdir/one.json" 0 "$gdir/count"; then
      jq -c '.[]' "$gdir/one.json" >>"$gdir/all.jsonl"
    else
      perr="$gpth: $API_ERROR"; break
    fi
  done
  jq -s 'unique_by(.id)' "$gdir/all.jsonl" >"$gdir/all.json"
  if [ -n "$perr" ]; then
    ui_spin_stop 1 "Cannot read $([ "$kind" = repo ] && echo "the repo" || echo "projects"): $perr"
    jq -nc --arg n "$name" --arg k "$kind" --arg p "$path" --arg e "$perr" \
      '{name: $n, kind: $k, path: $p, projects_total: 0, projects_candidate: 0, error: $e}' >>"$JR_WORK/groups.jsonl"
    return 1
  fi
  # only projects with activity since the start can have a job in the period
  jq --arg g "$name" --argjson s "$JR_START" "$SC_JQ_TS"'
    map(select(.last_activity_at != null and (.last_activity_at | ts) >= ($s - 86400))
        | {g: $g, id, path: .path_with_namespace})' "$gdir/all.json" >"$gdir/projects.json"
  total=$(jq 'length' "$gdir/all.json")
  cand=$(jq 'length' "$gdir/projects.json")
  ui_spin_stop 0 "$total projects · ${B}$cand${RST} with activity since $JR_FROM_LABEL"

  if [ "$cand" -gt 0 ]; then
    export JR_GDIR="$gdir"
    : >"$gdir/done"
    cursor_hide
    seq 0 $((cand - 1)) | xargs -P "$JR_WORKERS" -n 1 "$GLB_SELF" __jr_project 2>>"$gdir/worker.log" &
    xpid=$!
    BC_XARGS_PID=$xpid
    while kill -0 "$xpid" 2>/dev/null; do
      d=$(wc -l <"$gdir/done" | tr -d ' ')
      ui_progress "$d" "$cand" "jobs + logs ${DIM}($JR_WORKERS workers)${RST}"
      sleep 0.15
    done
    wait "$xpid"
    BC_XARGS_PID=
    ui_progress_end
    cursor_show
  fi

  shopt -s nullglob
  local jbf=("$gdir"/p/*.jobs) lgf=("$gdir"/p/*.logs) cif=("$gdir"/p/*.ci) erf=("$gdir"/p/*.error)
  shopt -u nullglob
  cat "${jbf[@]}" /dev/null >>"$JR_WORK/jobs.jsonl"
  cat "${lgf[@]}" /dev/null >>"$JR_WORK/logs.jsonl"
  cat "${cif[@]}" /dev/null >>"$JR_WORK/ci.jsonl"
  cat "${erf[@]}" /dev/null >>"$JR_WORK/errs.jsonl"
  nj=$(cat "${jbf[@]}" /dev/null | sed -n '$=')
  nl=$(cat "${lgf[@]}" /dev/null | sed -n '$=')
  ui_ok "${nj:-0} job runs · ${nl:-0} logs sampled"
  [ "${#erf[@]}" -gt 0 ] && ui_warn "${#erf[@]} projects had read errors (first: $(jq -r '"\(.project): \(.error)"' "${erf[0]}"))"
  jq -nc --arg n "$name" --arg k "$kind" --arg p "$path" --argjson t "$total" --argjson c "$cand" \
    '{name: $n, kind: $k, path: $p, projects_total: $t, projects_candidate: $c, error: null}' >>"$JR_WORK/groups.jsonl"
  return 0
}

# ---------- run ----------
jr_run() {
  local i t0=$SECONDS r outdir P f
  if [ -z "$GLB_HDR" ]; then
    ui_err "Profile '$GLB_PROFILE' has no token. This tool needs a PAT with read_api (Reporter; Developer to read CI config)."
    return 1
  fi
  _jr_compute_period || return 1
  JR_WORK="$GLB_TMP/jr"
  rm -rf "$JR_WORK"; mkdir -p "$JR_WORK"
  for f in jobs logs ci groups errs; do : >"$JR_WORK/$f.jsonl"; done
  export JR_WORK GLB_TIMEOUT GLB_VERSION

  ui_title "Collecting job runs" "$JR_FROM_LABEL → $JR_TO_LABEL (UTC$SC_OFFSTR) · jobs: $JR_JOBS · $JR_SAMPLES logs per job name per project · $GLB_URL"
  for ((i = 0; i < ${#SC_GROUPS[@]}; i++)); do
    jr_collect_group "$i"
  done

  ui_nl
  ui_spin_start "Analyzing"
  for f in jobs logs ci groups errs; do jq -s . "$JR_WORK/$f.jsonl" >"$JR_WORK/$f.json"; done
  P=$(jq -nc --argjson s "$JR_START" --argjson e "$JR_END" --argjson o "$SC_OFF" --arg os "$SC_OFFSTR" \
    --argjson sc "$JR_SCALE" --argjson h "$JR_HEADROOM" --argjson z "$JR_SIZE_JSON" \
    '{start: $s, end: $e, off: $o, offstr: $os, scale: $sc, headroom: $h} + $z')
  r="$JR_WORK/report.json"
  if ! jq -n --argjson P "$P" --slurpfile jobs "$JR_WORK/jobs.json" --slurpfile logs "$JR_WORK/logs.json" \
    --slurpfile ci "$JR_WORK/ci.json" --slurpfile groups "$JR_WORK/groups.json" --slurpfile errs "$JR_WORK/errs.json" \
    -f "$GLB_ROOT/tools/job-resources.jq" >"$r.tmp" 2>"$JR_WORK/analyze.err"; then
    ui_spin_stop 1 "Analysis failed: $(head -c 300 "$JR_WORK/analyze.err")"
    return 1
  fi
  jq --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ver "$GLB_VERSION" --arg gl "$GLB_URL" --arg prof "$GLB_PROFILE" \
    --arg f "$JR_FROM_LABEL" --arg t "$JR_TO_LABEL" --argjson hrs "$(((JR_END - JR_START + 1800) / 3600))" \
    --argjson dur "$((SECONDS - t0))" --arg jobs "$JR_JOBS" --arg os "$SC_OFFSTR" --argjson P "$P" \
    --argjson smp "$JR_SAMPLES" --argjson ci "$([ "$JR_CI" = 1 ] && echo true || echo false)" \
    --argjson ia "$([ "$SC_INCLUDE_ARCHIVED" = 1 ] && echo true || echo false)" '
    {tool: "job-resources", gitlabbox_version: $ver, generated_at: $gen, duration_seconds: $dur, gitlab_url: $gl, profile: $prof,
     options: {jobs: ($jobs | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))), tz: $os,
               default_size: $P.size, size_rules: ($P.rules | map(del(.re))), scale: $P.scale, headroom_pct: $P.headroom,
               log_samples: $smp, read_ci_config: $ci, include_archived: $ia},
     period: {from: $f, to: $t, hours: $hrs}} + .' "$r.tmp" >"$r"
  ui_spin_stop 0 "Analysis done"

  outdir="${JR_OUT:-$GLB_ROOT/reports}"
  if [ "$outdir" != - ]; then
    outdir=$(make_report_dir "$outdir" job-resources "$(_sc_scope)") || { ui_err "Cannot create a report folder in $outdir"; return 1; }
    jq . "$r" >"$outdir/report.json"
    jr_to_csv "$r" >"$outdir/report.csv"
    jr_jobs_csv "$r" >"$outdir/jobs.csv"
    jr_runs_csv "$r" >"$outdir/runs.csv"
  else
    jq . "$r"
  fi

  jr_print_results "$r"
  jr_summary_box "$r" "$([ "$outdir" != - ] && printf '%s' "$outdir")"
  JR_LAST_DIR="$outdir"
  [ "$(jq '(.groups | map(select(.error != null)) | length) + (.failed_reads | length)' "$r")" -eq 0 ] || return 3
}

# ---------- outputs ----------
jr_to_csv() { # REPORT_JSON → the estimate sheet: TOTAL, then one row per group and per runner
  jq -r '
    def row($t; $n; $x): [$t, $n, $x.runs, $x.job_minutes, $x.cpu_hours, $x.jobs_peak, $x.jobs_p95, $x.peak_at,
      $x.cpu_peak, $x.cpu_p95, $x.mem_peak_gib, $x.mem_p95_gib, $x.recommended_cpu, $x.recommended_mem_gib,
      $x.busiest_hour.at, $x.busiest_hour.avg_jobs, $x.queue_p95_s];
    ["scope","name","runs","job_minutes","cpu_hours","peak_jobs_at_once","p95_jobs_at_once","peak_at",
     "peak_cpu","p95_cpu","peak_mem_gib","p95_mem_gib","recommended_cpu","recommended_mem_gib",
     "busiest_hour","busiest_hour_avg_jobs","queue_p95_s"],
    row("TOTAL"; ""; .totals),
    (.groups[] | select(.error == null) | row("group"; .name; .)),
    (.runners[] | row("runner"; "#\(.id // "?") \(.name // "")" + (if .executor then " (\(.executor))" else "" end); .))
    | @csv' "$1"
}

jr_jobs_csv() { # REPORT_JSON → one row per group × job name
  jq -r '
    ["group","job","runs","success","failed","canceled","projects","runners","avg_s","p50_s","p95_s","max_s",
     "queue_avg_s","queue_p95_s","queue_max_s","job_minutes","cpu","mem_gib","size_from","size_variants","measured_samples",
     "measured_cpu_avg","measured_cpu_max","measured_mem_max_gib","executors","images"],
    (.jobs_by_group[] | [.g, .name, .runs, .success, .failed, .canceled, .projects, .runners, .avg_s, .p50_s, .p95_s,
      .max_s, .queue_avg_s, .queue_p95_s, .queue_max_s, .job_minutes, .cpu, .mem_gib, .size_from, .size_variants,
      (.measured.samples // 0), .measured.cpu_avg, .measured.cpu_max, .measured.mem_max_gib,
      (.executors | to_entries | map("\(.key) \(.value)") | join(" | ")),
      (.images | keys | join(" | "))])
    | @csv' "$1"
}

jr_runs_csv() { # REPORT_JSON → one row per run
  jq -r '
    ["group","project","job_id","job","stage","status","branch","created_at","started_at","duration_s","queued_s",
     "runner_id","runner","executor","image","cpu","mem_gib","size_from","measured_cpu","measured_mem_gib","job_url"],
    (.runs[] | [.g, .project, .id, .name, .stage, .status, .ref, .created_at, .started_at, .duration_s, .queued_s,
      .runner_id, .runner, .executor, .image, .cpu, .mem_gib, .size_from, .measured.cores, .measured.mem_gib, .web_url])
    | @csv' "$1"
}

_jr_n() { [ "$1" = null ] && printf '—' || printf '%s' "$1"; }
_jr_dur() { [ "$1" = null ] && printf '—' || ui_duration "${1%.*}"; }

jr_print_results() { # REPORT_JSON
  local f="$1" n nm ru pr av p9 mx qp mi cp me sf ex id ty pk pc pm bh rd

  ui_title "Per job" "size = CPU / memory of one run · from: rule (--size) · measured (GLB_RES) · ci-config · assumed · + = sizes differ per project"
  ui_nl
  printf '  %s%-28s %6s %5s %8s %8s %8s %8s %8s %5s %6s %-9s %s%s\n' "$DIM" "JOB" "RUNS" "PROJ" "AVG" "P95" "MAX" \
    "QUEUE95" "MINUTES" "CPU" "MEM" "SIZE FROM" "EXECUTOR" "$RST" >&2
  jq -r --argjson m "$JR_ROWS" '.jobs[:$m][] | [.name, .runs, .projects, .avg_s, .p95_s, .max_s, .queue_p95_s, .job_minutes,
      .cpu, .mem_gib, (.size_from + (if .size_variants > 1 then "+" else "" end)),
      (.executors | keys | join(", ") | if . == "" then "—" else . end)]
      | map(tostring) | join("\u001f")' "$f" |
    while IFS=$'\x1f' read -r nm ru pr av p9 mx qp mi cp me sf ex; do
      [ "${#nm}" -gt 28 ] && nm="${nm:0:27}…"
      printf '  %-28s %6s %5s %8s %8s %8s %8s %8s %5s %6s %-9s %s\n' "$nm" "$ru" "$pr" "$(_jr_dur "$av")" "$(_jr_dur "$p9")" \
        "$(_jr_dur "$mx")" "$(_jr_dur "$qp")" "$mi" "$cp" "$me" "$sf" "$ex" >&2
    done
  n=$(jq '.jobs | length' "$f")
  [ "$n" -gt "$JR_ROWS" ] && ui_hint "… $((n - JR_ROWS)) more job names in jobs.csv"

  if [ "$(jq '.runners | length' "$f")" -gt 0 ]; then
    ui_title "Per runner" "at once = runs overlapping in time · CPU / MEM = sum of the sizes of the runs at once"
    ui_nl
    printf '  %s%-30s %-10s %-11s %6s %8s %6s %5s %6s %8s %-16s %8s%s\n' "$DIM" "RUNNER" "TYPE" "EXECUTOR" "RUNS" "MINUTES" \
      "PEAK" "P95" "CPU" "MEM GiB" "BUSIEST HOUR" "QUEUE95" "$RST" >&2
    jq -r --argjson m "$JR_ROWS" '.runners[:$m][] | ["#\(.id // "?") \(.name // "")", (.type // "—"), (.executor // "—"),
        .runs, .job_minutes, .jobs_peak, .jobs_p95, .cpu_peak, .mem_peak_gib, (.busiest_hour.at // "—"), .queue_p95_s]
        | map(tostring) | join("\u001f")' "$f" |
      while IFS=$'\x1f' read -r id ty ex ru mi pk p9 pc pm bh qp; do
        [ "${#id}" -gt 30 ] && id="${id:0:29}…"
        printf '  %-30s %-10s %-11s %6s %8s %6s %5s %6s %8s %-16s %8s\n' "$id" "${ty%_type}" "${ex:0:11}" "$ru" "$mi" "$pk" "$p9" \
          "$pc" "$pm" "$bh" "$(_jr_dur "$qp")" >&2
      done
    n=$(jq '.runners | length' "$f")
    [ "$n" -gt "$JR_ROWS" ] && ui_hint "… $((n - JR_ROWS)) more runners in report.csv"
  fi

  if [ "$(jq '.groups | length' "$f")" -gt 1 ]; then
    ui_title "Per group" "the load of each group on its own, on every runner"
    ui_nl
    printf '  %s%-20s %8s %6s %8s %6s %6s %8s %13s%s\n' "$DIM" "GROUP" "PROJECTS" "RUNS" "MINUTES" "PEAK" "CPU" "MEM GiB" \
      "RECOMMENDED" "$RST" >&2
    jq -r '.groups[] | [.name, .projects_total, .runs, .job_minutes, .jobs_peak, .cpu_peak, .mem_peak_gib,
        "\(.recommended_cpu) / \(.recommended_mem_gib)", (.error // "")] | map(tostring) | join("\u001f")' "$f" |
      while IFS=$'\x1f' read -r nm pr ru mi pk pc pm cp rd; do
        if [ -n "$rd" ]; then printf '  %-20s %s✖ not read: %s%s\n' "${nm:0:20}" "$CR" "${rd:0:90}" "$RST" >&2; continue; fi
        printf '  %-20s %8s %6s %8s %6s %6s %8s %13s\n' "${nm:0:20}" "$pr" "$ru" "$mi" "$pk" "$pc" "$pm" "$cp" >&2
      done
  fi

  if [ "$(jq '.totals.runs' "$f")" -gt 0 ]; then
    ui_title "Per hour of the day" "average runs at once (all days) · UTC$(jq -r '.options.tz' "$f")"
    ui_nl
    jq -r '(.by_hour | max_by(.avg_jobs) | .avg_jobs) as $m | .by_hour[] | [.hour, .avg_jobs, .avg_cpu, $m]
      | map(tostring) | join("\u001f")' "$f" |
      while IFS=$'\x1f' read -r h aj ac mx; do
        printf '  %02d:00  %6s jobs %6s CPU  %s\n' "$h" "$aj" "$ac" \
          "$(ui_minibar "$(jq -n --arg a "$aj" '$a | tonumber * 100 | round')" "$(jq -n --arg a "$mx" '$a | tonumber * 100 | round')" 30)" >&2
      done
  fi

  if [ "$(jq '.failed_reads | length' "$f")" -gt 0 ]; then
    ui_nl
    jq -r '.failed_reads[:5][] | "\(.project): \(.error)"' "$f" | while IFS= read -r l; do ui_err "$l"; done
    [ "$(jq '.failed_reads | length' "$f")" -gt 5 ] && ui_hint "… every read error is in report.json (failed_reads)"
  fi
}

jr_summary_box() { # REPORT_JSON [DIR]
  local f="$1" lines=() t as
  t=$(jq -c '.totals' "$f")
  _t() { printf '%s' "$t" | jq -r "$1"; }
  lines+=("${DIM}Period    ${RST} $(jq -r '"\(.period.from) → \(.period.to) (UTC\(.options.tz))"' "$f")")
  lines+=("${DIM}Scope     ${RST} $(jq -r '.groups | map(.name) | join(", ")' "$f") ${DIM}· $(_t .projects_total) projects · $(_t .projects_with_runs) with runs${RST}")
  lines+=("${DIM}Jobs      ${RST} $(jq -r '.options.jobs | join(", ")' "$f") ${DIM}· $(_t .runs) runs · $(_t .job_minutes) job minutes · $(_t .runners) runners${RST}")
  lines+=("${DIM}Executor  ${RST} $(_t '.executors | to_entries | map("\(.key) \(.value)") | join(" · ") | if . == "" then "—" else . end') ${DIM}(runs)${RST}")
  lines+=("${DIM}Size from ${RST} $(_t '.size_from | to_entries | map("\(.key) \(.value)") | join(" · ") | if . == "" then "—" else . end') ${DIM}(default $(jq -r '"\(.options.default_size.cpu) vCPU / \(.options.default_size.mem) GiB"' "$f"))${RST}")
  if [ "$(_t .runs)" -gt 0 ]; then
    lines+=("${DIM}At once   ${RST} peak ${B}$(_t .jobs_peak)${RST} runs ${DIM}($(_t .peak_at)) · p95 $(_t .jobs_p95)${RST}")
    lines+=("${DIM}CPU       ${RST} peak ${B}$(_t .cpu_peak)${RST} vCPU ${DIM}· p95 $(_t .cpu_p95) · $(_t .cpu_hours) CPU hours${RST}")
    lines+=("${DIM}Memory    ${RST} peak ${B}$(_t .mem_peak_gib)${RST} GiB ${DIM}· p95 $(_t .mem_p95_gib)${RST}")
    lines+=("${CG}Needed    ${RST} ${B}$(_t .recommended_cpu) vCPU / $(_t .recommended_mem_gib) GiB${RST} ${DIM}(peak$(jq -r 'if .options.scale != 1 then " × \(.options.scale)" else "" end' "$f") + $(jq -r '.options.headroom_pct' "$f")% headroom)${RST}")
    [ "$(_t '.busiest_hour != null')" = true ] &&
      lines+=("${DIM}Busiest   ${RST} $(_t .busiest_hour.at) ${DIM}· avg $(_t .busiest_hour.avg_jobs) runs at once$([ "$(_t '.queue_p95_s // 0 | . > 60')" = true ] && printf ' · queue p95 %s' "$(_jr_dur "$(_t .queue_p95_s)")")${RST}")
  fi
  lines+=("${DIM}Logs      ${RST} $(jq -r '.logs | "\(.read) read · \(.with_executor) showed the executor · \(.measured) with GLB_RES" + (if .failed > 0 then " · \(.failed) not readable" else "" end)' "$f")")
  [ "$(jq -r '.options.read_ci_config' "$f")" = true ] &&
    lines+=("${DIM}CI config ${RST} $(jq -r '.ci_config | "\(.readable) read · \(.with_kubernetes_vars) set KUBERNETES_* sizes" + (if .not_readable > 0 then " · \(.not_readable) not readable (needs Developer)" else "" end)' "$f")")
  [ "$(_t .projects_not_read)" -gt 0 ] && lines+=("${DIM}Errors    ${RST} ${CR}$(_t .projects_not_read) projects not read${RST}")
  [ "$(jq '.groups | map(select(.error != null)) | length' "$f")" -gt 0 ] &&
    lines+=("${DIM}Missing   ${RST} ${CR}$(jq -r '.groups | map(select(.error != null) | .name) | join(", ")' "$f") not read${RST}")
  lines+=("${DIM}Duration  ${RST} $(ui_duration "$(jq -r '.duration_seconds // 0' "$f")")")
  [ -n "$2" ] && lines+=("${DIM}Report    ${RST} ${CC}$(_bc_tilde "$2")/${RST} ${DIM}report.csv · jobs.csv · runs.csv · report.json${RST}")
  ui_nl
  ui_box "Job resource estimate" "${lines[@]}"
  as=$(_t '((.size_from.assumed // 0) * 100 / ([.runs, 1] | max)) | floor')
  if [ "$(_t .runs)" -gt 0 ] && [ "$as" -ge 50 ]; then
    ui_hint "$as% of the runs use the assumed size. GitLab does not record CPU / memory per job:"
    ui_hint "give the real size with --size 'JOB=CPU/MEM', or measure it once in a sandbox repo (./gitlabbox.sh resources --snippet)."
  fi
}

jr_view_report() { # REPORT_JSON
  ui_title "$(basename "$(dirname "$1")")" "generated $(jq -r '.generated_at' "$1")"
  JR_ROWS=15
  jr_print_results "$1"
  jr_summary_box "$1" "$(dirname "$1")"
}

# ---------- interactive ----------
jr_interactive() {
  local k v
  jr_defaults
  ui_title "$TOOL_JR_NAME" "How long do the jobs run, how many at once, and how much CPU / memory does that need?"
  ui_nl
  if [ -z "$(cfg_resolve_name "")" ] && [ "$(cfg_count)" = 0 ]; then
    ui_warn "No GitLab connection yet."
    ui_confirm "Set up a connection now?" y || return
    setup_wizard || return
    ui_nl
  fi
  pick_profile "Which connection?" include_env || return
  JR_PROFILE="$PICKED_PROFILE"
  BC_PROFILE="$JR_PROFILE"
  bc_prepare_profile || return
  if [ -z "$GLB_HDR" ]; then
    ui_err "Profile '$GLB_PROFILE' has no token — this tool needs a PAT with read_api."
    ui_hint "Add one via Manage profiles → Change token."
    return
  fi

  SC_GROUPS=()
  UI_HINTS=("Every project in one or more groups (subgroups included)" "One or more repos" "Groups and repos")
  ui_select k "What to read?" "Groups" "Repos" "Both" || return
  if [ "$k" != 1 ]; then
    ui_hint "Comma-separated LABEL=path/to/group or path/to/group. The same LABEL twice = one group in several locations."
    while :; do
      ui_input v "Groups" ""
      _sc_add_groups group "$v" || continue
      [ "${#SC_GROUPS[@]}" -gt 0 ] && break
      ui_warn "Enter at least one group."
    done
  fi
  if [ "$k" != 0 ]; then
    ui_hint "Comma-separated LABEL=path/to/repo or path/to/repo. Repos with the same LABEL are counted together."
    while :; do
      ui_input v "Repos" ""
      [ -n "$(_sc_trim "$v")" ] || { ui_warn "Enter at least one repo."; continue; }
      _sc_add_groups repo "$v" && break
    done
  fi
  ui_hint "Job names, comma-separated, case-insensitive, * = anything. E.g. sast:gate  ·  build*,test:*  ·  * (every job)"
  while :; do ui_input JR_JOBS "Job names" "$JR_JOBS"; [ -n "$(_sc_glob_re "$JR_JOBS")" ] && break; done

  UI_HINTS=("Up to now" "Up to now" "Up to now" "Up to now" "A start and an end")
  UI_SELECT_DEFAULT=1
  ui_select k "Period" "Last 24 hours" "Last 7 days (recommended)" "Last 30 days" "Since a date & time" "Custom range" || return
  case "$k" in
    0) JR_HOURS=24 ;;
    2) JR_DAYS=30 ;;
    3 | 4)
      ui_input SC_TZ "UTC offset" "$(date +%z)"
      _sc_parse_tz "$SC_TZ" || { SC_TZ=""; _sc_parse_tz ""; }
      while :; do ui_input JR_SINCE "From (YYYY-MM-DD HH:MM)" ""; [ -n "$(_sg_time "$JR_SINCE")" ] && break; ui_warn "Use YYYY-MM-DD HH:MM"; done
      if [ "$k" = 4 ]; then
        while :; do ui_input JR_UNTIL "To (YYYY-MM-DD HH:MM, empty = now)" ""; [ -z "$JR_UNTIL" ] || [ -n "$(_sg_time "$JR_UNTIL")" ] && break; ui_warn "Use YYYY-MM-DD HH:MM"; done
      fi ;;
  esac

  ui_hint "CPU/MEM for one run when nothing better is known (no rule, no GLB_RES, no KUBERNETES_* in the CI config)."
  ui_hint "E.g. 1/2 = 1 vCPU / 2 GiB · 0.5/512Mi · add rules: sast:gate=2/4,1/2"
  while :; do ui_input JR_SIZE "Size per run" "$JR_SIZE"; _jr_parse_sizes "$JR_SIZE" && break; done
  ui_hint "1 = as measured. 3 = what if the load triples (e.g. more groups onboard)."
  while :; do
    ui_input JR_SCALE "Scale the load" "$JR_SCALE"
    _sc_is_num "$JR_SCALE" && [ "$(jq -n --arg s "$JR_SCALE" '$s | tonumber > 0')" = true ] && break
    ui_warn "Use a number > 0"
  done
  ui_confirm "Include archived projects?" n && SC_INCLUDE_ARCHIVED=1
  ui_input JR_OUT "Output folder" "$GLB_ROOT/reports" path

  ui_nl
  _jr_compute_period || return
  local glist="" g
  for g in "${SC_GROUPS[@]}"; do glist="${glist:+$glist, }$(printf '%s' "$g" | cut -f2)"; done
  ui_box "Ready to run" \
    "${DIM}Connect ${RST} $(profile_label "$JR_PROFILE")" \
    "${DIM}Scope   ${RST} $glist" \
    "${DIM}Jobs    ${RST} $JR_JOBS" \
    "${DIM}Period  ${RST} $JR_FROM_LABEL → $JR_TO_LABEL (UTC$SC_OFFSTR)" \
    "${DIM}Size    ${RST} $JR_SIZE ${DIM}(CPU/MEM per run)$([ "$JR_SCALE" != 1 ] && printf ' · load × %s' "$JR_SCALE")${RST}" \
    "${DIM}Output  ${RST} $(_bc_tilde "$JR_OUT")"
  ui_nl
  UI_HINTS=("" "Answer all questions again" "Back to the main menu")
  ui_select k "Go?" "🚀 Run it!" "✏️  Start over" "✖  Cancel" || return
  case "$k" in 1) jr_interactive; return ;; 2) return ;; esac

  jr_run
  [ -d "${JR_LAST_DIR:-}" ] || return
  while :; do
    ui_nl
    UI_HINTS=("" "after_script for a sandbox repo: prints the real CPU / memory of a job in its log" "Open in Finder / file manager" "")
    ui_select k "Next?" "← Back to the main menu" "🧪 Show the calibration snippet" "📂 Open the report folder" "Quit" || return
    case "$k" in
      0) return ;;
      1) ui_nl; jr_snippet >&2 ;;
      2) if command -v open >/dev/null; then open "$JR_LAST_DIR"; else xdg-open "$JR_LAST_DIR" >/dev/null 2>&1; fi ;;
      3) exit 0 ;;
    esac
  done
}

# ---------- flag mode ----------
jr_usage() {
  cat >&2 <<EOF

  ${B}gitlabbox.sh resources${RST} — $TOOL_JR_NAME

  ${B}Scope${RST} (comma-separated, repeatable; LABEL=path or just path)
    -g, --groups LIST          groups (subgroups included; the same LABEL twice = one group in several locations)
    -r, --repos LIST           repos (the same LABEL on several repos = counted together)

  ${B}What counts${RST}
    -j, --jobs LIST            job names, comma-separated globs, case-insensitive (default: * = every job)

  ${B}Period${RST} (default: the last 7 days up to now)
        --hours N  /  -d, --days N  /  --since TIME  /  --until TIME  /  --tz OFFSET   (same as 'gate')

  ${B}Size${RST} (GitLab does not record CPU / memory per job)
        --size LIST            CPU/MEM per run when nothing better is known (default: $JR_SIZE = 1 vCPU / 2 GiB),
                               plus rules per job: 'sast:gate=2/4,build*=1/1.5,1/2' (CPU: 0.5 or 500m · MEM: GiB or 512Mi)
        --scale X              multiply the load, e.g. 3 = what if three times as many pipelines run (default 1)
        --headroom PCT         added on top of the peak for the recommendation (default $JR_HEADROOM)
        --samples N            logs read per job name per project: executor, image, GLB_RES (default $JR_SAMPLES, 0 = none)
        --log-kb N             read the first N KB of each log (default $JR_LOG_KB)
        --no-ci-config         don't read KUBERNETES_* sizes from the CI config (saves one request per project)
        --snippet              print the calibration after_script (measure a job once in a sandbox repo) and exit

  ${B}Other${RST}
    -p, --profile NAME         profile with a PAT (read_api; Reporter, Developer to read CI config)
        --include-archived     include archived projects
    -w, --workers N            parallel projects (default 6)
    -o, --out DIR              parent folder (default: reports/) → DIR/<date>_job-resources_<scope>/, or '-' for JSON on stdout

  ${B}Files${RST}
    report.csv      the estimate: TOTAL, per group, per runner → runs at once, CPU / memory at the peak and p95, recommended
    jobs.csv        per group × job: runs, duration avg / p50 / p95 / max, queue, size and where it came from, executor
    runs.csv        one row per run: runner, executor, image, size, measured CPU / memory (GLB_RES)
    report.json     everything above + per hour of the day, per day, logs and CI config read

  ${B}Examples${RST}
    ./gitlabbox.sh resources -g 'A=org/team-a,B=org/team-b' -j 'sast:gate'
    ./gitlabbox.sh resources -g org/team-a -j '*' --size 'sast:gate=2/4,1/2' --days 30
    ./gitlabbox.sh resources -g org/team-a -r 'sandbox=me/sast-sandbox' -j sast:gate --scale 3
    ./gitlabbox.sh resources --snippet > calibrate.yml

  ${DIM}Exit codes: 0 report written · 1 error · 3 report written, but some groups or projects could not be read${RST}

EOF
}

jr_cli() {
  jr_defaults
  while [ $# -gt 0 ]; do
    case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;; esac
    case "$1" in
      -h | --help) jr_usage; return 0 ;;
      --snippet) jr_snippet; return 0 ;;
      -p | --profile) JR_PROFILE="$2"; shift 2 ;;
      -g | --groups | --group) _sc_add_groups group "$2" || return 1; shift 2 ;;
      -r | --repos | --repo) _sc_add_groups repo "$2" || return 1; shift 2 ;;
      -j | --jobs) JR_JOBS="$2"; shift 2 ;;
      --hours) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--hours must be ≥ 1"; return 1; }; JR_HOURS="$2"; shift 2 ;;
      -d | --days) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--days must be ≥ 1"; return 1; }; JR_DAYS="$2"; shift 2 ;;
      --since) JR_SINCE="$2"; shift 2 ;;
      --until) JR_UNTIL="$2"; shift 2 ;;
      --tz) SC_TZ="$2"; shift 2 ;;
      --size) JR_SIZE="$2"; shift 2 ;;
      --scale) JR_SCALE="$2"; shift 2 ;;
      --headroom) _bc_is_int "$2" || { ui_err "--headroom must be a whole number (percent)"; return 1; }; JR_HEADROOM="$2"; shift 2 ;;
      --samples) _bc_is_int "$2" || { ui_err "--samples must be ≥ 0"; return 1; }; JR_SAMPLES="$2"; shift 2 ;;
      --log-kb) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--log-kb must be ≥ 1"; return 1; }; JR_LOG_KB="$2"; shift 2 ;;
      --no-ci-config) JR_CI=0; shift ;;
      --include-archived) SC_INCLUDE_ARCHIVED=1; shift ;;
      -w | --workers) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--workers must be ≥ 1"; return 1; }; JR_WORKERS="$2"; shift 2 ;;
      -o | --out) JR_OUT="$2"; shift 2 ;;
      *) ui_err "Unknown option: $1"; jr_usage; return 1 ;;
    esac
  done
  if [ "${#SC_GROUPS[@]}" -eq 0 ]; then
    ui_err "Nothing to read. Use -g 'LABEL=path/to/group,…' and/or -r 'path/to/repo,…'."
    jr_usage
    return 1
  fi
  BC_PROFILE="$JR_PROFILE"
  bc_prepare_profile || return 1
  jr_run
}
