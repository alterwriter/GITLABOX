# shellcheck shell=bash
# lib/setup.sh — wizard koneksi GitLab + kelola profile.
#
# Catatan: GitLab REST API itu stateless — gak ada "login/session" kayak di
# browser. Tiap request cukup bawa token di header:
#   PRIVATE-TOKEN: <token>        → Personal / Project / Group Access Token
#   Authorization: Bearer <token> → OAuth2 access token
# Tool ini cuma butuh baca (scope read_api), gak pernah nulis ke GitLab.

# Cek apakah URL beneran GitLab API: /api/v4/version tanpa token → 401 (atau 200).
_setup_probe() { # _setup_probe URL INSECURE CA → set PROBE_RC (0 ok, 2 ssl, 1 lain) PROBE_MSG
  local GLB_API="$1/api/v4" GLB_INSECURE="$2" GLB_CACERT="$3" GLB_HDR=""
  if api_get "/version" "$GLB_TMP/probe"; then PROBE_RC=0; PROBE_MSG="API GitLab kedetect"; return; fi
  case "$API_STATUS" in
    401 | 403) PROBE_RC=0; PROBE_MSG="API GitLab kedetect (butuh token — normal)"; return ;;
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

  ui_title "Setup koneksi GitLab" "API GitLab gak pakai session/login — cukup URL + access token (scope: read_api)."
  ui_nl

  # 1) jenis instance
  UI_HINTS=("https://gitlab.com — SaaS publik punya GitLab Inc."
    "Server GitLab sendiri / kantor (Community / Enterprise Edition)"
    "GitLab Dedicated (single-tenant SaaS, misal xxx.gitlab-dedicated.com)")
  ui_select k "GitLab-nya di mana?" "GitLab.com (SaaS)" "Self-hosted (CE / EE)" "GitLab Dedicated" || return 1
  case "$k" in
    0) kind=saas; url="https://gitlab.com" ;;
    1) kind=self-hosted ;;
    2) kind=dedicated ;;
  esac

  # 2) URL + probe
  while [ "$kind" != saas ]; do
    ui_input url "URL GitLab" "" plain
    if [ -z "$url" ]; then ui_warn "URL wajib diisi, contoh: https://gitlab.example.com"; continue; fi
    url=$(normalize_url "$url")
    ui_spin_start "Ngecek $url"
    _setup_probe "$url" 0 ""
    if [ "$PROBE_RC" = 0 ]; then ui_spin_stop 0 "$PROBE_MSG"; break; fi
    ui_spin_stop 1 "$PROBE_MSG"
    if [ "$PROBE_RC" = 2 ]; then
      ui_hint "Sertifikat server gak dipercaya sama sistem lu (umum di self-hosted)."
      case "$url" in https://*) ui_hint "Atau server-nya cuma http:// ? Kalau iya, pilih 'Ketik ulang URL' & tulis http:// eksplisit." ;; esac
      UI_HINTS=("Lanjut atur SSL (CA custom / skip verify) di langkah berikut" "Misal ternyata server-nya http://")
      ui_select k "Mau gimana?" "Lanjut ke setting SSL" "Ketik ulang URL" || return 1
      [ "$k" = 1 ] && continue
      break
    fi
    UI_HINTS=("Mungkin typo, atau lagi gak konek VPN" "Lanjut aja, nanti dites lagi pas udah ada token")
    ui_select k "Mau gimana?" "Ketik ulang URL" "Lanjut pakai URL ini" || return 1
    [ "$k" = 1 ] && break
  done
  host=$(url_host "$url")

  # 3) SSL (self-hosted / dedicated, atau kalau probe-nya error SSL)
  if [ "$kind" != saas ]; then
    UI_SELECT_DEFAULT=0; [ "${PROBE_RC:-0}" = 2 ] && UI_SELECT_DEFAULT=1
    UI_HINTS=("Pakai CA bawaan sistem (paling aman)"
      "File .pem CA internal kantor, misal ~/certs/corp-ca.pem"
      "Matikan cek sertifikat — cuma buat lab/internal yang lu percaya")
    ui_select k "Verifikasi SSL" "Normal (rekomendasi)" "Pakai CA bundle custom" "Skip verifikasi (insecure)" || return 1
    case "$k" in
      1)
        ui_hint "Kosongin + Enter buat balik ke verifikasi normal."
        while :; do
          ui_input ca "Path CA bundle (.pem/.crt)" "" path
          if [ -z "$ca" ]; then k=0; break; fi
          [ -f "$ca" ] && break
          ui_warn "File '$ca' gak ketemu."
        done
        ;;
      2) verify=false ;;
    esac
    if [ "$k" != 0 ]; then
      local ins=0; [ "$verify" = false ] && ins=1
      ui_spin_start "Ngecek ulang $url"
      _setup_probe "$url" "$ins" "$ca"
      ui_spin_stop "$PROBE_RC" "$PROBE_MSG"
    fi
  fi

  # 4) auth
  ui_nl
  UI_HINTS=("Paling umum. Bikin di Settings → Access Tokens, scope: read_api"
    "Token bot per project/group. Scope read_api, role minimal Reporter"
    "Token OAuth2 app (dikirim sebagai Authorization: Bearer)"
    "Token gak disimpan di disk — dibaca dari env var tiap kali jalan"
    "Cuma bisa baca project public, rate limit lebih ketat")
  ui_select k "Cara autentikasi" "Personal Access Token (PAT)" "Project / Group Access Token" \
    "OAuth2 access token" "Ambil dari environment variable" "Tanpa token (public repo aja)" || return 1
  auth=pat
  case "$k" in
    0 | 1)
      [ "$k" = 0 ] && ui_hint "Bikin token: $(_setup_token_url "$url")"
      [ "$k" = 0 ] && ui_hint "(GitLab lama < 16: $url/-/profile/personal_access_tokens)"
      ui_input token "Token" "" secret
      ;;
    2) auth=oauth; ui_input token "OAuth access token" "" secret ;;
    3)
      UI_HINTS=("Header PRIVATE-TOKEN (PAT / project / group token)" "Header Authorization: Bearer")
      ui_select k "Jenis token di env var" "Access token (PAT/project/group)" "OAuth2 token" || return 1
      [ "$k" = 1 ] && auth=oauth
      ui_input tenv "Nama env var" "GITLAB_TOKEN"
      if [ -z "$(printenv "$tenv" 2>/dev/null)" ]; then
        ui_warn "\$$tenv lagi kosong di shell ini. Set dulu: export $tenv=glpat-xxxx"
      fi
      ;;
    4) auth=none ;;
  esac

  # 5) tes koneksi
  ui_nl
  local ins=0 t="$token"
  [ "$verify" = false ] && ins=1
  [ -n "$tenv" ] && t=$(printenv "$tenv" 2>/dev/null)
  GLB_TOKEN_SOURCE="input barusan"; [ -n "$tenv" ] && GLB_TOKEN_SOURCE="env \$$tenv"
  [ -z "$t" ] && GLB_TOKEN_SOURCE="tanpa token"
  use_profile_values "draft" "$url" "$auth" "$t" "$verify" "$ca"
  if ! glb_check_connection; then
    UI_HINTS=("Simpan dulu, benerin belakangan via Kelola profile" "Gak disimpan apa-apa")
    ui_select k "Koneksi gagal. Tetep simpan?" "Simpan aja" "Batal" || return 1
    [ "$k" = 1 ] && return 1
  fi

  # 6) nama profile
  ui_nl
  def_name=$(printf '%s' "$host" | sed 's/^gitlab\.//; s/\..*$//')
  [ "$kind" = saas ] && def_name="gitlab-com"
  case "$host" in *[!0-9.]*) ;; *) def_name="self-hosted" ;; esac
  [ -z "$def_name" ] && def_name="gitlab"
  while :; do
    ui_input name "Nama profile" "$def_name"
    name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '-')
    if cfg_exists "$name"; then
      ui_confirm "Profile '$name' udah ada. Timpa?" n || continue
    fi
    break
  done
  if [ "$(cfg_count)" -gt 0 ] && [ "$(cfg_default)" != "$name" ]; then
    mk=0
    ui_confirm "Jadiin profile default?" y && mk=1
  fi

  [ "$auth" = none ] && auth=pat
  cfg_save_profile "$name" "$url" "$kind" "$auth" "$token" "$tenv" "$verify" "$ca" "$mk"
  ui_ok "Profile ${B}$name${RST} tersimpan di ${DIM}$GLB_CONFIG${RST} (chmod 600)"
  [ -n "$token" ] && ui_hint "Token disimpan plain-text di file itu (hanya bisa dibaca user lu). Mau lebih aman? pakai opsi env var."
  return 0
}

