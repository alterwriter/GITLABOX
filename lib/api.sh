# shellcheck shell=bash
# lib/api.sh — curl wrapper for the GitLab REST API v4.
#   - auth via a header file (the token never appears in argv / `ps`)
#   - automatic retry on 429 (rate limit, honors Retry-After) and 5xx
#   - pagination follows the x-next-page header
#   - human-friendly error messages (SSL, DNS, 401, 403, 404, ...)
#
# Result variables: API_STATUS, API_ERROR, API_NEXT_PAGE, API_TRUNCATED, API_COUNT

API_STATUS=; API_ERROR=; API_NEXT_PAGE=; API_TRUNCATED=0; API_COUNT=0

_uri() { jq -rn --arg s "$1" '$s | @uri'; }

_api_curl() { # _api_curl URL BODY HEADERS
  local args=(-sS -g --connect-timeout 10 --max-time "${GLB_TIMEOUT:-60}"
    -A "gitlabbox/${GLB_VERSION:-dev}" -H "Accept: application/json")
  [ "${GLB_INSECURE:-0}" = 1 ] && args+=(-k)
  [ -n "${GLB_CACERT:-}" ] && args+=(--cacert "$GLB_CACERT")
  [ -n "${GLB_HDR:-}" ] && args+=(-H "@$GLB_HDR")
  curl "${args[@]}" -D "$3" -o "$2" -w '%{http_code}' "$1"
}

_api_header() { # _api_header FILE NAME → value (last matching header)
  tr -d '\r' <"$1" 2>/dev/null | awk -v k="$2" '
    BEGIN { k = tolower(k) ":" }
    index(tolower($0), k) == 1 { v = substr($0, length(k) + 1); sub(/^[ \t]+/, "", v) }
    END { print v }'
}

_api_curl_hint() { # _api_curl_hint EXIT_CODE
  case "$1" in
    6) printf 'Host not found (DNS). Check the URL — or do you need to turn on a VPN?' ;;
    7) printf 'Connection refused — the server/port is not reachable.' ;;
    28) printf 'Timeout — the server took too long to respond.' ;;
    35 | 51 | 53 | 54 | 58 | 59 | 60 | 66 | 77 | 83 | 90 | 91)
      printf 'SSL/TLS problem (self-signed certificate / internal CA?). Set a CA bundle or skip verification in setup.' ;;
    *) printf 'curl error %s' "$1" ;;
  esac
}

_api_http_hint() { # _api_http_hint CODE HEADERS BODY
  local code="$1" msg loc
  msg=$(jq -r 'if type == "object" then (.message // .error_description // .error // empty) | tostring else empty end' "$3" 2>/dev/null | head -c 200)
  case "$code" in
    401) printf '401 Unauthorized — token is missing / wrong / expired / revoked.' ;;
    403) printf '403 Forbidden — token lacks scope (read_api required) or your role is too low.' ;;
    404) printf '404 Not Found — wrong path, or the project is private and the token has no access.' ;;
    3??)
      loc=$(_api_header "$2" location)
      printf '%s Redirect to %s — check the URL (http vs https / sub-path / SSO).' "$code" "${loc:-?}" ;;
    429) printf '429 Rate limited repeatedly — try lowering --workers.' ;;
    5??) printf '%s Server error from GitLab.' "$code" ;;
    *) printf 'HTTP %s' "$code" ;;
  esac
  [ -n "$msg" ] && printf ' [%s]' "$msg"
  return 0
}

# api_get PATH OUT_BODY → returns 0 on 2xx + valid JSON
api_get() {
  local path="$1" body="$2" hdrs="$2.hdr" errf="$2.err" attempt=0 code rc wait
  API_ERROR=; API_NEXT_PAGE=
  while :; do
    attempt=$((attempt + 1))
    code=$(_api_curl "$GLB_API$path" "$body" "$hdrs" 2>"$errf")
    rc=$?
    API_STATUS="$code"
    if [ "$rc" -ne 0 ]; then
      case "$rc" in
        28 | 52 | 55 | 56) if [ "$attempt" -lt 4 ]; then sleep "$attempt"; continue; fi ;;
      esac
      API_ERROR="$(_api_curl_hint "$rc")"
      return 1
    fi
    case "$code" in
      2??)
        if ! jq -e 'type' "$body" >/dev/null 2>&1; then
          API_ERROR="Response is not JSON — wrong GitLab URL, or blocked by SSO/proxy."
          return 1
        fi
        API_NEXT_PAGE=$(_api_header "$hdrs" x-next-page)
        return 0
        ;;
      429 | 500 | 502 | 503 | 504)
        wait=$(_api_header "$hdrs" retry-after)
        case "$wait" in '' | *[!0-9]*) wait=$((attempt * 2)) ;; esac
        if [ "$code" = 429 ] && [ "$wait" -gt 90 ]; then
          # don't silently wait tens of minutes — just say so
          API_ERROR="429 GitLab rate limit (asked to wait ${wait}s). Use a token (anonymous limits are much lower) or lower --workers."
          return 1
        fi
        if [ "$attempt" -lt 6 ]; then
          sleep "$wait"
          continue
        fi
        ;;
    esac
    API_ERROR="$(_api_http_hint "$code" "$hdrs" "$body")"
    return 1
  done
}

