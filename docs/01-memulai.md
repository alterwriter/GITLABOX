# 1. Memulai

[← README](../README.md) · [Koneksi & autentikasi →](02-koneksi-autentikasi.md)

## Kebutuhan

| Komponen | Versi minimal | Cek | Install |
|---|---|---|---|
| bash | 3.2 (bawaan macOS sudah cukup) | `bash --version` | — |
| curl | yang support `-H @file` (7.55+) | `curl --version` | `brew install curl` / `apt install curl` |
| jq | 1.6 | `jq --version` | `brew install jq` / `apt install jq` |

Selain itu cuma pakai tool standar Unix: `sed`, `awk`, `tr`, `xargs`, `seq`, `mktemp`. Gak butuh Python, Node, atau package manager lain.

Sudah dites di macOS (bash 3.2 + BSD userland). Linux (bash 4/5 + GNU userland) juga didukung, karena script-nya sengaja menghindari fitur yang beda antar platform. Misalnya perhitungan tanggal dikerjakan di `jq`, bukan pakai `date -d`/`date -v`.

## Instalasi

```bash
git clone git@github.com:alterwriter/GITLABOX.git
cd GITLABOX
chmod +x gitlabbox.sh
```

Opsional, biar bisa dipanggil dari folder mana saja:

```bash
ln -s "$PWD/gitlabbox.sh" /usr/local/bin/gitlabbox
gitlabbox --version
```

Symlink aman dipakai. Script akan me-resolve lokasi aslinya buat nemuin `lib/` dan `tools/`.

## Pertama kali jalan

1. **Sambungkan ke GitLab.** Langkah-langkahnya dijelaskan di [Koneksi & autentikasi](02-koneksi-autentikasi.md).
   ```bash
   ./gitlabbox.sh setup
   ```
2. **Cek koneksinya.**
   ```bash
   ./gitlabbox.sh whoami
   ```
   ```
   ✔ Konek ke https://gitlab.example.com
   ╭─ Koneksi OK ──────────────────────────────────────────────╮
   │ Profile  kantor                                           │
   │ URL      https://gitlab.example.com                       │
   │ Versi    GitLab 17.5.1-ee                                 │
   │ Login    @username (Nama Kamu)                            │
   │ Token    tersimpan di config                              │
   │          gitlabbox · scope: read_api · expire: 2027-01-01 │
   ╰───────────────────────────────────────────────────────────╯
   ```
3. **Buka menu dan jalankan report pertama.**
   ```bash
   ./gitlabbox.sh
   ```

## Daftar command

| Command | Fungsi |
|---|---|
| `./gitlabbox.sh` (atau `menu`) | Menu interaktif |
| `./gitlabbox.sh setup` | Wizard tambah koneksi GitLab |
| `./gitlabbox.sh profiles` | Tabel semua profile koneksi |
| `./gitlabbox.sh whoami [-p PROFILE]` | Tes koneksi + info user & token |
| `./gitlabbox.sh branches [opsi]` | Branch & Committer Report via flag (lihat [panduan tool](03-branch-committer-report.md)) |
| `./gitlabbox.sh reports` | Pilih dan tampilkan ulang report JSON yang tersimpan |
| `./gitlabbox.sh --help` | Bantuan |
| `./gitlabbox.sh --version` | Versi |

Alias: `branches` = `branch-committers` = `bc`, `profiles` = `profile`.

## Navigasi keyboard

Semua menu pilihan memakai kontrol yang sama:

| Tombol | Aksi |
|---|---|
| `↑` / `↓` (atau `k` / `j`, `w` / `s`) | Pindah pilihan |
| `1` – `9` | Lompat ke pilihan ke-N |
| `Enter` | Pilih |
| `q` / `Esc` | Batal / kembali |
| `Ctrl+C` | Keluar dari program (cursor & file sementara dibersihkan) |

Di bawah menu ada baris `↳` yang ngasih keterangan buat pilihan yang lagi disorot. Setelah dipilih, menu dirangkum jadi satu baris `✔ Pertanyaan › jawaban`, jadi riwayat jawaban tetap terbaca di layar.

Input teks:
- Nilai default ditampilkan dalam kurung. Tekan `Enter` buat pakai nilai itu.
- Input path (misal file `.txt` atau folder output) mendukung **Tab autocomplete** dan `~`.
- Input token disembunyikan. Setelah diisi, yang tampil cuma 6 karakter pertama + `••••`.

## Mode interaktif vs mode flag

| | Interaktif | Flag |
|---|---|---|
| Butuh terminal (TTY) | Ya | Tidak |
| Cocok untuk | Eksplorasi, sekali jalan | Script, cron, CI |
| Konfirmasi sebelum jalan | Ada (ringkasan + "Gas?") | Tidak, langsung jalan |
| Output ke stdout | — | Bisa (`-o -`) |

Semua tampilan UI (spinner, tabel, pesan) ditulis ke **stderr**. Artinya stdout tetap bersih buat di-pipe, contohnya `./gitlabbox.sh branches -r a/b -o - | jq`.

## Variabel lingkungan

| Variabel | Fungsi |
|---|---|
| `GITLAB_URL` / `CI_SERVER_URL` | URL GitLab buat profile `env` (tanpa file config) |
| `GITLAB_TOKEN` | Token buat profile `env`, sekaligus fallback buat profile yang gak punya token |
| `GITLAB_AUTH` | `pat` (default) atau `oauth` buat profile `env` |
| `GITLAB_INSECURE=1` | Skip verifikasi SSL buat profile `env` |
| `GITLAB_CA_BUNDLE` | Path CA bundle buat profile `env` |
| `GITLABBOX_HOME` | Lokasi folder config (default `~/.gitlabbox`) |
| `GITLABBOX_TIMEOUT` | Timeout total per request dalam detik (default `60`) |
| `NO_COLOR=1` | Matikan warna |

## Langkah berikutnya

- [Koneksi & autentikasi](02-koneksi-autentikasi.md): detail token, SSL, dan multi-instance.
- [Branch & Committer Report](03-branch-committer-report.md): semua cara memakai tool.
