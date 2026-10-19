# 5. Cara kerja

[← Format output](04-format-output.md) · [Arsitektur & pengembangan →](06-arsitektur.md)

## Alur besar

```
input (-r / -f / -g / -a)
   │
   ▼
parse_target ──► normalisasi path / host / jenis (project | group | account)
   │
   ▼
expand ──► group:/account: diubah jadi daftar project  ──► dedupe
   │
   ▼
untuk setiap repo (berurutan):
   1. GET /projects/:path            → id, default branch, visibility
   2. GET /projects/:id/repository/branches   (semua halaman)
   3. filter branch (glob)
   4. N worker paralel, 1 proses per branch:
        GET /projects/:id/repository/commits?ref_name=<branch>[&since=…]  (semua halaman s/d batas)
        → kelompokkan per email → hitung
   5. gabung + urutkan → tabel di layar
   │
   ▼
gabung semua repo → report.json → (opsional) report.csv
```

## Endpoint API yang dipakai

Semuanya `GET` dan read-only. Scope yang dibutuhkan cuma `read_api`.

| Endpoint | Dipakai untuk | Parameter |
|---|---|---|
| `/version` | Probe URL di wizard, info versi | — |
| `/user` | Tes koneksi, username di mode akun | — |
| `/personal_access_tokens/self` | Info nama, scope, dan expire token (GitLab 15.5+, opsional) | — |
| `/projects?per_page=1&visibility=public` | Tes akses tanpa token | — |
| `/projects/:id` | Resolve path atau ID jadi project | `:id` = path ter-URL-encode (`a%2Fb`) atau angka |
| `/projects/:id/repository/branches` | Daftar branch | `per_page=100&page=N` |
| `/projects/:id/repository/commits` | Commit per branch | `ref_name`, `since`, `per_page=100&page=N` |
| `/groups/:id/projects` | Expand `group:` | `include_subgroups=true`, `simple=true`, `order_by=path`, `archived=false` |
| `/projects` | Expand `account:` | `membership` / `owned` / `min_access_level`, `simple=true`, `order_by=path`, `archived=false` |

## Cara menghitung committer

Untuk setiap branch:

1. Ambil commit yang **reachable dari ujung branch**. Ini sama dengan `git log <branch>`, urut dari terbaru, dibatasi `since` dan `max_commits_per_branch`.
2. Dari tiap commit, ambil identitas `{name, email}`:
   - `--identity author` (default): `author_name`, `author_email`
   - `--identity committer`: `committer_name`, `committer_email`
3. Kunci pengelompokan = `lowercase(email)`. Kalau email kosong, pakai `"name:" + lowercase(name)`.
4. `committer_count` = jumlah kunci unik. `commit_count` = jumlah commit yang dibaca.
5. `committers` diurutkan berdasarkan jumlah commit (terbanyak dulu), lalu nama.

Di level repo, `unique_committers` = jumlah kunci unik **gabungan semua branch yang dianalisis**.

### Hal yang perlu dipahami

