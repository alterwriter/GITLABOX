#!/usr/bin/env bash
# GITLABBOX — interactive CLI toolbox for GitLab (gitlab.com & self-hosted).
#
# Usage:
#   ./gitlabbox.sh                 interactive menu (↑/↓ + Enter)
#   ./gitlabbox.sh setup           GitLab connection wizard (URL, token, SSL)
#   ./gitlabbox.sh profiles        list connection profiles
#   ./gitlabbox.sh whoami [-p P]   test connection + token info
#   ./gitlabbox.sh branches ...    Branch & Committer Report (flag mode, for CI)
#
# Requires: bash 3.2+, curl, jq 1.6+

set -o pipefail
GLB_VERSION="0.1.0"
GLB_TIMEOUT="${GITLABBOX_TIMEOUT:-60}"

# resolve the script's real location (safe when symlinked into /usr/local/bin)
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir=$(cd -P "$(dirname "$_src")" && pwd)
  _src=$(readlink "$_src")
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
GLB_ROOT=$(cd -P "$(dirname "$_src")" && pwd)
GLB_SELF="$GLB_ROOT/gitlabbox.sh"
export GLB_ROOT GLB_SELF GLB_VERSION GLB_TIMEOUT

# shellcheck source=lib/ui.sh
. "$GLB_ROOT/lib/ui.sh"
# shellcheck source=lib/config.sh
. "$GLB_ROOT/lib/config.sh"
# shellcheck source=lib/api.sh
. "$GLB_ROOT/lib/api.sh"
# shellcheck source=lib/targets.sh
. "$GLB_ROOT/lib/targets.sh"
# shellcheck source=lib/setup.sh
. "$GLB_ROOT/lib/setup.sh"
# shellcheck source=tools/branch-committers.sh
. "$GLB_ROOT/tools/branch-committers.sh"

# Internal worker (invoked by xargs -P); skips the setup/traps below.
if [ "${1:-}" = __bc_branch ]; then
  bc_worker "$2"
  exit 0
fi

check_deps() {
  local miss=()
  command -v curl >/dev/null || miss+=(curl)
  command -v jq >/dev/null || miss+=(jq)
  if [ "${#miss[@]}" -gt 0 ]; then
    ui_err "Missing: ${miss[*]}"
    ui_hint "macOS : brew install ${miss[*]}"
    ui_hint "Debian: sudo apt install ${miss[*]}"
    exit 1
  fi
}
check_deps

GLB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/gitlabbox.XXXXXX") || exit 1
chmod 700 "$GLB_TMP"
export GLB_TMP

cleanup() {
  ui_spin_kill
  [ -n "${BC_XARGS_PID:-}" ] && kill "$BC_XARGS_PID" 2>/dev/null
  cursor_show
  rm -rf "$GLB_TMP"
}
trap cleanup EXIT
trap 'ui_spin_kill; printf "\n" >&2; ui_warn "Cancelled (Ctrl+C)"; exit 130' INT TERM

usage() {
  ui_banner
  cat >&2 <<EOF

  ${B}Usage${RST}
    ./gitlabbox.sh                 interactive menu (↑/↓ + Enter)
    ./gitlabbox.sh setup           GitLab connection wizard (gitlab.com / self-hosted)
    ./gitlabbox.sh profiles        list connection profiles
    ./gitlabbox.sh whoami [-p P]   test connection + token info
    ./gitlabbox.sh branches -h     $TOOL_BC_NAME (flag mode, for scripts/CI)
    ./gitlabbox.sh reports         view saved reports

  ${B}Environment${RST}
    GITLAB_URL / GITLAB_TOKEN      connect without a config file (e.g. in CI)
    GITLAB_INSECURE=1              skip SSL verification (env profile)
    GITLAB_CA_BUNDLE=path.pem      custom CA (env profile)
    GITLABBOX_HOME                 config location (default ~/.gitlabbox)
    NO_COLOR=1                     disable colors

EOF
}

status_line() {
  local p
  p=$(cfg_resolve_name "")
  if [ -n "$p" ]; then
    printf '\n  %s●%s connection: %s  %s(%s profiles)%s\n' "$CG" "$RST" "$(profile_label "$p")" "$DIM" "$(cfg_count)" "$RST" >&2
  else
    printf '\n  %s○%s no GitLab connection yet — choose %sSet up a GitLab connection%s first\n' "$CY" "$RST" "$B" "$RST" >&2
  fi
}

whoami_cmd() {
  local p=""
  [ "${1:-}" = -p ] || [ "${1:-}" = --profile ] && p="${2:-}"
  if [ -z "$p" ]; then
    if [ "$UI_TTY" = 1 ] && [ "$(cfg_count)" -gt 1 ]; then pick_profile "Which profile to test?" include_env || return 1; p="$PICKED_PROFILE"
    else p=$(cfg_resolve_name ""); fi
  fi
  [ -n "$p" ] || { ui_err "No profiles yet. Run: ./gitlabbox.sh setup"; return 1; }
  use_profile "$p" || { ui_err "Profile '$p' not found."; return 1; }
  glb_check_connection
}

interactive_main() {
  local k
  if [ "$UI_TTY" != 1 ]; then usage; exit 1; fi
  while :; do
    ui_clear
    ui_banner
    status_line
    ui_nl
    UI_HINTS=("List branches + committer count per repo (single / all your repos / .txt / group) → JSON/CSV"
      "Re-open a JSON report you generated earlier"
      "Add a connection: gitlab.com, self-hosted, or Dedicated"
      "Test / change token / set default / delete a profile"
      "Check token validity, user, scopes, GitLab version"
      "")
    ui_select k "What do you want to do?" \
      "🌿  $TOOL_BC_NAME" \
      "📊  View saved reports" \
      "🔌  Set up a GitLab connection" \
      "🗂   Manage profiles" \
      "👤  Check connection (whoami)" \
      "🚪  Quit" || exit 0
    case "$k" in
      0) bc_interactive ;;
      1) reports_browse; ui_pause ;;
      2) setup_wizard; ui_pause ;;
      3) profiles_manage ;;
      4) whoami_cmd; ui_pause ;;
      5) exit 0 ;;
    esac
  done
}

main() {
  case "${1:-}" in
    "" | menu) interactive_main ;;
    setup) ui_banner; setup_wizard ;;
    profiles | profile) profiles_list; ui_nl ;;
    whoami) shift; whoami_cmd "$@" ;;
    branches | branch-committers | bc) shift; bc_cli "$@" ;;
    reports) reports_browse ;;
    -h | --help | help) usage ;;
    -v | --version | version) printf 'gitlabbox %s\n' "$GLB_VERSION" ;;
    *) ui_err "Unknown command: $1"; usage; exit 1 ;;
  esac
}

main "$@"
