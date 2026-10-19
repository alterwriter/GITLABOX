# shellcheck shell=bash
# lib/ui.sh — warna, banner, menu panah, input, spinner, progress bar, box.
# Semua output UI ke stderr, jadi stdout bisa dipakai buat pipe (misal -o -).
# Kompatibel bash 3.2 (bawaan macOS).

UI_TTY=0
[ -t 0 ] && [ -t 2 ] && UI_TTY=1

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
  RST=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
  C1=$'\033[38;5;202m'   # merah-oranye
  C2=$'\033[38;5;208m'   # oranye GitLab
  C3=$'\033[38;5;214m'   # kuning-oranye
  CP=$'\033[38;5;135m'   # ungu
  CG=$'\033[38;5;42m'    # hijau
  CR=$'\033[38;5;203m'   # merah
  CY=$'\033[38;5;221m'   # kuning
  CC=$'\033[38;5;81m'    # cyan
else
  RST=; B=; DIM=; C1=; C2=; C3=; CP=; CG=; CR=; CY=; CC=
fi

UI_ESC=$'\033'
UI_SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
UI_SPIN_PID=
UI_HINTS=()
UI_SELECT_DEFAULT=0

cursor_hide() { [ "$UI_TTY" = 1 ] && printf '\033[?25l' >&2; return 0; }
cursor_show() { [ "$UI_TTY" = 1 ] && printf '\033[?25h' >&2; return 0; }
ui_clear()    { [ "$UI_TTY" = 1 ] && printf '\033[H\033[2J\033[3J' >&2; return 0; }

ui_info()  { printf '  %sℹ%s %s\n' "$CC" "$RST" "$*" >&2; }
ui_ok()    { printf '  %s✔%s %s\n' "$CG" "$RST" "$*" >&2; }
ui_warn()  { printf '  %s▲%s %s\n' "$CY" "$RST" "$*" >&2; }
ui_err()   { printf '  %s✖%s %s\n' "$CR" "$RST" "$*" >&2; }
ui_hint()  { printf '    %s%s%s\n' "$DIM" "$*" "$RST" >&2; }
ui_nl()    { printf '\n' >&2; }

ui_title() {
  printf '\n  %s▌%s %s%s%s\n' "$C2" "$RST" "$B" "$1" "$RST" >&2
  [ -n "${2:-}" ] && ui_hint "$2"
  return 0
}

# Panjang teks yang keliatan (tanpa kode warna ANSI).
ui_vlen() {
  local s
  s=$(printf '%s' "$1" | sed "s/${UI_ESC}\[[0-9;]*m//g")
  printf '%s' "${#s}"
}

ui_repeat() { # ui_repeat CHAR N
  local i out=""
  for ((i = 0; i < $2; i++)); do out="$out$1"; done
  printf '%s' "$out"
}

ui_banner() {
  local cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
  if [ "$cols" -lt 74 ]; then
    printf '\n  %s%s▟▙ GITLABBOX%s %sv%s%s\n' "$C2" "$B" "$RST" "$DIM" "$GLB_VERSION" "$RST" >&2
    return
  fi
  printf '\n' >&2
  printf '  %s%s%s\n' "$C1" ' ██████╗ ██╗████████╗██╗      █████╗ ██████╗ ██████╗  ██████╗ ██╗  ██╗' "$RST" >&2
  printf '  %s%s%s\n' "$C1" '██╔════╝ ██║╚══██╔══╝██║     ██╔══██╗██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝' "$RST" >&2
  printf '  %s%s%s\n' "$C2" '██║  ███╗██║   ██║   ██║     ███████║██████╔╝██████╔╝██║   ██║ ╚███╔╝' "$RST" >&2
  printf '  %s%s%s\n' "$C2" '██║   ██║██║   ██║   ██║     ██╔══██║██╔══██╗██╔══██╗██║   ██║ ██╔██╗' "$RST" >&2
  printf '  %s%s%s\n' "$C3" '╚██████╔╝██║   ██║   ███████╗██║  ██║██████╔╝██████╔╝╚██████╔╝██╔╝ ██╗' "$RST" >&2
  printf '  %s%s%s\n' "$C3" ' ╚═════╝ ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝' "$RST" >&2
  printf '  %sGitLab toolbox · v%s · gitlab.com & self-hosted%s\n' "$DIM" "$GLB_VERSION" "$RST" >&2
}

