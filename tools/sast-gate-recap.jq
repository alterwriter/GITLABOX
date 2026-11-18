# tools/sast-gate-recap.jq — report.json → short recap text, ready to paste into chat (jq -r)

def dur: if . == null then "—" else (round) as $s
  | if $s >= 60 then "\($s / 60 | floor)m \($s % 60)s" else "\($s)s" end end;
def pc: if . == null then "—" else "\(.)%" end;
def name: split("/") | last;

def block($label; $g):
  [ "\($label) — \($g.gate_pipelines) pipelines with the SAST gate",
    "   ✅ Passed \($g.passed) · ❌ Break \($g.break) (\($g.break_rate | pc))"
      + (if $g.warn > 0 then " · ⚠️ Failed, allowed \($g.warn)" else "" end)
      + (if $g.other > 0 then " · ⏸ Other \($g.other)" else "" end),
    (if $g.break > 0 then "   Break: \($g.break_script) blocked by the gate · \($g.break_infra) runner / timeout errors" else empty end),
    (if $g.recovered > 0 then "   \($g.recovered) passed after a retry" else empty end),
    "   Repos: \($g.projects_total) projects · \($g.projects_read) read · \($g.repos_ran) ran the gate · \($g.repos_no_sast) had pipelines without it · \($g.repos_idle) no pipeline",
    (if $g.jobs > 0 then "   Job time: avg \($g.avg_duration_s | dur) · p95 \($g.p95_duration_s | dur) · max \($g.max_duration_s | dur) · queue avg \($g.queue_avg_s | dur)" else empty end),
    (if $g.runner_peak.peak > 0 then "   Runner peak: \($g.runner_peak.peak) SAST jobs at the same time (\($g.runner_peak.at))" else empty end),
    (if (($g.top_break_repos // []) | length) > 0 then
       "   Most breaks: " + ($g.top_break_repos | map("\(.project | name) (\(.break))") | join(", ")) else empty end) ];

.period.from as $from
| "*SAST Gate Recap*",
"Period: \(.period.from) → \(.period.to) (UTC\(.options.tz))",
"Jobs: \(.options.jobs | join(", ")) · branches: \(.options.branches)",
"",
(.groups | to_entries[] | .value as $g | (.key + 1) as $i
  | if $g.error != null then "\($i). \($g.name) — not read: \($g.error)", ""
    else (block("\($i). \($g.name)"; $g)[]), "" end),
(if (.groups | length) > 1 then (block("Total"; .totals)[]), "" else empty end),
(if .totals.no_sast_pipelines > 0 then
   "Pipelines without the SAST job on these branches: \(.totals.no_sast_pipelines) in \(.totals.repos_no_sast) repos (see pipelines.csv, result NO_SAST)."
 else empty end),
(.groups | map(select(.start != null and .start != $from)) | if length > 0 then
   "Counted from: " + (map("\(.name) since \(.start)") | join(", ")) + "." else empty end)
