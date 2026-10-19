# 2. Koneksi & autentikasi

[← Memulai](01-memulai.md) · [Branch & Committer Report →](03-branch-committer-report.md)

## Konsep: gak ada "session"

GitLab REST API v4 itu **stateless**. Gak ada login, cookie, atau session seperti di browser. Setiap request cukup membawa dua hal:

1. **Base URL instance**, misalnya `https://gitlab.com` atau `https://gitlab.example.com`. Semua endpoint ada di bawah `<base>/api/v4`.
2. **Access token** di header HTTP.

| Jenis token | Header yang dikirim GITLABBOX |
|---|---|
| Personal Access Token (PAT) | `PRIVATE-TOKEN: <token>` |
| Project Access Token | `PRIVATE-TOKEN: <token>` |
| Group Access Token | `PRIVATE-TOKEN: <token>` |
| OAuth2 access token | `Authorization: Bearer <token>` |

GITLABBOX menyimpan kombinasi URL + cara auth ini sebagai **profile**.

## Jenis instance

| Jenis | URL | Catatan |
|---|---|---|
| **GitLab.com (SaaS)** | `https://gitlab.com` (diisi otomatis) | Rate limit ketat buat akses tanpa token. Scope akun `all` diblok. |
| **Self-hosted (CE/EE)** | URL server kamu sendiri | Bisa pakai sertifikat internal. Bisa juga di sub-path, misal `https://host/gitlab`. |
| **GitLab Dedicated** | `https://<tenant>.gitlab-dedicated.com` | Diperlakukan sama seperti self-hosted. |

## Wizard setup

```bash
./gitlabbox.sh setup        # atau menu → 🔌 Setup koneksi GitLab
```

Langkah-langkahnya:

| # | Langkah | Detail |
|---|---|---|
| 1 | **GitLab-nya di mana?** | GitLab.com / Self-hosted / Dedicated |
| 2 | **URL GitLab** (selain SaaS) | Skema `https://` ditambahkan kalau gak ditulis. Akhiran `/` dan `/api/v4` dibuang otomatis. URL-nya langsung di-probe ke `/api/v4/version`. Respons `200` atau `401/403` berarti API GitLab kedeteksi. |
| 3 | **Verifikasi SSL** (selain SaaS) | Normal (CA sistem) · CA bundle custom (`.pem`/`.crt`) · Skip verifikasi. Kalau probe di langkah 2 gagal karena SSL, opsi CA custom jadi pilihan default. |
| 4 | **Cara autentikasi** | PAT · Project/Group token · OAuth2 · Env var · Tanpa token |
| 5 | **Input token** | Disembunyikan. Buat PAT, wizard nampilin link pembuatan token yang scope `read_api`-nya udah terisi. |
| 6 | **Tes koneksi** | Panggil `/user`, `/version`, dan `/personal_access_tokens/self`, terus tampilkan user, versi, nama/scope/expire token. Kalau gagal, ada pilihan: tetap simpan atau batal. |
| 7 | **Nama profile** | Default diambil dari hostname, misal `gitlab.example.com` → `example`, `gitlab.com` → `gitlab-com`, alamat IP → `self-hosted`. |
| 8 | **Jadikan default?** | Ditanyakan kalau sudah ada profile lain. |

Contoh tampilannya:

```
  ✔ GitLab-nya di mana? › Self-hosted (CE / EE)
  ✔ URL GitLab › https://gitlab.example.com
  ✔ API GitLab kedetect (butuh token — normal)
  ✔ Verifikasi SSL › Normal (rekomendasi)
  ✔ Cara autentikasi › Personal Access Token (PAT)
    Bikin token: https://gitlab.example.com/-/user_settings/personal_access_tokens?name=gitlabbox&scopes=read_api
  ✔ Token › glpat-•••••••••• (26 karakter)
  ✔ Konek ke https://gitlab.example.com
  ╭─ Koneksi OK ─────────────────────────────────────╮
  │ ...                                              │
  ╰──────────────────────────────────────────────────╯
  ✔ Nama profile › example
  ✔ Profile example tersimpan di ~/.gitlabbox/config.json (chmod 600)
```

## Token: jenis, scope, dan role

**Scope minimal: `read_api`.** GITLABBOX cuma melakukan `GET`, jadi scope `api` (read-write) gak diperlukan dan sebaiknya gak dipakai.

| Jenis token | Cara bikin | Cocok untuk |
|---|---|---|
| **Personal Access Token** | Avatar → Preferences → Access Tokens. URL langsung: `<gitlab>/-/user_settings/personal_access_tokens` (GitLab < 16: `/-/profile/personal_access_tokens`) | Pemakaian pribadi. **Wajib** buat mode "semua repo akun saya". |
| **Project Access Token** | Project → Settings → Access Tokens | Scan 1 project dari CI |
| **Group Access Token** | Group → Settings → Access Tokens | Scan 1 group dari CI |
| **OAuth2 token** | Dari OAuth application | Integrasi dengan SSO/app lain |

Role minimal di project: **Reporter**. Role ini sudah cukup buat baca branch dan commit di project private/internal.

Tes koneksi akan ngasih peringatan kalau:
- token gak punya scope `read_api` atau `api` (endpoint branch/commit bakal `403`),
- token expire dalam kurang dari 14 hari.

## Metode "Ambil dari environment variable"

Dengan metode ini, token **gak disimpan ke disk**. Yang disimpan di profile cuma *nama* variabelnya, misalnya `GITLAB_TOKEN_KANTOR`, lalu tokennya dibaca setiap kali tool jalan:

