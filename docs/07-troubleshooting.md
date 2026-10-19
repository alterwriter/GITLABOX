# 7. Troubleshooting

[← Architecture & development](06-architecture.md) · [Security →](08-security.md)

The most useful first steps:

```bash
./gitlabbox.sh whoami            # is the token valid? which scopes? which GitLab version?
./gitlabbox.sh profiles          # which profile is the default?
```

## Error messages & fixes

| Message | Cause | Fix |
|---|---|---|
| `401 Unauthorized — token is missing / wrong / expired / revoked` | Invalid token | Create a new token → Manage profiles → Change token |
| `403 Forbidden — token lacks scope (read_api required) or your role is too low` | The token only has `read_repository`, or your project role is below Reporter | Use a token with the `read_api` scope, or ask for Reporter+ access |
| `404 Not Found — wrong path, or the project is private and the token has no access` | Typo in the path, the project was moved/deleted, or GitLab hides private projects from users without access | Check the path in the browser, using the same account |
| `Host '…' has no profile yet` | The repo URL points to an instance you haven't set up | `./gitlabbox.sh setup` for that host |
| `Host not found (DNS). Check the URL — or do you need to turn on a VPN?` | DNS lookup failed (curl exit 6) | Turn on the company VPN or fix the URL |
| `Connection refused` | The port is closed (curl exit 7) | Check the URL/port and firewall |
| `Timeout` | The server is slow (curl exit 28) | `export GITLABBOX_TIMEOUT=180` |
| `SSL/TLS problem (self-signed certificate / internal CA?)` | Your system does not trust the server certificate | Re-run setup with a **custom CA bundle** (your company's CA `.pem`). Only **skip verification** if you really must. |
| `SSL/TLS problem` even though the server uses `http://` | You typed the URL without a scheme, so `https://` was assumed | Type `http://` explicitly in the wizard |
| `Response is not JSON — wrong GitLab URL, or blocked by SSO/proxy` | The URL leads to an HTML page (SSO login, captive portal, reverse proxy) | Make sure `<url>/api/v4/version` is reachable. Check the GitLab root URL. |
| `302 Redirect to … — check the URL (http vs https / sub-path / SSO)` | The server redirects, e.g. from http to https or to an SSO page | Use the redirect target as the profile URL |
| `429 GitLab rate limit (asked to wait Ns)` | Too many requests, usually from access **without a token** | Use a token, lower `-w`, narrow the scan with `-d` / `-b` |
| `Account mode needs a token` | A profile without a token was used for `--mine` / `-a` | Add a PAT to the profile |
| `Scope 'all' on gitlab.com means every public repo in the world` | `-a all` on gitlab.com | Use `member` |
| `Token has no read_api/api scope` (warning) | A token with narrow scopes | Recreate the token with `read_api` |
| `Interactive menus need a terminal (TTY)` | Run without a terminal (pipe, CI, cron) | Use flag mode: `./gitlabbox.sh branches ...` |
| `Missing: jq` | `jq` is not installed | `brew install jq` / `apt install jq` |

## Other symptoms

**Almost every branch has a committer count similar to `main`.**
That's expected. Branches created from `main` carry the history of `main`. Use `-d 30` / `-d 90` to look at recent activity only. See [How it works](05-how-it-works.md#things-to-keep-in-mind).

**There is a `+` in the COMMITS column.**
That branch has more commits than `--max-commits`. Raise the cap (`-m 20000` or `-m 0`) if you need accurate numbers for the full history.

**One person is counted twice.**
They committed with two different emails. Grouping deliberately uses the email only.

**The scan is very slow.**
Work out the estimate in [API cost](05-how-it-works.md#api-cost). The usual cause is repos with hundreds of branches and long histories. Narrow it down with `-b`, `-d`, or `--repo-filter`.

**Account mode only finds a few projects.**
- Using a Project/Group Access Token? Those only see their own project/group. Use a PAT.
- Archived projects are skipped by default. Add `--include-archived`.
- The `owned` scope only covers projects you own. Try `member`.

**Colors or box characters look broken.**
Make sure your terminal uses a UTF-8 locale (`echo $LANG` → `en_US.UTF-8` or similar). If needed, disable colors with `NO_COLOR=1`.

**Arrow keys don't respond.**
Some terminals send arrow keys in a different mode. Use `j`/`k` or the number keys `1`–`9` instead.

**SSH to GitHub/GitLab times out on port 22 (when cloning this repo).**
Your network blocks port 22. Use SSH over port 443. For GitHub, add this to `~/.ssh/config`:

```
Host github.com
  HostName ssh.github.com
  Port 443
  User git
```

GitHub's official ED25519 fingerprint: `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`.

## Manual debugging

Try the same requests directly with `curl`. If these work but GITLABBOX fails, it's a bug in the tool:

```bash
curl -sS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "https://gitlab.example.com/api/v4/user" | jq .
curl -sS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://gitlab.example.com/api/v4/projects/$(jq -rn --arg s 'team/app' '$s|@uri')/repository/branches?per_page=5" | jq '.[].name'
```
