# 6. Arsitektur & pengembangan

[← Cara kerja](05-cara-kerja.md) · [Troubleshooting →](07-troubleshooting.md)

## Prinsip desain

- **Bash 3.2-compatible**, supaya bisa jalan di macOS tanpa install apa-apa. Artinya gak pakai `declare -A`, `mapfile`, `${var,,}`, `wait -n`, atau `read -t` pecahan.
- **`jq` buat semua urusan JSON**, termasuk aritmatika tanggal (`now - N*86400 | todate`). Dengan begitu gak bergantung ke perbedaan `date` antara GNU dan BSD.
- **UI ke stderr, data ke stdout**, supaya bisa di-pipe.
- **Library kecil yang bisa dipakai ulang** di `lib/`, sedangkan tiap fitur jadi 1 file di `tools/`.
- **Gak ada `set -e` / `set -u`.** Error ditangani eksplisit (`|| return`) karena alur interaktif butuh kontrol penuh. Yang dipakai cuma `set -o pipefail`.

## Struktur file

```
gitlabbox.sh               entry point
├─ source lib/ui.sh
├─ source lib/config.sh
├─ source lib/api.sh
├─ source lib/targets.sh
├─ source lib/setup.sh
└─ source tools/branch-committers.sh
```

Urutan eksekusi `gitlabbox.sh`:

1. Resolve lokasi asli script (aman untuk symlink) → `GLB_ROOT`, `GLB_SELF`.
2. Source semua library dan tool.
3. Kalau argumen pertama `__bc_branch`, jalankan **worker** lalu exit. Langkah setup di bawah dilewati.
4. Cek dependensi (`curl`, `jq`).
5. Bikin folder sementara `GLB_TMP` (700) dan pasang `trap` buat cleanup (EXIT) serta Ctrl+C (INT/TERM).
6. `main "$@"` → dispatch ke menu atau command.

## Referensi library

### `lib/ui.sh`: tampilan

| Fungsi | Kegunaan |
|---|---|
| `ui_banner` | Banner ASCII bergradasi (versi ringkas kalau terminal < 74 kolom) |
| `ui_title "Judul" ["sub"]` | Header bagian |
| `ui_ok` / `ui_err` / `ui_warn` / `ui_info` / `ui_hint` | Pesan bersimbol `✔ ✖ ▲ ℹ` dan teks redup |
| `ui_box "Judul" baris...` | Kotak rounded. Lebarnya otomatis dan mengabaikan kode warna ANSI. |
| `ui_select VAR "Tanya" opsi...` | Menu ↑/↓. Hasilnya **index** (0-based) di `VAR`, return 1 kalau batal. Opsional: `UI_HINTS=(...)` buat keterangan per opsi, `UI_SELECT_DEFAULT=N` buat posisi awal. |
| `ui_confirm "Tanya" [y\|n]` | Ya/Tidak, return 0 kalau Ya |
| `ui_input VAR "Label" [default] [plain\|secret\|path]` | Input teks. `secret` = disembunyikan, `path` = readline + Tab completion. |
| `ui_spin_start "pesan" [file_counter]` / `ui_spin_stop RC "pesan"` | Spinner di background. Kalau `file_counter` diisi, angka di file itu ikut ditampilkan live. |
| `ui_progress DONE TOTAL "label"` / `ui_progress_end` | Progress bar 1 baris |
| `ui_minibar VAL MAX WIDTH` | Bar mini lebar tetap buat tabel |
| `ui_pause`, `ui_clear`, `ui_duration DETIK` | Utilitas |

Warna otomatis mati kalau stderr bukan TTY, `NO_COLOR` ter-set, atau `TERM=dumb`. Menu interaktif butuh stdin **dan** stderr berupa TTY (`UI_TTY=1`).

### `lib/config.sh`: profile

