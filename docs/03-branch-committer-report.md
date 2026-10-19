# 3. Branch & Committer Report

[← Koneksi & autentikasi](02-koneksi-autentikasi.md) · [Format output →](04-format-output.md)

Tool ini menjawab pertanyaan: **"Di repo ini ada branch apa saja, dan berapa orang yang commit ke masing-masing branch?"** Hasilnya diurutkan dari committer terbanyak ke paling sedikit.

Contoh kegunaannya:
- Audit branch: cari branch yang ramai, branch yang sepi, atau branch yang sudah lama gak disentuh.
- Inventaris kontributor per repo atau per tim, misalnya buat review akses atau onboarding/offboarding.
- Bahan laporan rutin (misal per bulan) yang diekspor ke Sheets/Excel.

## Sumber repo

Ada 5 cara menentukan repo yang mau di-scan. Semuanya bisa dicampur dalam satu run.

| Sumber | Menu interaktif | Flag | Di file `.txt` |
|---|---|---|---|
| 1 / beberapa repo | Ketik langsung | `-r REPO` (bisa diulang / dipisah koma) | baris biasa |
| Semua repo akun kamu | Semua repo yang bisa diakses akun gw | `--mine`, `-a SCOPE` | `account:SCOPE`, `mine` |
| File `.txt` | Bulk dari file .txt | `-f FILE` | — |
| Satu group | Semua project di group | `-g GROUP` | `group:PATH` |
| Argumen posisi | — | `./gitlabbox.sh branches a/b c/d` | — |

### Format penulisan repo

```text
my-group/my-app                                       # path (namespace/project)
my-group/sub/deep/project                             # subgroup bertingkat
12345                                                 # project ID
https://gitlab.example.com/my-group/my-app            # URL web
https://gitlab.example.com/my-group/my-app/-/tree/dev # URL apa saja dari browser (/-/... dibuang)
https://gitlab.example.com/my-group/my-app.git        # clone URL HTTPS
git@gitlab.example.com:my-group/my-app.git            # clone URL SSH
ssh://git@gitlab.example.com:2222/my-group/my-app.git # SSH dengan port
group:my-org/backend                                  # semua project di group + subgroup
account:member                                        # semua repo yang akun kamu member
account:developer@gitlab.example.com                  # scope + instance tertentu
mine                                                  # = account:member
```

Aturan parsing:
- Teks setelah ` #` dianggap komentar. Baris kosong dan baris yang diawali `#` dilewati.
- Line ending Windows (CRLF) aman.
- Query string, fragment, `/-/...`, `.git`, dan `/` di akhir dibuang.
- **Duplikat dibuang**, termasuk kalau repo yang sama ditulis dengan format berbeda (misal `a/b` dan `https://<host-profile>/a/b`).
- Mode interaktif "Ketik langsung" menerima beberapa repo yang dipisah koma atau spasi.

Template lengkapnya ada di [`repos.example.txt`](../repos.example.txt). Salin jadi `repos.txt` (file ini di-ignore git).

### Mode "semua repo akun saya"

Daftar repo diambil dari `GET /projects` memakai token kamu. Scope menentukan project mana saja yang ikut:

| Scope | Parameter API | Isi |
|---|---|---|
| `member` *(default)* | `membership=true` | Semua project di mana kamu member, langsung maupun lewat group. Sama seperti "Your projects" di UI. |
| `owned` | `owned=true` | Project yang kamu owner, biasanya yang ada di namespace pribadi |
| `reporter` | `membership=true&min_access_level=20` | Role minimal Reporter |
| `developer` | `membership=true&min_access_level=30` | Role minimal Developer |
| `maintainer` | `membership=true&min_access_level=40` | Role minimal Maintainer |
| `all` | — | Semua project yang visible buat kamu, termasuk internal/public walau bukan member. **Cuma bisa di self-hosted.** Di gitlab.com diblok karena isinya semua repo publik sedunia. |

Catatan:
- **Wajib pakai token.** Tanpa token gak ada "akun" yang bisa dicek.
- Project yang di-archive **dilewati**, kecuali kalau pakai `--include-archived`.
- Hasilnya tergantung jenis token. Project/Group Access Token cuma "melihat" project/group miliknya sendiri, jadi buat mode ini sebaiknya pakai **PAT**.
- Hasil bisa disaring pakai `--repo-filter` (glob, dipisah koma), misalnya `--repo-filter 'payments/*,*-service'`.

Di menu interaktif, setelah daftar repo diambil, kamu dapat preview dan bisa menyaring dulu sebelum scan:

```
  ✔ Scope repo akun lu › Semua yang gw member (rekomendasi)
  ✔ Ikut sertain project yang di-archive? › Tidak
  ✔ Akun @username: 87 project (scope: member · gitlab.example.com)
    • backend/api
    • backend/worker
    • platform/infra
    … +79 lagi
  ▲ 87 repo itu banyak — saran: pakai rentang 90 hari / filter branch biar cepet.
  ? Lanjut?
  ❯ ▶  Scan 87 project ini
    🔍 Filter nama repo
    ←  Batal
```

