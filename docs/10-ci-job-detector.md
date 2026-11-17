# 10. CI Job Detector

[← SAST Gate Capacity Planner](09-sast-capacity-planner.md) · [README](../README.md)

This tool answers: **"Which of our repos have a job like `sast:gate` in their pipeline, and did it actually run?"**

You name the jobs, for example `sast:gate`, `*sast*`, or `sast:gate,semgrep-*`. For every repo the tool checks:

| Check | Source | Meaning |
|---|---|---|
| **Defined** | The merged CI config of the branch: `include:`, templates, and `extends` are expanded by GitLab | The job is written into the pipeline |
| **Ran** | Jobs and trigger jobs of the **latest pipeline** on the branch | The job really ran, with its status |

No job or repo names are built in. You type them in every run.

## What you need

- A profile with a token (scope `read_api`). See [Connection & authentication](02-connection-and-auth.md).
- **Developer** on a project to read its merged CI config. With only Reporter access, the tool still checks the latest pipeline and marks the config as *not readable*.

## Repos

The repo sources are the same as in the [Branch & Committer Report](03-branch-committer-report.md#repo-sources):

- one or more repos,
- a `.txt` file,
- **one or more groups** (comma-separated, subgroups included),
- every repo your account can access.

## Job names

- Separate several names with commas. Matching is case-insensitive.
- `*` matches anything and `?` matches one character.
- A name without `*` must match exactly: `sast:gate` matches `sast:gate` and `SAST:GATE`, not `sast:gate-v2`.
- Use `*sast*` (the default) to catch every similar name, such as `sast`, `SAST`, `sast:gate`, `semgrep-sast`, or `nodejs-scan-sast`.

## Result per repo

| Result | Meaning |
|---|---|
| ✔ `FOUND` | A matching job is in the latest pipeline. Its status (success / failed / skipped / manual …) is shown. |
| ▲ `NOT_RUN` | Defined in the CI config, but not in the latest pipeline: skipped by `rules:`, or no pipeline on that branch yet |
| ✖ `MISSING` | The CI config is readable and has no matching job |
| ? `UNKNOWN` | The CI config is not readable (needs Developer) and the job was not seen in the latest pipeline |
| – `NO_CI` | No CI config, CI/CD disabled, or an empty repository |
| ! `ERROR` | The project could not be read (404 / 403 / no profile for its host) |

A `FOUND` repo whose job is **not** in its own config gets a note. That usually means the job comes from a compliance pipeline or a security policy. The table is sorted so the repos that need attention come first: `MISSING`, then `NOT_RUN`, `UNKNOWN`, `NO_CI`, `ERROR`, and `FOUND`.

**Coverage** in the summary box = `FOUND` ÷ (repos − `NO_CI` − `ERROR`).

## Interactive use

`./gitlabbox.sh` → **🔎 CI Job Detector**

```
  ✔ Where do the repos come from? › Every project in one or more groups
  ✔ Group path(s) › my-org/backend, my-org/frontend
  ✔ Job names to look for › sast:gate,*sast*
  ✔ Which branch? › Default branch (recommended)
  ✔ Output folder › ~/GITLABOX/reports

     PROJECT                                              RESULT   MATCHED JOBS
  ✖ my-org/backend/billing                               MISSING  —
  ▲ my-org/backend/orders                                NOT_RUN  sast:gate (defined)  Defined, but not in the latest pipeline (skipped by rules?)
  – my-org/frontend/docs                                 NO_CI    —
  ✔ my-org/backend/payments                              FOUND    sast:gate (success)

  ╭─ CI job check ───────────────────────────────────────────────╮
  │ Jobs      sast:gate, *sast* · branch: default branch         │
  │ Repos     4 checked                                          │
  │ ✔ Found     1 (in the latest pipeline)                       │
  │ ▲ Not run   1 (defined, not in the latest pipeline)          │
  │ ✖ Missing   1 (not defined, not run)                         │
  │ – No CI     1                                                │
  │ Coverage  33% of 3 repos with CI run the job                 │
  ╰──────────────────────────────────────────────────────────────╯
```

## Flag mode

```bash
./gitlabbox.sh cijobs -g 'my-org/backend,my-org/frontend' -j 'sast:gate'
./gitlabbox.sh cijobs --mine -j '*sast*' --repo-filter 'my-team/*'
./gitlabbox.sh cijobs -f repos.txt --ref develop
./gitlabbox.sh cijobs -g my-org -o - | jq -r '.repositories[] | select(.result == "MISSING") | .project'
```

| Option | Default | Description |
|---|---|---|
| `-r`, `-f`, `-g`, `-a`, `--mine` | — | Repo source, same as `branches` |
| `--repo-filter GLOB` | — | Filter group/account results |
| `--include-archived` | — | Include archived projects |
| `-j, --jobs LIST` | `*sast*` | Job names, comma-separated globs, case-insensitive |
| `--ref BRANCH` | default branch | Check this branch instead of each repo's default branch |
| `-p, --profile NAME` | default profile | Connection profile |
| `-w, --workers N` | `6` | Repos checked in parallel |
| `-o, --out DIR` | `reports/` | Parent folder, or `-` for JSON on stdout |

Exit code `0` = every repo was read, `3` = some repos returned `ERROR`. The report is written in both cases.

## Output files

`reports/<YYYY-MM-DD_HHMM>_ci-jobs_<scope>/`:

| File | Contents |
|---|---|
| `report.csv` | One row per repo: `project, result, defined, defined_jobs, ran_jobs, pipeline_id, pipeline_status, pipeline_at, branch, config, note, error, web_url` |
| `report.json` | The same data, plus options and counts per result |

## How it works

| Endpoint | Used for |
|---|---|
| `GET /projects/:id` | Default branch, whether CI/CD is enabled |
| `GET /projects/:id/ci/lint?include_jobs=true` | The merged config, with includes expanded → defined job names (hidden `.jobs` and keywords are ignored). `content_ref` is added with `--ref`. |
| `GET /projects/:id/pipelines?ref=…&per_page=1` | The latest pipeline on the branch |
| `GET /projects/:id/pipelines/:pid/jobs` and `/bridges` | Jobs and trigger jobs of that pipeline |

## Caveats

- **Defined** is a static check. It does not evaluate `rules:`, so a job can be defined and still never run. That case shows up as `NOT_RUN`.
- Only the **latest** pipeline is checked. A job that runs only on merge requests or on a schedule may be missing from it.
- Jobs inside **child/downstream** pipelines are not listed. Only the trigger job in the parent pipeline is.
- Jobs injected by a compliance pipeline or a scan execution policy are not part of the project's own config. They show up as `FOUND` with a note, or as `MISSING` when no pipeline has run them yet.
