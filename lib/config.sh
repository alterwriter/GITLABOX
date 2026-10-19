# shellcheck shell=bash
# lib/config.sh — GitLab connection profiles.
#
# Stored in ~/.gitlabbox/config.json (folder 700, file 600). One profile =
# one GitLab instance (gitlab.com / self-hosted / dedicated) + how to authenticate.
#
# Example:
# {
#   "default": "work",
#   "profiles": {
#     "work": { "url": "https://gitlab.example.com", "kind": "self-hosted",
#                 "auth": "pat", "token": "glpat-xxx", "token_env": "",
#                 "verify_ssl": true, "ca_bundle": "" }
#   }
# }
#
# Token order: env var named in token_env → stored token → $GITLAB_TOKEN → no token.
# With no config at all (e.g. in CI): GITLAB_URL / CI_SERVER_URL + GITLAB_TOKEN
# automatically become the "env" profile.

GLB_HOME="${GITLABBOX_HOME:-$HOME/.gitlabbox}"
GLB_CONFIG="$GLB_HOME/config.json"

cfg_init() {
  if [ ! -d "$GLB_HOME" ]; then mkdir -p "$GLB_HOME" && chmod 700 "$GLB_HOME"; fi
  if [ ! -f "$GLB_CONFIG" ]; then
    (umask 077 && printf '{"default":null,"profiles":{}}\n' >"$GLB_CONFIG")
  fi
}

# cfg_jq FILTER [jq args...] — read the config
cfg_jq() {
  local f="$1"; shift
  [ -f "$GLB_CONFIG" ] || { jq -nr "$@" "{\"default\":null,\"profiles\":{}} | $f"; return; }
  jq -r "$@" "$f" "$GLB_CONFIG"
}

# cfg_write FILTER [jq args...] — modify the config atomically
cfg_write() {
  local f="$1" tmp; shift
  cfg_init
  tmp="$GLB_CONFIG.tmp.$$"
  (umask 077 && jq "$@" "$f" "$GLB_CONFIG" >"$tmp") && mv "$tmp" "$GLB_CONFIG"
}

cfg_profiles()  { cfg_jq '.profiles | keys[]'; }
cfg_count()     { cfg_jq '.profiles | length'; }
cfg_default()   { cfg_jq '.default // empty'; }
cfg_exists()    { [ "$(cfg_jq '.profiles[$n] != null' --arg n "$1")" = true ]; }
cfg_field()     { cfg_jq '.profiles[$n][$k] | if . == null then empty else tostring end' --arg n "$1" --arg k "$2"; }

normalize_url() {
  local u="$1"
  u="${u%/}"
  case "$u" in http://* | https://*) ;; *) u="https://$u" ;; esac
  u="${u%/api/v4}"
  u="${u%/}"
  printf '%s' "$u"
}

url_host() { # https://user@host:8443/path → host
  local r="${1#*://}"
  r="${r%%/*}"; r="${r##*@}"; r="${r%%:*}"
  printf '%s' "$r" | tr '[:upper:]' '[:lower:]'
}

url_path() { # https://host/gitlab → /gitlab
  local r="${1#*://}"
  case "$r" in */*) printf '/%s' "${r#*/}" ;; *) printf '' ;; esac
}

# Active profile: argument → config default → the only profile → "env"
cfg_resolve_name() {
  local want="$1" d c
  if [ -n "$want" ]; then printf '%s' "$want"; return; fi
  d=$(cfg_default)
  if [ -n "$d" ] && cfg_exists "$d"; then printf '%s' "$d"; return; fi
  c=$(cfg_count)
  if [ "$c" = 1 ]; then cfg_profiles; return; fi
  if [ -n "${GITLAB_URL:-}${CI_SERVER_URL:-}" ]; then printf 'env'; return; fi
  printf ''
}

