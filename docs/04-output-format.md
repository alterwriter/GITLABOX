# 4. Output format

[← Branch & Committer Report](03-branch-committer-report.md) · [How it works →](05-how-it-works.md)

Reports can be written in two formats:
- **JSON** holds the complete, nested data: report → repositories → branches → committers.
- **CSV** is flat, one row per branch, for Sheets/Excel.

All examples on this page use fictional data.

## JSON

### Top-level structure

```json
{
  "tool": "branch-committers",
  "gitlabbox_version": "0.1.0",
  "generated_at": "2026-10-19T03:15:00Z",
  "duration_seconds": 72,
  "options": { ... },
  "summary": { ... },
  "repositories": [ ... ]
}
```

| Field | Type | Description |
|---|---|---|
| `tool` | string | Always `"branch-committers"` |
| `gitlabbox_version` | string | Version of the tool that produced the report |
| `generated_at` | string (ISO 8601, UTC) | When the report was generated |
| `duration_seconds` | number | Scan duration |
| `options` | object | Parameters used (see below) |
| `summary` | object | Summary numbers |
| `repositories` | array | One entry per repo, in input order |

### `options`

```json
{
  "since": "2026-07-21T03:13:48Z",
  "since_days": 90,
  "max_commits_per_branch": 5000,
  "identity": "author",
  "branch_filter": "main,release/*",
  "repo_filter": "backend/*",
  "include_archived": false
}
```

| Field | Type | Description |
|---|---|---|
| `since` | string \| null | Lower bound for commit dates (UTC). `null` = full history. |
| `since_days` | number \| null | Value of `--since-days` |
| `max_commits_per_branch` | number \| null | `null` = no limit |
| `identity` | string | `author` / `committer` |
| `branch_filter` | string \| null | Branch filter globs |
| `repo_filter` | string \| null | Repo filter globs (group/account mode) |
| `include_archived` | boolean | Whether archived projects were included |

### `summary`

```json
{ "repos_total": 12, "repos_ok": 11, "repos_failed": 1, "branches_analyzed": 36 }
```

### `repositories[]`

```json
{
  "input": "backend/worker",
  "project": "backend/worker",
  "id": 512,
  "name": "worker",
  "web_url": "https://gitlab.example.com/backend/worker",
  "default_branch": "main",
  "visibility": "private",
  "archived": false,
  "gitlab_url": "https://gitlab.example.com",
  "profile": "work",
  "branch_count_total": 144,
  "branch_count_analyzed": 3,
  "branches_failed": 0,
  "unique_committers": 26,
  "branches": [ ... ],
  "error": null
}
```

| Field | Type | Description |
|---|---|---|
| `input` | string | The repo as written in the input (after normalization) |
| `project` | string | `path_with_namespace` from GitLab |
| `id` | number | Project ID |
| `name` | string | Project name |
| `web_url` | string | Project web URL |
| `default_branch` | string \| null | Default branch |
| `visibility` | string | `private` · `internal` · `public` |
| `archived` | boolean | Archived status |
| `gitlab_url` | string | Instance base URL |
| `profile` | string | Profile used |
| `branch_count_total` | number | Number of branches in the repo |
| `branch_count_analyzed` | number | Number of branches analyzed (after filtering) |
| `branches_failed` | number | Number of branches that could not be read |
| `unique_committers` | number | Unique people **across all analyzed branches** |
| `branches` | array | Sorted by `committer_count` desc, then `commit_count` desc, then name |
| `error` | string \| null | If not `null`, this repo failed and `branches` is empty |

When a repo fails (404, 403, host without a profile, rate limit, etc.), only these fields are set:

```json
{
  "input": "team/legacy-app",
  "project": "team/legacy-app",
  "gitlab_url": "https://gitlab.example.com",
  "branch_count_total": 0,
  "branch_count_analyzed": 0,
  "unique_committers": 0,
  "branches": [],
  "error": "403 Forbidden — token lacks scope (read_api required) or your role is too low. [403 Forbidden]"
}
```

### `branches[]`

```json
{
  "name": "main",
  "committer_count": 26,
  "commit_count": 1532,
  "truncated": false,
  "default": true,
  "protected": true,
  "merged": false,
  "last_commit_at": "2026-10-14T10:00:00.000+07:00",
  "last_commit_author": "Dev A",
  "last_commit_sha": "a1b2c3d4",
  "web_url": "https://gitlab.example.com/backend/worker/-/tree/main",
  "top_committers": [
    { "name": "Dev A", "email": "dev.a@example.com", "commits": 212 },
    { "name": "Dev B", "email": "dev.b@example.com", "commits": 180 }
  ],
  "committers": [ "…every committer, same shape as top_committers…" ],
  "error": null
}
```

