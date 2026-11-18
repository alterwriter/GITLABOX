# 12. SAST Gate Pass/Break Recap

[← Dependency Finder](11-dependency-finder.md) · [Job Resource Estimator →](13-job-resource-estimator.md)

This tool answers: **"In the groups where the SAST gate is live, how many pipelines passed, how many broke, and why?"**

You name the groups and the gate job (default `sast:gate`). For every pipeline in the period that ran the gate, the tool records the result, the failure reason, the job time, the queue time, and who triggered it. It then sums everything up per group and per day. It also crosschecks the rollout:

- how many projects are in the group, and how many could be read;
- which repos ran the gate;
- which repos ran pipelines on the same branches **without** the gate.

The input is the same group list as the [SAST Gate Capacity Planner](09-sast-capacity-planner.md). No group or job names are built in. You type them in every run.

## What you need

- A profile with a token (scope `read_api`). See [Connection & authentication](02-connection-and-auth.md).
- **Reporter** (or higher) on the groups, which is enough to read jobs and pipelines.

## Groups

Groups are comma-separated `LABEL=path/to/group` (or just the path). Subgroups are included.

- If you give the same LABEL twice, the paths are counted as one group in several locations.
- The same path twice is rejected, and so is a group plus its own subgroup under different labels. Either case would count projects twice.

If the groups went live at different times, give each one its own start with `--group-since 'B=2026-11-17 09:00'`. That group is then counted from its own start instead of the period start, so pipelines from before the gate existed don't show up as "without the gate".

## Result per pipeline

The **latest attempt** of each gate job in the pipeline decides the result. A job that failed and then passed on retry counts as `PASSED`, and is also counted as *passed after a retry*.

| Result | Meaning |
|---|---|
| ✔ `PASSED` | Every gate job succeeded |
| ✖ `BREAK` | A gate job failed and is not `allow_failure`, so the pipeline was blocked |
| ▲ `WARN` | A gate job failed but is `allow_failure: true`, so the pipeline went on |
| – `CANCELED` / `SKIPPED` / `RUNNING` | Canceled, skipped or manual, or still running at the end of the period |
| ○ `NO_SAST` | A pipeline on the same branches with no gate job at all (crosscheck). Child pipelines are not counted. |

Every `BREAK` also gets a **break type** from the job's `failure_reason`:

| Break type | failure_reason | Usually means |
|---|---|---|
| `script` | `script_failure` | The gate itself blocked the pipeline, normally because of findings |
| `infra` | anything else (`runner_system_failure`, `stuck_or_timeout_failure`, `job_execution_timeout`, …) | A runner or timeout problem, not the code |

**Break %** = `BREAK` ÷ (`PASSED` + `BREAK` + `WARN`). Canceled, skipped, and running pipelines are left out.

## Result per repo

| Status | Meaning |
|---|---|
| `RAN` | At least one pipeline ran the gate |
| `NO_SAST` | Ran pipelines on the tracked branches, but none had the gate job |
| `IDLE` | No pipeline in the period |
| `ERROR` | Jobs or pipelines could not be read (e.g. 403) |

## Branches

By default the tool counts the branches `dev, develop, development, main, master`, plus every **merge request pipeline** (`refs/merge-requests/…`), whatever its target. Use `-b` for your own list, or `--all-branches` to count every branch and tag.

## Interactive use

`./gitlabbox.sh` → **🚦 SAST Gate Pass/Break Recap**

```
  ✔ Groups › A=my-org/team-a, B=my-org/team-b
  ✔ Gate job names › sast:gate
  ✔ Period › Since a date & time
  ✔ From (YYYY-MM-DD HH:MM) › 2026-11-11 18:00
  ✔ Did some groups go live later (count them from their own start)? › Yes
  ✔ LABEL=YYYY-MM-DD HH:MM, comma-separated › B=2026-11-17 09:00
  ✔ Branches › Main branches (recommended)

  ▌ Per group
  GROUP            PROJECTS    RAN NO SAST  GATE PL  PASSED   BREAK BREAK%   WARN  OTHER  AVG JOB  P95 JOB   PEAK
  A                       5      3       1       31      23       5   17.2      1      2   2m 40s   3m 49s      1
  B                       4      3       0       36      24       6   18.8      2      4   2m 29s   4m 11s      1
  ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
  TOTAL                   9      6       1       67      47      11     18      3      6   2m 34s    4m 9s      2

  ╭─ SAST gate recap ─────────────────────────────────────────────────────────────╮
  │ Pipelines  67 ran the gate (of 79 on these branches)                          │
  │ ✔ Passed   47 (77%) · 6 after a retry                                         │
  │ ✖ Break    11 (18%) · 9 blocked by the gate · 2 runner / timeout              │
  │ ▲ Allowed  3 (failed, allow_failure)                                          │
  │ Job time   avg 2m 34s · p95 4m 9s · max 4m 18s · queue avg 21s · p95 2m 0s    │
  │ Peak       2 gate jobs at once (2026-11-12 01:13)                             │
  │ Repos      9 in the groups · 8 read · 6 ran the gate · 1 without it · …       │
  ╰───────────────────────────────────────────────────────────────────────────────╯
```

