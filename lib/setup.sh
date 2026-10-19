# shellcheck shell=bash
# lib/setup.sh — GitLab connection wizard + profile management.
#
# Note: the GitLab REST API is stateless — there is no "login/session" like in
# the browser. Every request just carries a token in a header:
#   PRIVATE-TOKEN: <token>        → Personal / Project / Group Access Token
#   Authorization: Bearer <token> → OAuth2 access token
# This tool only reads (scope read_api); it never writes to GitLab.

# Check whether the URL really is a GitLab API: /api/v4/version without a token → 401 (or 200).
_setup_probe() { # _setup_probe URL INSECURE CA → sets PROBE_RC (0 ok, 2 ssl, 1 other) PROBE_MSG
  local GLB_API="$1/api/v4" GLB_INSECURE="$2" GLB_CACERT="$3" GLB_HDR=""
  if api_get "/version" "$GLB_TMP/probe"; then PROBE_RC=0; PROBE_MSG="GitLab API detected"; return; fi
  case "$API_STATUS" in
    401 | 403) PROBE_RC=0; PROBE_MSG="GitLab API detected (token required — expected)"; return ;;
  esac
  case "$API_ERROR" in
    *SSL*) PROBE_RC=2 ;;
    *) PROBE_RC=1 ;;
  esac
  PROBE_MSG="$API_ERROR"
}

_setup_token_url() {
  printf '%s/-/user_settings/personal_access_tokens?name=gitlabbox&scopes=read_api' "$1"
}

