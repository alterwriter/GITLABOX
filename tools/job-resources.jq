# tools/job-resources.jq — job runs + sampled logs + CI config → load and CPU / memory needed per job, runner, group
# Run with: jq -n --argjson P PARAMS --slurpfile jobs J --slurpfile logs L --slurpfile ci C --slurpfile groups G
#                 --slurpfile projects PR --slurpfile errs E -f job-resources.jq
# P: {start, end, off, offstr, scale, headroom, size: {cpu, mem}, rules: [{glob, re, cpu, mem}]}

def lt: if . == null then null else ((. + $P.off) | floor | todate | .[:16] | sub("T"; " ")) end;
def day: (. + $P.off) | floor | todate | .[:10];
def r1: if . == null then null else (. * 10 | round) / 10 end;
def r2: if . == null then null else (. * 100 | round) / 100 end;
def avg: if length == 0 then null else add / length | r1 end;
def pct($q): sort | if length == 0 then null else .[((length * $q) | ceil) - 1] | r1 end;
def mx: if length == 0 then null else max | r1 end;
def busy: IN("running", "pending", "created", "preparing", "waiting_for_resource", "scheduled", "waiting_for_callback");
def most: if length == 0 then null else group_by(.) | max_by(length) | .[0] end;
def counts: map(select(. != null)) | group_by(.) | map({key: .[0], value: length}) | sort_by(-.value) | from_entries;

# "2" / "0.5" / "500m" → cores
def cpu_n: tostring | gsub("\\s"; "") | ascii_downcase
  | if test("^[0-9]+(\\.[0-9]+)?m$") then (.[:-1] | tonumber) / 1000
    elif test("^[0-9]+(\\.[0-9]+)?$") then tonumber else null end;
