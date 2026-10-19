# 4. Format output

[← Branch & Committer Report](03-branch-committer-report.md) · [Cara kerja →](05-cara-kerja.md)

Report bisa ditulis dalam dua format:
- **JSON** berisi data lengkap dan nested: report → repositories → branches → committers.
- **CSV** berbentuk flat, 1 baris per branch, buat Sheets/Excel.

Semua contoh di halaman ini memakai data fiktif.

## JSON

### Struktur tingkat atas

```json
{
  "tool": "branch-committers",
  "gitlabbox_version": "0.1.0",
  "generated_at": "2026-10-19T03:15:00Z",
  "duration_seconds": 72,
  "options": { ... },
  "summary": { ... },
  "repositories": [ ... ]
}
```

| Field | Tipe | Keterangan |
|---|---|---|
| `tool` | string | Selalu `"branch-committers"` |
| `gitlabbox_version` | string | Versi tool yang menghasilkan report |
| `generated_at` | string (ISO 8601, UTC) | Waktu report dibuat |
| `duration_seconds` | number | Lama scan |
| `options` | object | Parameter yang dipakai (lihat bawah) |
| `summary` | object | Ringkasan angka |
| `repositories` | array | Satu entri per repo, urut sesuai input |

### `options`

```json
{
  "since": "2026-07-21T03:13:48Z",
  "since_days": 90,
  "max_commits_per_branch": 5000,
  "identity": "author",
  "branch_filter": "main,release/*",
  "repo_filter": "backend/*",
  "include_archived": false
}
```

| Field | Tipe | Keterangan |
|---|---|---|
| `since` | string \| null | Batas bawah tanggal commit (UTC). `null` = semua history. |
| `since_days` | number \| null | Nilai `--since-days` |
| `max_commits_per_branch` | number \| null | `null` = tanpa batas |
| `identity` | string | `author` / `committer` |
| `branch_filter` | string \| null | Glob filter branch |
| `repo_filter` | string \| null | Glob filter repo (mode group/akun) |
| `include_archived` | boolean | Project archived ikut atau tidak |

### `summary`

```json
{ "repos_total": 12, "repos_ok": 11, "repos_failed": 1, "branches_analyzed": 36 }
```

### `repositories[]`

```json
{
  "input": "backend/worker",
  "project": "backend/worker",
  "id": 512,
  "name": "worker",
  "web_url": "https://gitlab.example.com/backend/worker",
  "default_branch": "main",
  "visibility": "private",
  "archived": false,
  "gitlab_url": "https://gitlab.example.com",
  "profile": "kantor",
  "branch_count_total": 144,
  "branch_count_analyzed": 3,
  "branches_failed": 0,
  "unique_committers": 26,
  "branches": [ ... ],
  "error": null
}
```

| Field | Tipe | Keterangan |
|---|---|---|
| `input` | string | Teks repo seperti yang ditulis di input (setelah dinormalisasi) |
| `project` | string | `path_with_namespace` dari GitLab |
| `id` | number | Project ID |
| `name` | string | Nama project |
| `web_url` | string | URL web project |
| `default_branch` | string \| null | Default branch |
| `visibility` | string | `private` · `internal` · `public` |
| `archived` | boolean | Status archived |
| `gitlab_url` | string | Base URL instance |
| `profile` | string | Profile yang dipakai |
| `branch_count_total` | number | Jumlah semua branch di repo |
| `branch_count_analyzed` | number | Jumlah branch yang dianalisis (setelah filter) |
| `branches_failed` | number | Jumlah branch yang gagal dibaca |
| `unique_committers` | number | Jumlah orang unik **gabungan semua branch yang dianalisis** |
| `branches` | array | Urut berdasarkan `committer_count` turun, lalu `commit_count` turun, lalu nama |
| `error` | string \| null | Kalau gak `null`, repo ini gagal dan `branches` kosong |

Kalau repo gagal (404, 403, host belum punya profile, rate limit, dll.), cuma field berikut yang terisi:

```json
{
  "input": "team/legacy-app",
  "project": "team/legacy-app",
  "gitlab_url": "https://gitlab.example.com",
  "branch_count_total": 0,
  "branch_count_analyzed": 0,
  "unique_committers": 0,
  "branches": [],
  "error": "403 Forbidden — token kurang scope (butuh read_api) atau role-nya gak cukup. [403 Forbidden]"
}
```

### `branches[]`

```json
{
  "name": "main",
  "committer_count": 26,
  "commit_count": 1532,
  "truncated": false,
  "default": true,
  "protected": true,
  "merged": false,
  "last_commit_at": "2026-10-14T10:00:00.000+07:00",
  "last_commit_author": "Dev A",
  "last_commit_sha": "a1b2c3d4",
  "web_url": "https://gitlab.example.com/backend/worker/-/tree/main",
  "top_committers": [
    { "name": "Dev A", "email": "dev.a@example.com", "commits": 212 },
    { "name": "Dev B", "email": "dev.b@example.com", "commits": 180 }
  ],
  "committers": [ "…semua committer, format sama dengan top_committers…" ],
  "error": null
}
```

