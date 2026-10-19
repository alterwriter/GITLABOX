# 1. Getting started

[← README](../README.md) · [Connection & authentication →](02-connection-and-auth.md)

## Requirements

| Component | Minimum version | Check | Install |
|---|---|---|---|
| bash | 3.2 (the macOS default is enough) | `bash --version` | — |
| curl | one that supports `-H @file` (7.55+) | `curl --version` | `brew install curl` / `apt install curl` |
| jq | 1.6 | `jq --version` | `brew install jq` / `apt install jq` |

Apart from these, only standard Unix tools are used: `sed`, `awk`, `tr`, `xargs`, `seq`, `mktemp`. No Python, Node, or other package managers needed.

Tested on macOS (bash 3.2 + BSD userland). Linux (bash 4/5 + GNU userland) is supported too, because the script deliberately avoids platform-specific behavior. For example, date math is done in `jq` instead of `date -d`/`date -v`.

## Installation

```bash
git clone git@github.com:alterwriter/GITLABOX.git
cd GITLABOX
chmod +x gitlabbox.sh
```

Optionally, make it callable from anywhere:

```bash
ln -s "$PWD/gitlabbox.sh" /usr/local/bin/gitlabbox
gitlabbox --version
```

Symlinks are fine. The script resolves its real location to find `lib/` and `tools/`.

## First run

1. **Connect to GitLab.** The steps are covered in [Connection & authentication](02-connection-and-auth.md).
   ```bash
   ./gitlabbox.sh setup
   ```
2. **Verify the connection.**
   ```bash
   ./gitlabbox.sh whoami
   ```
   ```
   ✔ Connected to https://gitlab.example.com
   ╭─ Connection OK ─────────────────────────────────────────────╮
   │ Profile  work                                               │
   │ URL      https://gitlab.example.com                         │
   │ Version  GitLab 17.5.1-ee                                   │
   │ User     @username (Your Name)                              │
   │ Token    stored in config                                   │
   │          gitlabbox · scopes: read_api · expires: 2027-01-01 │
   ╰─────────────────────────────────────────────────────────────╯
   ```
3. **Open the menu and run your first report.**
   ```bash
   ./gitlabbox.sh
   ```

## Commands

| Command | What it does |
|---|---|
| `./gitlabbox.sh` (or `menu`) | Interactive menu |
| `./gitlabbox.sh setup` | Wizard to add a GitLab connection |
| `./gitlabbox.sh profiles` | Table of all connection profiles |
| `./gitlabbox.sh whoami [-p PROFILE]` | Test the connection + show user & token info |
| `./gitlabbox.sh branches [options]` | Branch & Committer Report in flag mode (see the [tool guide](03-branch-committer-report.md)) |
| `./gitlabbox.sh reports` | Pick and re-display a saved JSON report |
| `./gitlabbox.sh --help` | Help |
| `./gitlabbox.sh --version` | Version |

Aliases: `branches` = `branch-committers` = `bc`, `profiles` = `profile`.

## Keyboard navigation

Every selection menu uses the same controls:

| Key | Action |
|---|---|
| `↑` / `↓` (or `k` / `j`, `w` / `s`) | Move the selection |
| `1` – `9` | Jump to option N |
| `Enter` | Choose |
| `q` / `Esc` | Cancel / go back |
| `Ctrl+C` | Quit the program (the cursor and temp files are cleaned up) |

A `↳` line under the menu describes the highlighted option. Once you choose, the menu collapses to a single `✔ Question › answer` line, so your answers stay readable on screen.

Text input:
- Defaults are shown in parentheses. Press `Enter` to accept them.
- Path inputs (such as the `.txt` file or the output folder) support **Tab completion** and `~`.
- Token input is hidden. Afterwards only the first 6 characters + `••••` are shown.

## Interactive mode vs flag mode

| | Interactive | Flags |
|---|---|---|
| Needs a terminal (TTY) | Yes | No |
| Best for | Exploring, one-off runs | Scripts, cron, CI |
| Confirmation before running | Yes (summary + "Go?") | No, runs immediately |
| Output to stdout | — | Yes (`-o -`) |

All UI output (spinners, tables, messages) goes to **stderr**, so stdout stays clean for piping, e.g. `./gitlabbox.sh branches -r a/b -o - | jq`.

## Environment variables

| Variable | Purpose |
|---|---|
| `GITLAB_URL` / `CI_SERVER_URL` | GitLab URL for the `env` profile (no config file) |
| `GITLAB_TOKEN` | Token for the `env` profile, and a fallback for profiles without a token |
| `GITLAB_AUTH` | `pat` (default) or `oauth` for the `env` profile |
| `GITLAB_INSECURE=1` | Skip SSL verification for the `env` profile |
| `GITLAB_CA_BUNDLE` | CA bundle path for the `env` profile |
| `GITLABBOX_HOME` | Config folder location (default `~/.gitlabbox`) |
| `GITLABBOX_TIMEOUT` | Total timeout per request in seconds (default `60`) |
| `NO_COLOR=1` | Disable colors |

## Next steps

- [Connection & authentication](02-connection-and-auth.md): token, SSL, and multi-instance details.
- [Branch & Committer Report](03-branch-committer-report.md): every way to use the tool.
