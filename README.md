# GITLABBOX

Toolbox CLI interaktif untuk GitLab, ditulis full **Bash**. Jalan di **GitLab.com (SaaS)**, **GitLab self-hosted (CE/EE)**, dan **GitLab Dedicated**.

Tool pertama di dalamnya: **Branch & Committer Report**. Tool ini ngelist semua branch di satu atau banyak repo, ngitung **jumlah committer unik per branch**, ngurutin dari yang paling ramai ke paling sepi, terus ngekspor hasilnya ke **JSON** atau **CSV**.

```
   ██████╗ ██╗████████╗██╗      █████╗ ██████╗ ██████╗  ██████╗ ██╗  ██╗
  ██╔════╝ ██║╚══██╔══╝██║     ██╔══██╗██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝
  ██║  ███╗██║   ██║   ██║     ███████║██████╔╝██████╔╝██║   ██║ ╚███╔╝
  ██║   ██║██║   ██║   ██║     ██╔══██║██╔══██╗██╔══██╗██║   ██║ ██╔██╗
  ╚██████╔╝██║   ██║   ███████╗██║  ██║██████╔╝██████╔╝╚██████╔╝██╔╝ ██╗
   ╚═════╝ ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝

  ● koneksi: kantor · gitlab.example.com  (2 profile)

  ? Mau ngapain bro? (↑/↓ · Enter · q batal)
  ❯ 🌿  Branch & Committer Report
    📊  Lihat report tersimpan
    🔌  Setup koneksi GitLab
    🗂   Kelola profile
    👤  Cek koneksi (whoami)
    🚪  Keluar
    ↳ List branch + jumlah committer per repo (single / semua repo akun lu / .txt / group) → JSON/CSV
```

## Fitur

- **Interaktif**: menu bisa dinavigasi pakai panah, ada spinner, progress bar, tabel berwarna, dan ringkasan di dalam box.
- **Mode flag**: semua yang bisa dilakukan di menu juga bisa lewat flag, jadi cocok buat script, cron, atau GitLab CI.
- **Sumber repo fleksibel**: satu repo, beberapa repo sekaligus, file `.txt`, satu group beserta subgroup-nya, atau **semua repo yang bisa diakses akun kamu**.
- **Multi-instance**: simpan beberapa profile koneksi (gitlab.com + self-hosted). Host dari URL repo otomatis dicocokkan ke profile yang sesuai.
- **Setup terpandu**: pilih jenis instance, URL, SSL (CA custom / skip verify), dan metode autentikasi (PAT, Project/Group token, OAuth2, env var, tanpa token). Koneksi langsung dites.
- **Tahan banting**: retry otomatis, menghormati rate limit (`Retry-After`), pagination, request paralel, dan error per repo gak menghentikan scan bulk.
- **Read-only & aman**: cuma `GET`, token gak pernah muncul di argumen proses, config ber-permission `600`.
- **Minim dependensi**: cukup `bash` 3.2+ (bawaan macOS), `curl`, dan `jq`.

## Quick start

```bash
git clone git@github.com:alterwriter/GITLABOX.git
cd GITLABOX
./gitlabbox.sh setup      # sambungkan ke GitLab (sekali saja)
./gitlabbox.sh            # buka menu interaktif
```

Contoh mode flag:

```bash
./gitlabbox.sh branches -r my-group/my-app                 # 1 repo
./gitlabbox.sh branches --mine -d 90 -F both               # semua repo akun kamu, 90 hari terakhir
./gitlabbox.sh branches -f repos.txt -b 'main,release/*'   # bulk dari file
./gitlabbox.sh branches -g my-org/backend -o - | jq .summary
```

Contoh hasil di layar:

```
  [1/3] acme/web
  ✔ Project acme/web · id 13 · private · default: main · gitlab.example.com
  ✔ 144 branch ketemu
  ✔ 144 branch dianalisis · 26 committer unik (gabungan semua branch) · 5s

    #  BRANCH                                  COMMITTERS            COMMITS  LAST        FLAGS  TOP COMMITTER
    1  main                                    ██████████████   26      1532  2026-10-14  D P ·  Dev A (212)
    2  release/2.0                             █████████████░   24       940  2026-10-11  · · ·  Dev B (131)
    3  feature/checkout-v2                     ██████░░░░░░░░   11     5000+  2026-10-07  · · ·  Dev C (88)
```

## Dokumentasi

| Dokumen | Isi |
|---|---|
| [Memulai](docs/01-memulai.md) | Kebutuhan, instalasi, first run, navigasi keyboard |
| [Koneksi & autentikasi](docs/02-koneksi-autentikasi.md) | SaaS vs self-hosted vs Dedicated, jenis token & scope, SSL, profile, env var, CI |
| [Branch & Committer Report](docs/03-branch-committer-report.md) | Panduan lengkap tool: sumber repo, opsi, alur interaktif, referensi CLI |
| [Format output](docs/04-format-output.md) | Skema JSON field-per-field, kolom CSV, resep `jq` |
| [Cara kerja](docs/05-cara-kerja.md) | Endpoint API, algoritma hitung committer, pagination, retry, paralelisme, estimasi biaya API |
| [Arsitektur & pengembangan](docs/06-arsitektur.md) | Struktur kode, referensi fungsi library, cara nambah tool baru, cara testing |
| [Troubleshooting](docs/07-troubleshooting.md) | Daftar error umum dan solusinya |
| [Keamanan](docs/08-keamanan.md) | Model keamanan, penyimpanan token, data di report |

## Struktur

```
GITLABOX/
├── gitlabbox.sh               # entry point: menu utama & dispatch command
├── lib/
│   ├── ui.sh                  # warna, banner, menu ↑/↓, input, spinner, progress bar, box
│   ├── config.sh              # profile koneksi & resolusi token
│   ├── api.sh                 # wrapper curl: auth, retry/429, pagination, pesan error
│   ├── targets.sh             # parsing input repo (path / ID / URL / SSH / group: / account:)
│   └── setup.sh               # wizard koneksi & kelola profile
├── tools/
│   └── branch-committers.sh   # Tool #1: Branch & Committer Report
├── docs/                      # dokumentasi detail
├── repos.example.txt          # template daftar repo
└── reports/                   # output default (di-ignore git)
```

## Catatan privasi

Report yang dihasilkan berisi **nama repo, nama branch, nama, dan email** kontributor. Folder `reports/` dan `repos.txt` sudah masuk `.gitignore`. Jangan commit hasil scan ke repo publik. Detailnya ada di [Keamanan](docs/08-keamanan.md).
