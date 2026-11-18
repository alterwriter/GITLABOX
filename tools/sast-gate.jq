# tools/sast-gate.jq — SAST gate jobs + pipelines → pass / break recap per group
# Run with: jq -n --argjson P PARAMS --slurpfile jobs J --slurpfile pipes PL --slurpfile groups G
#                 --slurpfile projects PR --slurpfile errs E -f sast-gate.jq
# P: {start, end, off, offstr, branches (null = all), jobs, group_starts}

def lt: if . == null then null else ((. + $P.off) | floor | todate | .[:16] | sub("T"; " ")) end;
def day: (. + $P.off) | floor | todate | .[:10];
def hour: (((. + $P.off) / 3600) | floor) % 24;
def pct($a; $b): if $b > 0 then ($a * 1000 / $b | round) / 10 else null end;
def avg: if length == 0 then null else (add / length * 10 | round) / 10 end;
def p95: sort | if length == 0 then null else .[((length * 0.95) | ceil) - 1] | round end;
def mx: if length == 0 then null else max | round end;
def tracked: . as $r | $P.branches == null or ($r | startswith("refs/merge-requests/")) or any($P.branches[]; . == $r);
def busy: IN("running", "pending", "created", "preparing", "waiting_for_resource", "scheduled", "waiting_for_callback");
def key: "\(.pid):\(.pipeline)";

