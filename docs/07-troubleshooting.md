# 7. Troubleshooting

[← Arsitektur & pengembangan](06-arsitektur.md) · [Keamanan →](08-keamanan.md)

Langkah pertama yang paling berguna:

```bash
./gitlabbox.sh whoami            # token valid? scope apa? versi GitLab?
./gitlabbox.sh profiles          # profile mana yang default?
```

## Pesan error & solusinya

| Pesan | Penyebab | Solusi |
|---|---|---|
| `401 Unauthorized — token kosong / salah / expired / di-revoke` | Token gak valid | Bikin token baru → menu Kelola profile → Ganti token |
| `403 Forbidden — token kurang scope (butuh read_api) atau role-nya gak cukup` | Scope token cuma `read_repository`, atau role di project di bawah Reporter | Pakai token dengan scope `read_api`, atau minta akses Reporter+ |
| `404 Not Found — path salah, atau project private & token gak punya akses` | Typo path, project sudah dipindah/dihapus, atau GitLab menyembunyikan project private dari user yang gak punya akses | Cek path di browser. Cek juga apakah repo-nya memang terlihat dengan akun yang sama. |
| `Host '…' belum punya profile` | URL repo dari instance yang belum disetup | `./gitlabbox.sh setup` buat host tersebut |
| `Host gak ketemu (DNS). Cek URL, atau perlu nyalain VPN?` | DNS gagal (curl exit 6) | Nyalakan VPN kantor atau perbaiki URL |
| `Koneksi ditolak` | Port tertutup (curl exit 7) | Cek URL/port, firewall |
| `Timeout` | Server lambat (curl exit 28) | `export GITLABBOX_TIMEOUT=180` |
| `Masalah SSL/TLS (sertifikat self-signed / CA internal?)` | Sertifikat server gak dipercaya sistem | Setup ulang dengan **CA bundle custom** (`.pem` CA kantor). Pakai **skip verifikasi** cuma kalau benar-benar perlu. |
| `Masalah SSL/TLS` padahal server pakai `http://` | Kamu nulis URL tanpa skema, jadi otomatis dianggap `https://` | Tulis `http://` secara eksplisit di wizard |
| `Response bukan JSON — URL GitLab salah, atau ketahan SSO/proxy` | URL mengarah ke halaman HTML (login SSO, captive portal, reverse proxy) | Pastikan `<url>/api/v4/version` bisa diakses. Cek URL root GitLab-nya. |
| `302 Redirect ke … — cek URL (http vs https / sub-path / SSO)` | Server redirect, misalnya dari http ke https atau ke halaman SSO | Pakai URL hasil redirect sebagai URL profile |
| `429 Rate limit GitLab (disuruh nunggu Ns)` | Terlalu banyak request, biasanya karena akses **tanpa token** | Pakai token, turunkan `-w`, persempit dengan `-d` / `-b` |
| `Mode akun butuh token` | Profile tanpa token dipakai buat `--mine` / `-a` | Tambahkan PAT ke profile |
| `Scope 'all' di gitlab.com = semua repo publik sedunia` | `-a all` di gitlab.com | Pakai `member` |
| `Token gak punya scope read_api/api` (warning) | Token dengan scope sempit | Bikin ulang token dengan `read_api` |
| `Menu interaktif butuh terminal (TTY)` | Dijalankan tanpa terminal (pipe, CI, cron) | Pakai mode flag: `./gitlabbox.sh branches ...` |
| `Butuh: jq` | `jq` belum terpasang | `brew install jq` / `apt install jq` |

## Gejala lain

**Angka committer di hampir semua branch mirip dengan `main`.**
Ini normal. Branch yang dibuat dari `main` membawa history `main`. Pakai `-d 30` / `-d 90` buat melihat aktivitas terbaru saja. Penjelasannya ada di [Cara kerja](05-cara-kerja.md#hal-yang-perlu-dipahami).

**Ada tanda `+` di kolom COMMITS.**
Commit di branch itu melebihi `--max-commits`. Naikkan batasnya (`-m 20000` atau `-m 0`) kalau perlu angka yang akurat untuk seluruh history.

**Satu orang terhitung dua kali.**
Orang itu commit pakai dua email berbeda. Pengelompokan sengaja cuma pakai email.

**Scan lama sekali.**
Hitung estimasinya di [Biaya API](05-cara-kerja.md#biaya-api). Biasanya penyebabnya repo dengan ratusan branch dan history panjang. Persempit dengan `-b`, `-d`, atau `--repo-filter`.

**Mode akun cuma menemukan sedikit project.**
- Pakai Project/Group Access Token? Token jenis itu cuma melihat project/group-nya sendiri. Pakai PAT.
- Project archived dilewati secara default. Tambahkan `--include-archived`.
- Scope `owned` cuma mencakup project yang kamu owner. Coba `member`.

**Warna atau karakter kotak berantakan.**
Pastikan terminal memakai locale UTF-8 (`echo $LANG` → `en_US.UTF-8` atau sejenisnya). Kalau perlu, matikan warna dengan `NO_COLOR=1`.

**Tombol panah gak merespons.**
Beberapa terminal mengirim kode panah dalam mode berbeda. Pakai `j`/`k` atau angka `1`–`9` sebagai alternatif.

**SSH ke GitHub/GitLab timeout di port 22 (waktu clone repo ini).**
Jaringannya memblok port 22. Pakai SSH lewat port 443. Untuk GitHub tambahkan ini ke `~/.ssh/config`:

```
Host github.com
  HostName ssh.github.com
  Port 443
  User git
```

Fingerprint resmi GitHub buat ED25519: `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`.

## Debug manual

Request yang sama bisa dicoba langsung dengan `curl`. Kalau ini berhasil tapi GITLABBOX gagal, berarti ada bug di tool:

```bash
curl -sS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "https://gitlab.example.com/api/v4/user" | jq .
curl -sS -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
  "https://gitlab.example.com/api/v4/projects/$(jq -rn --arg s 'team/app' '$s|@uri')/repository/branches?per_page=5" | jq '.[].name'
```