setup_wizard() {
  local k url kind auth token="" tenv="" verify=true ca="" name def_name mk=1 host

  ui_title "GitLab connection setup" "The GitLab API has no session/login — all you need is a URL + access token (scope: read_api)."
  ui_nl

  # 1) instance type
  UI_HINTS=("https://gitlab.com — the public SaaS run by GitLab Inc."
    "Your own / your company's GitLab server (Community / Enterprise Edition)"
    "GitLab Dedicated (single-tenant SaaS, e.g. xxx.gitlab-dedicated.com)")
  ui_select k "Where is your GitLab?" "GitLab.com (SaaS)" "Self-hosted (CE / EE)" "GitLab Dedicated" || return 1
  case "$k" in
    0) kind=saas; url="https://gitlab.com" ;;
    1) kind=self-hosted ;;
    2) kind=dedicated ;;
  esac

  # 2) URL + probe
  while [ "$kind" != saas ]; do
    ui_input url "GitLab URL" "" plain
    if [ -z "$url" ]; then ui_warn "URL is required, e.g. https://gitlab.example.com"; continue; fi
    url=$(normalize_url "$url")
    ui_spin_start "Checking $url"
    _setup_probe "$url" 0 ""
    if [ "$PROBE_RC" = 0 ]; then ui_spin_stop 0 "$PROBE_MSG"; break; fi
    ui_spin_stop 1 "$PROBE_MSG"
    if [ "$PROBE_RC" = 2 ]; then
      ui_hint "Your system does not trust the server certificate (common for self-hosted)."
      case "$url" in https://*) ui_hint "Or is the server plain http:// ? If so, choose 'Re-enter URL' and type http:// explicitly." ;; esac
      UI_HINTS=("Configure SSL (custom CA / skip verification) in the next step" "e.g. the server turns out to be http://")
      ui_select k "What now?" "Continue to SSL settings" "Re-enter URL" || return 1
      [ "$k" = 1 ] && continue
      break
    fi
    UI_HINTS=("Maybe a typo, or you're not on the VPN" "Continue anyway — it will be tested again once a token is set")
    ui_select k "What now?" "Re-enter URL" "Continue with this URL" || return 1
    [ "$k" = 1 ] && break
  done
  host=$(url_host "$url")

  # 3) SSL (self-hosted / dedicated, or when the probe hit an SSL error)
  if [ "$kind" != saas ]; then
    UI_SELECT_DEFAULT=0; [ "${PROBE_RC:-0}" = 2 ] && UI_SELECT_DEFAULT=1
    UI_HINTS=("Use the system CA store (safest)"
      "Your company's internal CA .pem file, e.g. ~/certs/corp-ca.pem"
      "Disable certificate checks — only for lab/internal servers you trust")
    ui_select k "SSL verification" "Normal (recommended)" "Use a custom CA bundle" "Skip verification (insecure)" || return 1
    case "$k" in
      1)
        ui_hint "Leave empty + Enter to go back to normal verification."
        while :; do
          ui_input ca "CA bundle path (.pem/.crt)" "" path
          if [ -z "$ca" ]; then k=0; break; fi
          [ -f "$ca" ] && break
          ui_warn "File '$ca' not found."
        done
        ;;
      2) verify=false ;;
    esac
    if [ "$k" != 0 ]; then
      local ins=0; [ "$verify" = false ] && ins=1
      ui_spin_start "Re-checking $url"
      _setup_probe "$url" "$ins" "$ca"
      ui_spin_stop "$PROBE_RC" "$PROBE_MSG"
    fi
  fi

  # 4) auth
  ui_nl
  UI_HINTS=("Most common. Create one under Settings → Access Tokens, scope: read_api"
    "Bot token per project/group. Scope read_api, role Reporter or higher"
    "OAuth2 app token (sent as Authorization: Bearer)"
    "Token is not stored on disk — read from an env var on every run"
    "Can only read public projects, stricter rate limits")
  ui_select k "Authentication method" "Personal Access Token (PAT)" "Project / Group Access Token" \
    "OAuth2 access token" "Read from an environment variable" "No token (public repos only)" || return 1
  auth=pat
  case "$k" in
    0 | 1)
      [ "$k" = 0 ] && ui_hint "Create a token: $(_setup_token_url "$url")"
      [ "$k" = 0 ] && ui_hint "(GitLab < 16: $url/-/profile/personal_access_tokens)"
      ui_input token "Token" "" secret
      ;;
    2) auth=oauth; ui_input token "OAuth access token" "" secret ;;
    3)
      UI_HINTS=("PRIVATE-TOKEN header (PAT / project / group token)" "Authorization: Bearer header")
      ui_select k "Token type in the env var" "Access token (PAT/project/group)" "OAuth2 token" || return 1
      [ "$k" = 1 ] && auth=oauth
      ui_input tenv "Env var name" "GITLAB_TOKEN"
      if [ -z "$(printenv "$tenv" 2>/dev/null)" ]; then
        ui_warn "\$$tenv is currently empty in this shell. Set it first: export $tenv=glpat-xxxx"
      fi
      ;;
    4) auth=none ;;
  esac

  # 5) connection test
  ui_nl
  local ins=0 t="$token"
  [ "$verify" = false ] && ins=1
  [ -n "$tenv" ] && t=$(printenv "$tenv" 2>/dev/null)
  GLB_TOKEN_SOURCE="just entered"; [ -n "$tenv" ] && GLB_TOKEN_SOURCE="env \$$tenv"
  [ -z "$t" ] && GLB_TOKEN_SOURCE="no token"
  use_profile_values "draft" "$url" "$auth" "$t" "$verify" "$ca"
  if ! glb_check_connection; then
    UI_HINTS=("Save it now, fix it later via Manage profiles" "Nothing is saved")
    ui_select k "Connection failed. Save anyway?" "Save anyway" "Cancel" || return 1
    [ "$k" = 1 ] && return 1
  fi

  # 6) profile name
  ui_nl
  def_name=$(printf '%s' "$host" | sed 's/^gitlab\.//; s/\..*$//')
  [ "$kind" = saas ] && def_name="gitlab-com"
  case "$host" in *[!0-9.]*) ;; *) def_name="self-hosted" ;; esac
  [ -z "$def_name" ] && def_name="gitlab"
  while :; do
    ui_input name "Profile name" "$def_name"
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '-')
    if cfg_exists "$name"; then
      ui_confirm "Profile '$name' already exists. Overwrite?" n || continue
    fi
    break
  done
  if [ "$(cfg_count)" -gt 0 ] && [ "$(cfg_default)" != "$name" ]; then
    mk=0
    ui_confirm "Make this the default profile?" y && mk=1
  fi

  [ "$auth" = none ] && auth=pat
  cfg_save_profile "$name" "$url" "$kind" "$auth" "$token" "$tenv" "$verify" "$ca" "$mk"
  ui_ok "Profile ${B}$name${RST} saved to ${DIM}$GLB_CONFIG${RST} (chmod 600)"
  [ -n "$token" ] && ui_hint "The token is stored in plain text in that file (readable only by your user). Want it safer? Use the env var option."
  return 0
}

