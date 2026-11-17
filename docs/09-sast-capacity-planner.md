# 9. SAST Gate Capacity Planner

[← Security](08-security.md) · [README](../README.md)

This tool answers: **"Does a dedicated SAST gate runner have enough capacity for every group we want on it — and if not, how much do we need and who should go first?"**

It collects push and merge traffic on the tracked branches of the groups you name, measures the SAST jobs that already run for groups onboarded on an existing runner, uses those actuals to calibrate the estimate, and projects the combined peak concurrency on the dedicated runner.

No group names are built in. You type them in every run.

## What you need

- A profile with a **Personal Access Token** (scope `read_api`) — see [Connection & authentication](02-connection-and-auth.md). The profile decides whether you talk to gitlab.com or your own instance.
- **Reporter** (or higher) on every group you list. Reading project jobs may need **Developer** on some instances.
- Optional: owner/admin rights on the existing runner if you want to measure **every** job on it (`--runner-ids`).

## Groups

Two lists, both comma-separated:

| List | Meaning |
|---|---|
| **Onboarded** | Groups whose SAST jobs already run on the existing runner. Their actual jobs are measured and used to calibrate the estimate. They are assumed to move to the dedicated runner. |
| **Target** | Groups not onboarded yet. Their load is estimated from traffic × the calibration factor. |

Each entry is `LABEL=path/to/group` or just `path/to/group` (the path becomes the label). Group URLs work too.

**Subgroups:** write the subgroup's path (`org/big-group/sub-1`) to collect only that subgroup and its children, not the whole parent group.

```text
onboarded:  A=org/team-a, B=org/team-b, S1=org/big/sub-1, S2=org/big/sub-2
target:     C=org/team-c, org/team-d
```

## What gets collected

| Item | Source | Notes |
|---|---|---|
| Push events | `GET /projects/:id/events?action=pushed` | Only pushes to the tracked branches (default `dev, develop, development, main, master`). Branch deletions are ignored. `commits` = sum of `commit_count`. |
| Merge events | `GET /groups/:id/merge_requests?state=merged&target_branch=…` | Merged MRs whose target is a tracked branch, by `merged_at`. |
| Active repos | both of the above | Projects with at least one push or merge in the window. Only projects with `last_activity_at` inside the period are inspected in detail. |
| SAST jobs *(onboarded only)* | `GET /projects/:id/jobs` | Jobs whose **name** matches `--sast-jobs` (glob, case-insensitive, default `*sast*`). Newest first, stops once it passes the start of the period. |
| Runner jobs *(optional)* | `GET /runners/:id/jobs` | Every job on the given runner IDs, regardless of project or name. |

Windows: **1d** (the last full day), **1w** (last 7 days), **1m** (last 30 days, or `--days N`). By default the period ends at the end of yesterday in your local UTC offset (`--tz`, `--until`).

## How the estimate works

```
events            = pushes + merged MRs                     (per group, per window)
estimated jobs    = events × jobs per event × factor        (jobs per event default 2)
factor            = actual SAST jobs / (events × jobs per event), over the onboarded groups (1m)
job duration      = average duration of the matched SAST jobs (or --job-minutes, default 3)
```

**Peak concurrency** is the highest number of jobs running at the same moment:

- **Onboarded groups** use their **measured** job timeline (`started_at` → `finished_at`).
- **Target groups** get a synthetic timeline: every event starts `jobs per event × factor` jobs that last `job duration`.
- **Combined** overlays every group on one timeline, so it is the real simultaneous peak (≤ the sum of the individual peaks).

Also reported per group and window: peak events per **hour** and per **minute** (with timestamps), events per branch, and the hour-of-day / weekday distribution.

For onboarded groups: SAST job count, average/P95 duration, peak and average concurrency, utilization of the existing runner (`--existing-capacity`, default 50), jobs that waited more than `--queue-threshold` seconds (default 30, from `queued_duration`), and average/P95/max wait.

### Why calibrate?

Raw events overcount: a merge done in the UI also creates a push on the target branch, CI rules may skip SAST on some pushes, and a pipeline may run one job or several. The ratio between what actually ran and what the formula predicts, measured on the onboarded groups, corrects the estimate for the target groups. The per-group ratios are printed so you can spot an outlier.

## The verdict and the onboarding plan

- **Fits** when `ceil(combined peak) ≤ capacity` (`--capacity`, default 100). **Headroom** = capacity − needed.
- **Recommended capacity** = combined peak × (1 + safety margin), default margin 20%.
- **Onboarding plan:** the onboarded groups move first. Target groups are then added from the lightest to the heaviest; each one goes into **wave 1** if the combined peak still fits, otherwise into **wave 2** (needs more capacity).
- Groups that could not be read (404, 403, …) are **excluded and flagged as NOT MEASURED** instead of being counted as zero.

## Interactive use