### Mode group

`-g my-org/backend` atau `group:my-org/backend` mengambil semua project di group itu, **termasuk subgroup**, yang belum di-archive. Daftarnya bisa disaring dengan `--repo-filter` dan ditambah project archived dengan `--include-archived`.

## Alur interaktif

```bash
./gitlabbox.sh     # → 🌿 Branch & Committer Report
```

| # | Pertanyaan | Pilihan |
|---|---|---|
| 1 | Pakai koneksi yang mana? | Cuma muncul kalau ada lebih dari 1 profile (atau ada profile `env`) |
| 2 | Repo-nya dari mana? | Ketik langsung · Semua repo akun · File .txt · Group |
| 3 | Hitung commit dari kapan? | Semua history · 30 · 90 · 180 · 365 hari · Custom |
| 4 | Opsi lanjutan | **Pakai default** atau **Atur sendiri**: filter branch, author/committer, batas commit (1.000 / 5.000 / 20.000 / tanpa batas), jumlah worker (1–32) |
| 5 | Format report | JSON · CSV · JSON + CSV |
| 6 | Folder output | Default `reports/` di folder tool |
| 7 | Ringkasan → Gas? | 🚀 Gas · ✏️ Ulang dari awal · ✖ Batal |
| 8 | Next? | Balik ke menu · 📂 Buka folder report · Keluar |

Ringkasan sebelum jalan:

```
  ╭─ Siap jalan ─────────────────────────────────────────────────────────────╮
  │ Koneksi  kantor · gitlab.example.com                                     │
  │ Repo     akun @username · scope member · 12 project (filter 'backend/*') │
  │ Rentang  90 hari terakhir                                                │
  │ Opsi     filter 'main,release/*' · author · max 5000 commit/branch · 6 … │
  │ Output   BOTH → ~/GITLABOX/reports                                       │
  ╰──────────────────────────────────────────────────────────────────────────╯
```

Selama scan, setiap repo melewati 3 tahap: resolve project, ambil daftar branch (dengan counter), lalu hitung committer per branch (dengan progress bar). Setelah itu tabel top branch langsung ditampilkan:

```
  [2/12] backend/worker
  ✔ Project backend/worker · id 512 · private · default: main · gitlab.example.com
  ✔ 3 dari 144 branch cocok filter main,release/*
  ⠼ ████████████████████░░░░░░░░░░  66% 2/3 ngitung committer per branch (6 worker)
```

Kalau repo yang di-scan lebih dari satu, di akhir ada **leaderboard lintas repo** (top 10 branch paling ramai dari semua repo), lalu box ringkasan:

```
  ╭─ Report siap ───────────────────────────────────────────────────────────────╮
  │ Repo     11 sukses · 1 gagal                                                │
  │ Branch   36 dianalisis                                                      │
  │ Rentang  sejak 2026-07-21 (90 hari)                                         │
  │ Durasi   1m 12s                                                             │
  │ JSON     reports/branch-committers_bulk-12repos_20261019-101500.json        │
  │ CSV      reports/branch-committers_bulk-12repos_20261019-101500.csv         │
  ╰─────────────────────────────────────────────────────────────────────────────╯

  ✖ team/legacy-app — 403 Forbidden — token kurang scope (butuh read_api) atau role-nya gak cukup.
```

### Membaca tabel

```
    #  BRANCH                                  COMMITTERS            COMMITS  LAST        FLAGS  TOP COMMITTER
    1  main                                    ██████████████   26      1532  2026-10-14  D P ·  Dev A (212)
    2  feature/checkout-v2                     ██████░░░░░░░░   11     5000+  2026-10-07  · · M  Dev C (88)
```

| Kolom | Arti |
|---|---|
| `COMMITTERS` | Jumlah orang unik (berdasarkan email) + bar yang dinormalisasi terhadap branch teramai di repo itu |
| `COMMITS` | Jumlah commit yang dibaca. **`+`** artinya terpotong oleh `--max-commits`, jadi angka committer bisa lebih kecil dari aslinya. |
| `LAST` | Tanggal commit terakhir di ujung branch |
| `FLAGS` | `D` = default branch · `P` = protected · `M` = sudah di-merge ke default branch |
| `TOP COMMITTER` | Orang dengan commit terbanyak di branch itu (jumlah commit) |

Secara default tabel di layar cuma menampilkan 10 branch teratas per repo (bisa diubah dengan `--rows`). **File report selalu berisi semua branch.**

## Referensi CLI

```bash
./gitlabbox.sh branches [opsi] [REPO ...]
```

### Sumber repo

