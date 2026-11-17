# tools/sast-capacity-report.jq — renders summary.json as a Markdown report.

def n: if . == null then "—" else tostring end;
def row: "| " + (map(n) | join(" | ")) + " |";
def head($cols): ($cols | row), ("|" + ($cols | map("---") | join("|")) + "|");
def dur: if . == null then "—" elif . >= 60 then "\(. / 60 | floor)m \(. % 60 | floor)s" else "\(. | floor)s" end;
def yes: if . then "yes" else "no" end;

. as $S
| ($S.params) as $P
| [
  "# SAST Gate runner capacity report",
  "",
  "Generated \($S.generated_at) · period \($S.period.from) → \($S.period.to) (\($S.period.days) days, UTC\($P.offstr)) · GitLab \($S.gitlab_url)",
  "",
  "## Verdict",
  "",
  "**\($S.verdict.summary)**",
  "",
  (head(["Window", "Projected peak", "At", "Capacity", "Headroom", "Fits", "Recommended (+\($P.safety_pct)%)"])),
  ($S.combined[] | [.window, .projected_peak.peak, .projected_peak.at, .capacity, .headroom, (.fits | yes), .recommended_capacity] | row),
  "",
  "## Scope",
  "",
  (head(["Group", "Status", "Path", "Projects", "Active in period (any activity)", "Note"])),
  ($S.groups[] | [.name, .status, .path, .projects_total, .projects_candidate,
     (if (.project_errors // 0) > 0 then "\(.project_errors) projects had read errors" else "" end)] | row),
  ($S.groups_failed[] | [.name, .status, .path, "—", "—", "NOT MEASURED: \(.error)"] | row),
  "",
  "Branches: `\($P.branches | join("`, `"))` · SAST jobs matched by name: `\($P.sast_jobs)` · jobs per event: \($P.jpe) · job duration used: \($P.job_duration_used_s | dur) (\($P.job_duration_source))",
  "",
  "## Events and estimated load per group",
  "",
  "Events = pushes to the tracked branches + merged MRs targeting them. Estimated jobs = events × \($P.jpe) × calibration factor \($S.calibration.factor). Peak concurrency is the highest number of jobs running at the same time.",
  "",
  (head(["Group", "Status", "Window", "Active repos", "Pushes", "Commits", "Merges", "Events", "Est. jobs", "Peak events/hour", "Peak events/min", "Peak concurrency", "Source"])),
  ($S.groups[] | . as $g | .windows[]
    | [$g.name, $g.status, .window, .active_repos, .pushes, .commits, .merges, .events, .est_jobs_corrected,
       "\(.peak_events_per_hour.count) (\(.peak_events_per_hour.at // "—"))",
       "\(.peak_events_per_minute.count) (\(.peak_events_per_minute.at // "—"))",
       "\(.projected_peak.peak) (\(.projected_peak.at // "—"))", .projected_source] | row),
  "",
  "### Events per branch (\($S.verdict.window))",
  "",
  (head(["Group", "Branch", "Pushes", "Commits", "Merges"])),
  ($S.groups[] | . as $g | .windows[-1].by_branch[]
    | [$g.name, .branch, .pushes, .commits, .merges] | row),
  "",
  "## Combined (all \($S.groups | length) groups)",
  "",
  (head(["Window", "Events", "Est. jobs", "Projected peak", "At", "Sum of group peaks", "Capacity", "Headroom", "Fits"])),
  ($S.combined[] | [.window, .events, .est_jobs_corrected, .projected_peak.peak, .projected_peak.at, .sum_of_group_peaks, .capacity, .headroom, (.fits | yes)] | row),
  "",
  "The projected peak overlaps every group on one timeline, so it is lower than or equal to the sum of the individual peaks.",
  "",
  (if ($S.groups | map(select(.status == "onboarded")) | length) > 0 then
    ("## Onboarded groups: actual SAST jobs on the existing runner (capacity \($P.cap_existing))",
     "",
     (head(["Group", "Window", "SAST jobs", "Avg duration", "P95 duration", "Peak concurrency", "Avg concurrency", "Util. peak %", "Util. avg %", "Queued > \($P.queue_threshold)s", "Avg wait", "P95 wait", "Max wait"])),
     ($S.groups[] | select(.status == "onboarded") | . as $g | .windows[]
       | . as $w | .actual
       | [$g.name, $w.window, .jobs, (.avg_duration_s | dur), (.p95_duration_s | dur),
          "\(.peak_concurrency.peak) (\(.peak_concurrency.at // "—"))", .avg_concurrency, .util_peak_pct, .util_avg_pct,
          .queued_jobs, (.queue_avg_s | dur), (.queue_p95_s | dur), (.queue_max_s | dur)] | row),
     "",
     "### Estimate vs actual (calibration, \($S.verdict.window))",
     "",
     (head(["Group", "Events", "Estimated jobs", "Actual SAST jobs", "Factor (actual / estimated)"])),
     ($S.calibration.per_group[] | [.group, .events, .est_jobs, .actual_jobs, .factor] | row),
     "",
     "Overall factor: **\($S.calibration.factor)** — \($S.calibration.note).",
     "")
   else empty end),
  (if $S.runner_utilization then
    ("## Runner utilization (all jobs on runner IDs \($P.runner_ids | join(", ")))",
     "",
     (head(["Window", "Jobs", "Avg duration", "Peak concurrency", "Avg concurrency", "Util. peak %", "Util. avg %", "Queued > \($P.queue_threshold)s", "Avg wait", "P95 wait"])),
     ($S.runner_utilization[] | [.window, .jobs, (.avg_duration_s | dur), "\(.peak_concurrency.peak) (\(.peak_concurrency.at // "—"))",
        .avg_concurrency, .util_peak_pct, .util_avg_pct, .queued_jobs, (.queue_avg_s | dur), (.queue_p95_s | dur)] | row),
     "")
   else empty end),
  "## Busiest hours and days (\($S.verdict.window), all groups)",
  "",
  "Busiest hours: \($S.combined_distribution.busiest_hours | map("\(.hour):00 (\(.events))") | join(", ")) · busiest days: \($S.combined_distribution.busiest_days | map("\(.day) (\(.events))") | join(", "))",
  "",
  (head(["Group"] + [range(0; 24) | tostring | if length == 1 then "0" + . else . end])),
  ($S.groups[] | [.name] + .distribution.hour_of_day | row),
  "",
  (head(["Group", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])),
  ($S.groups[] | [.name] + .distribution.weekday | row),
  "",
  "## Onboarding plan",
  "",
  "Onboarded groups move to the dedicated runner first (projected peak \($S.plan.onboarded_peak.peak)). Target groups are then added from the lightest load up, as long as the combined peak stays within \($P.cap_dedicated).",
  "",
  (head(["Order", "Group", "Own peak", "Combined peak after adding", "Fits"])),
  ($S.plan.steps | to_entries[] | [(.key + 1), .value.group, .value.own_peak, .value.cumulative_peak, (.value.fits | yes)] | row),
  "",
  "- Wave 1: \(if ($S.plan.wave1 | length) > 0 then $S.plan.wave1 | join(", ") else "—" end)",
  "- Wave 2 (needs more capacity): \(if ($S.plan.wave2 | length) > 0 then $S.plan.wave2 | join(", ") else "—" end)",
  "",
  "## Method and caveats",
  "",
  "- Pushes come from project push events (`push_data.ref` in the tracked branches); merges from merged MRs whose target branch is tracked.",
  "- A merge done in the GitLab UI also creates a push event on the target branch, so raw events can overcount pipelines. The calibration factor from the onboarded groups corrects for this and for rules that skip SAST.",
  "- Onboarded groups are projected with their measured job timeline; target groups with events × jobs per event × factor, each job lasting the measured average duration.",
  "- Only projects with activity during the period are inspected in detail; archived projects are \(if $P.include_archived then "included" else "excluded" end).",
  "- SAST job utilization counts only jobs matching `\($P.sast_jobs)`. Use runner IDs to measure every job on the runner."
  ]
| .[]
