# 3. Branch & Committer Report

[← Connection & authentication](02-connection-and-auth.md) · [Output format →](04-output-format.md)

This tool answers: **"Which branches does this repo have, and how many people have committed to each one?"** Results are sorted from the most committers to the fewest.

Typical uses:
- Branch audits: find busy branches, quiet branches, and branches nobody has touched in a long time.
- Contributor inventory per repo or per team, e.g. for access reviews or onboarding/offboarding.
- Recurring reports (e.g. monthly) exported to Sheets/Excel.

## Repo sources

There are 5 ways to choose which repos to scan, and they can all be combined in one run.

| Source | Interactive menu | Flag | In a `.txt` file |
|---|---|---|---|
| One / several repos | Type them in | `-r REPO` (repeatable / comma-separated) | a plain line |
| All repos your account can access | All repos my account can access | `--mine`, `-a SCOPE` | `account:SCOPE`, `mine` |
| A `.txt` file | Bulk from a .txt file | `-f FILE` | — |
| One group | Every project in a group | `-g GROUP` | `group:PATH` |
| Positional arguments | — | `./gitlabbox.sh branches a/b c/d` | — |

### How to write a repo

```text
my-group/my-app                                       # path (namespace/project)
my-group/sub/deep/project                             # nested subgroups
12345                                                 # project ID
https://gitlab.example.com/my-group/my-app            # web URL
https://gitlab.example.com/my-group/my-app/-/tree/dev # any URL from the browser (/-/... is dropped)
https://gitlab.example.com/my-group/my-app.git        # HTTPS clone URL
git@gitlab.example.com:my-group/my-app.git            # SSH clone URL
ssh://git@gitlab.example.com:2222/my-group/my-app.git # SSH with a port
group:my-org/backend                                  # every project in the group + subgroups
account:member                                        # every repo your account is a member of
account:developer@gitlab.example.com                  # scope + specific instance
mine                                                  # = account:member
```

Parsing rules:
- Anything after ` #` is a comment. Blank lines and lines starting with `#` are skipped.
- Windows line endings (CRLF) are fine.
- Query strings, fragments, `/-/...`, `.git`, and trailing `/` are removed.
- **Duplicates are dropped**, even when the same repo is written in different forms (e.g. `a/b` and `https://<profile-host>/a/b`).
- The interactive "Type them in" option accepts several repos separated by commas or spaces.

The full template is in [`repos.example.txt`](../repos.example.txt). Copy it to `repos.txt` (that file is git-ignored).

### "All repos my account can access" mode

The repo list comes from `GET /projects` using your token. The scope decides which projects are included:

| Scope | API parameters | Contents |
|---|---|---|
| `member` *(default)* | `membership=true` | Every project you are a member of, directly or through a group. Same as "Your projects" in the UI. |
| `owned` | `owned=true` | Projects you own, usually the ones in your personal namespace |
| `reporter` | `membership=true&min_access_level=20` | Role Reporter or higher |
| `developer` | `membership=true&min_access_level=30` | Role Developer or higher |
| `maintainer` | `membership=true&min_access_level=40` | Role Maintainer or higher |
| `all` | — | Every project visible to you, including internal/public ones you are not a member of. **Self-hosted only.** Blocked on gitlab.com, where it would mean every public repo in the world. |

Notes:
- **A token is required.** Without one there is no "account" to look up.
- Archived projects are **skipped** unless you pass `--include-archived`.
- Results depend on the token type. Project/Group Access Tokens only "see" their own project/group, so use a **PAT** for this mode.
- Results can be narrowed with `--repo-filter` (comma-separated globs), e.g. `--repo-filter 'payments/*,*-service'`.

In the interactive menu you get a preview of the list, and you can filter it before scanning:

```
  ✔ Account repo scope › Everything I'm a member of (recommended)
  ✔ Include archived projects? › No
  ✔ Account @username: 87 projects (scope: member · gitlab.example.com)
    • backend/api
    • backend/worker
    • platform/infra
    … +79 more
  ▲ 87 repos is a lot — tip: use a 90-day range / branch filter to speed things up.
  ? Continue?
  ❯ ▶  Scan these 87 projects
    🔍 Filter by repo name
    ←  Cancel
```

### Group mode