# concurrent jobs, from started → finished (a job still running counts until the period end)
def peak: [.[] | select(.started != null) | ([.started, 1], [(.finished // $P.end), -1])]
  | sort_by(.[0], .[1])
  | reduce .[] as $e ({c: 0, p: 0, at: null}; .c += $e[1] | if .c > .p then .p = .c | .at = $e[0] else . end)
  | {peak: .p, at: (.at | lt)};

def tally: . as $p
  | {gate_pipelines: length}
  + (reduce ("PASSED", "BREAK", "WARN", "CANCELED", "SKIPPED", "RUNNING") as $r ({};
      .[$r | ascii_downcase] = ([$p[] | select(.result == $r)] | length)))
  | . + {break_script: ([$p[] | select(.result == "BREAK" and .break_type == "script")] | length),
         break_infra: ([$p[] | select(.result == "BREAK" and .break_type == "infra")] | length),
         recovered: ([$p[] | select(.recovered)] | length),
         other: (.canceled + .skipped + .running), decided: (.passed + .break + .warn)}
  | . + {pass_rate: pct(.passed; .decided), break_rate: pct(.break; .decided)};

def jobstats:
  [.[].duration | select(. != null)] as $d | [.[].queued | select(. != null)] as $q
  | {jobs: length, avg_duration_s: ($d | avg), p95_duration_s: ($d | p95), max_duration_s: ($d | mx),
     queue_avg_s: ($q | avg), queue_p95_s: ($q | p95), queue_max_s: ($q | mx), runner_peak: peak};

def top($k; $n): map(select(.result == "BREAK")) | group_by(.[$k]) | map({($k): .[0][$k], break: length})
  | sort_by(-.break, .[$k]) | .[:$n];

($jobs[0] | map(select(.ref | tracked))) as $J
| ($pipes[0] | map(select(.ref | tracked))) as $PL
| ($PL | map({key: "\(.pid):\(.id)", value: .}) | from_entries) as $plk

# one row per pipeline that ran a gate job; the latest attempt of each job name decides
| [$J | group_by([.pid, .pipeline])[]
   | . as $all
   | ([group_by(.name)[] | max_by(.id)]) as $L
   | $plk[$all[0] | key] as $pl
   | (([$L[] | select(.status == "failed" and (.allow_failure | not))] | first)
      // ([$L[] | select(.status == "failed")] | first)) as $f
   | {g: $all[0].g, project: $all[0].project, pid: $all[0].pid, pipeline: $all[0].pipeline,
      ref: $all[0].ref, source: ($pl.source // $all[0].pipeline_source),
      created: ($pl.created // ($all | map(.created) | min)),
      result: (if any($L[]; .status == "failed" and (.allow_failure | not)) then "BREAK"
               elif $f != null then "WARN"
               elif all($L[]; .status == "success") then "PASSED"
               elif any($L[]; .status == "canceled") then "CANCELED"
               elif any($L[]; .status | busy) then "RUNNING"
               else "SKIPPED" end),
      break_type: (if $f == null then null elif ($f.failure_reason // "") == "script_failure" then "script" else "infra" end),
      failure_reason: ($f.failure_reason // null),
      jobs: [$L[] | {name, status}],
      duration_s: ([$L[].duration | select(. != null)] | mx),
      queued_s: ([$L[].queued | select(. != null)] | mx),
      retries: (($all | length) - ($L | length)),
      recovered: (any($all[]; .status == "failed") and all($L[]; .status == "success")),
      user: $L[0].user, sha: $L[0].sha, commit: $L[0].commit,
      pipeline_status: ($pl.status // null),
      pipeline_url: ($pl.web_url // ($L[0].web_url // "" | sub("/-/jobs/[0-9]+$"; "/-/pipelines/\($all[0].pipeline)"))),
      job_url: (($f // $L[0]).web_url)}] as $GP

# pipelines on the same branches with no gate job at all (child pipelines excluded)
| ($GP | map({key: key, value: true}) | from_entries) as $gk
| [$PL[] | select($gk["\(.pid):\(.id)"] | not) | select(.source != "parent_pipeline")
   | {g, project, pid, pipeline: .id, ref, source, created, result: "NO_SAST", pipeline_status: .status,
      pipeline_url: .web_url, sha}] as $NG

| ($GP | group_by(.pid) | map({key: "\(.[0].pid)", value: .}) | from_entries) as $gbp
| ($NG | group_by(.pid) | map({key: "\(.[0].pid)", value: .}) | from_entries) as $nbp
| ($errs[0] | map({key: "\(.pid)", value: .error}) | from_entries) as $ek

| [$projects[0][] | . as $p
   | ($gbp["\(.id)"] // []) as $mine | ($nbp["\(.id)"] // []) as $ng
   | ($mine | tally) as $t | ($mine | max_by(.created)) as $last
   | {g, project: .path, web_url,
      status: (if $ek["\(.id)"] then "ERROR" elif ($mine | length) > 0 then "RAN" elif ($ng | length) > 0 then "NO_SAST" else "IDLE" end),
      pipelines: (($mine | length) + ($ng | length)), gate_pipelines: $t.gate_pipelines,
      passed: $t.passed, break: $t.break, warn: $t.warn, other: $t.other, no_sast_pipelines: ($ng | length),
      break_rate: $t.break_rate, last_result: ($last.result // null), last_at: ($last.created | lt),
      error: $ek["\(.id)"]}] as $R

| def repo_counts: {
    repos_ran: (map(select(.status == "RAN")) | length), repos_no_sast: (map(select(.status == "NO_SAST")) | length),
    repos_idle: (map(select(.status == "IDLE")) | length), repos_error: (map(select(.status == "ERROR")) | length)};

  ($P.start | day) as $d0
| {
    groups: [$groups[0][] | . as $gr
      | [$GP[] | select(.g == $gr.name)] as $gp | [$NG[] | select(.g == $gr.name)] as $ng
      | [$J[] | select(.g == $gr.name)] as $gj | [$R[] | select(.g == $gr.name)] as $gr_repos
      | {name, path, start: (.start | lt), error, projects_total, projects_active: .projects_candidate,
         projects_read: (.projects_total - ($gr_repos | repo_counts | .repos_error)),
         pipelines: (($gp | length) + ($ng | length)), no_sast_pipelines: ($ng | length)}
      + ($gr_repos | repo_counts) + ($gp | tally) + ($gj | jobstats)
      + {top_break_repos: ($gr_repos | map(select(.break > 0)) | sort_by(-.break, .project) | .[:5]
                           | map({project, break, break_rate}))}],
    totals: ({projects_total: ([$groups[0][].projects_total] | add // 0),
              projects_active: ([$groups[0][].projects_candidate] | add // 0),
              pipelines: (($GP | length) + ($NG | length)), no_sast_pipelines: ($NG | length)}
      + ($R | repo_counts) + {projects_read: (([$groups[0][].projects_total] | add // 0) - ($R | repo_counts | .repos_error))}
      + ($GP | tally) + ($J | jobstats)),
    daily: (([range((((($P.start + $P.off) / 86400) | floor) * 86400 - $P.off); $P.end; 86400)] | map(day)) as $days
      | ($GP | group_by(.created | day) | map({key: (.[0].created | day), value: tally}) | from_entries) as $bd
      | [$days[] | {date: .} + (($bd[.] // ([] | tally)) | {gate_pipelines, passed, break, warn, other, break_rate})]),
    by_hour: [range(24) as $h | [$GP[] | select((.created | hour) == $h)] | {hour: $h, gate_pipelines: length,
              break: (map(select(.result == "BREAK")) | length)}],
    failure_reasons: ($GP | map(select(.result == "BREAK" or .result == "WARN"))
      | group_by(.failure_reason // "unknown") | map({reason: (.[0].failure_reason // "unknown"), count: length})
      | sort_by(-.count)),
    top_break_repos: ($R | map(select(.break > 0)) | sort_by(-.break, .project) | .[:10]
                      | map({g, project, break, gate_pipelines, break_rate})),
    top_break_branches: ($GP | top("ref"; 5)),
    top_break_users: ($GP | map(select(.user != null)) | top("user"; 10)),
    repositories: ($R | sort_by(
      ({ERROR: 0, NO_SAST: 1, RAN: 2, IDLE: 3}[.status]), -.break, .project)),
    pipelines: (($GP + $NG) | sort_by(-.created)
      | map(. + {created_at: (.created | lt)} | del(.created))),
    failed_reads: $errs[0]
  }
