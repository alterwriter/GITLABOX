# 11. Dependency Finder

[← CI Job Detector](10-ci-job-detector.md) · [README](../README.md)

This tool answers: **"Which of our repos use a library like *X*, and which version?"**

You give keywords instead of exact package names, because one library family often has many names. For example, `sdk` finds `aws-sdk`, `@aws-sdk/client-s3`, `github.com/aws/aws-sdk-go-v2`, `firebase-admin-sdk`, `midtrans-sdk`, and `AWSSDK.S3`. For every repo, the tool reads the dependency manifests on one branch: the default branch, or `master` / any branch you choose. It then lists the libraries that match.

No library or repo names are built in. You type them in every run.

## What you need

- A profile with a token (scope `read_api`). See [Connection & authentication](02-connection-and-auth.md).
- **Reporter** (or higher) on the projects, which is enough to read repository files.

## Repos

The repo sources are the same as in the [Branch & Committer Report](03-branch-committer-report.md#repo-sources):

- one or more repos,
- a `.txt` file,
- **one or more groups** (comma-separated, subgroups included),
- every repo your account can access.

## Keywords

| Keyword | Matches | Example |
|---|---|---|
| plain word | any library whose name **contains** it, case-insensitive | `sdk`, `firebase`, `midtrans` |
| with `*` or `?` | glob on the **whole** name | `@aws-sdk/*`, `com.google.firebase:*`, `*-sdk` |

Separate several keywords with commas. Maven / Gradle libraries are named `group:artifact` (`com.google.firebase:firebase-messaging`), so both parts can be matched.

## Manifests read

| Ecosystem | Files |
|---|---|
| npm | `package.json` (dependencies, devDependencies, peerDependencies, optionalDependencies) |
| PyPI | `requirements*.txt`, `requirements/*.txt`, `Pipfile`, `pyproject.toml` (PEP 621 + Poetry), `setup.py` |
| Go | `go.mod` (direct + `// indirect`) |
| Maven / Gradle / sbt | `pom.xml` (with `${property}` versions), `build.gradle`, `build.gradle.kts`, `*.versions.toml` (version catalogs), `build.sbt` |
| NuGet | `*.csproj`, `*.fsproj`, `*.vbproj`, `Directory.Packages.props`, `packages.config` |
| Packagist | `composer.json` |
| RubyGems / CocoaPods | `Gemfile`, `Podfile` |
| Cargo | `Cargo.toml` |
| pub (Dart / Flutter) | `pubspec.yaml` |

Manifests are found anywhere in the repo, which covers monorepos. Folders like `node_modules/`, `vendor/`, `Pods/`, `.venv/`, and `site-packages/` are skipped. Only **direct** dependencies are read. Lockfiles are not.

### Optional: source code search

Choose **Manifests + source code search** (or `--code`) to also search each repo's code for the keyword. This catches imports and vendored or copied SDKs that are not in a manifest. It uses the GitLab search API, which is slower and **rate-limited**: by default 30 searches per minute per user on gitlab.com and on most self-hosted instances. Use it on a group or a short repo list, not on every repo you can access.

## Result per repo

| Result | Meaning |
|---|---|
| ✔ `USED` | At least one manifest has a matching library |
| ◆ `CODE_ONLY` | No matching library in a manifest, but the keyword was found in the code (only with code search) |
| · `NOT_FOUND` | The repo has manifests, and none of them matches |
| – `NO_MANIFEST` | No manifest found, or an empty repository / the branch does not exist |
| ! `ERROR` | The project could not be read |

## Interactive use

`./gitlabbox.sh` → **📦 Dependency Finder**

```
  ✔ Where do the repos come from? › Every project in one or more groups
  ✔ Group path(s) › my-org/backend, my-org/mobile
  ✔ Library keywords › sdk, firebase
  ✔ Which branch? › A specific branch
  ✔ Branch › master
  ✔ What to scan? › Dependency manifests (recommended)

  ▌ Libraries found
  ECOSYSTEM  LIBRARY                                          REPOS  VERSIONS
  go         github.com/aws/aws-sdk-go-v2                         4  v1.24.0, v1.21.2
  maven      com.google.firebase:firebase-messaging               3  23.1.0
  npm        @aws-sdk/client-s3                                   2  ^3.400.0

  ▌ Per repo
     PROJECT                                          RESULT      MATCHES
  ✔ my-org/backend/orders                            USED        github.com/aws/aws-sdk-go-v2@v1.24.0
  ✔ my-org/mobile/app                                USED        com.google.firebase:firebase-messaging@23.1.0
  · my-org/backend/billing                           NOT_FOUND   —
```

## Flag mode

```bash
./gitlabbox.sh deps -g my-org -k sdk
./gitlabbox.sh deps --mine -k 'firebase,@aws-sdk/*' --ref master
./gitlabbox.sh deps -f repos.txt -k midtrans --code
./gitlabbox.sh deps -g my-org -k sdk -o - | jq -r '.libraries[] | "\(.repos)\t\(.name)"'
```

| Option | Default | Description |
|---|---|---|
| `-r`, `-f`, `-g`, `-a`, `--mine` | — | Repo source, same as `branches` |
| `--repo-filter GLOB` | — | Filter group/account results |
| `--include-archived` | — | Include archived projects |
| `-k, --keywords LIST` | — (required) | Library keywords (see above) |
| `--ref BRANCH` | default branch | Scan this branch instead, e.g. `master` |
| `--code` | — | Also search the source code |
| `--max-tree N` | `20000` | Max files listed per repo |
| `--max-files N` | `300` | Max manifests read per repo |
| `-p, --profile NAME` | default profile | Connection profile |
| `-w, --workers N` | `6` | Repos scanned in parallel |
| `-o, --out DIR` | `reports/` | Parent folder, or `-` for JSON on stdout |

Exit code `0` = every repo was read, `3` = some repos returned `ERROR`.

## Output files

`reports/<YYYY-MM-DD_HHMM>_deps_<scope>/`:

| File | Contents |
|---|---|
| `report.csv` | **One sheet.** One row per matched library (and per code hit): `project, result, keyword, ecosystem, library, version, scope, file, line, file_url, branch, note`. Repos without a match get one row with their result. |
| `report.json` | Per repo: manifests read, matches, code hits. Plus `libraries`: every matched library with the number of repos, versions, and project list. |

## How it works

| Endpoint | Used for |
|---|---|
| `GET /projects/:id` | Default branch |
| `GET /projects/:id/repository/tree?recursive=true&ref=…` | Finding manifest files (up to `--max-tree` entries) |
| `GET /projects/:id/repository/files/:path?ref=…` | Reading each manifest |
| `GET /projects/:id/search?scope=blobs&search=…&ref=…` | Optional code search |

API cost per repo: 1 + (files ÷ 100) + number of manifests, plus one search per keyword with `--code`.

## Caveats

- Only **direct** dependencies are read. A library that comes in transitively, through another package, is not found unless it is also in a manifest or the code search finds it.
- Versions are shown as written in the manifest (`^3.4`, `>=2.0`, `${aws.version}` resolved from `<properties>` when possible). They are not the resolved, installed versions.
- Gradle and Maven files are read as text, not evaluated. Dependencies added by plugins, loops, or variables in a separate file may be missed.
- For very large repos, the file list is cut at `--max-tree`, and the note column says so.