`-g my-org/backend` or `group:my-org/backend` fetches every non-archived project in that group, **including subgroups**. The list can be narrowed with `--repo-filter`, and archived projects can be added with `--include-archived`.

## Interactive flow

```bash
./gitlabbox.sh     # → 🌿 Branch & Committer Report
```

| # | Question | Choices |
|---|---|---|
| 1 | Which connection? | Only shown when there is more than one profile (or an `env` profile) |
| 2 | Where do the repos come from? | Type them in · All repos my account can access · .txt file · Group |
| 3 | Count commits since when? | Full history · 30 · 90 · 180 · 365 days · Custom |
| 4 | Advanced options | **Use defaults** or **Customize**: branch filter, author/committer, commit cap (1,000 / 5,000 / 20,000 / no limit), worker count (1–32) |
| 5 | Report format | JSON · CSV · JSON + CSV |
| 6 | Output folder | Defaults to `reports/` in the tool folder |
| 7 | Summary → Go? | 🚀 Run it · ✏️ Start over · ✖ Cancel |
| 8 | Next? | Back to the main menu · 📂 Open the report folder · Quit |

The summary before running:

```
  ╭─ Ready to run ─────────────────────────────────────────────────────────────────╮
  │ Connect  work · gitlab.example.com                                             │
  │ Repos    account @username · scope member · 12 projects (filter 'backend/*')   │
  │ Range    last 90 days                                                          │
  │ Options  filter 'main,release/*' · author · max 5000 commits/branch · 6 work…  │
  │ Output   BOTH → ~/GITLABOX/reports                                             │
  ╰────────────────────────────────────────────────────────────────────────────────╯
```

During the scan each repo goes through 3 stages: resolve the project, fetch the branch list (with a live counter), and count committers per branch (with a progress bar). The top-branches table is shown right after:

```
  [2/12] backend/worker
  ✔ Project backend/worker · id 512 · private · default: main · gitlab.example.com
  ✔ 3 of 144 branches match filter main,release/*
  ⠼ ████████████████████░░░░░░░░░░  66% 2/3 counting committers per branch (6 workers)
```

When more than one repo is scanned, you also get a **cross-repo leaderboard** at the end (the 10 busiest branches across all repos), followed by a summary box:

```
  ╭─ Report ready ──────────────────────────────────────────────────────────────╮
  │ Repos    11 succeeded · 1 failed                                            │
  │ Branches 36 analyzed                                                        │
  │ Range    since 2026-07-21 (90 days)                                         │
  │ Duration 1m 12s                                                             │
  │ JSON     reports/branch-committers_bulk-12repos_20261019-101500.json        │
  │ CSV      reports/branch-committers_bulk-12repos_20261019-101500.csv         │
  ╰─────────────────────────────────────────────────────────────────────────────╯

  ✖ team/legacy-app — 403 Forbidden — token lacks scope (read_api required) or your role is too low.
```

### Reading the table

```
    #  BRANCH                                  COMMITTERS            COMMITS  LAST        FLAGS  TOP COMMITTER
    1  main                                    ██████████████   26      1532  2026-10-14  D P ·  Dev A (212)
    2  feature/checkout-v2                     ██████░░░░░░░░   11     5000+  2026-10-07  · · M  Dev C (88)
```

| Column | Meaning |
|---|---|
| `COMMITTERS` | Number of unique people (by email) + a bar normalized to the busiest branch in that repo |
| `COMMITS` | Number of commits read. **`+`** means it hit `--max-commits`, so the committer count may be lower than the real one. |
| `LAST` | Date of the latest commit at the branch tip |
| `FLAGS` | `D` = default branch · `P` = protected · `M` = merged into the default branch |
| `TOP COMMITTER` | The person with the most commits on that branch (commit count) |

By default the on-screen table only shows the top 10 branches per repo (change it with `--rows`). **The report file always contains every branch.**

## CLI reference

```bash
./gitlabbox.sh branches [options] [REPO ...]
```

### Repo sources