`./gitlabbox.sh` → **🏃 SAST Gate Capacity Planner**

```
  ✔ Which connection? › work · gitlab.example.com
  ✔ Groups already onboarded (existing runner, empty = none) › A=org/team-a,S1=org/big/sub-1
  ✔ Target groups (not onboarded yet, empty = none) › C=org/team-c, org/team-d
  ✔ Tracked branches › dev,develop,development,main,master
  ✔ Collection period › Last 30 days up to yesterday (recommended)
  ✔ Dedicated runner capacity (concurrent jobs) › 100
  ✔ Existing runner capacity › 50
  ✔ SAST job names › *sast*
  ✔ Runner IDs (empty = skip) › —
  ✔ Estimation model › Use defaults (recommended)
```

Then a live view per group (projects → pushes + SAST jobs → merged MRs), followed by the result tables and a verdict box:

```
  ╭─ Capacity check ───────────────────────────────────────────────────────────╮
  │ Verdict   ✖ DOES NOT FIT                                                   │
  │ Peak      118.4 concurrent jobs at 2026-11-04T10:12:00+07:00 (window 1m)   │
  │ Capacity  100 · headroom -19 · recommended with 20% margin: 143            │
  │ Short by  19 jobs                                                          │
  │ Wave 1    D, C                                                             │
  │ Wave 2    E (after adding capacity)                                        │
  │ Report    ~/GITLABOX/reports/sast-capacity_20261117-101500/report.md       │
  ╰────────────────────────────────────────────────────────────────────────────╯
```

## Flag mode

```bash
./gitlabbox.sh capacity \
  --onboarded 'A=org/team-a,B=org/team-b,S1=org/big/sub-1,S2=org/big/sub-2' \
  --target 'C=org/team-c,D=org/team-d,E=org/team-e' \
  --capacity 100 --existing-capacity 50 --sast-jobs 'sast:*'
```

| Option | Default | Description |
|---|---|---|
| `--onboarded LIST` | — | Onboarded groups (repeatable) |
| `--target LIST` | — | Target groups (repeatable) |
| `-p, --profile NAME` | default profile | Profile with a PAT |
| `-b, --branches LIST` | `dev,develop,development,main,master` | Tracked branches |
| `-d, --days N` | `30` | Longest window (windows: 1d, 1w, N days) |
| `--until YYYY-MM-DD` | yesterday | Last day included |
| `--tz OFFSET` | system | UTC offset for days/hours, e.g. `+07:00` |
| `--sast-jobs GLOB` | `*sast*` | Job names that count as SAST (comma-separated globs) |
| `--runner-ids LIST` | — | Also measure every job on these runners (owner/admin) |
| `--existing-capacity N` | `50` | Existing runner capacity |
| `--queue-threshold S` | `30` | A job counts as queued after S seconds |
| `--capacity N` | `100` | Dedicated runner capacity |
| `--jobs-per-event N` | `2` | SAST jobs per push/merge |
| `--job-minutes N` | `3` | Job duration when not measured |
| `--fixed-duration` | — | Ignore the measured duration |
| `--safety PCT` | `20` | Safety margin for the recommendation |
| `--include-archived` | — | Include archived projects |
| `-w, --workers N` | `6` | Parallel requests |
| `-o, --out DIR` | `reports/` | Parent folder for the result folder |

## Output files

Everything lands in `reports/sast-capacity_<timestamp>/`:

| File | Contents |
|---|---|
| `report.md` | Ready-to-share report: verdict, scope, per-group tables, combined, onboarded actuals, calibration, distribution, onboarding plan, method & caveats |
| `summary.json` | Every number above, machine-readable |
| `groups_windows.csv` | One row per group × window: events, estimated jobs, peaks (hour/minute/concurrency), actual job stats |
| `combined.csv` | Combined peak per window vs capacity |
| `branches.csv` | Pushes / commits / merges per group × window × branch |
| `onboarding_plan.csv` | Target groups in onboarding order with the combined peak after each |
| `distribution_hour_of_day.csv` | Events per hour of day (0–23) per group |
| `distribution_weekday.csv` | Events per weekday per group |
| `events_hourly.csv` | Pushes and merges per clock hour per group — for re-simulating with other assumptions |

These files contain group, project, and branch names. Keep them out of public repos (`reports/` is git-ignored).

## Caveats

- Push events are kept by GitLab for a limited time (by default several years, but admins can shorten it).
- Projects with no `last_activity_at` inside the period are skipped as inactive.
- `queued_duration` needs a reasonably recent GitLab (≥ 13.x). Missing values are ignored.
- The job timeline for onboarded groups only contains jobs matching `--sast-jobs`. If the existing runner also runs other jobs, use `--runner-ids` to see its full utilization.
- If no onboarded group has both events and SAST jobs, the factor stays 1 and the report says the estimate is uncalibrated.
