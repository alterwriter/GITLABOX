# tools/sast-capacity.jq — analysis step of the SAST Gate Capacity Planner.
#
# Inputs (all timestamps are epoch seconds):
#   $P      params: end, windows[{label,secs}], off, offstr, jpe, dur_min, use_measured,
#           cap_existing, cap_dedicated, safety_pct, queue_threshold, + echo-only fields
#   $ev[0]  trigger events  [{g, type: push|merge, t, branch, project, commits}]
#   $jb[0]  SAST jobs       [{g, project, name, status, created, started, finished, queued, runner}]
#   $rj[0]  runner jobs     (same shape, g = runner id) — empty unless --runner-ids is used
#   $gr[0]  groups          [{name, path, status: onboarded|target, projects_total, projects_candidate, error}]

def iso($t): if $t == null then null else ((($t + $P.off) | floor | todate) | sub("Z$"; "")) + $P.offstr end;
def r2: if . == null then null else (. * 100 | round) / 100 end;
def mean: if length == 0 then null else (add / length) end;
def pctl($p): if length == 0 then null else (sort | .[((length - 1) * $p) | floor]) end;

# Highest number of events falling into one clock bucket ($size seconds, local time).
def bucket_peak($size):
  if length == 0 then {count: 0, at: null}
  else (map(((. + $P.off) / $size) | floor) | group_by(.) | map({k: .[0], n: length}) | max_by(.n)) as $m
    | {count: $m.n, at: iso($m.k * $size - $P.off)}
  end;

# Peak of overlapping weighted intervals [{s, e, w}] (starts sort before ends at equal times).
def sweep:
  if length == 0 then {peak: 0, at: null}
  else ([.[] | {t: .s, d: .w}, {t: .e, d: (0 - .w)}] | sort_by(.t, (0 - .d))
      | reduce .[] as $x ({cur: 0, peak: 0, at: null};
          .cur += $x.d | if .cur > .peak + 0.000001 then .peak = .cur | .at = $x.t else . end))
    | {peak: (.peak | r2), at: iso(.at)}
  end;

# Average concurrency over a window.
def busy($secs): if length == 0 then 0 else ((map((.e - .s) * .w) | add) / $secs | r2) end;

def ran: map(select(.started != null));