| Option | Description |
|---|---|
| `-r, --repo REPO` | Path / ID / URL. Repeatable, or several at once separated by commas/spaces. |
| `-f, --file FILE` | `.txt` file, one repo per line |
| `-g, --group GROUP` | Every project in the group + subgroups |
| `-a, --account SCOPE` | Every project your account can access: `member` · `owned` · `reporter` · `developer` · `maintainer` · `all` |
| `--mine` | Shorthand for `--account member` |
| `--repo-filter GLOB` | Filter `-g` / `-a` results, comma-separated globs |
| `--include-archived` | Include archived projects in `-g` / `-a` results |

### Connection

| Option | Description |
|---|---|
| `-p, --profile NAME` | Profile to use. Default: the default profile. Without a config: `GITLAB_URL` + `GITLAB_TOKEN`. |

### Analysis

| Option | Default | Description |
|---|---|---|
| `-d, --since-days N` | full history | Only count commits from the last N days (`since=` in the API) |
| `--all-history` | — | Force full history |
| `-m, --max-commits N` | `5000` | Max commits read per branch. `0` = no limit. |
| `-b, --branch-filter GLOB` | all | Branch name filter, comma-separated globs |
| `--identity WHO` | `author` | `author` or `committer` (see [how it works](05-how-it-works.md#author-vs-committer)) |
| `-w, --workers N` | `6` | Parallel requests per repo |
| `--top N` | `5` | Top committers per branch in the report |

### Output

| Option | Default | Description |
|---|---|---|
| `-F, --format FMT` | `json` | `json` · `csv` · `both` |
| `-o, --out PATH` | `reports/` | A folder, a file name (`x.json` / `x.csv`, the other format uses the same base name), or `-` for stdout (one format only) |
| `--rows N` | `10` | Table rows per repo on screen |

Long options also accept `=`, e.g. `--format=csv` or `--since-days=30`.

### Globs (branch & repo filters)

- Bash pattern matching: `*` (anything, **including `/`**), `?` (one character), `[abc]`.
- Separate several patterns with commas. Spaces around commas are ignored.
- Branch filter example: `main,develop,release/*,hotfix-*`
- Repo filter example: `backend/*,*-service,platform/infra`

### Output file names

`branch-committers_<slug>_<YYYYmmdd-HHMMSS>.{json,csv}`, where:
- `<slug>` = the repo path with `/` replaced by `_` when there is one repo, e.g. `my-group_my-app`,
- `<slug>` = `bulk-<N>repos` when there are several repos.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Every repo succeeded |
| `3` | Some repos failed (the report is still written; failed repos have an `error` field) |
| `1` | Every repo failed, bad input, or no profile configured |
| `130` | Cancelled with Ctrl+C |

### Examples

```bash
# one repo, full history, JSON into reports/
./gitlabbox.sh branches -r my-group/my-app

# several repos at once
./gitlabbox.sh branches -r "team/api, team/web" -r https://gitlab.com/acme/mobile-app

# every repo I'm a member of, last 90 days, JSON + CSV
./gitlabbox.sh branches --mine -d 90 -F both

# payments team repos where my role is at least developer
./gitlabbox.sh branches -a developer --repo-filter 'payments/*' -p work

# one group, release branches only, saved to a specific folder
./gitlabbox.sh branches -g my-org/backend -b 'main,release/*' -o ~/audit/2026-10/

# bulk from a file, CSV to a specific file name
./gitlabbox.sh branches -f repos.txt -F csv -o ~/audit/branches.csv

# pipe into jq: top 5 branches
./gitlabbox.sh branches -r 123 -o - | jq '.repositories[0].branches[:5] | map({name, committer_count})'

# big monorepo: no commit cap, more workers, count by committer
./gitlabbox.sh branches -r big/monorepo -m 0 -w 12 --identity committer
```

## Viewing saved reports

The **📊 View saved reports** menu, or `./gitlabbox.sh reports`, lists the 15 most recent JSON files in `reports/`. Pick one and its per-repo tables and leaderboard are shown again without calling the API.

## Performance tips

| Situation | Suggestion |
|---|---|
| Many repos (dozens to hundreds) | `-d 90` and/or `-b 'main,develop,release/*'` |
| Repos with long histories | Keep `-m 5000` (the default). Capped branches are marked with `+`. |
| Hitting `429` rate limits | Lower `-w` and make sure you use a token |
| Slow network / VPN | Raise `GITLABBOX_TIMEOUT` |

API request estimates are in [How it works → API cost](05-how-it-works.md#api-cost).