# Pilih profile lewat menu. Hasil di variabel PICKED_PROFILE.
pick_profile() { # pick_profile "Judul" [include_env]
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
    names+=(env); labels+=("$(profile_label env) ${DIM}(dari env var)${RST}")
  fi
  if [ "${#names[@]}" -eq 0 ]; then PICKED_PROFILE=""; return 1; fi
  if [ "${#names[@]}" -eq 1 ]; then PICKED_PROFILE="${names[0]}"; UI_SELECT_DEFAULT=0; return 0; fi
  ui_select k "${1:-Pilih profile}" "${labels[@]}" || return 1
  PICKED_PROFILE="${names[$k]}"
}

profiles_manage() {
  local k tok
  while :; do
    ui_title "Kelola profile" "Config: $GLB_CONFIG"
    if [ "$(cfg_count)" = 0 ]; then
      ui_warn "Belum ada profile."
      ui_confirm "Bikin sekarang?" y && setup_wizard
      return
    fi
    profiles_list
    ui_nl
    UI_SELECT_DEFAULT=0
    pick_profile "Profile yang mau dikelola" || return
    local p="$PICKED_PROFILE"
    UI_HINTS=("Cek token, user, versi GitLab" "Profile ini dipakai kalau gak milih" "Paste token baru (misal yang lama expire)" "Hapus permanen dari config" "")
    ui_select k "Aksi buat '$p'" "Tes koneksi" "Jadiin default" "Ganti token" "Hapus profile" "← Balik" || return
    case "$k" in
      0) use_profile "$p" && glb_check_connection; ui_pause ;;
      1) cfg_set_default "$p"; ui_ok "Default sekarang: $p" ;;
      2)
        ui_input tok "Token baru" "" secret
        if [ -n "$tok" ]; then
          GLB_NEW_TOKEN="$tok" cfg_write '.profiles[$n].token = $ENV.GLB_NEW_TOKEN | .profiles[$n].token_env = ""' --arg n "$p"
          ui_ok "Token diupdate."
          use_profile "$p" && glb_check_connection
          ui_pause
        fi
        ;;
      3) ui_confirm "Yakin hapus '$p'?" n && cfg_delete_profile "$p" && ui_ok "Profile '$p' dihapus." ;;
      4) return ;;
    esac
  done
}