| Opsi | Keterangan |
|---|---|
| `-r, --repo REPO` | Path / ID / URL. Bisa diulang, atau beberapa sekaligus dipisah koma/spasi. |
| `-f, --file FILE` | File `.txt`, 1 repo per baris |
| `-g, --group GROUP` | Semua project di group + subgroup |
| `-a, --account SCOPE` | Semua project yang bisa diakses akun: `member` · `owned` · `reporter` · `developer` · `maintainer` · `all` |
| `--mine` | Singkatan dari `--account member` |
| `--repo-filter GLOB` | Saring hasil `-g` / `-a`, glob dipisah koma |
| `--include-archived` | Ikutkan project archived di hasil `-g` / `-a` |

### Koneksi

| Opsi | Keterangan |
|---|---|
| `-p, --profile NAME` | Profile yang dipakai. Default: profile default. Kalau gak ada config: `GITLAB_URL` + `GITLAB_TOKEN`. |

### Analisis

| Opsi | Default | Keterangan |
|---|---|---|
| `-d, --since-days N` | semua history | Cuma hitung commit N hari terakhir (`since=` di API) |
| `--all-history` | — | Paksa semua history |
| `-m, --max-commits N` | `5000` | Batas commit yang dibaca per branch. `0` = tanpa batas. |
| `-b, --branch-filter GLOB` | semua | Filter nama branch, glob dipisah koma |
| `--identity WHO` | `author` | `author` atau `committer` (lihat [cara kerja](05-cara-kerja.md#author-vs-committer)) |
| `-w, --workers N` | `6` | Jumlah request paralel per repo |
| `--top N` | `5` | Jumlah top committer per branch di report |

### Output

| Opsi | Default | Keterangan |
|---|---|---|
| `-F, --format FMT` | `json` | `json` · `csv` · `both` |
| `-o, --out PATH` | `reports/` | Bisa berupa folder, nama file (`x.json` / `x.csv`, pasangannya ikut nama yang sama), atau `-` buat stdout (cuma 1 format) |
| `--rows N` | `10` | Jumlah baris tabel per repo di layar |

Opsi panjang juga bisa ditulis dengan `=`, misalnya `--format=csv` atau `--since-days=30`.

### Glob (filter branch & repo)

- Pakai pattern matching bash: `*` (apa saja, **termasuk `/`**), `?` (1 karakter), `[abc]`.
- Beberapa pola dipisah koma. Spasi di sekitar koma diabaikan.
- Contoh filter branch: `main,develop,release/*,hotfix-*`
- Contoh filter repo: `backend/*,*-service,platform/infra`

### Nama file output

`branch-committers_<slug>_<YYYYmmdd-HHMMSS>.{json,csv}`, dengan:
- `<slug>` = path repo dengan `/` diganti `_` kalau cuma 1 repo, misalnya `my-group_my-app`,
- `<slug>` = `bulk-<N>repos` kalau lebih dari 1 repo.

### Exit code

| Kode | Arti |
|---|---|
| `0` | Semua repo sukses |
| `3` | Sebagian repo gagal (report tetap ditulis, repo yang gagal punya field `error`) |
| `1` | Semua repo gagal, input salah, atau belum ada profile |
| `130` | Dibatalkan dengan Ctrl+C |

### Contoh

```bash
# 1 repo, semua history, JSON ke reports/
./gitlabbox.sh branches -r my-group/my-app

# beberapa repo sekaligus
./gitlabbox.sh branches -r "team/api, team/web" -r https://gitlab.com/acme/mobile-app

# semua repo yang saya member, 90 hari, JSON + CSV
./gitlabbox.sh branches --mine -d 90 -F both

# repo tim payments yang role saya minimal developer
./gitlabbox.sh branches -a developer --repo-filter 'payments/*' -p kantor

# 1 group, cuma branch rilis, simpan ke folder tertentu
./gitlabbox.sh branches -g my-org/backend -b 'main,release/*' -o ~/audit/2026-10/

# bulk dari file, CSV ke nama file tertentu
./gitlabbox.sh branches -f repos.txt -F csv -o ~/audit/branches.csv

# pipe ke jq: 5 branch teratas
./gitlabbox.sh branches -r 123 -o - | jq '.repositories[0].branches[:5] | map({name, committer_count})'

# monorepo besar: tanpa batas commit, worker lebih banyak, hitung berdasarkan committer
./gitlabbox.sh branches -r big/monorepo -m 0 -w 12 --identity committer
```

## Melihat report tersimpan

Menu **📊 Lihat report tersimpan** atau `./gitlabbox.sh reports` menampilkan 15 file JSON terbaru di `reports/`. Pilih salah satu, lalu tabel per repo dan leaderboard-nya ditampilkan ulang tanpa memanggil API lagi.

## Tips performa

| Kondisi | Saran |
|---|---|
| Banyak repo (puluhan sampai ratusan) | `-d 90` dan/atau `-b 'main,develop,release/*'` |
| Repo dengan history panjang | Biarkan `-m 5000` (default). Branch yang kena batas ditandai `+`. |
| Kena `429` rate limit | Turunkan `-w`, pastikan pakai token |
| Jaringan lambat / VPN | Naikkan `GITLABBOX_TIMEOUT` |

Estimasi jumlah request API ada di [Cara kerja → Biaya API](05-cara-kerja.md#biaya-api).