- **History ikut terwariskan.** Branch `feature/x` yang dibuat dari `main` ikut membawa seluruh history `main`. Akibatnya banyak branch punya angka committer mirip dengan `main`. Kalau mau melihat aktivitas yang benar-benar baru di sebuah branch, pakai `--since-days`.
- **Batas commit.** Kalau branch punya commit lebih banyak dari `--max-commits`, yang dibaca cuma N commit terbaru (`truncated: true`, tampil `+` di tabel). Committer lama yang cuma muncul di history tua bisa jadi gak terhitung.
- **Satu orang, banyak email.** Kalau seseorang commit pakai dua email berbeda (misal email kantor dan email pribadi), dia terhitung 2 orang. GITLABBOX sengaja gak menebak-nebak penggabungan identitas.
- **Bot ikut terhitung.** Akun seperti Renovate, Dependabot, atau bot release juga punya email. Saring di tahap analisis kalau perlu, misalnya dengan `jq` (lihat [resep](04-format-output.md#resep-jq)).
- **`merged`** berasal dari GitLab (`branch.merged`), artinya ujung branch sudah ada di default branch.

### Author vs committer

| | Author | Committer |
|---|---|---|
| Siapa | Orang yang **menulis** perubahan | Orang/sistem yang **menerapkan** commit ke repo |
| Beda dari author kalau | — | rebase, cherry-pick, `git am`, merge/squash lewat UI GitLab, commit lewat Web IDE |
| Contoh | `Dev A` | bisa jadi `GitLab` / `noreply@…` di merge lewat UI |

Untuk pertanyaan "siapa saja yang kontribusi kode", pakai **author** (default).

## Pagination

- Semua list endpoint dipanggil dengan `per_page=100`.
- Halaman berikutnya diambil dari header **`x-next-page`**. Kalau header itu kosong, berarti sudah halaman terakhir.
- Fallback: kalau header pagination hilang (misalnya dibuang proxy) dan halaman terisi penuh (100 item), halaman berikutnya tetap dicoba.
- Untuk commit, pengambilan berhenti begitu sudah mencapai `max_commits_per_branch`. Sisanya gak di-download sama sekali.

## Retry & rate limit

| Kondisi | Perilaku |
|---|---|
| Error jaringan sementara (curl exit 28/52/55/56: timeout, empty reply, send/recv error) | Retry maksimal 3x, jeda 1s, 2s, 3s |
| HTTP `429`, `500`, `502`, `503`, `504` | Retry maksimal 5x. Jeda mengikuti header `Retry-After` kalau ada, kalau gak ada `attempt × 2` detik. |
| HTTP `429` dengan `Retry-After` > 90 detik | **Langsung gagal** dengan pesan jelas. Biasanya ini akses anonim yang kena limit, jadi lebih baik dikasih tahu daripada nunggu diam-diam berpuluh menit. |
| HTTP `401/403/404/3xx` | Gak di-retry. Pesan error dibuat manusiawi (lihat [Troubleshooting](07-troubleshooting.md)). |
| Respons `2xx` tapi bukan JSON | Gagal dengan pesan "URL GitLab salah / ketahan SSO/proxy" |

Timeout per request: connect 10 detik, total `GITLABBOX_TIMEOUT` (default 60 detik).

## Paralelisme

- Repo diproses **satu per satu**, supaya output di layar tetap berurutan dan rapi.
- Di dalam satu repo, branch diproses **paralel** dengan `xargs -P <workers>`. Tiap worker adalah proses `gitlabbox.sh __bc_branch <index>` terpisah.
- Worker dapat konteks lewat environment variable (`GLB_API`, `GLB_HDR`, `BC_PID`, `BC_SINCE`, …) dan menulis hasilnya ke file JSON per branch di folder sementara.
- Progress bar di proses utama menghitung baris di file `done` yang ditambah setiap worker selesai.
- Default 6 worker. Rate limit request terautentikasi di gitlab.com cukup longgar buat angka ini. Di self-hosted, batasnya tergantung setting admin.

## Biaya API

Estimasi jumlah request per repo:

```
1 (project) + ⌈branch / 100⌉ (list branch) + Σ ⌈min(commit_branch, max_commits) / 100⌉ (commit)
```

| Skenario | Branch | Commit dibaca/branch | ≈ Request |
|---|---|---|---|
| Repo kecil | 10 | 200 | 1 + 1 + 10×2 = **22** |
| Repo sedang | 150 | 5.000 (batas default) | 1 + 2 + 150×50 = **7.503** |
| Repo sedang, `-d 90` | 150 | ~150 | 1 + 2 + 150×2 = **303** |
| Repo sedang, `-b 'main,release/*'` | 5 | 5.000 | 1 + 2 + 5×50 = **253** |

Mode "semua repo akun" menambah 1 request `/user` dan ⌈jumlah project / 100⌉ request daftar project.

**Kesimpulan:** buat scan rutin banyak repo, `--since-days` dan `--branch-filter` adalah cara paling efektif buat memangkas waktu dan beban ke server GitLab.

## File sementara

- Satu folder per run: `mktemp -d $TMPDIR/gitlabbox.XXXXXX` dengan permission `700`.
- Isinya: file header auth, halaman-halaman respons API, hasil per branch dan per repo.
- Dihapus otomatis waktu exit, termasuk kalau dibatalkan dengan Ctrl+C. Proses worker yang masih jalan juga ikut dihentikan.
