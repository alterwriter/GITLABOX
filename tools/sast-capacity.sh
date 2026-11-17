# shellcheck shell=bash
# tools/sast-capacity.sh — SAST Gate Capacity Planner.
#
# Collects push / merge traffic on the tracked branches of the groups you name,
# measures actual SAST jobs for groups already onboarded on the existing runner,
# calibrates the estimate against those actuals, and checks whether every group
# fits on a dedicated runner of a given capacity.
#
# GitLab APIs used (all read-only, scope read_api, token required):
#   GET /groups/:id/projects?include_subgroups=true      projects per group
#   GET /projects/:id/events?action=pushed&after&before  push events
#   GET /groups/:id/merge_requests?state=merged&target_branch=B&updated_after
#   GET /projects/:id/jobs                               SAST jobs (onboarded groups)
#   GET /runners/:id/jobs                                optional, runner owner/admin only
#
# Analysis lives in tools/sast-capacity.jq, the Markdown report in tools/sast-capacity-report.jq.

TOOL_SC_NAME="SAST Gate Capacity Planner"

SC_JQ_TS='def ts: if . == null then null else
  (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")) as $m
  | (($m.d + "Z") | fromdateiso8601)
    - (if ($m.z // "Z") == "Z" then 0
       else ($m.z | capture("(?<sg>[+-])(?<h>[0-9]{2}):?(?<mi>[0-9]{2})")) as $o
         | (($o.h | tonumber) * 3600 + ($o.mi | tonumber) * 60) * (if $o.sg == "+" then 1 else -1 end) end) end;'

sc_defaults() {
  SC_PROFILE=""
  SC_GROUPS=()            # "status<TAB>name<TAB>path"
  SC_BRANCHES="dev,develop,development,main,master"
  SC_DAYS=30
  SC_UNTIL=""
  SC_TZ=""
  SC_JOB_GLOB="*sast*"
  SC_RUNNER_IDS=""
  SC_CAP_EXISTING=50
  SC_CAP=100
  SC_JPE=2
  SC_JOB_MIN=3
  SC_MEASURED=1
  SC_SAFETY=20
  SC_QUEUE_THR=30
  SC_WORKERS=6
  SC_OUT=""
  SC_INCLUDE_ARCHIVED=0
}

_sc_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
_sc_is_num() { case "$1" in '' | *[!0-9.]* | *.*.*) return 1 ;; *) return 0 ;; esac; }

# _sc_add_groups STATUS "LABEL=path, path2, ..." → appends to SC_GROUPS ("status<TAB>label<TAB>path1|path2"), returns 1 on bad input
#   - the same LABEL with different paths in one list = one group spread over several locations (merged)
#   - the same path twice, a label in both lists, or a parent + its own subgroup under different labels → rejected
_sc_add_groups() {
  local status="$1" item name path i g gs gn gp p merged
  while IFS= read -r item; do
    item=$(_sc_trim "$item")
    [ -z "$item" ] && continue
    case "$item" in
      *=*) name=$(_sc_trim "${item%%=*}"); path=$(_sc_trim "${item#*=}") ;;
      *) name=""; path="$item" ;;
    esac
    if ! parse_target "$path" || [ "$T_KIND" = account ]; then
      ui_err "Invalid group: $item"; return 1
    fi
    path="$T_PATH"
    [ -n "$T_HOST" ] && path="${path#groups/}"   # https://host/groups/org/team (older group URL form)
    [ -z "$name" ] && name="$path"
    merged=-1
    for i in "${!SC_GROUPS[@]}"; do
      g="${SC_GROUPS[$i]}"
      gs=$(printf '%s' "$g" | cut -f1); gn=$(printf '%s' "$g" | cut -f2); gp=$(printf '%s' "$g" | cut -f3)
      while IFS= read -r p; do
        if [ "$p" = "$path" ]; then
          ui_err "'$path' is listed twice$([ "$gn" != "$name" ] && printf " (already as '%s')" "$gn")."; return 1
        fi
        if [ "$gn" != "$name" ]; then
          case "$path/" in "$p"/*)
            ui_err "'$path' ($name) is inside '$p' ($gn) — its projects would be counted twice. Remove one of them."; return 1 ;;
          esac
          case "$p/" in "$path"/*)
            ui_err "'$p' ($gn) is inside '$path' ($name) — its projects would be counted twice. Remove one of them."; return 1 ;;
          esac
        fi
      done < <(printf '%s\n' "$gp" | tr '|' '\n')
      if [ "$gn" = "$name" ]; then
        if [ "$gs" != "$status" ]; then
          ui_err "'$name' is already in the $(printf '%s' "$gs" | sed 's/onboarded/measured (already on the existing runner)/; s/target/estimated (not onboarded yet)/') list. Put each group in one list only."
          return 1
        fi
        merged=$i
      fi
    done
    if [ "$merged" -ge 0 ]; then
      SC_GROUPS[$merged]="${SC_GROUPS[$merged]}|$path"
    else
      SC_GROUPS+=("$status	$name	$path")
    fi
  done < <(printf '%s\n' "$2" | tr ',' '\n')
  return 0
}

# glob list ("*sast*,secret-*") → anchored regex
_sc_glob_re() {
  local g out="" r
  while IFS= read -r g; do
    g=$(_sc_trim "$g")
    [ -z "$g" ] && continue
    r=$(printf '%s' "$g" | sed -e 's/[][\.^$+(){}|]/\\&/g' -e 's/\*/.*/g' -e 's/?/./g')
    out="${out:+$out|}$r"
  done < <(printf '%s\n' "$1" | tr ',' '\n')
  [ -n "$out" ] && printf '^(%s)$' "$out"
}