# ui_box "Judul" "baris 1" "baris 2" ...
ui_box() {
  local title="$1" w=0 l n line
  shift
  for line in "$@"; do
    l=$(ui_vlen "$line"); [ "$l" -gt "$w" ] && w=$l
  done
  l=$(ui_vlen "$title"); [ $((l + 4)) -gt "$w" ] && w=$((l + 4))
  printf '  %s╭─%s %s%s%s %s%s╮%s\n' "$DIM" "$RST" "$B" "$title" "$RST" "$DIM" \
    "$(ui_repeat ─ $((w - l - 1)))" "$RST" >&2
  for line in "$@"; do
    n=$(ui_vlen "$line")
    printf '  %s│%s %s%*s %s│%s\n' "$DIM" "$RST" "$line" $((w - n)) "" "$DIM" "$RST" >&2
  done
  printf '  %s╰%s╯%s\n' "$DIM" "$(ui_repeat ─ $((w + 2)))" "$RST" >&2
}

# ui_select VAR "Pertanyaan" "opsi 1" "opsi 2" ...
#   - navigasi ↑/↓ (atau j/k), Enter buat pilih, q/Esc buat batal
#   - UI_HINTS=(...) opsional: keterangan per opsi, muncul di bawah menu
#   - UI_SELECT_DEFAULT=N opsional: posisi kursor awal
#   - hasil: index opsi (0-based) di VAR; return 1 kalau batal
ui_select() {
  local __var="$1" title="$2"
  shift 2
  local opts=("$@") n=$# sel=${UI_SELECT_DEFAULT:-0} key rest i hl=0
  local hints=("${UI_HINTS[@]}")
  UI_HINTS=(); UI_SELECT_DEFAULT=0
  [ "${#hints[@]}" -gt 0 ] && hl=1
  [ "$sel" -ge "$n" ] && sel=0

  if [ "$UI_TTY" != 1 ]; then
    ui_err "Menu interaktif butuh terminal (TTY). Pakai mode flag, cek: gitlabbox.sh --help"
    return 1
  fi

  printf '  %s?%s %s%s%s %s(↑/↓ · Enter · q batal)%s\n' "$C2" "$RST" "$B" "$title" "$RST" "$DIM" "$RST" >&2
  cursor_hide
  while :; do
    for ((i = 0; i < n; i++)); do
      if [ "$i" -eq "$sel" ]; then
        printf '\r\033[2K  %s%s❯ %s%s\n' "$C2" "$B" "${opts[$i]}" "$RST" >&2
      else
        printf '\r\033[2K    %s\n' "${opts[$i]}" >&2
      fi
    done
    [ "$hl" = 1 ] && printf '\r\033[2K    %s↳ %s%s\n' "$DIM" "${hints[$sel]:-}" "$RST" >&2

    IFS= read -rsn1 key
    if [ "$key" = "$UI_ESC" ]; then
      IFS= read -rsn2 -t 1 rest
      key="$key$rest"
    fi
    case "$key" in
      "$UI_ESC[A" | "$UI_ESC"OA | k | w) sel=$(((sel - 1 + n) % n)) ;;
      "$UI_ESC[B" | "$UI_ESC"OB | j | s) sel=$(((sel + 1) % n)) ;;
      [1-9]) [ "$key" -le "$n" ] && sel=$((key - 1)) ;;
      "") break ;;
      q | Q | "$UI_ESC")
        printf '\033[%dA\r\033[J' $((n + hl + 1)) >&2
        printf '  %s✖ %s%s\n' "$DIM" "$title" "$RST" >&2
        cursor_show
        return 1
        ;;
    esac
    printf '\033[%dA' $((n + hl)) >&2
  done
  # ringkas jadi 1 baris: "✔ Pertanyaan › pilihan"
  printf '\033[%dA\r\033[J' $((n + hl + 1)) >&2
  printf '  %s✔%s %s %s›%s %s%s%s\n' "$CG" "$RST" "$title" "$DIM" "$RST" "$CC" \
    "$(printf '%s' "${opts[$sel]}" | sed "s/${UI_ESC}\[[0-9;]*m//g")" "$RST" >&2
  cursor_show
  printf -v "$__var" '%s' "$sel"
}

# ui_confirm "Pertanyaan" [y|n]  → return 0 kalau Ya
ui_confirm() {
  local c
  [ "${2:-y}" = n ] && UI_SELECT_DEFAULT=1
  ui_select c "$1" "Ya" "Tidak" || return 1
  [ "$c" = 0 ]
}