| Fungsi | Kegunaan |
|---|---|
| `cfg_profiles` / `cfg_count` / `cfg_default` / `cfg_exists NAME` / `cfg_field NAME KEY` | Baca config |
| `cfg_save_profile NAME URL KIND AUTH TOKEN TOKEN_ENV VERIFY CA MAKE_DEFAULT` | Simpan profile. Token dioper lewat env ke `jq`, bukan lewat argv. |
| `cfg_delete_profile`, `cfg_set_default` | Ubah config (atomic) |
| `cfg_resolve_name [NAME]` | Profile efektif (argumen → default → satu-satunya → `env`) |
| `cfg_find_by_host HOST` | Cari profile berdasarkan host |
| `use_profile NAME` | Aktifkan profile: set & export `GLB_URL`, `GLB_API`, `GLB_HOST`, `GLB_HDR`, `GLB_INSECURE`, `GLB_CACERT`, … |
| `use_profile_values ...` | Sama, tapi dari nilai langsung (dipakai wizard sebelum disimpan) |
| `normalize_url`, `url_host`, `url_path` | Utilitas URL |

### `lib/api.sh`: HTTP

| Fungsi | Kegunaan |
|---|---|
| `api_get PATH OUT_FILE` | GET `$GLB_API$PATH` → body di `OUT_FILE`, header di `OUT_FILE.hdr`. Return 0 kalau 2xx + JSON valid. Variabel hasil: `API_STATUS`, `API_ERROR`, `API_NEXT_PAGE`. |
| `api_get_all PATH OUT_FILE [MAX] [COUNTER_FILE]` | Ambil semua halaman jadi 1 array JSON. Variabel hasil: `API_COUNT`, `API_TRUNCATED`. |
| `glb_check_connection` | Tes koneksi + box info (dipakai `whoami` & wizard) |
| `_uri STRING` | URL-encode (lewat `jq @uri`) |

### `lib/targets.sh`: input

| Fungsi | Kegunaan |
|---|---|
| `parse_target "baris"` | Set `T_KIND` (`project`/`group`/`account`), `T_HOST`, `T_PATH` |
| `read_targets_file FILE` | Baris valid dari file (tanpa komentar, CRLF aman) |
| `split_targets "a, b c"` | Pecah jadi 1 per baris |

### `lib/setup.sh`: koneksi

`setup_wizard`, `pick_profile "Judul" [include_env]` (hasil di `PICKED_PROFILE`), `profiles_manage`, `profiles_list`.

## Anatomi tool: `tools/branch-committers.sh`

| Bagian | Fungsi |
|---|---|
| Default & opsi | `bc_defaults` → variabel `BC_*` |
| Profile per repo | `bc_prepare_profile`, `bc_bind_profile HOST` |
| Expand input | `bc_expand_targets`, `bc_fetch_projects group\|account ARG OUT`, `_bc_glob_lines` |
| Worker | `bc_worker IDX`, program jq `BC_JQ_BRANCH` |
| Per repo | `bc_scan_repo IDX` |
| Tabel | `_bc_table`, `bc_print_repo_table`, `bc_print_leaderboard` |
| Report | `bc_run` (gabung + tulis), `bc_to_csv`, `_bc_out_paths` |
| UI | `bc_interactive`, `_bc_pick_account`, `bc_view_report`, `reports_browse` |
| CLI | `bc_cli`, `bc_usage` |

## Menambah tool baru

Contohnya tool `stale-branches` buat cari branch yang gak aktif.

**1. Bikin `tools/stale-branches.sh`**