# Choose a profile from a menu. Result in PICKED_PROFILE.
pick_profile() { # pick_profile "Title" [include_env]
  local names=() labels=() p i=0 k def
  def=$(cfg_default)
  for p in $(cfg_profiles); do
    names+=("$p")
    if [ "$p" = "$def" ]; then
      labels+=("$(profile_label "$p") ${CG}● default${RST}"); UI_SELECT_DEFAULT=$i
    else
      labels+=("$(profile_label "$p")")
    fi
    i=$((i + 1))
  done
  if [ "${2:-}" = include_env ] && [ -n "${GITLAB_URL:-}${CI_SERVER_URL:-}" ] && ! cfg_exists env; then
    names+=(env); labels+=("$(profile_label env) ${DIM}(from env vars)${RST}")
  fi
  if [ "${#names[@]}" -eq 0 ]; then PICKED_PROFILE=""; return 1; fi
  if [ "${#names[@]}" -eq 1 ]; then PICKED_PROFILE="${names[0]}"; UI_SELECT_DEFAULT=0; return 0; fi
  ui_select k "${1:-Choose a profile}" "${labels[@]}" || return 1
  PICKED_PROFILE="${names[$k]}"
}

profiles_manage() {
  local k tok
  while :; do
    ui_title "Manage profiles" "Config: $GLB_CONFIG"
    if [ "$(cfg_count)" = 0 ]; then
      ui_warn "No profiles yet."
      ui_confirm "Create one now?" y && setup_wizard
      return
    fi
    profiles_list
    ui_nl
    UI_SELECT_DEFAULT=0
    pick_profile "Which profile?" || return
    local p="$PICKED_PROFILE"
    UI_HINTS=("Check token, user, GitLab version" "Used when no profile is chosen" "Paste a new token (e.g. the old one expired)" "Permanently remove from config" "")
    ui_select k "Action for '$p'" "Test connection" "Make default" "Change token" "Delete profile" "← Back" || return
    case "$k" in
      0) use_profile "$p" && glb_check_connection; ui_pause ;;
      1) cfg_set_default "$p"; ui_ok "Default is now: $p" ;;
      2)
        ui_input tok "New token" "" secret
        if [ -n "$tok" ]; then
          GLB_NEW_TOKEN="$tok" cfg_write '.profiles[$n].token = $ENV.GLB_NEW_TOKEN | .profiles[$n].token_env = ""' --arg n "$p"
          ui_ok "Token updated."
          use_profile "$p" && glb_check_connection
          ui_pause
        fi
        ;;
      3) ui_confirm "Really delete '$p'?" n && cfg_delete_profile "$p" && ui_ok "Profile '$p' deleted." ;;
      4) return ;;
    esac
  done
}

profiles_list() {
  local p def u tenv tok ssl
  def=$(cfg_default)
  if [ "$(cfg_count)" = 0 ]; then ui_warn "No profiles yet. Run: ./gitlabbox.sh setup"; return; fi
  printf '\n  %s%-2s %-16s %-36s %-12s %-16s %s%s\n' "$DIM" "" "PROFILE" "URL" "TYPE" "TOKEN" "SSL" "$RST" >&2
  for p in $(cfg_profiles); do
    u=$(cfg_field "$p" url); tenv=$(cfg_field "$p" token_env); tok=$(cfg_field "$p" token)
    if [ -n "$tenv" ]; then tok="env \$$tenv"; elif [ -n "$tok" ]; then tok="stored"; else tok="—"; fi
    ssl="verify"; [ "$(cfg_field "$p" verify_ssl)" = false ] && ssl="${CY}insecure${RST}"
    [ -n "$(cfg_field "$p" ca_bundle)" ] && ssl="custom CA"
    printf '  %s%s%s %-16s %-36s %-12s %-16s %s\n' "$CG" "$([ "$p" = "$def" ] && printf '● ' || printf '  ')" "$RST" \
      "$p" "${u:0:36}" "$(cfg_field "$p" kind)" "$tok" "$ssl" >&2
  done
}