profiles_list() {
  local p def u tenv tok ssl
  def=$(cfg_default)
  if [ "$(cfg_count)" = 0 ]; then ui_warn "Belum ada profile. Jalanin: ./gitlabbox.sh setup"; return; fi
  printf '\n  %s%-2s %-16s %-36s %-12s %-16s %s%s\n' "$DIM" "" "PROFILE" "URL" "JENIS" "TOKEN" "SSL" "$RST" >&2
  for p in $(cfg_profiles); do
    u=$(cfg_field "$p" url); tenv=$(cfg_field "$p" token_env); tok=$(cfg_field "$p" token)
    if [ -n "$tenv" ]; then tok="env \$$tenv"; elif [ -n "$tok" ]; then tok="tersimpan"; else tok="—"; fi
    ssl="verify"; [ "$(cfg_field "$p" verify_ssl)" = false ] && ssl="${CY}insecure${RST}"
    [ -n "$(cfg_field "$p" ca_bundle)" ] && ssl="custom CA"
    printf '  %s%s%s %-16s %-36s %-12s %-16s %s\n' "$CG" "$([ "$p" = "$def" ] && printf '● ' || printf '  ')" "$RST" \
      "$p" "${u:0:36}" "$(cfg_field "$p" kind)" "$tok" "$ssl" >&2
  done
}