```bash
export GITLAB_TOKEN_KANTOR=glpat-xxxxxxxx    # misal dari password manager / keychain
./gitlabbox.sh
```

Contoh mengambil token dari macOS Keychain:

```bash
export GITLAB_TOKEN_KANTOR="$(security find-generic-password -s gitlabbox-kantor -w)"
```

## Urutan resolusi

**Profile mana yang dipakai** (kalau gak ada `-p`):
1. profile `default` di config,
2. kalau cuma ada 1 profile, profile itu,
3. profile virtual `env` kalau `GITLAB_URL` / `CI_SERVER_URL` ter-set.

**Token yang dipakai sebuah profile:**
1. isi env var yang namanya disimpan di `token_env` (kalau gak kosong),
2. `token` yang tersimpan di config,
3. `$GITLAB_TOKEN`,
4. tanpa token, cuma bisa baca project public.

## File config

Lokasinya `~/.gitlabbox/config.json`, atau `$GITLABBOX_HOME/config.json`. Folder-nya `700`, file-nya `600`, dan ditulis secara atomic (tulis ke file sementara dulu, lalu di-`mv`).

```json
{
  "default": "kantor",
  "profiles": {
    "kantor": {
      "url": "https://gitlab.example.com",
      "kind": "self-hosted",
      "auth": "pat",
      "token": "",
      "token_env": "GITLAB_TOKEN_KANTOR",
      "verify_ssl": true,
      "ca_bundle": "/Users/me/certs/corp-ca.pem"
    },
    "gitlab-com": {
      "url": "https://gitlab.com",
      "kind": "saas",
      "auth": "pat",
      "token": "glpat-xxxxxxxxxxxxxxxxxxxx",
      "token_env": "",
      "verify_ssl": true,
      "ca_bundle": ""
    }
  }
}
```

| Field | Nilai |
|---|---|
| `url` | Base URL tanpa `/api/v4` |
| `kind` | `saas` · `self-hosted` · `dedicated` |
| `auth` | `pat` (header `PRIVATE-TOKEN`) · `oauth` (header `Authorization: Bearer`) |
| `token` | Token plain text. Kosongkan kalau pakai `token_env`. |
| `token_env` | Nama env var yang berisi token |
| `verify_ssl` | `false` = skip verifikasi (`curl -k`) |
| `ca_bundle` | Path CA custom (`curl --cacert`) |

## Kelola profile

Menu **🗂 Kelola profile** menampilkan tabel profile, lalu kamu bisa pilih salah satu buat:

| Aksi | Efek |
|---|---|
| Tes koneksi | Sama seperti `whoami` |
| Jadiin default | Set `default` |
| Ganti token | Simpan token baru (sekaligus mengosongkan `token_env`) lalu langsung dites |
| Hapus profile | Hapus dari config. Kalau yang dihapus profile default, default pindah ke profile lain. |

```
     PROFILE          URL                                  JENIS        TOKEN            SSL
  ●  kantor           https://gitlab.example.com           self-hosted  env $GITLAB_...  custom CA
     gitlab-com       https://gitlab.com                   saas         tersimpan        verify
```

## Multi-instance

Kalau input repo berupa **URL lengkap**, misalnya `https://gitlab.com/acme/app` atau `git@gitlab.example.com:team/svc.git`, host-nya dicocokkan ke profile yang `url`-nya punya host yang sama. Jadi satu file `.txt` bisa berisi campuran repo dari beberapa instance:

```text
team/payments                                  # → profile aktif
https://gitlab.com/acme/mobile-app             # → profile dengan host gitlab.com
git@gitlab.example.com:platform/infra.git      # → profile dengan host gitlab.example.com
account:member@gitlab.com                      # semua repo akun kamu di gitlab.com
```

Kalau host-nya belum punya profile, repo itu dicatat gagal dengan pesan `Host '...' belum punya profile`. Scan tetap lanjut ke repo berikutnya.

**Self-hosted di sub-path** (`https://host/gitlab`): prefix `/gitlab` otomatis dibuang dari path repo yang diambil dari URL.

## Tanpa config (CI / sekali jalan)

```bash
GITLAB_URL=https://gitlab.example.com GITLAB_TOKEN=glpat-xxx \
  ./gitlabbox.sh branches -r team/app -o -
```

Contoh job GitLab CI. Di sini `CI_SERVER_URL` otomatis tersedia, jadi cukup set token sebagai **CI/CD variable** (masked + protected):

```yaml
branch-committer-report:
  image: alpine:3.20
  before_script:
    - apk add --no-cache bash curl jq git
    - git clone https://github.com/alterwriter/GITLABOX.git /opt/gitlabox
  script:
    - export GITLAB_TOKEN="$GITLABBOX_READ_TOKEN"     # PAT / group token, scope read_api
    - /opt/gitlabox/gitlabbox.sh branches -g "$CI_PROJECT_NAMESPACE" -d 30 -F both -o report/ || [ $? -eq 3 ]
  artifacts:
    paths: [report/]
    expire_in: 7 days
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
```

> `CI_JOB_TOKEN` **gak bisa** dipakai. Token itu cuma punya akses ke sebagian kecil endpoint API dan pakai header yang berbeda (`JOB-TOKEN`).

`|| [ $? -eq 3 ]` bikin job tetap sukses kalau cuma sebagian repo yang gagal. Penjelasan exit code ada di [panduan tool](03-branch-committer-report.md#exit-code).
