# 13. Job Resource Estimator

[← SAST Gate Pass/Break Recap](12-sast-gate-recap.md) · [README](../README.md)

This tool answers: **"How long do our jobs run, how many run at once, on which runners and executors, and how much CPU and memory does that load need?"**

You name the groups or repos and the jobs, for example `sast:gate`, `build*,test:*`, or `*` for every job. For every run in the period, the tool records:

- the duration and the queue time,
- the runner that took the run,
- the executor and the image, read from a few job logs.

It then sums everything up per job, per runner, and per group:

- runs at once (peak and p95),
- the CPU and memory those runs need at the peak,
- a recommended size with headroom.

No group, repo, or job names are built in. You type them in every run.

## What GitLab can and cannot tell

GitLab does **not** record the CPU or memory a job uses. The API gives the timing (created, started, finished, queued) and the runner of each job. The job log shows the executor and the image. So the tool **measures** the timing and the concurrency, and **estimates** the size of one run.

The size of one run comes from the first source that has a value:

| # | Source | `size_from` | How |
|---|---|---|---|
| 1 | Your rule | `rule` | `--size 'sast:gate=2/4'`: that job takes 2 vCPU / 4 GiB |
| 2 | Measured | `measured` | A `GLB_RES` line in a log of that job, printed by the [calibration snippet](#calibration-measure-a-job-once). The highest value over the sampled runs is used. |
| 3 | CI config | `ci-config` | `KUBERNETES_CPU_REQUEST` / `KUBERNETES_MEMORY_REQUEST` (or `*_LIMIT`) in the project's merged CI config, on the job or in the top-level `variables:` |
| 4 | Assumed | `assumed` | The default `--size` (1 vCPU / 2 GiB) |

The summary box shows how many runs got their size from each source. If half or more were `assumed`, the tool tells you how to calibrate.

## What you need

- A profile with a token (scope `read_api`). See [Connection & authentication](02-connection-and-auth.md).
- **Reporter** on the groups, which is enough to read jobs and job logs.
- **Developer** to read the merged CI config (source 3). Without it, the config is reported as *not readable* and the tool goes on.

## Scope

- `-g` takes groups: `LABEL=path/to/group` or just the path, comma-separated, subgroups included. The same LABEL twice = one group in several locations.
- `-r` takes repos: `LABEL=path/to/repo` or just the path. Repos with the same LABEL are counted together.
- A repo inside a group you also listed is rejected, because its runs would be counted twice.

## Executor detection

The executor is read from the start of the job log (`Preparing the "kubernetes" executor`, `Using Docker executor with image …`). It works for every executor that GitLab Runner prints there: kubernetes, docker, docker+machine, docker-autoscaler, shell, instance, custom, and so on.

Logs cost one request each, so only a few are read. By default that is 2 per job name per project (`--samples`), taking the newest run of each runner first, and only the first 64 KB of each log (`--log-kb`). A run whose own log was not read gets the executor its runner showed in the other logs. The log content itself is not saved. Only the parsed values are: executor, image, Kubernetes namespace, runner version, and `GLB_RES`.

## Runs at once and the estimate

| Value | Meaning |
|---|---|
| **Peak** | The highest number of runs overlapping in time, from each run's start and finish. A run still going counts until the end of the period. |
| **P95** | The number of runs at once that covers 95% of the *busy* time (time with at least one run). |
| **CPU / MEM** | The same sweep, but each run counts with its size, so it is the CPU / memory the overlapping runs need together. |
| **Busiest hour** | The clock hour with the most run time. Its *avg runs at once* = run seconds in that hour ÷ 3600. |
| **Needed** | Peak CPU / memory × `--scale` + `--headroom` % (default 20), rounded up |

These values are given in total, per runner (the load on that runner), and per group (the load of that group on its own, over every runner). `--scale 3` answers "what if three times as many pipelines run", for example when more groups onboard. It multiplies CPU and memory, but not the run counts.

A long **queue p95** on a runner usually means it is already full at the busy hours.

## Calibration: measure a job once

The real CPU and memory of a job can only be read inside the job. `./gitlabbox.sh resources --snippet` prints an `after_script` that reads the job container's cgroup (v2 or v1) and prints one line:

```
GLB_RES cpu_usec=301000000 mem_peak=2411724800 mem_limit=4294967296 cpu_max=200000/100000 nproc=8
```

You don't need to change the real CI template:

1. Create a sandbox repo, include or copy the job there (e.g. `sast:gate`), and add the `after_script`.
2. Run its pipeline a few times on the same runner as the real job.
3. Run the tool with the sandbox repo in scope: `-g 'A=my-org/team-a' -r 'sandbox=me/sast-sandbox'`.

The tool finds `GLB_RES` in the sampled logs of the sandbox and uses the result for every run of that job name in scope:

- **CPU** = `cpu_usec` ÷ the job duration (average cores over the run),
- **memory** = `mem_peak` (`memory.peak` on cgroup v2).

The limits (`cpu_max`, `mem_limit`) are kept in `jobs.csv` and `report.json`. You can also just read the line yourself and pass `--size 'sast:gate=CPU/MEM'`.

## Interactive use

`./gitlabbox.sh` → **🧮 Job Resource Estimator**

```
  ✔ What to read? › Both
  ✔ Groups › A=my-org/team-a, B=my-org/team-b
  ✔ Repos › sandbox=me/sast-sandbox
  ✔ Job names › *
  ✔ Period › Last 7 days (recommended)
  ✔ Size per run › 1/2
  ✔ Scale the load › 1

  ▌ Per job
  JOB                            RUNS  PROJ      AVG      P95      MAX  QUEUE95  MINUTES   CPU    MEM SIZE FROM EXECUTOR
  sast:gate                        78     5    3m 5s   3m 55s   3m 59s   3m 20s    240.8   1.7   2.25 measured  kubernetes
  build                            72     4    2m 1s   2m 56s    3m 0s   3m 20s    145.6     1      2 assumed+  docker
  test                             70     4      58s   1m 27s   1m 30s   3m 20s     67.3     1      2 assumed+  kubernetes

  ▌ Per runner
  RUNNER                         TYPE       EXECUTOR      RUNS  MINUTES   PEAK   P95    CPU  MEM GiB BUSIEST HOUR      QUEUE95
  #9 k8s-shared                  instance   kubernetes     148    308.1      2     2    2.7      4.3 2026-11-15 14:00   3m 20s
  #12 docker-group               group      docker          72    145.6      2     1      2        4 2026-11-13 17:00   3m 20s

  ╭─ Job resource estimate ──────────────────────────────────────────────────────╮
  │ Jobs       * · 220 runs · 453.7 job minutes · 2 runners                      │
  │ Executor   kubernetes 148 · docker 72 (runs)                                 │
  │ Size from  assumed 106 · measured 78 · ci-config 36 (default 1 vCPU / 2 GiB) │
  │ At once    peak 4 runs (2026-11-17 02:02) · p95 3                            │
  │ CPU        peak 4.7 vCPU · p95 3.7 · 10.1 CPU hours                          │
  │ Memory     peak 8.3 GiB · p95 6.3                                            │
  │ Needed     6 vCPU / 10 GiB (peak + 20% headroom)                             │
  ╰──────────────────────────────────────────────────────────────────────────────╯
```

`+` after the size source means the job has different sizes in different projects (e.g. one project sets `KUBERNETES_*`). The run also shows a table per group and the average runs at once per hour of the day. Afterwards, **🧪 Show the calibration snippet** prints the `after_script`.

## Flag mode

```bash
./gitlabbox.sh resources -g 'A=my-org/team-a,B=my-org/team-b' -j 'sast:gate'
./gitlabbox.sh resources -g my-org/team-a -j '*' --size 'sast:gate=2/4,1/2' --days 30
./gitlabbox.sh resources -g my-org/team-a -r 'sandbox=me/sast-sandbox' -j sast:gate --scale 3
./gitlabbox.sh resources --snippet > calibrate.yml
./gitlabbox.sh resources -g my-org/team-a -o - | jq '.runners[] | {id, executor, jobs_peak, cpu_peak}'
```

| Option | Default | Description |
|---|---|---|
| `-g, --groups LIST` | — | `LABEL=path` or `path`, comma-separated, repeatable |
| `-r, --repos LIST` | — | `LABEL=path/to/repo` or `path`, comma-separated, repeatable |
| `-j, --jobs LIST` | `*` | Job names, comma-separated globs, case-insensitive |
| `--hours N` / `-d, --days N` | 7 days | The last N hours / days, up to now |
| `--since TIME` / `--until TIME` | — / now | `YYYY-MM-DD HH:MM`, a date, or `HH:MM` (today). A bare `--until` date means the end of that day. |
| `--tz OFFSET` | system | UTC offset for times and hours, e.g. `+07:00` |
| `--size LIST` | `1/2` | Default `CPU/MEM` per run, plus rules `JOB=CPU/MEM`. CPU: `0.5` or `500m`. MEM: GiB or a unit (`512Mi`, `2G`, `2Gi`). |
| `--scale X` | `1` | Multiply the load (CPU and memory) |
| `--headroom PCT` | `20` | Added on top of the peak for *Needed* |
| `--samples N` | `2` | Logs read per job name per project (`0` = none, so no executor and no `GLB_RES`) |
| `--log-kb N` | `64` | Read the first N KB of each log |
| `--no-ci-config` | — | Don't read `KUBERNETES_*` from the CI config (saves one request per project) |
| `--snippet` | — | Print the calibration `after_script` and exit |
| `--include-archived` | — | Include archived projects |
| `-p, --profile NAME` | default profile | Connection profile |
| `-w, --workers N` | `6` | Projects read in parallel |
| `-o, --out DIR` | `reports/` | Parent folder, or `-` for JSON on stdout |

Exit code `0` = every group and project was read · `1` = error, no report · `3` = report written, but some groups or projects could not be read.

## Output files

`reports/<YYYY-MM-DD_HHMM>_job-resources_<scope>/`:

| File | Contents |
|---|---|
| `report.csv` | **The estimate sheet.** A `TOTAL` row, then one row per group and per runner: runs, job minutes, CPU hours, peak / p95 runs at once and when, peak / p95 CPU and memory, recommended CPU / memory, busiest hour, queue p95. |
| `jobs.csv` | One row per group × job name: runs, success / failed / canceled, projects, runners, duration avg / p50 / p95 / max, queue avg / p95 / max, job minutes, size and where it came from, size variants, measured samples / CPU / memory, executors, images. |
| `runs.csv` | One row per run: `group, project, job_id, job, stage, status, branch, created_at, started_at, duration_s, queued_s, runner_id, runner, executor, image, cpu, mem_gib, size_from, measured_cpu, measured_mem_gib, job_url` |
| `report.json` | Everything above, plus per runner (type, shared, version, groups), per hour of the day, per day, and how many logs and CI configs were read |

## How it works

| Endpoint | Used for |
|---|---|
| `GET /groups/:id/projects?include_subgroups=true` | Projects per group. Only projects with activity since the start (minus one day) are read further. |
| `GET /projects/:id` | A repo given with `-r` |
| `GET /projects/:id/jobs` | Jobs, newest first. Paging stops at the first page older than the start. |
| `GET /projects/:id/jobs/:job_id/trace` | The first `--log-kb` KB of a few logs per job name: executor, image, runner version, `GLB_RES` |
| `GET /projects/:id/ci/lint` | The merged CI config (includes expanded) → `KUBERNETES_*` variables. Only for projects with runs. |

API cost per active project: (jobs in the period ÷ 100) + (job names × `--samples`) + 1.

## Caveats

- The size of a run is an **estimate** unless it comes from `GLB_RES`. The concurrency and the timing are measured.
- *Measured* CPU is the average over the job, so short bursts are higher. On cgroup v2 without `memory.peak` (kernel < 5.19), memory falls back to the value at the end of the job, not the peak. cgroup v1 reports the real peak.
- Only the job container is counted. The Kubernetes helper and service containers, and Docker services, use resources on top.
- `KUBERNETES_*` sizes only apply if the runner allows overwriting them. The tool reads what the config asks for, not what the runner granted. Jobs that get them through `extends:` or a hidden job (`.template`) are not linked.
- Runs from projects outside your scope on the same runner are not included, so the per-runner load can be higher in reality.
- A run is counted when it was **created** inside the period.