The run also shows a table per day, the repos with the most breaks (with the failure reasons and branches), and the repos whose pipelines had no gate. Afterwards, **📋 Show the recap text** prints `recap.md`, ready to paste into a chat.

## Flag mode

```bash
./gitlabbox.sh gate -g 'A=my-org/team-a,B=my-org/team-b' --hours 24
./gitlabbox.sh gate -g 'A=my-org/team-a,B=my-org/team-b' --since '2026-11-11 18:00' --group-since 'B=2026-11-17 09:00'
./gitlabbox.sh gate -g my-org/team-a -j 'sast:gate,sast:pipeline-guard' --days 30 --recap
./gitlabbox.sh gate -g my-org/team-a -o - | jq '.repositories[] | select(.status == "NO_SAST") | .project'
```

| Option | Default | Description |
|---|---|---|
| `-g, --groups LIST` | — (required) | `LABEL=path` or `path`, comma-separated, repeatable |
| `-j, --jobs LIST` | `sast:gate` | Gate job names, comma-separated globs, case-insensitive |
| `-b, --branches LIST` | `dev,develop,development,main,master` | Tracked branches (merge request pipelines always count) |
| `--all-branches` | — | Count every branch and tag |
| `--hours N` / `-d, --days N` | 7 days | The last N hours / days, up to now |
| `--since TIME` | — | Start: `YYYY-MM-DD HH:MM`, a date, or `HH:MM` (today) |
| `--until TIME` | now | End. A bare date means the end of that day. |
| `--group-since LIST` | — | A later start per group: `'LABEL=YYYY-MM-DD HH:MM,…'` |
| `--tz OFFSET` | system | UTC offset for times and days, e.g. `+07:00` |
| `--include-archived` | — | Include archived projects |
| `-p, --profile NAME` | default profile | Connection profile |
| `-w, --workers N` | `6` | Projects read in parallel |
| `-o, --out DIR` | `reports/` | Parent folder, or `-` for JSON on stdout |
| `--recap` | — | Also print the recap text on stdout |

Exit code `0` = every group and project was read · `1` = error, no report · `3` = report written, but some groups or projects could not be read.

## Output files

`reports/<YYYY-MM-DD_HHMM>_sast-gate_<groups>/`:

| File | Contents |
|---|---|
| `report.csv` | **The recap sheet.** One row per group plus a `TOTAL` row: projects / read / ran / without the gate / no pipeline, pipelines, passed, break (blocked + infra), failed-allowed, canceled, skipped, running, passed after a retry, pass % and break %, job time avg / p95 / max, queue avg / p95 / max, runner peak and when it happened. |
| `pipelines.csv` | One row per pipeline: `group, project, pipeline_id, created_at, branch, source, result, break_type, failure_reason, gate_jobs, job_s, queue_s, retries, passed_after_retry, user, commit, sha, pipeline_status, pipeline_url, job_url`. `NO_SAST` rows are the crosscheck. |
| `recap.md` | A short text per group plus a total, ready to paste into a chat. |
| `report.json` | Everything above, plus per day, per hour of the day, per repo, top break repos / branches / users, failure reasons, and read errors. |

## How it works

| Endpoint | Used for |
|---|---|
| `GET /groups/:id/projects?include_subgroups=true` | Projects per group. Only projects with activity since the start (minus one day) are read further. |
| `GET /projects/:id/jobs` | Gate jobs, newest first. Paging stops at the first page older than the start. |
| `GET /projects/:id/pipelines?updated_after=…` | Every pipeline in the period, for the crosscheck and the pipeline status / source |

API cost per active project: (jobs in the period ÷ 100) + (pipelines in the period ÷ 100), at least 2 requests.

**Runner peak** = the highest number of gate jobs running at the same time, computed from each job's start and finish. Jobs from other projects on the same runner are not included. For the full runner load, see the [Capacity Planner](09-sast-capacity-planner.md) with `--runner-ids`.

## Caveats

- Gate jobs inside **child / downstream** pipelines are not linked to their parent pipeline.
- A project is read only if GitLab shows activity on it since the start. A project whose only pipelines come from schedules may not show activity and can be missed.
- `script_failure` is treated as "blocked by the gate". If the gate script itself crashes, that also counts as `script`.
- Pipelines are counted when they are **created**. A pipeline created before the start but retried inside the period is not counted.