# "2Gi" / "512Mi" / "1G" / "2" → GiB; $bare = GiB per unit-less number (1 for --size, 1/2^30 for Kubernetes bytes)
def mem_gib($bare): tostring | gsub("\\s"; "")
  | (capture("^(?<n>[0-9]+(\\.[0-9]+)?)(?<u>[A-Za-z]*)$") // null)
  | if . == null then null else
      (.u | ascii_downcase | sub("b$"; "")) as $u
      | ({"": null, k: 1e3, ki: 1024, m: 1e6, mi: 1048576, g: 1e9, gi: 1073741824, t: 1e12, ti: 1099511627776}[$u]) as $f
      | if $u == "" then (.n | tonumber) * $bare elif $f == null then null else (.n | tonumber) * $f / 1073741824 end
    end;

# concurrency over time: [{s, f, n, cpu, mem}] → for jobs, CPU and memory: the peak, when, and the p95 of busy time
def sweep:
  def one($k): [.[] | ([.s, .[$k]], [.f, -.[$k]])] | sort_by(.[0], .[1])
    | reduce .[] as $e ({c: 0, p: 0, at: null, last: null, segs: []};
        (if .last != null and $e[0] > .last and .c > 0.000001 then .segs += [[.c, $e[0] - .last]] else . end)
        | .c += $e[1] | .last = $e[0]
        | if .c > .p + 0.000001 then .p = .c | .at = $e[0] else . end)
    | {peak: (.p | r2), at: (.at | lt),
       p95: (.segs | sort_by(.[0]) | (map(.[1]) | add // 0) as $T
             | if $T == 0 then 0 else
                 (reduce .[] as $s ({acc: 0, v: null}; if .v == null then .acc += $s[1]
                   | (if .acc >= 0.95 * $T then .v = $s[0] else . end) else . end) | .v | r2) end)};
  {jobs: one("n"), cpu: one("cpu"), mem: one("mem")};

# seconds of each run per clock hour → [{h, sec, cpu_sec}]
def hour_slices: [.[] | . as $j | range(($j.s / 3600 | floor); ((($j.f - 0.001) / 3600) | floor) + 1) as $h
  | (([$j.f, ($h + 1) * 3600] | min) - ([$j.s, $h * 3600] | max)) as $sec
  | select($sec > 0) | {h: $h, sec: $sec, cpu_sec: ($sec * $j.cpu)}];

def busiest_hour: hour_slices | group_by(.h) | map({h: .[0].h, sec: (map(.sec) | add), cpu_sec: (map(.cpu_sec) | add)})
  | if length == 0 then null else max_by(.sec)
    | {at: (.h * 3600 | lt), avg_jobs: (.sec / 3600 | r2), avg_cpu: (.cpu_sec / 3600 | r2)} end;

def estimate($sw): {
  jobs_peak: $sw.jobs.peak, jobs_p95: $sw.jobs.p95, peak_at: $sw.jobs.at,
  cpu_peak: ($sw.cpu.peak * $P.scale | r1), cpu_p95: ($sw.cpu.p95 * $P.scale | r1),
  mem_peak_gib: ($sw.mem.peak * $P.scale | r1), mem_p95_gib: ($sw.mem.p95 * $P.scale | r1),
  recommended_cpu: ($sw.cpu.peak * $P.scale * (1 + $P.headroom / 100) | ceil),
  recommended_mem_gib: ($sw.mem.peak * $P.scale * (1 + $P.headroom / 100) | ceil)};

def load: . as $r | sweep as $sw | {
  runs: length, job_minutes: (map(.f - .s) | add // 0 | . / 60 | r1),
  cpu_hours: (map((.f - .s) * .cpu) | add // 0 | . / 3600 | r1),
  queue_p95_s: ([.[].queued | select(. != null)] | pct(0.95)),
  busiest_hour: busiest_hour} + estimate($sw);

def jobstats: . as $r | [.[].duration | select(. != null)] as $d | [.[].queued | select(. != null)] as $q
  | ([.[] | select(.measured != null)]) as $m | {
  runs: length,
  success: map(select(.status == "success")) | length,
  failed: ($r | map(select(.status == "failed")) | length),
  canceled: ($r | map(select(.status == "canceled")) | length),
  projects: ($r | map(.pid) | unique | length), runners: ($r | map(.runner_id) | unique | length),
  avg_s: ($d | avg), p50_s: ($d | pct(0.5)), p95_s: ($d | pct(0.95)), max_s: ($d | mx),
  queue_avg_s: ($q | avg), queue_p95_s: ($q | pct(0.95)), queue_max_s: ($q | mx),
  job_minutes: ($r | map(.f - .s) | add // 0 | . / 60 | r1),
  # the most common size of this job; size_variants > 1 when projects / rules give it different sizes
  size_variants: ($r | map([.cpu, .mem, .size_from]) | unique | length)} + ($r | map([.cpu, .mem, .size_from]) | most
    | {cpu: .[0], mem_gib: (.[1] | r2), size_from: .[2]}) + {
  measured: (if ($m | length) == 0 then null else
    {samples: ($m | length), cpu_avg: ([$m[].measured.cores] | avg | r2), cpu_max: ([$m[].measured.cores] | max | r2),
     mem_max_gib: ([$m[].measured.mem_gib] | max | r2),
     cpu_limit: ([$m[].measured.cpu_limit | select(. != null)] | max // null),
     mem_limit_gib: ([$m[].measured.mem_limit_gib | select(. != null)] | max // null | r2)} end),
  executors: ($r | map(.executor) | counts), images: ($r | map(.image) | counts | to_entries | .[:3] | from_entries)};

($jobs[0] | map({key: "\(.id)", value: .}) | from_entries) as $JI
| ($logs[0] | map(select(.error == null)) | map({key: "\(.id)", value: .}) | from_entries) as $LG
| ($ci[0] | map({key: "\(.pid)", value: .}) | from_entries) as $CI

# GLB_RES lines (calibration snippet) → measured cores and memory per sampled run
| ([$logs[0][] | select(.res != null) | . as $l | $JI["\(.id)"] as $j | select($j != null)
    | ($l.res.cpu_max // "" | split("/")) as $cq
    | {id, name: $j.name,
       cores: (if ($j.duration // 0) > 0 then (($l.res.cpu_usec // "0") | tonumber) / 1e6 / $j.duration else null end),
       mem_gib: (($l.res.mem_peak // "0") | tonumber / 1073741824),
       cpu_limit: (if ($cq | length) == 2 and ($cq[0] | test("^[0-9]+$")) and ($cq[1] | test("^[1-9][0-9]*$"))
                   then ($cq[0] | tonumber) / ($cq[1] | tonumber) | r2 else null end),
       mem_limit_gib: (($l.res.mem_limit // "") | if test("^[0-9]+$") and (tonumber < 1e15) then tonumber / 1073741824 else null end)}
    | select(.cores != null)]) as $MS
| ($MS | map({key: "\(.id)", value: .}) | from_entries) as $MI
| ($MS | group_by(.name) | map({key: .[0].name, value: {cpu: (map(.cores) | max | r2), mem: (map(.mem_gib) | max | r2)}})
  | from_entries) as $MN

# the executor of a run: its own log, else what that runner showed in the other sampled logs
| ([$logs[0][] | select(.executor != null) | . as $l | $JI["\(.id)"] | select(. != null) | {r: .runner.id, e: $l.executor}]
   | group_by(.r) | map({key: "\(.[0].r)", value: (map(.e) | most)}) | from_entries) as $RX
| ([$logs[0][] | select(.image != null) | . as $l | $JI["\(.id)"] | select(. != null) | {k: "\(.pid):\(.name)", i: $l.image}]
   | group_by(.k) | map({key: .[0].k, value: (map(.i) | most)}) | from_entries) as $IMG
| ([$logs[0][] | select(.runner_version != null) | . as $l | $JI["\(.id)"] | select(. != null) | {r: .runner.id, v: $l.runner_version}]
   | group_by(.r) | map({key: "\(.[0].r)", value: (map(.v) | most)}) | from_entries) as $RV

| def size($j):
    (first($P.rules[] | . as $x | select($j.name | test($x.re; "i"))) // null) as $rule
    | ($CI["\($j.pid)"] // {}) as $c
    | (($c.global // {}) + (($c.jobs // {})[$j.name] // {})) as $kv
    | {cpu: (($kv.KUBERNETES_CPU_REQUEST // $kv.KUBERNETES_CPU_LIMIT) | if . == null then null else cpu_n end),
       mem: (($kv.KUBERNETES_MEMORY_REQUEST // $kv.KUBERNETES_MEMORY_LIMIT) | if . == null then null else mem_gib(1 / 1073741824) end)} as $k8s
    | if $rule != null then {cpu: ($rule.cpu | cpu_n), mem: ($rule.mem | mem_gib(1)), size_from: "rule"}
      elif $MN[$j.name] != null then {cpu: $MN[$j.name].cpu, mem: $MN[$j.name].mem, size_from: "measured"}
      elif $k8s.cpu != null or $k8s.mem != null then
        {cpu: ($k8s.cpu // ($P.size.cpu | cpu_n)), mem: ($k8s.mem // ($P.size.mem | mem_gib(1)) | r2), size_from: "ci-config"}
      else {cpu: ($P.size.cpu | cpu_n), mem: ($P.size.mem | mem_gib(1)), size_from: "assumed"} end;

# one row per run that actually started; a run still going counts until the period end
  [$jobs[0][] | select(.started != null)
   | (.finished // (if .status | busy then $P.end else null end)) as $f
   | select($f != null and $f > .started)
   | . + {s: .started, f: ([$f, $P.end] | min), n: 1, runner_id: .runner.id,
          executor: ($LG["\(.id)"].executor // $RX["\(.runner.id)"] // null),
          image: ($LG["\(.id)"].image // $IMG["\(.pid):\(.name)"] // null),
          measured: ($MI["\(.id)"] // null | if . == null then null else {cores: (.cores | r2), mem_gib: (.mem_gib | r2), cpu_limit, mem_limit_gib} end)}
   | . + size(.)] as $R

| ($R | map(.runner_id) | unique) as $runner_ids
| {
    groups: [$groups[0][] | . as $gr | [$R[] | select(.g == $gr.name)] as $r
      | {name, kind, path, error, projects_total, projects_active: .projects_candidate,
         projects_with_runs: ($r | map(.pid) | unique | length),
         projects_not_read: ([$errs[0][] | select(.g == $gr.name)] | length)}
        + ($r | load)
        + {top_jobs: ($r | group_by(.name) | map({name: .[0].name, runs: length, job_minutes: (map(.f - .s) | add / 60 | r1)})
                     | sort_by(-.job_minutes) | .[:5])}],
    totals: ({projects_total: ([$groups[0][].projects_total] | add // 0),
              projects_with_runs: ($R | map(.pid) | unique | length), runners: ($runner_ids | length),
              projects_not_read: ($errs[0] | length),
              size_from: ($R | map(.size_from) | counts), executors: ($R | map(.executor // "unknown") | counts)}
             + ($R | load)),
    jobs: ($R | group_by(.name) | map({name: .[0].name} + jobstats) | sort_by(-.job_minutes)),
    jobs_by_group: ($R | group_by([.g, .name]) | map({g: .[0].g, name: .[0].name} + jobstats) | sort_by(.g, -.job_minutes)),
    runners: ($R | group_by(.runner_id) | map(. as $r | $r[0].runner as $x
      | {id: $r[0].runner_id, name: ($x.description // $x.name // null), type: ($x.runner_type // null),
         shared: ($x.is_shared // null), executor: ($r | map(.executor) | map(select(. != null)) | most),
         version: $RV["\($r[0].runner_id)"], groups: ($r | map(.g) | unique), job_names: ($r | map(.name) | unique | length)}
        + ($r | load)) | sort_by(-.job_minutes)),
    by_hour: ((($P.end - $P.start) / 86400) as $days | ($R | hour_slices) as $hs
      | [range(24) as $h | [$hs[] | select((((.h * 3600 + $P.off) / 3600 | floor) % 24) == $h)]
         | {hour: $h, avg_jobs: ((map(.sec) | add // 0) / 3600 / $days | r2),
            avg_cpu: ((map(.cpu_sec) | add // 0) / 3600 / $days | r2)}]),
    daily: (([range((((($P.start + $P.off) / 86400) | floor) * 86400 - $P.off); $P.end; 86400)] | map(day)) as $days
      | ($R | group_by(.s | day) | map({key: (.[0].s | day), value: {runs: length,
              job_minutes: (map(.f - .s) | add / 60 | r1)}}) | from_entries) as $bd
      | [$days[] | {date: .} + ($bd[.] // {runs: 0, job_minutes: 0})]),
    logs: {sampled: ($logs[0] | length), read: ([$logs[0][] | select(.error == null)] | length),
           failed: ([$logs[0][] | select(.error != null)] | length),
           with_executor: ([$logs[0][] | select(.executor != null)] | length), measured: ($MS | length),
           first_error: ([$logs[0][] | select(.error != null) | .error] | first // null)},
    ci_config: {projects: ($ci[0] | length), readable: ([$ci[0][] | select(.readable)] | length),
                not_readable: ([$ci[0][] | select(.readable | not)] | length),
                with_kubernetes_vars: ([$ci[0][] | select(.readable and ((.global | length) + (.jobs | length)) > 0)] | length),
                first_error: ([$ci[0][] | select(.readable | not) | .error] | first // null)},
    runs: ($R | sort_by(-.s) | map({g, project, id, name, stage, status, ref, created_at: (.created | lt),
            started_at: (.s | lt), duration_s: (.f - .s | r1), queued_s: (.queued | r1), runner_id,
            runner: (.runner.description // .runner.name // null), executor, image, cpu, mem_gib: (.mem | r2), size_from,
            measured, web_url})),
    failed_reads: $errs[0]
  }
