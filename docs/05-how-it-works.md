# 5. How it works

[← Output format](04-output-format.md) · [Architecture & development →](06-architecture.md)

## The big picture

```
input (-r / -f / -g / -a)
   │
   ▼
parse_target ──► normalize path / host / kind (project | group | account)
   │
   ▼
expand ──► group:/account: become a list of projects  ──► dedupe
   │
   ▼
for each repo (sequentially):
   1. GET /projects/:path            → id, default branch, visibility
   2. GET /projects/:id/repository/branches   (all pages)
   3. branch filter (glob)
   4. N parallel workers, one process per branch:
        GET /projects/:id/repository/commits?ref_name=<branch>[&since=…]  (all pages up to the cap)
        → group by email → count
   5. merge + sort → table on screen
   │
   ▼
merge all repos → report.json → (optional) report.csv
```

## API endpoints used

All of them are read-only `GET`s. The only scope needed is `read_api`.

| Endpoint | Used for | Parameters |
|---|---|---|
| `/version` | Probing the URL in the wizard, version info | — |
| `/user` | Connection test, username in account mode | — |
| `/personal_access_tokens/self` | Token name, scopes, and expiry (GitLab 15.5+, optional) | — |
| `/projects?per_page=1&visibility=public` | Testing access without a token | — |
| `/projects/:id` | Resolving a path or ID to a project | `:id` = URL-encoded path (`a%2Fb`) or a number |
| `/projects/:id/repository/branches` | Branch list | `per_page=100&page=N` |
| `/projects/:id/repository/commits` | Commits per branch | `ref_name`, `since`, `per_page=100&page=N` |
| `/groups/:id/projects` | Expanding `group:` | `include_subgroups=true`, `simple=true`, `order_by=path`, `archived=false` |
| `/projects` | Expanding `account:` | `membership` / `owned` / `min_access_level`, `simple=true`, `order_by=path`, `archived=false` |

## How committers are counted

For each branch:

1. Fetch the commits **reachable from the branch tip**, the same set as `git log <branch>`, newest first, limited by `since` and `max_commits_per_branch`.
2. Take the identity `{name, email}` of each commit:
   - `--identity author` (default): `author_name`, `author_email`
   - `--identity committer`: `committer_name`, `committer_email`
3. Grouping key = `lowercase(email)`. If the email is empty, `"name:" + lowercase(name)` is used.
4. `committer_count` = number of unique keys. `commit_count` = number of commits read.
5. `committers` is sorted by commit count (highest first), then by name.

At the repo level, `unique_committers` = unique keys **across all analyzed branches**.

### Things to keep in mind

- **History is inherited.** A `feature/x` branch created from `main` carries the whole history of `main`. As a result many branches show committer counts similar to `main`. To see only recent activity on a branch, use `--since-days`.
- **Commit cap.** When a branch has more commits than `--max-commits`, only the newest N are read (`truncated: true`, shown as `+` in the table). Older committers who only appear in old history may be missed.
- **One person, several emails.** Someone committing with two different emails (e.g. work and personal) counts as 2 people. GITLABBOX deliberately does not guess identity merges.
- **Bots count too.** Accounts such as Renovate, Dependabot, or release bots have emails as well. Filter them out at analysis time if needed, e.g. with `jq` (see the [recipes](04-output-format.md#jq-recipes)).
- **`merged`** comes from GitLab (`branch.merged`), meaning the branch tip is already contained in the default branch.

### Author vs committer

| | Author | Committer |
|---|---|---|
| Who | The person who **wrote** the change | The person/system that **applied** the commit to the repo |
| Differs from the author when | — | rebase, cherry-pick, `git am`, merge/squash via the GitLab UI, commits via the Web IDE |
| Example | `Dev A` | may be `GitLab` / `noreply@…` for merges done in the UI |

To answer "who contributed code", use **author** (the default).

## Pagination

- Every list endpoint is called with `per_page=100`.
- The next page comes from the **`x-next-page`** header. An empty header means the last page.
- Fallback: if the pagination headers are missing (e.g. stripped by a proxy) and a page is full (100 items), the next page is still tried.
- For commits, fetching stops as soon as `max_commits_per_branch` is reached. The rest is never downloaded.

## Retries & rate limits

| Condition | Behavior |
|---|---|
| Transient network errors (curl exit 28/52/55/56: timeout, empty reply, send/recv error) | Up to 3 retries, waiting 1s, 2s, 3s |
| HTTP `429`, `500`, `502`, `503`, `504` | Up to 5 retries. Waits for the `Retry-After` header if present, otherwise `attempt × 2` seconds. |
| HTTP `429` with `Retry-After` > 90 seconds | **Fails immediately** with a clear message. This is usually anonymous access hitting its limit, and telling you is better than silently waiting for tens of minutes. |
| HTTP `401/403/404/3xx` | Not retried. Turned into a human-friendly message (see [Troubleshooting](07-troubleshooting.md)). |
| `2xx` response that is not JSON | Fails with "wrong GitLab URL / blocked by SSO/proxy" |

Per-request timeouts: 10 seconds to connect, `GITLABBOX_TIMEOUT` total (default 60 seconds).

## Parallelism

- Repos are processed **one at a time**, so the on-screen output stays ordered and tidy.
- Within a repo, branches are processed **in parallel** with `xargs -P <workers>`. Each worker is a separate `gitlabbox.sh __bc_branch <index>` process.
- Workers receive their context through environment variables (`GLB_API`, `GLB_HDR`, `BC_PID`, `BC_SINCE`, …) and write their result to a per-branch JSON file in the temp folder.
- The progress bar in the main process counts the lines in a `done` file that each worker appends to when it finishes.
- 6 workers by default. Authenticated rate limits on gitlab.com are generous enough for that. On self-hosted instances the limits depend on the admin's settings.

## API cost

Estimated number of requests per repo:

```
1 (project) + ⌈branches / 100⌉ (branch list) + Σ ⌈min(branch_commits, max_commits) / 100⌉ (commits)
```

| Scenario | Branches | Commits read/branch | ≈ Requests |
|---|---|---|---|
| Small repo | 10 | 200 | 1 + 1 + 10×2 = **22** |
| Medium repo | 150 | 5,000 (default cap) | 1 + 2 + 150×50 = **7,503** |
| Medium repo, `-d 90` | 150 | ~150 | 1 + 2 + 150×2 = **303** |
| Medium repo, `-b 'main,release/*'` | 5 | 5,000 | 1 + 2 + 5×50 = **253** |

Account mode adds 1 `/user` request and ⌈number of projects / 100⌉ project-list requests.

**Takeaway:** for routine scans of many repos, `--since-days` and `--branch-filter` are the most effective ways to cut both run time and load on the GitLab server.

## Temporary files

- One folder per run: `mktemp -d $TMPDIR/gitlabbox.XXXXXX` with permission `700`.
- It holds the auth header file, raw API response pages, and the per-branch and per-repo results.
- It is removed automatically on exit, including when cancelled with Ctrl+C. Any worker processes still running are stopped too.
