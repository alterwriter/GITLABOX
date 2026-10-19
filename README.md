# GITLABBOX

An interactive CLI toolbox for GitLab, written in pure **Bash**. Works with **GitLab.com (SaaS)**, **self-hosted GitLab (CE/EE)**, and **GitLab Dedicated**.

The first tool in the box is the **Branch & Committer Report**. It lists every branch in one or many repositories, counts the **unique committers per branch**, sorts them from busiest to quietest, and exports the result to **JSON** or **CSV**.

```
   ██████╗ ██╗████████╗██╗      █████╗ ██████╗ ██████╗  ██████╗ ██╗  ██╗
  ██╔════╝ ██║╚══██╔══╝██║     ██╔══██╗██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝
  ██║  ███╗██║   ██║   ██║     ███████║██████╔╝██████╔╝██║   ██║ ╚███╔╝
  ██║   ██║██║   ██║   ██║     ██╔══██║██╔══██╗██╔══██╗██║   ██║ ██╔██╗
  ╚██████╔╝██║   ██║   ███████╗██║  ██║██████╔╝██████╔╝╚██████╔╝██╔╝ ██╗
   ╚═════╝ ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝

  ● connection: work · gitlab.example.com  (2 profiles)

  ? What do you want to do? (↑/↓ · Enter · q to cancel)
  ❯ 🌿  Branch & Committer Report
    📊  View saved reports
    🔌  Set up a GitLab connection
    🗂   Manage profiles
    👤  Check connection (whoami)
    🚪  Quit
    ↳ List branches + committer count per repo (single / all your repos / .txt / group) → JSON/CSV
```

## Features

- **Interactive**: arrow-key menus, spinners, progress bars, colored tables, and boxed summaries.
- **Flag mode**: anything you can do in the menu can also be done with flags, so it fits scripts, cron jobs, and GitLab CI.
- **Flexible repo sources**: one repo, several repos, a `.txt` file, a whole group including subgroups, or **every repo your account can access**.
- **Multi-instance**: store several connection profiles (for example gitlab.com plus a self-hosted server). The host in a repo URL is matched to the right profile automatically.
- **Guided setup**: pick the instance type, URL, SSL mode (custom CA / skip verification), and auth method (PAT, project/group token, OAuth2, env var, or none). The connection is tested right away.
- **Resilient**: automatic retries, honors rate limits (`Retry-After`), pagination, parallel requests, and a failure in one repo never stops a bulk scan.
- **Read-only & safe**: `GET` requests only, the token never appears in process arguments, and the config file is `chmod 600`.
- **Minimal dependencies**: just `bash` 3.2+ (the macOS default), `curl`, and `jq`.

## Quick start

```bash
git clone git@github.com:alterwriter/GITLABOX.git
cd GITLABOX
./gitlabbox.sh setup      # connect to GitLab (one time)
./gitlabbox.sh            # open the interactive menu
```

Flag mode examples:

```bash
./gitlabbox.sh branches -r my-group/my-app                 # one repo
./gitlabbox.sh branches --mine -d 90 -F both               # all your repos, last 90 days
./gitlabbox.sh branches -f repos.txt -b 'main,release/*'   # bulk from a file
./gitlabbox.sh branches -g my-org/backend -o - | jq .summary
```

Sample output:

```
  [1/3] acme/web
  ✔ Project acme/web · id 13 · private · default: main · gitlab.example.com
  ✔ 144 branches found
  ✔ 144 branches analyzed · 26 unique committers (across all branches) · 5s

    #  BRANCH                                  COMMITTERS            COMMITS  LAST        FLAGS  TOP COMMITTER
    1  main                                    ██████████████   26      1532  2026-10-14  D P ·  Dev A (212)
    2  release/2.0                             █████████████░   24       940  2026-10-11  · · ·  Dev B (131)
    3  feature/checkout-v2                     ██████░░░░░░░░   11     5000+  2026-10-07  · · ·  Dev C (88)
```

## Documentation

| Document | Contents |
|---|---|
| [Getting started](docs/01-getting-started.md) | Requirements, installation, first run, keyboard navigation |
| [Connection & authentication](docs/02-connection-and-auth.md) | SaaS vs self-hosted vs Dedicated, token types & scopes, SSL, profiles, env vars, CI |
| [Branch & Committer Report](docs/03-branch-committer-report.md) | Full tool guide: repo sources, options, interactive flow, CLI reference |
| [Output format](docs/04-output-format.md) | Field-by-field JSON schema, CSV columns, `jq` recipes |
| [How it works](docs/05-how-it-works.md) | API endpoints, committer counting, pagination, retries, parallelism, API cost estimates |
| [Architecture & development](docs/06-architecture.md) | Code layout, library reference, adding a new tool, testing |
| [Troubleshooting](docs/07-troubleshooting.md) | Common errors and fixes |
| [Security](docs/08-security.md) | Security model, token storage, data in reports |

## Layout

```
GITLABOX/
├── gitlabbox.sh               # entry point: main menu & command dispatch
├── lib/
│   ├── ui.sh                  # colors, banner, ↑/↓ menus, input, spinner, progress bar, box
│   ├── config.sh              # connection profiles & token resolution
│   ├── api.sh                 # curl wrapper: auth, retry/429, pagination, error messages
│   ├── targets.sh             # repo input parsing (path / ID / URL / SSH / group: / account:)
│   └── setup.sh               # connection wizard & profile management
├── tools/
│   └── branch-committers.sh   # Tool #1: Branch & Committer Report
├── docs/                      # detailed documentation
├── repos.example.txt          # repo list template
└── reports/                   # default output (git-ignored)
```

## Privacy note

Generated reports contain **repository names, branch names, and contributor names and emails**. The `reports/` folder and `repos.txt` are already in `.gitignore`. Never commit scan results to a public repo. See [Security](docs/08-security.md) for details.

## License

[MIT](LICENSE). Free to use, modify, and distribute, as long as the copyright and license notice are included.