# api_get_all PATH OUT_FILE [MAX_ITEMS] [COUNTER_FILE]
#   merges all pages into one JSON array. MAX_ITEMS=0 → no limit.
#   API_TRUNCATED=1 when it stopped because of MAX_ITEMS while more data exists.
api_get_all() {
  local path="$1" out="$2" max="${3:-0}" cfile="${4:-}" page=1 sep='?' dir="$2.pages" pf n total=0
  case "$path" in *\?*) sep='&' ;; esac
  rm -rf "$dir"; mkdir -p "$dir"
  API_TRUNCATED=0
  while :; do
    pf="$dir/$(printf '%06d' "$page").json"
    api_get "${path}${sep}per_page=100&page=${page}" "$pf" || { rm -rf "$dir"; return 1; }
    n=$(jq 'if type == "array" then length else 0 end' "$pf")
    total=$((total + n))
    [ -n "$cfile" ] && printf '%s' "$total" >"$cfile"
    if [ "$max" -gt 0 ] && [ "$total" -ge "$max" ]; then
      if [ "$total" -gt "$max" ] || [ -n "$API_NEXT_PAGE" ]; then API_TRUNCATED=1; fi
      break
    fi
    if [ -z "$API_NEXT_PAGE" ]; then
      # fallback in case a proxy strips the pagination headers
      if [ "$n" -eq 100 ] && ! grep -qi '^x-next-page:' "$pf.hdr"; then
        page=$((page + 1)); continue
      fi
      break
    fi
    page="$API_NEXT_PAGE"
  done
  jq -s --argjson max "$max" 'map(select(type == "array")) | add // [] | if $max > 0 then .[:$max] else . end' \
    "$dir"/*.json >"$out"
  API_COUNT=$total
  [ "$max" -gt 0 ] && [ "$total" -gt "$max" ] && API_COUNT=$max
  rm -rf "$dir"
  return 0
}

# glb_check_connection → prints connection details, returns 1 on failure
glb_check_connection() {
  local f="$GLB_TMP/check" lines=() ok=0 user ver tinfo scopes exp_days
  if [ -n "$GLB_HDR" ]; then
    ui_spin_start "Testing connection to $GLB_HOST"
    if api_get "/user" "$f.user"; then
      user=$(jq -r '"@\(.username) (\(.name))" + (if .is_admin then " · admin" else "" end)' "$f.user")
      api_get "/version" "$f.ver" && ver=$(jq -r '.version' "$f.ver")
      if api_get "/personal_access_tokens/self" "$f.tok"; then
        tinfo=$(jq -r '"\(.name) · scopes: \(.scopes | join(", ")) · expires: \(.expires_at // "never")"' "$f.tok")
        scopes=$(jq -r '.scopes | join(" ")' "$f.tok")
        exp_days=$(jq -r 'if .expires_at then (((.expires_at + "T00:00:00Z") | fromdateiso8601) - now) / 86400 | floor else 9999 end' "$f.tok")
      fi
      ui_spin_stop 0 "Connected to $GLB_URL"
    else
      ui_spin_stop 1 "Connection failed: $API_ERROR"
      ok=1
    fi
  else
    ui_spin_start "Testing public access to $GLB_HOST"
    if api_get "/projects?per_page=1&visibility=public&simple=true" "$f.pub"; then
      ui_spin_stop 0 "Public API is reachable (no token)"
    else
      ui_spin_stop 1 "Failed: $API_ERROR"
      ok=1
    fi
  fi
  [ "$ok" = 0 ] || return 1

  lines+=("${DIM}Profile ${RST} $GLB_PROFILE")
  lines+=("${DIM}URL     ${RST} $GLB_URL")
  [ -n "${ver:-}" ] && lines+=("${DIM}Version ${RST} GitLab $ver")
  if [ -n "${user:-}" ]; then lines+=("${DIM}User    ${RST} ${CG}$user${RST}"); else lines+=("${DIM}User    ${RST} ${CY}anonymous (public only)${RST}"); fi
  lines+=("${DIM}Token   ${RST} ${GLB_TOKEN_SOURCE:-—}")
  [ -n "${tinfo:-}" ] && lines+=("${DIM}        ${RST} $tinfo")
  [ "$GLB_INSECURE" = 1 ] && lines+=("${DIM}SSL     ${RST} ${CY}verification disabled (insecure)${RST}")
  [ -n "$GLB_CACERT" ] && lines+=("${DIM}SSL     ${RST} CA bundle: $GLB_CACERT")
  ui_box "Connection OK" "${lines[@]}"

  if [ -n "${scopes:-}" ]; then
    case " $scopes " in
      *" api "* | *" read_api "*) ;;
      *) ui_warn "Token has no read_api/api scope — branch & commit endpoints will return 403." ;;
    esac
  fi
  if [ -n "${exp_days:-}" ] && [ "$exp_days" -lt 14 ]; then
    ui_warn "Token expires in $exp_days days."
  fi
  return 0
}
