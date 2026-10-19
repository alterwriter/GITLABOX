# 6. Architecture & development

[← How it works](05-how-it-works.md) · [Troubleshooting →](07-troubleshooting.md)

## Design principles

- **Bash 3.2-compatible**, so it runs on macOS without installing anything. That rules out `declare -A`, `mapfile`, `${var,,}`, `wait -n`, and fractional `read -t`.
- **`jq` for everything JSON**, including date math (`now - N*86400 | todate`). That removes any dependency on GNU vs BSD `date` differences.
- **UI to stderr, data to stdout**, so output can be piped.
- **Small reusable libraries** in `lib/`, and one file per feature in `tools/`.
- **No `set -e` / `set -u`.** Errors are handled explicitly (`|| return`) because the interactive flow needs full control. Only `set -o pipefail` is used.

## File layout

```
gitlabbox.sh               entry point
├─ source lib/ui.sh
├─ source lib/config.sh
├─ source lib/api.sh
├─ source lib/targets.sh
├─ source lib/setup.sh
└─ source tools/branch-committers.sh
```

What `gitlabbox.sh` does, in order:

1. Resolves the script's real location (symlink-safe) → `GLB_ROOT`, `GLB_SELF`.
2. Sources all libraries and tools.
3. If the first argument is `__bc_branch`, runs the **worker** and exits, skipping the setup below.
4. Checks dependencies (`curl`, `jq`).
5. Creates the temp folder `GLB_TMP` (700) and installs `trap`s for cleanup (EXIT) and Ctrl+C (INT/TERM).
6. `main "$@"` → dispatches to the menu or a command.

## Library reference

### `lib/ui.sh`: display

| Function | Purpose |
|---|---|
| `ui_banner` | Gradient ASCII banner (compact version when the terminal is < 74 columns) |
| `ui_title "Title" ["sub"]` | Section header |
| `ui_ok` / `ui_err` / `ui_warn` / `ui_info` / `ui_hint` | Messages with `✔ ✖ ▲ ℹ` symbols, and dimmed text |
| `ui_box "Title" lines...` | Rounded box. Width is automatic and ignores ANSI color codes. |
| `ui_select VAR "Question" options...` | ↑/↓ menu. Puts the 0-based **index** in `VAR`, returns 1 when cancelled. Optional: `UI_HINTS=(...)` for per-option descriptions, `UI_SELECT_DEFAULT=N` for the initial position. |
| `ui_confirm "Question" [y\|n]` | Yes/No, returns 0 for Yes |
| `ui_input VAR "Label" [default] [plain\|secret\|path]` | Text input. `secret` = hidden, `path` = readline + Tab completion. |
| `ui_spin_start "message" [counter_file]` / `ui_spin_stop RC "message"` | Background spinner. If `counter_file` is given, the number in it is shown live. |
| `ui_progress DONE TOTAL "label"` / `ui_progress_end` | One-line progress bar |
| `ui_minibar VAL MAX WIDTH` | Fixed-width mini bar for tables |
| `ui_pause`, `ui_clear`, `ui_duration SECONDS` | Utilities |

Colors are disabled automatically when stderr is not a TTY, `NO_COLOR` is set, or `TERM=dumb`. Interactive menus need both stdin **and** stderr to be TTYs (`UI_TTY=1`).

### `lib/config.sh`: profiles

| Function | Purpose |
|---|---|
| `cfg_profiles` / `cfg_count` / `cfg_default` / `cfg_exists NAME` / `cfg_field NAME KEY` | Read the config |
| `cfg_save_profile NAME URL KIND AUTH TOKEN TOKEN_ENV VERIFY CA MAKE_DEFAULT` | Save a profile. The token is passed to `jq` through the environment, not argv. |
| `cfg_delete_profile`, `cfg_set_default` | Modify the config (atomically) |
| `cfg_resolve_name [NAME]` | Effective profile (argument → default → the only one → `env`) |
| `cfg_find_by_host HOST` | Find a profile by host |
| `use_profile NAME` | Activate a profile: sets & exports `GLB_URL`, `GLB_API`, `GLB_HOST`, `GLB_HDR`, `GLB_INSECURE`, `GLB_CACERT`, … |
| `use_profile_values ...` | Same, but from raw values (used by the wizard before saving) |
| `normalize_url`, `url_host`, `url_path` | URL utilities |

### `lib/api.sh`: HTTP

| Function | Purpose |
|---|---|
| `api_get PATH OUT_FILE` | GET `$GLB_API$PATH` → body in `OUT_FILE`, headers in `OUT_FILE.hdr`. Returns 0 on 2xx + valid JSON. Result variables: `API_STATUS`, `API_ERROR`, `API_NEXT_PAGE`. |
| `api_get_all PATH OUT_FILE [MAX] [COUNTER_FILE]` | Fetch every page into a single JSON array. Result variables: `API_COUNT`, `API_TRUNCATED`. |
| `glb_check_connection` | Connection test + info box (used by `whoami` and the wizard) |
| `_uri STRING` | URL-encode (via `jq @uri`) |

### `lib/targets.sh`: input

| Function | Purpose |
|---|---|
| `parse_target "line"` | Sets `T_KIND` (`project`/`group`/`account`), `T_HOST`, `T_PATH` |
| `read_targets_file FILE` | Valid lines from a file (no comments, CRLF-safe) |
| `split_targets "a, b c"` | Split into one per line |

### `lib/setup.sh`: connections

`setup_wizard`, `pick_profile "Title" [include_env]` (result in `PICKED_PROFILE`), `profiles_manage`, `profiles_list`.