```bash
# shellcheck shell=bash
# tools/stale-branches.sh — cari branch yang commit terakhirnya > N hari.

TOOL_SB_NAME="Stale Branch Finder"

sb_run() { # sb_run PROJECT_PATH DAYS
  local f="$GLB_TMP/sb" cut
  cut=$(jq -nr --argjson d "$2" 'now - ($d * 86400) | todate')
  ui_spin_start "Ngambil branch $1" "$f.count"
  if ! api_get_all "/projects/$(_uri "$1")/repository/branches" "$f.json" 0 "$f.count"; then
    ui_spin_stop 1 "$API_ERROR"; return 1
  fi
  ui_spin_stop 0 "$(jq length "$f.json") branch"
  jq -r --arg cut "$cut" '.[] | select(.commit.committed_date < $cut and (.default | not))
    | "\(.commit.committed_date[:10])  \(.name)"' "$f.json" | sort
}

sb_interactive() {
  local repo days
  ui_title "$TOOL_SB_NAME"
  pick_profile "Koneksi?" include_env || return
  use_profile "$PICKED_PROFILE" || return
  ui_input repo "Repo" ""
  ui_input days "Gak aktif lebih dari (hari)" "90"
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

**2. Daftarkan di `gitlabbox.sh`**

```bash
. "$GLB_ROOT/tools/stale-branches.sh"                 # di blok source

# di interactive_main: tambah hint + opsi + case
"🧹  $TOOL_SB_NAME"
6) sb_interactive; ui_pause ;;

# di main:
stale) shift; sb_cli "$@" ;;
```

**3. Pedoman**

- Prefix semua fungsi dan variabel global dengan singkatan tool (`sb_`, `SB_`) supaya gak bentrok.
- Pakai `api_get_all` buat list endpoint, karena pagination dan retry sudah ditangani di situ.
- Semua output UI lewat fungsi `ui_*` (ke stderr). Data/hasil ke stdout atau file.
- Simpan file sementara di `$GLB_TMP`, karena folder itu otomatis dibersihkan.
- Kalau butuh paralel, ikuti pola worker `__bc_branch`: dispatch di bagian atas `gitlabbox.sh` sebelum setup/trap, dan konteksnya dioper lewat `export`.

## Testing

### Cek syntax

```bash
for f in gitlabbox.sh lib/*.sh tools/*.sh; do /bin/bash -n "$f" && echo "ok $f"; done
shellcheck gitlabbox.sh lib/*.sh tools/*.sh      # kalau shellcheck terpasang
```

Pakai `/bin/bash` (3.2 di macOS) buat memastikan tetap kompatibel.

### Tes non-interaktif ke instance mana pun

```bash
GITLABBOX_HOME=$(mktemp -d) GITLAB_URL=https://gitlab.example.com GITLAB_TOKEN=... \
  ./gitlabbox.sh branches -r team/app -m 50 -o - | jq .summary
```

`GITLABBOX_HOME` sementara memastikan config asli kamu gak tersentuh.

### Mock server

Selama pengembangan, tool ini dites dengan mock GitLab API kecil (HTTP lokal) yang meniru endpoint di tabel [Cara kerja](05-cara-kerja.md#endpoint-api-yang-dipakai): pagination `x-next-page`, `401` tanpa token, `404`, scope `membership/owned/min_access_level`, project archived, dan email dengan huruf besar-kecil berbeda. Arahkan `GITLAB_URL` ke mock tersebut.

Skenario yang perlu dicek:

| Skenario | Yang diharapkan |
|---|---|
| Branch > 100 | Semua halaman terambil |
| Nama branch `release/1.0` | `ref_name` ter-encode, commit terbaca |
| Email beda kapitalisasi | Dihitung 1 orang |
| Repo sama via path & URL | Muncul sekali |
| Repo 404 / host tanpa profile | Tercatat `error`, scan lanjut, exit code 3 |
| `429` + `Retry-After` besar | Gagal cepat dengan pesan rate limit |
| `-m 50` | `truncated: true`, tanda `+` |
| Mode akun tanpa token | Ditolak dengan pesan jelas |

### Tes UI interaktif

Menu bisa dikendalikan otomatis pakai `expect` (bawaan macOS):

```tcl
spawn ./gitlabbox.sh
expect "Mau ngapain bro?";        send "\r"
expect "Repo-nya dari mana?";     send "j"; send "\r"
expect "Scope repo akun lu";      send "\r"
...
```

`j` = ↓, `\r` = Enter. Kasih `sleep 0.2` di antara tombol supaya render sempat selesai.