# "+07:00" / "+0700" / "7" / "UTC" → SC_OFF (seconds) + SC_OFFSTR ("+07:00")
_sc_parse_tz() {
  local z="${1:-$(date +%z)}" sg="+" h m
  case "$z" in UTC | utc | Z | z) z="+0000" ;; esac
  case "$z" in -*) sg="-"; z="${z#-}" ;; +*) z="${z#+}" ;; esac
  z="${z/:/}"
  case "$z" in
    [0-9]) h="0$z"; m=00 ;;
    [0-9][0-9]) h="$z"; m=00 ;;
    [0-9][0-9][0-9][0-9]) h="${z:0:2}"; m="${z:2:2}" ;;
    *) return 1 ;;
  esac
  SC_OFF=$(((10#$h * 3600 + 10#$m * 60) * $([ "$sg" = - ] && echo -1 || echo 1)))
  SC_OFFSTR="$sg$h:$m"
}

_sc_compute_period() {
  _sc_parse_tz "$SC_TZ" || { ui_err "Invalid --tz: $SC_TZ (use e.g. +07:00)"; return 1; }
  if [ -n "$SC_UNTIL" ]; then
    case "$SC_UNTIL" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) ui_err "--until must be YYYY-MM-DD"; return 1 ;; esac
    SC_END=$(jq -nr --arg d "$SC_UNTIL" --argjson o "$SC_OFF" '(($d + "T00:00:00Z") | fromdateiso8601) - $o + 86400')
  else
    SC_END=$(jq -nr --argjson o "$SC_OFF" '((now + $o) / 86400 | floor) * 86400 - $o')
  fi
  SC_START=$((SC_END - SC_DAYS * 86400))
  SC_AFTER=$(jq -nr --argjson t "$((SC_START - 86400))" '$t | todate | .[:10]')
  SC_BEFORE=$(jq -nr --argjson t "$((SC_END + 86400))" '$t | todate | .[:10]')
  SC_START_ISO=$(jq -nr --argjson t "$SC_START" '$t | todate')
  SC_FROM_LABEL=$(jq -nr --argjson t "$SC_START" --argjson o "$SC_OFF" '($t + $o) | todate | .[:10]')
  SC_TO_LABEL=$(jq -nr --argjson t "$((SC_END - 1))" --argjson o "$SC_OFF" '($t + $o) | todate | .[:10]')
  SC_WINDOWS=$(jq -nc --argjson d "$SC_DAYS" '
    [{label: "1d", secs: 86400}, {label: "1w", secs: 604800},
     {label: (if $d == 30 then "1m" else "\($d)d" end), secs: ($d * 86400)}]
    | map(select(.secs <= $d * 86400)) | unique_by(.secs) | sort_by(.secs)')
  SC_BRANCHES_JSON=$(printf '%s\n' "$SC_BRANCHES" | tr ',' '\n' | while IFS= read -r b; do _sc_trim "$b"; echo; done |
    sed '/^$/d' | jq -R . | jq -sc .)
  SC_JOB_RE=$(_sc_glob_re "$SC_JOB_GLOB")
  export SC_START SC_END SC_AFTER SC_BEFORE SC_BRANCHES_JSON SC_JOB_RE SC_JQ_TS
}

# ---------- worker: one process per project ----------
# _sc_jobs_since PATH OUT LABEL REGEX → appends matching jobs created in the period (newest first, stops early)
_sc_jobs_since() {
  local path="$1" out="$2" label="$3" re="$4" page=1 pf="$2.page" n oldest sep='?'
  case "$path" in *\?*) sep='&' ;; esac
  while :; do
    api_get "${path}${sep}per_page=100&page=${page}" "$pf" || return 1
    jq -c --arg g "$label" --argjson s "$SC_START" --argjson e "$SC_END" --arg re "$re" "$SC_JQ_TS"'
      .[] | {g: $g, project: (.pipeline.project_id // .project.id // null), name, status,
             created: (.created_at | ts), started: (.started_at | ts), finished: (.finished_at | ts),
             queued: .queued_duration, runner: (.runner.id // null), ref}
      | select(.created != null and .created >= $s and .created < $e)
      | select($re == "" or ((.name // "") | test($re; "i")))' "$pf" >>"$out"
    n=$(jq 'length' "$pf")
    oldest=$(jq "$SC_JQ_TS"'[.[].created_at | ts] | min // 0 | floor' "$pf")
    [ "$n" -lt 100 ] && break
    [ "$oldest" -lt "$SC_START" ] && break
    [ -z "$API_NEXT_PAGE" ] && break
    page="$API_NEXT_PAGE"
  done
  rm -f "$pf" "$pf.hdr" "$pf.err"
  return 0
}

sc_worker() {
  local i="$1" p g status pid base raw
  p=$(jq -c --argjson i "$i" '.[$i]' "$SC_GDIR/projects.json")
  g=$(printf '%s' "$p" | jq -r '.g'); status=$(printf '%s' "$p" | jq -r '.status'); pid=$(printf '%s' "$p" | jq -r '.id')
  base="$SC_GDIR/p/$(printf '%05d' "$i")"
  raw="$base.raw"
  : >"$base.events"
  if api_get_all "/projects/$pid/events?action=pushed&after=$SC_AFTER&before=$SC_BEFORE" "$raw"; then
    jq -c --arg g "$g" --argjson pid "$pid" --argjson s "$SC_START" --argjson e "$SC_END" \
      --argjson br "$SC_BRANCHES_JSON" "$SC_JQ_TS"'
      .[] | select(.push_data != null and .push_data.ref_type == "branch" and .push_data.action != "removed")
      | select(.push_data.ref | IN($br[]))
      | {g: $g, type: "push", t: (.created_at | ts), branch: .push_data.ref, project: $pid,
         commits: (.push_data.commit_count // 0)}
      | select(.t >= $s and .t < $e)' "$raw" >>"$base.events"
  else
    printf 'events %s: %s\n' "$(printf '%s' "$p" | jq -r '.path')" "$API_ERROR" >>"$base.err"
  fi
  if [ "$status" = onboarded ]; then
    : >"$base.jobs"
    _sc_jobs_since "/projects/$pid/jobs" "$base.jobs" "$g" "$SC_JOB_RE" ||
      printf 'jobs %s: %s\n' "$(printf '%s' "$p" | jq -r '.path')" "$API_ERROR" >>"$base.err"
  fi
  rm -f "$raw" "$raw.hdr" "$raw.err"
  printf '%s\n' "$i" >>"$SC_GDIR/done"
}

# ---------- collection for one group ----------
sc_collect_group() {
  local gi="$1" status name path enc gdir total cand n xpid d b nm nerr arch="&archived=false"
  status=$(printf '%s' "${SC_GROUPS[$gi]}" | cut -f1)
  name=$(printf '%s' "${SC_GROUPS[$gi]}" | cut -f2)
  path=$(printf '%s' "${SC_GROUPS[$gi]}" | cut -f3)
  local paths=() gpth perr="" np
  while IFS= read -r gpth; do paths+=("$gpth"); done < <(printf '%s\n' "$path" | tr '|' '\n')
  np=${#paths[@]}
  path=$(printf '%s' "$path" | sed 's/|/, /g')
  gdir="$SC_WORK/g$gi"
  mkdir -p "$gdir/p"
  [ "$SC_INCLUDE_ARCHIVED" = 1 ] && arch=""

  printf '\n  %s[%d/%d]%s %s%s%s %s(%s · %s)%s\n' "$DIM" $((gi + 1)) "${#SC_GROUPS[@]}" "$RST" "$B" "$name" "$RST" \
    "$DIM" "$status" "$path" "$RST" >&2

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
    API_ERROR="$perr"
    ui_spin_stop 1 "Cannot list projects: $API_ERROR"
    jq -nc --arg n "$name" --arg p "$path" --arg s "$status" --arg e "$API_ERROR" \
      '{name: $n, path: $p, status: $s, projects_total: 0, projects_candidate: 0, error: $e}' >>"$SC_WORK/groups.jsonl"
    return 1
  fi
  jq --arg g "$name" --arg st "$status" --argjson s "$SC_START" "$SC_JQ_TS"'
    map(select(.last_activity_at != null and (.last_activity_at | ts) >= $s)
        | {g: $g, status: $st, id, path: .path_with_namespace})' "$gdir/all.json" >"$gdir/projects.json"
  total=$(jq 'length' "$gdir/all.json")
  cand=$(jq 'length' "$gdir/projects.json")
  ui_spin_stop 0 "$total projects · ${B}$cand${RST} with activity since $SC_FROM_LABEL"

  if [ "$cand" -gt 0 ]; then
    export SC_GDIR="$gdir"
    : >"$gdir/done"
    cursor_hide
    seq 0 $((cand - 1)) | xargs -P "$SC_WORKERS" -n 1 "$GLB_SELF" __sc_project 2>>"$gdir/worker.log" &
    xpid=$!
    BC_XARGS_PID=$xpid
    while kill -0 "$xpid" 2>/dev/null; do
      d=$(wc -l <"$gdir/done" | tr -d ' ')
      ui_progress "$d" "$cand" "pushes$([ "$status" = onboarded ] && printf ' + SAST jobs') ${DIM}($SC_WORKERS workers)${RST}"
      sleep 0.15
    done
    wait "$xpid"
    BC_XARGS_PID=
    ui_progress_end
    cursor_show
  fi

  ui_spin_start "Merged MRs on tracked branches"
  : >"$gdir/merges.raw"
  nerr=""
  for gpth in "${paths[@]}"; do
    while IFS= read -r b; do
      if api_get_all "/groups/$(_uri "$gpth")/merge_requests?state=merged&scope=all&target_branch=$(_uri "$b")&updated_after=$(_uri "$SC_START_ISO")" "$gdir/mr.json"; then
        jq -c --arg g "$name" --argjson s "$SC_START" --argjson e "$SC_END" "$SC_JQ_TS"'
          .[] | select(.merged_at != null)
          | {g: $g, type: "merge", t: (.merged_at | ts), branch: .target_branch, project: .project_id, commits: 0, mr: (.id // null)}
          | select(.t >= $s and .t < $e)' "$gdir/mr.json" >>"$gdir/merges.raw"
      else
        nerr="$gpth: $API_ERROR"
      fi
    done < <(printf '%s' "$SC_BRANCHES_JSON" | jq -r '.[]')
  done
  # one MR can be returned for several locations only if they overlap; dedupe anyway
  jq -c -s 'unique_by([.mr, .project, .t, .branch])[] | del(.mr)' "$gdir/merges.raw" /dev/null >"$gdir/merges" 2>/dev/null || : >"$gdir/merges"
  nm=$(sed -n '$=' "$gdir/merges"); nm=${nm:-0}
  if [ -n "$nerr" ]; then ui_spin_stop 1 "Merged MRs: $nerr"; else ui_spin_stop 0 "$nm merged MRs"; fi

  shopt -s nullglob
  local evf=("$gdir"/p/*.events) jbf=("$gdir"/p/*.jobs) erf=("$gdir"/p/*.err)
  shopt -u nullglob
  cat "${evf[@]}" "$gdir/merges" /dev/null >>"$SC_WORK/events.jsonl"
  cat "${jbf[@]}" /dev/null >>"$SC_WORK/jobs.jsonl"
  n=$(cat "${evf[@]}" /dev/null | sed -n '$=')
  if [ "$status" = onboarded ]; then
    ui_ok "${n:-0} pushes · $nm merges · $(cat "${jbf[@]}" /dev/null | sed -n '$=' | grep . || echo 0) SAST jobs"
  else
    ui_ok "${n:-0} pushes · $nm merges"
  fi
  if [ "${#erf[@]}" -gt 0 ]; then
    ui_warn "${#erf[@]} projects had read errors (first: $(head -1 "${erf[0]}"))"
  fi
  jq -nc --arg n "$name" --arg p "$path" --arg s "$status" --argjson t "$total" --argjson c "$cand" \
    --argjson ne "${#erf[@]}" '{name: $n, path: $p, status: $s, projects_total: $t, projects_candidate: $c,
      project_errors: $ne, error: null}' >>"$SC_WORK/groups.jsonl"
  return 0
}

sc_collect_runners() {
  local r
  [ -n "$SC_RUNNER_IDS" ] || return 0
  ui_title "Runner jobs" "all jobs on runner IDs $SC_RUNNER_IDS (needs runner owner or admin)"
  while IFS= read -r r; do
    r=$(_sc_trim "$r"); [ -z "$r" ] && continue
    ui_spin_start "Runner $r"
    if _sc_jobs_since "/runners/$r/jobs?order_by=id&sort=desc" "$SC_WORK/runner.jsonl" "$r" ""; then
      ui_spin_stop 0 "Runner $r: $(jq -s --arg r "$r" 'map(select(.g == $r)) | length' "$SC_WORK/runner.jsonl") jobs in period"
    else
      ui_spin_stop 1 "Runner $r: $API_ERROR"
    fi
  done < <(printf '%s\n' "$SC_RUNNER_IDS" | tr ',' '\n')
}

# ---------- outputs ----------
sc_write_csvs() { # SUMMARY OUTDIR
  local s="$1" d="$2"
  jq -r '
    ["group","status","window","active_repos","pushes","commits","merges","events","est_jobs_raw","est_jobs_corrected",
     "peak_events_hour","peak_events_hour_at","peak_events_minute","peak_events_minute_at",
     "est_peak_concurrency","est_peak_concurrency_at","projected_peak","projected_peak_at","projected_source",
     "actual_sast_jobs","actual_avg_duration_s","actual_p95_duration_s","actual_peak_concurrency","actual_peak_at",
     "actual_avg_concurrency","util_peak_pct","util_avg_pct","queued_jobs","queue_avg_s","queue_p95_s","queue_max_s"],
    (.groups[] | . as $g | .windows[] |
      [$g.name, $g.status, .window, .active_repos, .pushes, .commits, .merges, .events, .est_jobs_raw, .est_jobs_corrected,
       .peak_events_per_hour.count, .peak_events_per_hour.at, .peak_events_per_minute.count, .peak_events_per_minute.at,
       .est_peak_concurrency_corrected.peak, .est_peak_concurrency_corrected.at, .projected_peak.peak, .projected_peak.at,
       .projected_source, .actual.jobs, .actual.avg_duration_s, .actual.p95_duration_s, .actual.peak_concurrency.peak,
       .actual.peak_concurrency.at, .actual.avg_concurrency, .actual.util_peak_pct, .actual.util_avg_pct,
       .actual.queued_jobs, .actual.queue_avg_s, .actual.queue_p95_s, .actual.queue_max_s])
    | @csv' "$s" >"$d/groups_windows.csv"
  jq -r '["group","window","branch","pushes","commits","merges"],
    (.groups[] | . as $g | .windows[] | . as $w | .by_branch[] | [$g.name, $w.window, .branch, .pushes, .commits, .merges]) | @csv' \
    "$s" >"$d/branches.csv"
  jq -r '["window","groups","events","est_jobs_corrected","projected_peak","projected_peak_at","sum_of_group_peaks",
          "needed","capacity","headroom","fits","recommended_capacity"],
    (.combined[] | [.window, .groups, .events, .est_jobs_corrected, .projected_peak.peak, .projected_peak.at,
                    .sum_of_group_peaks, .needed, .capacity, .headroom, .fits, .recommended_capacity]) | @csv' \
    "$s" >"$d/combined.csv"
  jq -r '["group"] + [range(0; 24) | tostring],
    (.groups[] | [.name] + .distribution.hour_of_day), (["ALL"] + .combined_distribution.hour_of_day) | @csv' \
    "$s" >"$d/distribution_hour_of_day.csv"
  jq -r '["group","Mon","Tue","Wed","Thu","Fri","Sat","Sun"],
    (.groups[] | [.name] + .distribution.weekday), (["ALL"] + .combined_distribution.weekday) | @csv' \
    "$s" >"$d/distribution_weekday.csv"
  jq -r --argjson o "$SC_OFF" --arg os "$SC_OFFSTR" '
    ["hour","group","pushes","merges"],
    (group_by([((.t + $o) / 3600 | floor), .g])[]
      | [((((.[0].t + $o) / 3600 | floor) * 3600) | todate | sub("Z$"; "") | . + $os), .[0].g,
         (map(select(.type == "push")) | length), (map(select(.type == "merge")) | length)]) | @csv' \
    "$SC_WORK/events.json" >"$d/events_hourly.csv"
  jq -r '["order","group","own_peak","cumulative_peak","fits"],
    (.plan.steps | to_entries[] | [(.key + 1), .value.group, .value.own_peak, .value.cumulative_peak, .value.fits]) | @csv' \
    "$s" >"$d/onboarding_plan.csv"
}

_sc_num() { [ "$1" = null ] && printf '—' || printf '%s' "$1"; }

sc_print_results() { # SUMMARY
  local s="$1" line g st w rp pu me ev ej ph pm pc src
  ui_title "Load per group" "events = pushes + merged MRs · est. jobs = events × $SC_JPE × factor $(jq -r '.calibration.factor' "$s") · peak = concurrent jobs"
  ui_nl
  printf '  %s%-16s %-9s %-4s %6s %7s %7s %7s %9s %7s %8s %10s  %s%s\n' "$DIM" "GROUP" "STATUS" "WIN" "REPOS" "PUSHES" \
    "MERGES" "EVENTS" "EST JOBS" "PEAK/H" "PEAK/MIN" "PEAK CONC" "SOURCE" "$RST" >&2
  jq -r '.groups[] | . as $g | .windows[] | [$g.name, $g.status, .window, .active_repos, .pushes, .merges, .events,
      .est_jobs_corrected, .peak_events_per_hour.count, .peak_events_per_minute.count, .projected_peak.peak,
      .projected_source] | map(tostring) | join("\u001f")' "$s" |
    while IFS=$'\x1f' read -r g st w rp pu me ev ej ph pm pc src; do
      printf '  %-16s %-9s %-4s %6s %7s %7s %7s %9s %7s %8s %10s  %s%s%s\n' "${g:0:16}" "$st" "$w" "$rp" "$pu" "$me" "$ev" \
        "$ej" "$ph" "$pm" "$pc" "$DIM" "$src" "$RST" >&2
    done

  if [ "$(jq '[.groups[] | select(.status == "onboarded")] | length' "$s")" -gt 0 ]; then
    ui_title "Onboarded groups — actual SAST jobs on the existing runner (capacity $SC_CAP_EXISTING)"
    ui_nl
    printf '  %s%-16s %-4s %7s %8s %8s %9s %8s %10s %10s %8s %8s %8s%s\n' "$DIM" "GROUP" "WIN" "JOBS" "AVG DUR" "P95 DUR" \
      "PEAK CONC" "AVG CONC" "UTIL PEAK" "UTIL AVG" "QUEUED" "AVG WAIT" "P95 WAIT" "$RST" >&2
    jq -r '.groups[] | select(.status == "onboarded") | . as $g | .windows[] | .actual as $a
        | [$g.name, .window, $a.jobs, $a.avg_duration_s, $a.p95_duration_s, $a.peak_concurrency.peak, $a.avg_concurrency,
           $a.util_peak_pct, $a.util_avg_pct, $a.queued_jobs, $a.queue_avg_s, $a.queue_p95_s]
        | map(tostring) | join("\u001f")' "$s" |
      while IFS=$'\x1f' read -r g w j ad pd pk ac up ua q qa qp; do
        printf '  %-16s %-4s %7s %8s %8s %9s %8s %9s%% %9s%% %8s %8s %8s\n' "${g:0:16}" "$w" "$j" "$(_sc_num "$ad")s" \
          "$(_sc_num "$pd")s" "$pk" "$ac" "$up" "$ua" "$q" "$(_sc_num "$qa")s" "$(_sc_num "$qp")s" >&2
      done
    ui_nl
    ui_hint "Estimate vs actual ($(jq -r '.verdict.window' "$s")): $(jq -r '.calibration.per_group | map("\(.group) \(.actual_jobs)/\(.est_jobs) = \(.factor // "n/a")") | join(" · ")' "$s")"
    ui_hint "Calibration factor: $(jq -r '.calibration.factor' "$s") — $(jq -r '.calibration.note' "$s")"
  fi

  if [ "$(jq '.runner_utilization != null' "$s")" = true ]; then
    ui_title "Runner utilization (all jobs on runner IDs $SC_RUNNER_IDS)"
    jq -r '.runner_utilization[] | "  \(.window): \(.jobs) jobs · peak \(.peak_concurrency.peak) (\(.peak_concurrency.at // "—")) · avg \(.avg_concurrency) · util peak \(.util_peak_pct)% / avg \(.util_avg_pct)% · queued \(.queued_jobs)"' "$s" >&2
  fi

  if [ "$(jq '.groups_failed | length' "$s")" -gt 0 ]; then
    ui_nl
    jq -r '.groups_failed[] | "\(.name)\u001f\(.error)"' "$s" |
      while IFS=$'\x1f' read -r g e; do ui_err "$g not measured — $e"; done
  fi
  ui_title "Combined — all $(jq '.groups | length' "$s") groups on a $SC_CAP-job dedicated runner"
  ui_nl
  printf '  %s%-4s %8s %10s %12s  %-25s %10s %9s  %s%s\n' "$DIM" "WIN" "EVENTS" "EST JOBS" "PEAK CONC" "PEAK AT" "SUM PEAKS" \
    "HEADROOM" "FITS" "$RST" >&2
  jq -r '.combined[] | [.window, .events, .est_jobs_corrected, .projected_peak.peak, (.projected_peak.at // "—"),
      .sum_of_group_peaks, .headroom, .fits] | map(tostring) | join("\u001f")' "$s" |
    while IFS=$'\x1f' read -r w ev ej pk at sp hr ok; do
      printf '  %-4s %8s %10s %12s  %-25s %10s %9s  %s\n' "$w" "$ev" "$ej" "$pk" "$at" "$sp" "$hr" \
        "$([ "$ok" = true ] && printf '%s✔ yes%s' "$CG" "$RST" || printf '%s✖ no%s' "$CR" "$RST")" >&2
    done
  ui_nl
  ui_hint "Busiest hours: $(jq -r '.combined_distribution.busiest_hours | map("\(.hour):00 (\(.events))") | join(", ")' "$s") · busiest days: $(jq -r '.combined_distribution.busiest_days | map("\(.day) (\(.events))") | join(", ")' "$s")"

  if [ "$(jq '.plan.steps | length' "$s")" -gt 0 ]; then
    ui_title "Onboarding order (onboarded groups first, then lightest target first)"
    ui_hint "onboarded groups' combined peak: $(jq -r '.plan.onboarded_peak.peak' "$s")"
    jq -r '.plan.steps | to_entries[] | [(.key + 1), .value.group, .value.own_peak, .value.cumulative_peak, .value.fits]
      | map(tostring) | join("\u001f")' "$s" |
      while IFS=$'\x1f' read -r o g own cum ok; do
        printf '  %2s. %-16s own peak %7s → combined %7s  %s\n' "$o" "${g:0:16}" "$own" "$cum" \
          "$([ "$ok" = true ] && printf '%sfits%s' "$CG" "$RST" || printf '%sneeds more capacity%s' "$CY" "$RST")" >&2
      done
  fi
}

sc_run() {
  local i t0=$SECONDS s fits lines=() outdir ts
  if [ -z "$GLB_HDR" ]; then
    ui_err "Profile '$GLB_PROFILE' has no token. This tool needs a PAT with read_api (Reporter on every group)."
    return 1
  fi
  _sc_compute_period || return 1
  SC_WORK="$GLB_TMP/sc"
  rm -rf "$SC_WORK"; mkdir -p "$SC_WORK"
  : >"$SC_WORK/events.jsonl"; : >"$SC_WORK/jobs.jsonl"; : >"$SC_WORK/runner.jsonl"; : >"$SC_WORK/groups.jsonl"
  export SC_WORK GLB_TIMEOUT GLB_VERSION

  ui_title "Collecting traffic" "$SC_FROM_LABEL → $SC_TO_LABEL ($SC_DAYS days, UTC$SC_OFFSTR) · branches: $SC_BRANCHES · $GLB_URL"
  for ((i = 0; i < ${#SC_GROUPS[@]}; i++)); do
    sc_collect_group "$i"
  done
  sc_collect_runners

  ui_nl
  ui_spin_start "Analyzing"
  jq -s . "$SC_WORK/events.jsonl" >"$SC_WORK/events.json"
  jq -s . "$SC_WORK/jobs.jsonl" >"$SC_WORK/jobs.json"
  jq -s . "$SC_WORK/runner.jsonl" >"$SC_WORK/runner.json"
  jq -s . "$SC_WORK/groups.jsonl" >"$SC_WORK/groups.json"
  local P
  P=$(jq -nc --argjson end "$SC_END" --argjson w "$SC_WINDOWS" --argjson off "$SC_OFF" --arg offstr "$SC_OFFSTR" \
    --argjson jpe "$SC_JPE" --argjson dm "$SC_JOB_MIN" --argjson um "$([ "$SC_MEASURED" = 1 ] && echo true || echo false)" \
    --argjson ce "$SC_CAP_EXISTING" --argjson cd "$SC_CAP" --argjson sp "$SC_SAFETY" --argjson qt "$SC_QUEUE_THR" \
    --argjson br "$SC_BRANCHES_JSON" --arg sj "$SC_JOB_GLOB" --arg ri "$SC_RUNNER_IDS" \
    --argjson ia "$([ "$SC_INCLUDE_ARCHIVED" = 1 ] && echo true || echo false)" '
    {end: $end, windows: $w, off: $off, offstr: $offstr, jpe: $jpe, dur_min: $dm, use_measured: $um,
     cap_existing: $ce, cap_dedicated: $cd, safety_pct: $sp, queue_threshold: $qt,
     branches: $br, sast_jobs: $sj, runner_ids: ($ri | split(",") | map(gsub("\\s"; "")) | map(select(. != ""))),
     include_archived: $ia}')
  s="$SC_WORK/summary.json"
  if ! jq -n --argjson P "$P" --slurpfile ev "$SC_WORK/events.json" --slurpfile jb "$SC_WORK/jobs.json" \
    --slurpfile rj "$SC_WORK/runner.json" --slurpfile gr "$SC_WORK/groups.json" \
    -f "$GLB_ROOT/tools/sast-capacity.jq" >"$s.tmp" 2>"$SC_WORK/analyze.err"; then
    ui_spin_stop 1 "Analysis failed: $(head -c 300 "$SC_WORK/analyze.err")"
    return 1
  fi
  jq --arg gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg ver "$GLB_VERSION" --arg gl "$GLB_URL" --arg prof "$GLB_PROFILE" \
    --arg f "$SC_FROM_LABEL" --arg t "$SC_TO_LABEL" --argjson d "$SC_DAYS" --argjson dur "$((SECONDS - t0))" '
    {tool, gitlabbox_version: $ver, generated_at: $gen, duration_seconds: $dur, gitlab_url: $gl, profile: $prof,
     period: {from: $f, to: $t, days: $d}} + del(.tool)' "$s.tmp" >"$s"
  ui_spin_stop 0 "Analysis done"

  ts=$(date +%Y%m%d-%H%M%S)
  outdir="${SC_OUT:-$GLB_ROOT/reports}"
  outdir="${outdir%/}/sast-capacity_$ts"
  mkdir -p "$outdir" || { ui_err "Cannot create $outdir"; return 1; }
  jq . "$s" >"$outdir/summary.json"
  sc_write_csvs "$s" "$outdir"
  jq -r -f "$GLB_ROOT/tools/sast-capacity-report.jq" "$s" >"$outdir/report.md"

  sc_print_results "$s"

  fits=$(jq -r '.verdict.fits' "$s")
  lines+=("${DIM}Verdict  ${RST} $([ "$fits" = true ] && printf '%s✔ FITS%s' "$CG" "$RST" || printf '%s✖ DOES NOT FIT%s' "$CR" "$RST")")
  lines+=("${DIM}Peak     ${RST} $(jq -r '.verdict.projected_peak' "$s") concurrent jobs at $(jq -r '.verdict.projected_peak_at // "—"' "$s") (window $(jq -r '.verdict.window' "$s"))")
  lines+=("${DIM}Capacity ${RST} $SC_CAP · headroom $(jq -r '.verdict.headroom' "$s") · recommended with ${SC_SAFETY}% margin: $(jq -r '.verdict.recommended_capacity' "$s")")
  [ "$fits" != true ] && lines+=("${DIM}Short by ${RST} $(jq -r '.verdict.extra_capacity_needed' "$s") jobs")
  [ "$(jq '.groups_failed | length' "$s")" -gt 0 ] &&
    lines+=("${DIM}Missing  ${RST} ${CY}$(jq -r '.groups_failed | map(.name) | join(", ")' "$s") not measured (read errors)${RST}")
  [ "$(jq '.plan.wave1 | length' "$s")" -gt 0 ] && lines+=("${DIM}Wave 1   ${RST} $(jq -r '.plan.wave1 | join(", ")' "$s")")
  [ "$(jq '.plan.wave2 | length' "$s")" -gt 0 ] && lines+=("${DIM}Wave 2   ${RST} $(jq -r '.plan.wave2 | join(", ")' "$s") ${DIM}(after adding capacity)${RST}")
  lines+=("${DIM}Duration ${RST} $(ui_duration $((SECONDS - t0)))")
  lines+=("${DIM}Report   ${RST} ${CC}$(_bc_tilde "$outdir")/report.md${RST}")
  ui_nl
  ui_box "Capacity check" "${lines[@]}"
  ui_hint "$(jq -r '.verdict.summary' "$s")"
  ui_hint "Files: summary.json · report.md · groups_windows.csv · combined.csv · branches.csv · onboarding_plan.csv · distribution_*.csv · events_hourly.csv"
  SC_LAST_DIR="$outdir"
  return 0
}

# ---------- interactive ----------
sc_interactive() {
  local k v n_onb n_tgt
  sc_defaults
  ui_title "$TOOL_SC_NAME" "Does a dedicated SAST gate runner have room for all your groups?"
  ui_nl
  if [ -z "$(cfg_resolve_name "")" ] && [ "$(cfg_count)" = 0 ]; then
    ui_warn "No GitLab connection yet."
    ui_confirm "Set up a connection now?" y || return
    setup_wizard || return
    ui_nl
  fi
  pick_profile "Which connection?" include_env || return
  SC_PROFILE="$PICKED_PROFILE"
  BC_PROFILE="$SC_PROFILE"
  bc_prepare_profile || return
  if [ -z "$GLB_HDR" ]; then
    ui_err "Profile '$GLB_PROFILE' has no token — this tool needs a PAT with read_api."
    ui_hint "Add one via Manage profiles → Change token."
    return
  fi

  ui_hint "Both lists are collected and counted in the combined total. Put each group in ONE list:"
  ui_hint "  1) already on the existing runner → traffic + actual SAST jobs are measured (used to calibrate)"
  ui_hint "  2) not onboarded yet            → traffic only, SAST load is estimated"
  ui_hint "Format: comma-separated LABEL=path/to/group or path/to/group (subgroup paths collect only that subgroup)."
  while :; do
    SC_GROUPS=()
    ui_input v "1) Groups already on the existing runner (measured, empty = none)" ""
    _sc_add_groups onboarded "$v" || continue
    n_onb=${#SC_GROUPS[@]}
    ui_input v "2) Groups not onboarded yet (estimated, empty = none)" ""
    _sc_add_groups target "$v" || continue
    n_tgt=$((${#SC_GROUPS[@]} - n_onb))
    [ "${#SC_GROUPS[@]}" -gt 0 ] && break
    ui_warn "Enter at least one group."
  done

  ui_input SC_BRANCHES "Tracked branches" "$SC_BRANCHES"
  UI_HINTS=("Windows 1d / 1w / 1m, ending at the end of yesterday" "Pick the last day and the length of the longest window")
  ui_select k "Collection period" "Last 30 days up to yesterday (recommended)" "Custom" || return
  if [ "$k" = 1 ]; then
    while :; do ui_input SC_UNTIL "Last day included (YYYY-MM-DD, empty = yesterday)" ""; case "$SC_UNTIL" in '' | [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) break ;; esac; ui_warn "Use YYYY-MM-DD"; done
    while :; do ui_input v "Longest window in days" "30"; _bc_is_int "$v" && [ "$v" -ge 1 ] && break; done
    SC_DAYS=$v
    ui_input SC_TZ "UTC offset for days/hours" "$(date +%z)"
  fi

  ui_nl
  while :; do ui_input v "Dedicated runner capacity (concurrent jobs)" "$SC_CAP"; _bc_is_int "$v" && [ "$v" -ge 1 ] && break; done
  SC_CAP=$v
  if [ "$n_onb" -gt 0 ]; then
    while :; do ui_input v "Existing runner capacity" "$SC_CAP_EXISTING"; _bc_is_int "$v" && [ "$v" -ge 1 ] && break; done
    SC_CAP_EXISTING=$v
    ui_hint "SAST jobs are matched by job name (glob, comma-separated), e.g. *sast*,secret-detection"
    ui_input SC_JOB_GLOB "SAST job names" "$SC_JOB_GLOB"
    ui_hint "Optional: runner IDs to measure every job on the existing runner (needs runner owner/admin)."
    ui_input SC_RUNNER_IDS "Runner IDs (empty = skip)" ""
  fi

  UI_HINTS=("$SC_JPE jobs per event · job duration $([ "$n_onb" -gt 0 ] && printf 'measured on onboarded groups' || printf '%s min' "$SC_JOB_MIN") · ${SC_SAFETY}% safety margin · $SC_WORKERS workers"
    "Jobs per event, job duration, safety margin, queue threshold, archived projects, workers")
  ui_select k "Estimation model" "Use defaults (recommended)" "Customize" || return
  if [ "$k" = 1 ]; then
    while :; do ui_input v "SAST jobs triggered per push/merge" "$SC_JPE"; _sc_is_num "$v" && break; done; SC_JPE=$v
    if [ "$n_onb" -gt 0 ]; then
      UI_HINTS=("Average duration of the matched SAST jobs on the onboarded groups" "Use a fixed number of minutes")
      ui_select k "Job duration" "Measured (recommended)" "Fixed" || return
      SC_MEASURED=1; [ "$k" = 1 ] && SC_MEASURED=0
    else
      SC_MEASURED=0
    fi
    [ "$SC_MEASURED" = 0 ] && { while :; do ui_input v "Job duration (minutes)" "$SC_JOB_MIN"; _sc_is_num "$v" && break; done; SC_JOB_MIN=$v; }
    while :; do ui_input v "Safety margin (%)" "$SC_SAFETY"; _bc_is_int "$v" && break; done; SC_SAFETY=$v
    [ "$n_onb" -gt 0 ] && { while :; do ui_input v "Count a job as queued after (seconds)" "$SC_QUEUE_THR"; _bc_is_int "$v" && break; done; SC_QUEUE_THR=$v; }
    ui_confirm "Include archived projects?" n && SC_INCLUDE_ARCHIVED=1
    while :; do ui_input v "Parallel workers" "$SC_WORKERS"; _bc_is_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le 32 ] && break; done; SC_WORKERS=$v
  fi
  ui_input SC_OUT "Output folder" "$GLB_ROOT/reports" path

  ui_nl
  _sc_compute_period || return
  local glist="" g
  for g in "${SC_GROUPS[@]}"; do glist="${glist:+$glist, }$(printf '%s' "$g" | cut -f2)$([ "$(printf '%s' "$g" | cut -f1)" = onboarded ] && printf '*')"; done
  ui_box "Ready to run" \
    "${DIM}Connect ${RST} $(profile_label "$SC_PROFILE")" \
    "${DIM}Groups  ${RST} $n_onb onboarded + $n_tgt target: $glist ${DIM}(* = onboarded)${RST}" \
    "${DIM}Period  ${RST} $SC_FROM_LABEL → $SC_TO_LABEL · windows $(printf '%s' "$SC_WINDOWS" | jq -r 'map(.label) | join(" / ")')" \
    "${DIM}Branches${RST} $SC_BRANCHES" \
    "${DIM}Runner  ${RST} dedicated $SC_CAP$([ "$n_onb" -gt 0 ] && printf ' · existing %s · SAST jobs %s' "$SC_CAP_EXISTING" "$SC_JOB_GLOB")" \
    "${DIM}Output  ${RST} $(_bc_tilde "$SC_OUT")"
  ui_nl
  UI_HINTS=("" "Answer all questions again" "Back to the main menu")
  ui_select k "Go?" "🚀 Run it!" "✏️  Start over" "✖  Cancel" || return
  case "$k" in 1) sc_interactive; return ;; 2) return ;; esac

  sc_run || return
  ui_nl
  UI_HINTS=("" "Open in Finder / file manager" "")
  ui_select k "Next?" "← Back to the main menu" "📂 Open the report folder" "Quit" || return
  case "$k" in
    1) if command -v open >/dev/null; then open "$SC_LAST_DIR"; else xdg-open "$SC_LAST_DIR" >/dev/null 2>&1; fi ;;
    2) exit 0 ;;
  esac
}

# ---------- flag mode ----------
sc_usage() {
  cat >&2 <<EOF

  ${B}gitlabbox.sh capacity${RST} — $TOOL_SC_NAME

  ${B}Groups${RST} (comma-separated, repeatable; LABEL=path or just path; subgroup paths allowed)
        --onboarded LIST       groups already on the existing runner: traffic + actual SAST
                               jobs are measured and used to calibrate the estimate
        --target LIST          groups not onboarded yet: traffic only, SAST load estimated
                               (both lists count toward the combined total; one list per group)

  ${B}Connection${RST}
    -p, --profile NAME         profile with a PAT (read_api, Reporter on every group)

  ${B}Collection${RST}
    -b, --branches LIST        tracked branches (default: $SC_BRANCHES)
    -d, --days N               longest window in days (default 30 → windows 1d / 1w / 1m)
        --until YYYY-MM-DD     last day included (default: yesterday)
        --tz OFFSET            UTC offset for day/hour buckets (default: system, e.g. +07:00)
        --include-archived     include archived projects
    -w, --workers N            parallel requests (default 6)

  ${B}Onboarded groups${RST}
        --sast-jobs GLOB       job names that count as SAST (default: *sast*)
        --runner-ids LIST      also measure every job on these runner IDs (owner/admin only)
        --existing-capacity N  capacity of the existing runner (default 50)
        --queue-threshold S    count a job as queued after S seconds (default 30)

  ${B}Capacity model${RST}
        --capacity N           dedicated runner capacity (default 100)
        --jobs-per-event N     SAST jobs per push/merge (default 2)
        --job-minutes N        job duration when not measured (default 3)
        --fixed-duration       don't use the measured duration of onboarded jobs
        --safety PCT           safety margin for the recommendation (default 20)

  ${B}Output${RST}
    -o, --out DIR              parent folder (default: reports/) → DIR/sast-capacity_<timestamp>/

  ${B}Examples${RST}
    ./gitlabbox.sh capacity --onboarded 'A=org/team-a,B=org/team-b' --target 'C=org/team-c'
    ./gitlabbox.sh capacity --onboarded 'S1=org/big/sub-1' --target org/team-d,org/team-e --capacity 100 -o ~/capacity

  ${DIM}Exit codes: 0 report written · 1 error${RST}

EOF
}

sc_cli() {
  sc_defaults
  while [ $# -gt 0 ]; do
    case "$1" in --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;; esac
    case "$1" in
      -h | --help) sc_usage; return 0 ;;
      -p | --profile) SC_PROFILE="$2"; shift 2 ;;
      --onboarded) _sc_add_groups onboarded "$2" || return 1; shift 2 ;;
      --target) _sc_add_groups target "$2" || return 1; shift 2 ;;
      -b | --branches) SC_BRANCHES="$2"; shift 2 ;;
      -d | --days) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--days must be ≥ 1"; return 1; }; SC_DAYS="$2"; shift 2 ;;
      --until) SC_UNTIL="$2"; shift 2 ;;
      --tz) SC_TZ="$2"; shift 2 ;;
      --include-archived) SC_INCLUDE_ARCHIVED=1; shift ;;
      -w | --workers) _bc_is_int "$2" && [ "$2" -ge 1 ] || { ui_err "--workers must be ≥ 1"; return 1; }; SC_WORKERS="$2"; shift 2 ;;
      --sast-jobs) SC_JOB_GLOB="$2"; shift 2 ;;
      --runner-ids) SC_RUNNER_IDS="$2"; shift 2 ;;
      --existing-capacity) _bc_is_int "$2" || { ui_err "--existing-capacity must be a number"; return 1; }; SC_CAP_EXISTING="$2"; shift 2 ;;
      --queue-threshold) _bc_is_int "$2" || { ui_err "--queue-threshold must be a number"; return 1; }; SC_QUEUE_THR="$2"; shift 2 ;;
      --capacity) _bc_is_int "$2" || { ui_err "--capacity must be a number"; return 1; }; SC_CAP="$2"; shift 2 ;;
      --jobs-per-event) _sc_is_num "$2" || { ui_err "--jobs-per-event must be a number"; return 1; }; SC_JPE="$2"; shift 2 ;;
      --job-minutes) _sc_is_num "$2" || { ui_err "--job-minutes must be a number"; return 1; }; SC_JOB_MIN="$2"; shift 2 ;;
      --fixed-duration) SC_MEASURED=0; shift ;;
      --safety) _bc_is_int "$2" || { ui_err "--safety must be a number"; return 1; }; SC_SAFETY="$2"; shift 2 ;;
      -o | --out) SC_OUT="$2"; shift 2 ;;
      *) ui_err "Unknown option: $1"; sc_usage; return 1 ;;
    esac
  done
  if [ "${#SC_GROUPS[@]}" -eq 0 ]; then
    ui_err "No groups given. Use --onboarded and/or --target."
    sc_usage
    return 1
  fi
  BC_PROFILE="$SC_PROFILE"
  bc_prepare_profile || return 1
  sc_run
}