| Field | Tipe | Keterangan |
|---|---|---|
| `name` | string | Nama branch |
| `committer_count` | number | Jumlah orang unik di commit yang dibaca |
| `commit_count` | number | Jumlah commit yang dibaca (dalam rentang `since`, maksimal `max_commits_per_branch`) |
| `truncated` | boolean | `true` = sebenarnya masih ada commit lain, tapi terpotong batas |
| `default` | boolean | Default branch |
| `protected` | boolean | Protected branch |
| `merged` | boolean | Sudah di-merge ke default branch (menurut GitLab) |
| `last_commit_at` | string | Waktu commit di ujung branch (zona waktu commit) |
| `last_commit_author` | string | Author commit terakhir |
| `last_commit_sha` | string | Short SHA commit terakhir |
| `web_url` | string | URL branch |
| `top_committers` | array | N teratas (default 5, atur dengan `--top`) |
| `committers` | array | Semua orang unik, urut berdasarkan jumlah commit |
| `error` | string \| null | Error saat membaca commit branch ini |

Kalau `error` sebuah branch terisi (commit-nya gagal dibaca), field yang ada cuma `name`, `committer_count: 0`, `commit_count: 0`, `committers: []`, `top_committers: []`, dan `error`.

Tiap entri committer berisi `name`, `email`, dan `commits`. Pengelompokannya pakai email huruf kecil. Kalau email kosong, dipakai nama. `name` dan `email` yang ditampilkan diambil dari commit pertama yang ketemu dari orang itu.

## CSV

Header (14 kolom):

```
project,branch,committer_count,commit_count,is_default,protected,merged,last_commit_at,last_commit_author,truncated,top_committers,branch_url,gitlab_url,error
```

Contoh:

```csv
"backend/worker","main",26,1532,true,true,false,"2026-10-14T10:00:00.000+07:00","Dev A",false,"Dev A <dev.a@example.com> (212); Dev B <dev.b@example.com> (180)","https://gitlab.example.com/backend/worker/-/tree/main","https://gitlab.example.com",
"team/legacy-app",,,,,,,,,,,,"https://gitlab.example.com","403 Forbidden — ..."
```

- 1 baris per branch, dengan urutan yang sama seperti di JSON.
- Repo yang gagal, atau yang gak punya branch cocok filter, tetap dapat **1 baris** dengan kolom `error` terisi (`gak ada branch yang cocok` buat kasus filter).
- `top_committers` digabung dengan format `Nama <email> (n); ...`.
- Boolean ditulis `true`/`false`, nilai kosong ditulis sebagai sel kosong. Semua string di-quote (format `@csv` dari jq).
- Import ke Google Sheets: **File → Import → Upload**, separator **Comma**.

## Resep `jq`

```bash
R=reports/branch-committers_bulk-12repos_20261019-101500.json

# ringkasan per repo
jq -r '.repositories[] | [.project, .branch_count_total, .unique_committers, (.error // "ok")] | @tsv' "$R"

# 10 branch teramai lintas repo
jq -r '[.repositories[] | .project as $p | .branches[] | {repo: $p, name, committer_count}]
       | sort_by(-.committer_count) | .[:10][] | "\(.committer_count)\t\(.repo) › \(.name)"' "$R"

# branch yang cuma disentuh 1 orang (bus factor 1)
jq -r '.repositories[] | .project as $p | .branches[] | select(.committer_count == 1)
       | "\($p) › \(.name) — \(.committers[0].email)"' "$R"

# branch sudah merged tapi belum dihapus
jq -r '.repositories[] | .project as $p | .branches[] | select(.merged and (.default | not))
       | "\($p) › \(.name)"' "$R"

# branch yang commit terakhirnya lebih dari 180 hari lalu
jq -r --arg cut "$(date -u -v-180d +%Y-%m-%d 2>/dev/null || date -u -d '180 days ago' +%Y-%m-%d)" \
   '.repositories[] | .project as $p | .branches[] | select(.last_commit_at[:10] < $cut)
    | "\(.last_commit_at[:10])  \($p) › \(.name)"' "$R"

# daftar semua kontributor unik + jumlah repo yang mereka sentuh
jq -r '[.repositories[] | .project as $p | .branches[].committers[] | {email: (.email | ascii_downcase), p: $p}]
       | group_by(.email) | map({email: .[0].email, repos: (map(.p) | unique | length)})
       | sort_by(-.repos)[] | "\(.repos)\t\(.email)"' "$R"

# repo yang gagal + alasannya
jq -r '.repositories[] | select(.error) | "\(.project): \(.error)"' "$R"
```