## Anatomy of a tool: `tools/branch-committers.sh`

| Part | Functions |
|---|---|
| Defaults & options | `bc_defaults` → `BC_*` variables |
| Per-repo profile | `bc_prepare_profile`, `bc_bind_profile HOST` |
| Input expansion | `bc_expand_targets`, `bc_fetch_projects group\|account ARG OUT`, `_bc_glob_lines` |
| Worker | `bc_worker IDX`, the `BC_JQ_BRANCH` jq program |
| Per repo | `bc_scan_repo IDX` |
| Tables | `_bc_table`, `bc_print_repo_table`, `bc_print_leaderboard` |
| Report | `bc_run` (merge + write), `bc_to_csv`, `_bc_out_paths` |
| UI | `bc_interactive`, `_bc_pick_account`, `bc_view_report`, `reports_browse` |
| CLI | `bc_cli`, `bc_usage` |

## Adding a new tool

Example: a `stale-branches` tool that finds inactive branches.

**1. Create `tools/stale-branches.sh`**

```bash
# shellcheck shell=bash
# tools/stale-branches.sh — find branches whose latest commit is older than N days.

TOOL_SB_NAME="Stale Branch Finder"

sb_run() { # sb_run PROJECT_PATH DAYS
  local f="$GLB_TMP/sb" cut
  cut=$(jq -nr --argjson d "$2" 'now - ($d * 86400) | todate')
  ui_spin_start "Fetching branches of $1" "$f.count"
  if ! api_get_all "/projects/$(_uri "$1")/repository/branches" "$f.json" 0 "$f.count"; then
    ui_spin_stop 1 "$API_ERROR"; return 1
  fi
  ui_spin_stop 0 "$(jq length "$f.json") branches"
  jq -r --arg cut "$cut" '.[] | select(.commit.committed_date < $cut and (.default | not))
    | "\(.commit.committed_date[:10])  \(.name)"' "$f.json" | sort
}

sb_interactive() {
  local repo days
  ui_title "$TOOL_SB_NAME"
  pick_profile "Which connection?" include_env || return
  use_profile "$PICKED_PROFILE" || return
  ui_input repo "Repo" ""
  ui_input days "Inactive for more than (days)" "90"
  sb_run "$repo" "$days"
}

sb_cli() { # stale -r REPO -d DAYS
  local repo="" days=90
  while [ $# -gt 0 ]; do
    case "$1" in -r) repo="$2"; shift 2 ;; -d) days="$2"; shift 2 ;; *) shift ;; esac
  done
  use_profile "$(cfg_resolve_name "")" || return 1
  sb_run "$repo" "$days"
}
```

**2. Register it in `gitlabbox.sh`**

```bash
. "$GLB_ROOT/tools/stale-branches.sh"                 # in the source block

# in interactive_main: add a hint + option + case
"🧹  $TOOL_SB_NAME"
6) sb_interactive; ui_pause ;;

# in main:
stale) shift; sb_cli "$@" ;;
```

**3. Guidelines**

- Prefix every function and global variable with the tool's initials (`sb_`, `SB_`) to avoid clashes.
- Use `api_get_all` for list endpoints, since it already handles pagination and retries.
- Send all UI output through the `ui_*` functions (to stderr). Data/results go to stdout or files.
- Keep temp files in `$GLB_TMP`, which is cleaned up automatically.
- If you need parallelism, follow the `__bc_branch` worker pattern: dispatch at the top of `gitlabbox.sh` before setup/traps, and pass context through `export`.

## Testing

### Syntax check

```bash
for f in gitlabbox.sh lib/*.sh tools/*.sh; do /bin/bash -n "$f" && echo "ok $f"; done
shellcheck gitlabbox.sh lib/*.sh tools/*.sh      # if shellcheck is installed
```

Use `/bin/bash` (3.2 on macOS) to make sure compatibility is preserved.

### Non-interactive test against any instance

```bash
GITLABBOX_HOME=$(mktemp -d) GITLAB_URL=https://gitlab.example.com GITLAB_TOKEN=... \
  ./gitlabbox.sh branches -r team/app -m 50 -o - | jq .summary
```

A temporary `GITLABBOX_HOME` makes sure your real config is never touched.

### Mock server

During development the tool was tested against a small mock GitLab API (local HTTP) that imitates the endpoints in the [How it works](05-how-it-works.md#api-endpoints-used) table: `x-next-page` pagination, `401` without a token, `404`, the `membership/owned/min_access_level` scopes, archived projects, and emails with mixed letter case. Point `GITLAB_URL` at such a mock.

Scenarios worth checking:

| Scenario | Expected |
|---|---|
| More than 100 branches | Every page is fetched |
| Branch named `release/1.0` | `ref_name` is encoded, commits are read |
| Emails differing only in case | Counted as one person |
| Same repo via path & URL | Appears once |
| Repo 404 / host without a profile | Recorded as `error`, the scan continues, exit code 3 |
| `429` + large `Retry-After` | Fails fast with a rate-limit message |
| `-m 50` | `truncated: true`, `+` marker |
| Account mode without a token | Rejected with a clear message |

### Interactive UI tests

Menus can be driven automatically with `expect` (bundled with macOS):

```tcl
spawn ./gitlabbox.sh
expect "What do you want to do?";       send "\r"
expect "Where do the repos come from?"; send "j"; send "\r"
expect "Account repo scope";            send "\r"
...
```

`j` = ↓, `\r` = Enter. Add `sleep 0.2` between keys so rendering can finish.