# ui_input VAR "Label" [default] [plain|secret|path]
ui_input() {
  local __var="$1" label="$2" def="${3:-}" mode="${4:-plain}" val disp shown=""
  [ -n "$def" ] && shown=" $DIM($def)$RST"
  printf '  %s?%s %s%s%s%s %s›%s ' "$C2" "$RST" "$B" "$label" "$RST" "$shown" "$DIM" "$RST" >&2
  case "$mode" in
    secret) IFS= read -rs val; printf '\n' >&2 ;;
    path) IFS= read -re val ;;
    *) IFS= read -r val ;;
  esac
  val="${val#"${val%%[![:space:]]*}"}"   # trim kiri
  val="${val%"${val##*[![:space:]]}"}"   # trim kanan
  [ -z "$val" ] && val="$def"
  case "$val" in "~/"*) val="$HOME/${val#\~/}" ;; esac
  disp="$val"
  if [ "$mode" = secret ] && [ -n "$val" ]; then
    disp="${val:0:6}$(ui_repeat • 10) ${DIM}(${#val} karakter)${RST}"
  fi
  [ "$UI_TTY" = 1 ] && printf '\033[1A\r\033[2K' >&2
  printf '  %s✔%s %s %s›%s %s%s%s\n' "$CG" "$RST" "$label" "$DIM" "$RST" "$CC" "${disp:-—}" "$RST" >&2
  printf -v "$__var" '%s' "$val"
}

ui_pause() {
  [ "$UI_TTY" = 1 ] || return 0
  printf '\n  %s%s%s' "$DIM" "${1:-Tekan Enter buat lanjut…}" "$RST" >&2
  IFS= read -rs _
  printf '\n' >&2
}

# ---------- spinner ----------
# ui_spin_start "pesan" [file_counter]  → jalan di background
# ui_spin_stop RC "pesan akhir"
ui_spin_start() {
  UI_SPIN_MSG="$1"
  local cfile="${2:-}"
  if [ "$UI_TTY" != 1 ]; then
    printf '  … %s\n' "$1" >&2
    return 0
  fi
  cursor_hide
  (
    trap 'exit 0' TERM
    i=0; t0=$SECONDS
    while :; do
      extra=""
      if [ -n "$cfile" ] && [ -s "$cfile" ]; then extra=" $C3$(cat "$cfile" 2>/dev/null)$RST"; fi
      printf '\r\033[2K  %s%s%s %s%s %s%ss%s' "$C2" "${UI_SPIN_FRAMES[$i]}" "$RST" \
        "$UI_SPIN_MSG" "$extra" "$DIM" $((SECONDS - t0)) "$RST" >&2
      i=$(((i + 1) % 10))
      sleep 0.08
    done
  ) &
  UI_SPIN_PID=$!
}

ui_spin_kill() {
  if [ -n "$UI_SPIN_PID" ]; then
    kill "$UI_SPIN_PID" 2>/dev/null
    wait "$UI_SPIN_PID" 2>/dev/null
    UI_SPIN_PID=
    printf '\r\033[2K' >&2
  fi
}

ui_spin_stop() {
  local rc="$1" msg="${2:-$UI_SPIN_MSG}"
  ui_spin_kill
  cursor_show
  if [ "$rc" = 0 ]; then ui_ok "$msg"; else ui_err "$msg"; fi
}

# ---------- progress bar ----------
UI_PROG_I=0
ui_progress() { # ui_progress DONE TOTAL "label"
  [ "$UI_TTY" = 1 ] || return 0
  local d=$1 t=$2 label=$3 w=30 f pct
  [ "$t" -gt 0 ] || t=1
  f=$((d * w / t)); pct=$((d * 100 / t))
  UI_PROG_I=$(((UI_PROG_I + 1) % 10))
  printf '\r\033[2K  %s%s%s %s%s%s%s%s %3d%% %s%d/%d%s %s' \
    "$C2" "${UI_SPIN_FRAMES[$UI_PROG_I]}" "$RST" \
    "$C2" "$(ui_repeat █ "$f")" "$DIM" "$(ui_repeat ░ $((w - f)))" "$RST" \
    "$pct" "$DIM" "$d" "$t" "$RST" "$label" >&2
}

ui_progress_end() { [ "$UI_TTY" = 1 ] && printf '\r\033[2K' >&2; return 0; }

# Mini bar buat tabel (lebar tetap, aman buat alignment).
ui_minibar() { # ui_minibar VALUE MAX WIDTH
  local v=$1 m=$2 w=$3 f
  [ "$m" -gt 0 ] || m=1
  f=$((v * w / m)); [ "$v" -gt 0 ] && [ "$f" -eq 0 ] && f=1
  printf '%s%s%s%s%s' "$C2" "$(ui_repeat █ "$f")" "$DIM" "$(ui_repeat ░ $((w - f)))" "$RST"
}

ui_duration() { # detik → "1m 12s"
  local s=$1
  if [ "$s" -ge 60 ]; then printf '%dm %ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}