cfg_find_by_host() {
  local h="$1" p
  for p in $(cfg_profiles); do
    if [ "$(url_host "$(cfg_field "$p" url)")" = "$h" ]; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# cfg_save_profile NAME URL KIND AUTH TOKEN TOKEN_ENV VERIFY(true/false) CA_BUNDLE MAKE_DEFAULT(1/0)
# The token is passed via env (not argv) so it never shows up in `ps`.
cfg_save_profile() {
  GLB_NEW_TOKEN="$5" cfg_write '
    .profiles[$n] = {
      url: $url, kind: $kind, auth: $auth,
      token: $ENV.GLB_NEW_TOKEN, token_env: $tenv,
      verify_ssl: ($verify == "true"), ca_bundle: $ca
    }
    | if ($mk == "1") or (.default == null) then .default = $n else . end' \
    --arg n "$1" --arg url "$2" --arg kind "$3" --arg auth "$4" --arg tenv "$6" \
    --arg verify "$7" --arg ca "$8" --arg mk "$9"
}

cfg_delete_profile() {
  cfg_write 'del(.profiles[$n]) | if .default == $n then .default = ((.profiles | keys)[0] // null) else . end' --arg n "$1"
}

cfg_set_default() { cfg_write '.default = $n' --arg n "$1"; }

# ---------- profile activation ----------
# use_profile_values NAME URL AUTH TOKEN VERIFY CA
#   sets + exports the GLB_* variables used by lib/api.sh (and by parallel workers).
use_profile_values() {
  local name="$1" url="$2" auth="$3" token="$4" verify="$5" ca="$6"
  GLB_PROFILE="$name"
  GLB_URL="$(normalize_url "$url")"
  GLB_API="$GLB_URL/api/v4"
  GLB_HOST="$(url_host "$GLB_URL")"
  GLB_URL_PATH="$(url_path "$GLB_URL")"
  GLB_AUTH="$auth"
  GLB_INSECURE=0; [ "$verify" = false ] && GLB_INSECURE=1
  GLB_CACERT="$ca"
  GLB_HDR=""
  token="$(printf '%s' "$token" | tr -d '[:space:]')"
  if [ -n "$token" ]; then
    GLB_HDR="$GLB_TMP/auth.$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-' '_').hdr"
    (
      umask 077
      if [ "$auth" = oauth ]; then
        printf 'Authorization: Bearer %s\n' "$token" >"$GLB_HDR"
      else
        printf 'PRIVATE-TOKEN: %s\n' "$token" >"$GLB_HDR"
      fi
    )
  fi
  export GLB_PROFILE GLB_URL GLB_API GLB_HOST GLB_URL_PATH GLB_AUTH GLB_INSECURE GLB_CACERT GLB_HDR
}

use_profile() {
  local name="$1" url auth token tenv verify ca
  if [ "$name" = env ] && ! cfg_exists env; then
    url="${GITLAB_URL:-${CI_SERVER_URL:-}}"
    [ -n "$url" ] || return 1
    GLB_TOKEN_SOURCE="env \$GITLAB_TOKEN"
    [ -n "${GITLAB_TOKEN:-}" ] || GLB_TOKEN_SOURCE="no token"
    verify=true; [ "${GITLAB_INSECURE:-0}" = 1 ] && verify=false
    use_profile_values env "$url" "${GITLAB_AUTH:-pat}" "${GITLAB_TOKEN:-}" "$verify" "${GITLAB_CA_BUNDLE:-}"
    return 0
  fi
  cfg_exists "$name" || return 1
  url=$(cfg_field "$name" url)
  auth=$(cfg_field "$name" auth)
  tenv=$(cfg_field "$name" token_env)
  verify=$(cfg_field "$name" verify_ssl)
  ca=$(cfg_field "$name" ca_bundle)
  if [ -n "$tenv" ] && [ -n "$(printenv "$tenv" 2>/dev/null)" ]; then
    token=$(printenv "$tenv"); GLB_TOKEN_SOURCE="env \$$tenv"
  elif [ -n "$(cfg_field "$name" token)" ]; then
    token=$(cfg_field "$name" token); GLB_TOKEN_SOURCE="stored in config"
  elif [ -n "${GITLAB_TOKEN:-}" ]; then
    token="$GITLAB_TOKEN"; GLB_TOKEN_SOURCE="env \$GITLAB_TOKEN"
  else
    token=""; GLB_TOKEN_SOURCE="no token (public only)"
    [ -n "$tenv" ] && GLB_TOKEN_SOURCE="env \$$tenv is EMPTY → no token"
  fi
  use_profile_values "$name" "$url" "${auth:-pat}" "$token" "${verify:-true}" "$ca"
}

# Short display label: "work · gitlab.example.com"
profile_label() {
  local p="$1" u
  if [ "$p" = env ] && ! cfg_exists env; then u="${GITLAB_URL:-${CI_SERVER_URL:-}}"; else u=$(cfg_field "$p" url); fi
  printf '%s %s· %s%s' "$p" "$DIM" "$(url_host "$u")" "$RST"
}
