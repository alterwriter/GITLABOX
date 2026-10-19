#!/usr/bin/env bash
# GITLABBOX — toolbox CLI interaktif buat GitLab (gitlab.com & self-hosted).
#
# Pakai:
#   ./gitlabbox.sh                 menu interaktif (↑/↓ + Enter)
#   ./gitlabbox.sh setup           wizard koneksi GitLab (URL, token, SSL)
#   ./gitlabbox.sh profiles        list profile koneksi
#   ./gitlabbox.sh whoami [-p P]   tes koneksi + info token
#   ./gitlabbox.sh branches ...    Branch & Committer Report (mode flag, buat CI)
#
# Butuh: bash 3.2+, curl, jq 1.6+

set -o pipefail
GLB_VERSION="0.1.0"
GLB_TIMEOUT="${GITLABBOX_TIMEOUT:-60}"

# resolve lokasi asli script (aman kalau di-symlink ke /usr/local/bin)
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

# Worker internal (dipanggil xargs -P), gak lewat setup/trap di bawah.
if [ "${1:-}" = __bc_branch ]; then
  bc_worker "$2"
  exit 0
fi

check_deps() {
  local miss=()
  command -v curl >/dev/null || miss+=(curl)
  command -v jq >/dev/null || miss+=(jq)
  if [ "${#miss[@]}" -gt 0 ]; then
    ui_err "Butuh: ${miss[*]}"
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
trap 'ui_spin_kill; printf "\n" >&2; ui_warn "Dibatalin (Ctrl+C)"; exit 130' INT TERM

usage() {
  ui_banner
  cat >&2 <<EOF

  ${B}Pakai${RST}
    ./gitlabbox.sh                 menu interaktif (↑/↓ + Enter)
    ./gitlabbox.sh setup           wizard koneksi GitLab (gitlab.com / self-hosted)
    ./gitlabbox.sh profiles        list profile koneksi
    ./gitlabbox.sh whoami [-p P]   tes koneksi + info token
    ./gitlabbox.sh branches -h     $TOOL_BC_NAME (mode flag, buat script/CI)
    ./gitlabbox.sh reports         lihat report tersimpan

  ${B}Env var${RST}
    GITLAB_URL / GITLAB_TOKEN      koneksi tanpa config (misal di CI)
    GITLAB_INSECURE=1              skip verifikasi SSL (profile env)
    GITLAB_CA_BUNDLE=path.pem      CA custom (profile env)
    GITLABBOX_HOME                 lokasi config (default ~/.gitlabbox)
    NO_COLOR=1                     matiin warna

EOF
}

status_line() {
  local p
  p=$(cfg_resolve_name "")
  if [ -n "$p" ]; then
    printf '\n  %s●%s koneksi: %s  %s(%s profile)%s\n' "$CG" "$RST" "$(profile_label "$p")" "$DIM" "$(cfg_count)" "$RST" >&2
  else
    printf '\n  %s○%s belum ada koneksi GitLab — pilih %sSetup koneksi%s dulu\n' "$CY" "$RST" "$B" "$RST" >&2
  fi
}

whoami_cmd() {
  local p=""
  [ "${1:-}" = -p ] || [ "${1:-}" = --profile ] && p="${2:-}"
  if [ -z "$p" ]; then
    if [ "$UI_TTY" = 1 ] && [ "$(cfg_count)" -gt 1 ]; then pick_profile "Tes profile yang mana?" include_env || return 1; p="$PICKED_PROFILE"
    else p=$(cfg_resolve_name ""); fi
  fi
  [ -n "$p" ] || { ui_err "Belum ada profile. Jalanin: ./gitlabbox.sh setup"; return 1; }
  use_profile "$p" || { ui_err "Profile '$p' gak ketemu."; return 1; }
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
    UI_HINTS=("List branch + jumlah committer per repo (single / semua repo akun lu / .txt / group) → JSON/CSV"
      "Buka ulang report JSON yang pernah dibikin"
      "Tambah koneksi: gitlab.com, self-hosted, atau dedicated"
      "Tes / ganti token / set default / hapus profile"
      "Cek token valid, user, scope, versi GitLab"
      "")
    ui_select k "Mau ngapain bro?" \
      "🌿  $TOOL_BC_NAME" \
      "📊  Lihat report tersimpan" \
      "🔌  Setup koneksi GitLab" \
      "🗂   Kelola profile" \
      "👤  Cek koneksi (whoami)" \
      "🚪  Keluar" || exit 0
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
    *) ui_err "Command gak dikenal: $1"; usage; exit 1 ;;
  esac
}

main "$@"
