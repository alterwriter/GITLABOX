# shellcheck shell=bash
# lib/targets.sh — repo input parsing.
#
# Accepted formats (can be mixed in a .txt file):
#   group/subgroup/project
#   12345                                         (project ID)
#   https://gitlab.example.com/group/project
#   https://gitlab.com/group/project/-/tree/main  (any URL copied from the browser)
#   git@gitlab.example.com:group/project.git
#   ssh://git@gitlab.example.com:2222/group/project.git
#   group:my-org/backend                          (every project in the group + subgroups)
#   account:member                                (every project your account is a member of)
#   account:developer@gitlab.example.com          (scope + specific host)
#   mine                                          (= account:member)
#   # comments & blank lines are skipped

# parse_target "line" → sets T_KIND (project|group|account) T_HOST T_PATH
parse_target() {
  local s="$1" rest
  T_KIND=project; T_HOST=""; T_PATH=""
  s="${s%%[[:space:]]#*}"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  case "$s" in
    account:* | mine | @me)
      # account:SCOPE[@host] — every project your account (token) can access
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

# read_targets_file FILE → prints valid lines (no comments/blank lines, CRLF-safe)
read_targets_file() {
  tr -d '\r' <"$1" | while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%[[:space:]]#*}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in '' | '#'*) continue ;; esac
    printf '%s\n' "$line"
  done
}

# split_targets "a, b c" → one per line
split_targets() { printf '%s\n' "$1" | tr ', ' '\n\n' | sed '/^$/d'; }
