# shellcheck shell=bash
# lib/targets.sh — parsing input repo.
#
# Format yang diterima (bisa dicampur di file .txt):
#   group/subgroup/project
#   12345                                         (project ID)
#   https://gitlab.example.com/group/project
#   https://gitlab.com/group/project/-/tree/main  (URL apapun dari browser)
#   git@gitlab.example.com:group/project.git
#   ssh://git@gitlab.example.com:2222/group/project.git
#   group:my-org/backend                          (semua project di group + subgroup)
#   account:member                                (semua project yang akun lu member)
#   account:developer@gitlab.example.com         (scope + host tertentu)
#   mine                                          (= account:member)
#   # komentar & baris kosong di-skip

# parse_target "baris" → set T_KIND (project|group) T_HOST T_PATH
parse_target() {
  local s="$1" rest
  T_KIND=project; T_HOST=""; T_PATH=""
  s="${s%%[[:space:]]#*}"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  case "$s" in
    account:* | mine | @me)
      # account:SCOPE[@host] — semua project yang bisa diakses akun (token) lu
      T_KIND=account
      rest="${s#account:}"
      case "$s" in mine | @me) rest=member ;; esac
      case "$rest" in *@*) T_HOST=$(url_host "${rest#*@}"); rest="${rest%%@*}" ;; esac
      T_PATH="${rest:-member}"
      return 0
      ;;
    group:*) T_KIND=group; s="${s#group:}" ;;
  esac
  case "$s" in
    http://* | https://*)
      rest="${s#*://}"
      T_HOST="${rest%%/*}"
      T_PATH=""; [ "$rest" != "$T_HOST" ] && T_PATH="${rest#*/}"
      ;;
    ssh://*)
      rest="${s#ssh://}"; rest="${rest#*@}"
      T_HOST="${rest%%/*}"; T_PATH="${rest#*/}"
      ;;
    *@*:*)
      rest="${s#*@}"
      T_HOST="${rest%%:*}"; T_PATH="${rest#*:}"
      ;;
    *) T_PATH="$s" ;;
  esac
  T_HOST="${T_HOST##*@}"; T_HOST="${T_HOST%%:*}"
  T_HOST=$(printf '%s' "$T_HOST" | tr '[:upper:]' '[:lower:]')
  T_PATH="${T_PATH%%\?*}"; T_PATH="${T_PATH%%#*}"
  T_PATH="${T_PATH%%/-/*}"
  T_PATH="${T_PATH%/}"; T_PATH="${T_PATH%.git}"; T_PATH="${T_PATH#/}"
  [ -n "$T_PATH" ]
}

# read_targets_file FILE → print baris valid (tanpa komentar/kosong, CRLF aman)
read_targets_file() {
  tr -d '\r' <"$1" | while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%[[:space:]]#*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in '' | '#'*) continue ;; esac
    printf '%s\n' "$line"
  done
}

# split_targets "a, b c" → satu per baris
split_targets() { printf '%s\n' "$1" | tr ', ' '\n\n' | sed '/^$/d'; }
