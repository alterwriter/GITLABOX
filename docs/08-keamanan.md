# 8. Keamanan

[← Troubleshooting](07-troubleshooting.md) · [README](../README.md)

## Ringkasan

| Aspek | Perlakuan |
|---|---|
| Akses ke GitLab | **Read-only**: semua request `GET`. Gak ada endpoint yang mengubah data. |
| Scope token | `read_api` sudah cukup. Hindari scope `api` (read-write). |
| Token di proses | Gak pernah muncul di argumen command line. Token ditulis ke file header sementara (`600`) lalu dibaca curl dengan `-H @file`. Akibatnya token gak terlihat di `ps`. |
| Token di config | `~/.gitlabbox/config.json` dengan permission `600` (folder `700`), atau gak disimpan sama sekali kalau pakai metode env var |
| Token di layar | Input disembunyikan. Yang ditampilkan cuma 6 karakter pertama + `••••`. |
| File sementara | `mktemp -d` (`700`), dihapus otomatis saat exit atau Ctrl+C |
| TLS | Diverifikasi secara default. Mendukung CA bundle custom. Skip verify cuma kalau dipilih eksplisit, dan selalu ditandai `insecure`. |
| Redirect | Gak diikuti otomatis, supaya header token gak terkirim ke host lain |

## Rekomendasi token

1. Bikin **PAT khusus** buat GITLABBOX, misalnya dengan nama `gitlabbox`. Jangan pakai ulang token lain.
2. Scope cuma **`read_api`**.
3. Pasang **tanggal expire** yang pendek, misalnya 30–90 hari. `whoami` akan memberi peringatan kalau tinggal kurang dari 14 hari.
4. Lebih baik pakai metode **env var** dan ambil token dari password manager/keychain:
   ```bash
   export GITLAB_TOKEN_KANTOR="$(security find-generic-password -s gitlabbox-kantor -w)"
   ```
5. Di CI, simpan token sebagai variable yang **masked + protected**.
6. Revoke token begitu gak dipakai lagi.

## Data di report

File report (`reports/*.json`, `*.csv`) berisi:

- nama dan path **repo**, termasuk repo private/internal,
- nama **branch**, yang kadang memuat nomor tiket atau nama fitur yang belum diumumkan,
- **nama dan email** kontributor. Ini termasuk data pribadi.

Karena itu:

- Folder `reports/` dan file `repos.txt` sudah masuk **`.gitignore`**. Jangan commit hasil scan, terutama ke repo publik.
- Bagikan report cuma ke pihak yang memang berhak melihat daftar repo dan kontributornya.
- Kalau report perlu dibagikan lebih luas, samarkan dulu email-nya, misalnya:
  ```bash
  jq '(.. | objects | select(has("email")) | .email) |= (split("@") | .[0][:2] + "***@" + .[1])' report.json > report.masked.json
  ```
- Hapus report lama yang sudah gak diperlukan.

## Skip verifikasi SSL

Opsi `Skip verifikasi (insecure)` atau `GITLAB_INSECURE=1` membuat koneksi rentan terhadap penyadapan (MITM), termasuk token yang ikut terkirim. Pakai opsi ini cuma untuk instance lab/internal di jaringan yang kamu percaya. Untuk server yang pakai sertifikat CA internal, pilihan yang benar adalah **CA bundle custom**:

```bash
# ambil CA chain dari server (cek fingerprint-nya ke tim infra!)
openssl s_client -connect gitlab.example.com:443 -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERT/,/END CERT/' > ~/certs/gitlab-example-chain.pem
```

## Melaporkan masalah keamanan

Kalau kamu menemukan celah keamanan di tool ini, misalnya token bocor ke log atau ke output, jangan buka issue publik yang berisi detail eksploitasi. Hubungi maintainer repo secara langsung.