| Field | Type | Description |
|---|---|---|
| `name` | string | Branch name |
| `committer_count` | number | Unique people among the commits read |
| `commit_count` | number | Commits read (within `since`, at most `max_commits_per_branch`) |
| `truncated` | boolean | `true` = more commits exist but were cut off by the cap |
| `default` | boolean | Default branch |
| `protected` | boolean | Protected branch |
| `merged` | boolean | Already merged into the default branch (according to GitLab) |
| `last_commit_at` | string | Time of the commit at the branch tip (in the commit's time zone) |
| `last_commit_author` | string | Author of the latest commit |
| `last_commit_sha` | string | Short SHA of the latest commit |
| `web_url` | string | Branch URL |
| `top_committers` | array | Top N (default 5, set with `--top`) |
| `committers` | array | Every unique person, sorted by commit count |
| `error` | string \| null | Error while reading this branch's commits |

When a branch's `error` is set (its commits could not be read), it only has `name`, `committer_count: 0`, `commit_count: 0`, `committers: []`, `top_committers: []`, and `error`.

Each committer entry has `name`, `email`, and `commits`. People are grouped by lowercased email, falling back to the name when the email is empty. The `name` and `email` shown come from the first commit found for that person.

## CSV

Header (14 columns):

```
project,branch,committer_count,commit_count,is_default,protected,merged,last_commit_at,last_commit_author,truncated,top_committers,branch_url,gitlab_url,error
```

Example:

```csv
"backend/worker","main",26,1532,true,true,false,"2026-10-14T10:00:00.000+07:00","Dev A",false,"Dev A <dev.a@example.com> (212); Dev B <dev.b@example.com> (180)","https://gitlab.example.com/backend/worker/-/tree/main","https://gitlab.example.com",
"team/legacy-app",,,,,,,,,,,,"https://gitlab.example.com","403 Forbidden — ..."
```

- One row per branch, in the same order as the JSON.
- A repo that failed, or that has no branch matching the filter, still gets **one row** with the `error` column filled in (`no matching branches` in the filter case).
- `top_committers` is joined as `Name <email> (n); ...`.
- Booleans are written as `true`/`false`, missing values as empty cells. All strings are quoted (jq's `@csv` format).
- Importing into Google Sheets: **File → Import → Upload**, separator **Comma**.

## `jq` recipes

```bash
R=reports/branch-committers_bulk-12repos_20261019-101500.json

# per-repo summary
jq -r '.repositories[] | [.project, .branch_count_total, .unique_committers, (.error // "ok")] | @tsv' "$R"

# 10 busiest branches across all repos
jq -r '[.repositories[] | .project as $p | .branches[] | {repo: $p, name, committer_count}]
       | sort_by(-.committer_count) | .[:10][] | "\(.committer_count)\t\(.repo) › \(.name)"' "$R"

# branches touched by a single person (bus factor 1)
jq -r '.repositories[] | .project as $p | .branches[] | select(.committer_count == 1)
       | "\($p) › \(.name) — \(.committers[0].email)"' "$R"

# merged branches that were never deleted
jq -r '.repositories[] | .project as $p | .branches[] | select(.merged and (.default | not))
       | "\($p) › \(.name)"' "$R"

# branches whose latest commit is older than 180 days
jq -r --arg cut "$(date -u -v-180d +%Y-%m-%d 2>/dev/null || date -u -d '180 days ago' +%Y-%m-%d)" \
   '.repositories[] | .project as $p | .branches[] | select(.last_commit_at[:10] < $cut)
    | "\(.last_commit_at[:10])  \($p) › \(.name)"' "$R"

# every unique contributor + how many repos they touched
jq -r '[.repositories[] | .project as $p | .branches[].committers[] | {email: (.email | ascii_downcase), p: $p}]
       | group_by(.email) | map({email: .[0].email, repos: (map(.p) | unique | length)})
       | sort_by(-.repos)[] | "\(.repos)\t\(.email)"' "$R"

# failed repos + reasons
jq -r '.repositories[] | select(.error) | "\(.project): \(.error)"' "$R"
```