def job_stats($j; $secs; $cap; $D):
  ($j | ran) as $r
  | ($r | map(select(.finished != null) | .finished - .started)) as $d
  | ($j | map(.queued) | map(select(. != null))) as $q
  | ($r | map({s: .started, e: (.finished // (.started + $D)), w: 1})) as $iv
  | ($iv | sweep) as $pk
  | {
      jobs: ($r | length),
      jobs_total: ($j | length),
      by_status: ($j | group_by(.status) | map({key: (.[0].status // "unknown"), value: length}) | from_entries),
      avg_duration_s: ($d | mean | r2),
      p95_duration_s: ($d | pctl(0.95) | r2),
      peak_concurrency: $pk,
      avg_concurrency: ($iv | busy($secs)),
      util_peak_pct: ($pk.peak / $cap * 100 | r2),
      util_avg_pct: (($iv | busy($secs)) / $cap * 100 | r2),
      queued_jobs: ($q | map(select(. > $P.queue_threshold)) | length),
      queue_avg_s: ($q | mean | r2),
      queue_p95_s: ($q | pctl(0.95) | r2),
      queue_max_s: ($q | max | r2),
      pending_now: ($j | map(select(.status == "pending")) | length)
    };

($ev[0]) as $E | ($jb[0]) as $J | ($rj[0]) as $R | ($gr[0]) as $GALL
| ($GALL | map(select(.error == null))) as $G
| ($GALL | map(select(.error != null))) as $GFAIL
| $P.end as $END
| ($P.windows | map(. + {from: ($END - .secs), to: $END})) as $W
| ($W | max_by(.secs)) as $M
| ($G | map(select(.status == "onboarded") | .name)) as $ONB

| def evw($g; $w): [$E[] | select(.g == $g and .t >= $w.from and .t < $w.to)];
  def jbw($g; $w): [$J[] | select(.g == $g and .created >= $w.from and .created < $w.to)];

# job duration used for estimates: measured on onboarded groups, or the fixed value
  ([$J[] | select((.g | IN($ONB[])) and .started != null and .finished != null
                  and .created >= $M.from and .created < $M.to) | .finished - .started]) as $durs
| (if $P.use_measured and ($durs | length) > 0 then ($durs | mean) else $P.dur_min * 60 end) as $D
| (if $P.use_measured and ($durs | length) > 0 then "measured" else "fixed" end) as $DSRC

# calibration: estimated jobs (events × jobs/event) vs actual SAST jobs, widest window
| [$G[] | select(.status == "onboarded") | . as $g
    | {group: .name, events: (evw($g.name; $M) | length)}
    | . + {est_jobs: (.events * $P.jpe), actual_jobs: (jbw(.group; $M) | ran | length)}
    | . + {factor: (if .est_jobs > 0 and .actual_jobs > 0 then (.actual_jobs / .est_jobs | r2) else null end)}] as $CAL
| ($CAL | map(select(.factor != null))) as $CALOK
| (if ($CALOK | length) > 0 then (($CALOK | map(.actual_jobs) | add) / ($CALOK | map(.est_jobs) | add)) else 1 end) as $F

| def est_iv($w8): map({s: .t, e: (.t + $D), w: $w8});
  def has_actual($g): $g.status == "onboarded" and ((jbw($g.name; $M) | ran | length) > 0);
  # what this group would put on the dedicated runner: measured jobs if we have them, else corrected estimate
  def proj_iv($g; $w):
    if has_actual($g)
    then jbw($g.name; $w) | ran | map({s: .started, e: (.finished // (.started + $D)), w: 1})
    else evw($g.name; $w) | est_iv($P.jpe * $F) end;

  def group_window($g; $w):
    evw($g.name; $w) as $e
    | ($e | map(select(.type == "push"))) as $pu
    | ($e | map(select(.type == "merge"))) as $me
    | {
        window: $w.label, from: iso($w.from), to: iso($w.to),
        active_repos: ($e | map(.project) | unique | length),
        pushes: ($pu | length),
        commits: ($pu | map(.commits // 0) | add // 0),
        merges: ($me | length),
        events: ($e | length),
        by_branch: ($e | group_by(.branch) | map({
          branch: .[0].branch,
          pushes: (map(select(.type == "push")) | length),
          commits: (map(select(.type == "push") | .commits // 0) | add // 0),
          merges: (map(select(.type == "merge")) | length)})),
        peak_events_per_hour: ($e | map(.t) | bucket_peak(3600)),
        peak_events_per_minute: ($e | map(.t) | bucket_peak(60)),
        est_jobs_raw: (($e | length) * $P.jpe),
        est_jobs_corrected: (($e | length) * $P.jpe * $F | r2),
        est_peak_concurrency_raw: ($e | est_iv($P.jpe) | sweep),
        est_peak_concurrency_corrected: ($e | est_iv($P.jpe * $F) | sweep),
        projected_peak: (proj_iv($g; $w) | sweep),
        projected_source: (if has_actual($g) then "actual" else "estimate" end),
        actual: (if $g.status == "onboarded" then job_stats(jbw($g.name; $w); $w.secs; $P.cap_existing; $D) else null end)
      };

  def distro($e):
    ($e | map((((.t + $P.off) % 86400) / 3600) | floor)) as $h
    | ($e | map(((((.t + $P.off) / 86400) | floor) + 3) % 7)) as $d
    | {
        hour_of_day: [range(0; 24) as $i | ($h | map(select(. == $i)) | length)],
        weekday: [range(0; 7) as $i | ($d | map(select(. == $i)) | length)]
      }
    | . + {
        busiest_hours: ([range(0; 24) as $i | {hour: $i, events: .hour_of_day[$i]}] | sort_by(-.events) | .[:3]),
        busiest_days: ([range(0; 7) as $i | {day: (["Mon","Tue","Wed","Thu","Fri","Sat","Sun"][$i]), events: .weekday[$i]}]
                       | sort_by(-.events) | .[:3])
      };

  def combined($names; $w):
    ([$G[] | select(.name | IN($names[]))]) as $gs
    | ([$gs[] | . as $g | proj_iv($g; $w)] | add // []) as $iv
    | ($iv | sweep) as $pk
    | {
        window: $w.label,
        groups: ($gs | length),
        events: ([$gs[] | evw(.name; $w) | length] | add // 0),
        est_jobs_corrected: (([$gs[] | evw(.name; $w) | length] | add // 0) * $P.jpe * $F | r2),
        projected_peak: $pk,
        sum_of_group_peaks: ([$gs[] | . as $g | proj_iv($g; $w) | sweep | .peak] | add // 0 | r2),
        needed: ($pk.peak | ceil),
        capacity: $P.cap_dedicated,
        headroom: ($P.cap_dedicated - ($pk.peak | ceil)),
        fits: (($pk.peak | ceil) <= $P.cap_dedicated),
        recommended_capacity: ($pk.peak * (1 + $P.safety_pct / 100) | ceil)
      };

# onboarding plan: onboarded groups move first (they are already running), then targets by ascending load
  ([$G[] | select(.status == "onboarded") | . as $g | proj_iv($g; $M)] | add // []) as $BASE
| ($BASE | sweep) as $BASEPK
| ([$G[] | select(.status == "target") | . as $g | {name, iv: proj_iv($g; $M)} | . + {own: (.iv | sweep | .peak)}]
   | sort_by(.own, .name)) as $TG
| (reduce $TG[] as $t ({iv: $BASE, steps: [], wave1: [], wave2: []};
    ((.iv + $t.iv) | sweep | .peak) as $cum
    | if ($cum | ceil) <= $P.cap_dedicated
      then .iv += $t.iv | .wave1 += [$t.name]
        | .steps += [{group: $t.name, own_peak: $t.own, cumulative_peak: ($cum | r2), fits: true}]
      else .wave2 += [$t.name]
        | .steps += [{group: $t.name, own_peak: $t.own, cumulative_peak: ($cum | r2), fits: false}]
      end)) as $PLAN

| combined($G | map(.name); $M) as $ALL
| {
    tool: "sast-capacity",
    params: ($P | del(.off) | . + {job_duration_used_s: ($D | r2), job_duration_source: $DSRC}),
    calibration: {
      factor: ($F | r2),
      calibrated: (($CALOK | length) > 0),
      per_group: $CAL,
      note: (if ($CALOK | length) > 0
             then "factor = actual SAST jobs / (events × jobs per event) over the onboarded groups; applied to estimates"
             else "no onboarded group had both events and SAST jobs — estimates are uncalibrated (factor 1)" end)
    },
    groups_failed: $GFAIL,
    groups: [$G[] | . as $g | . + {
      has_actual_jobs: has_actual($g),
      windows: [$W[] as $w | group_window($g; $w)],
      distribution: distro(evw($g.name; $M))
    }],
    combined: [$W[] as $w | combined($G | map(.name); $w)],
    combined_onboarded: (if ($ONB | length) > 0 then [$W[] as $w | combined($ONB; $w)] else [] end),
    combined_distribution: distro([$E[] | select(.t >= $M.from and .t < $M.to)]),
    runner_utilization: (if ($R | length) > 0
      then [$W[] as $w | {window: $w.label} + job_stats([$R[] | select(.created >= $w.from and .created < $w.to)]; $w.secs; $P.cap_existing; $D)]
      else null end),
    plan: {
      onboarded_peak: $BASEPK,
      onboarded_fit: (($BASEPK.peak | ceil) <= $P.cap_dedicated),
      steps: $PLAN.steps,
      wave1: $PLAN.wave1,
      wave2: $PLAN.wave2
    },
    verdict: {
      window: $M.label,
      fits: $ALL.fits,
      projected_peak: $ALL.projected_peak.peak,
      projected_peak_at: $ALL.projected_peak.at,
      capacity: $P.cap_dedicated,
      headroom: $ALL.headroom,
      needed: $ALL.needed,
      recommended_capacity: $ALL.recommended_capacity,
      extra_capacity_needed: ([0, $ALL.needed - $P.cap_dedicated] | max),
      summary: (
        if $ALL.fits then
          "FITS: all \($G | length) groups together peak at \($ALL.projected_peak.peak) concurrent jobs on a \($P.cap_dedicated)-job runner (headroom \($ALL.headroom)). With a \($P.safety_pct)% safety margin, plan for \($ALL.recommended_capacity)."
        else
          "DOES NOT FIT: all \($G | length) groups together peak at \($ALL.projected_peak.peak) concurrent jobs, above the \($P.cap_dedicated)-job capacity (short by \($ALL.needed - $P.cap_dedicated)). Needed: \($ALL.needed); with a \($P.safety_pct)% safety margin: \($ALL.recommended_capacity)."
          + (if ($BASEPK.peak | ceil) > $P.cap_dedicated then " The onboarded groups alone already exceed the capacity."
             elif ($PLAN.wave1 | length) > 0 then " Onboard first: \($PLAN.wave1 | join(", ")). Later, after adding capacity: \($PLAN.wave2 | join(", "))."
             else " No target group fits on top of the onboarded groups; add capacity before onboarding \($PLAN.wave2 | join(", "))." end)
        end
        + (if ($GFAIL | length) > 0 then " NOT MEASURED (read errors, excluded from the totals): \($GFAIL | map(.name) | join(", "))." else "" end))
    }
  }
