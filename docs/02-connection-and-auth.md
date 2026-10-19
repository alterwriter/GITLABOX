# 2. Connection & authentication

[← Getting started](01-getting-started.md) · [Branch & Committer Report →](03-branch-committer-report.md)

## Concept: there is no "session"

The GitLab REST API v4 is **stateless**. There is no login, cookie, or session like in the browser. Every request just carries two things:

1. **The instance base URL**, e.g. `https://gitlab.com` or `https://gitlab.example.com`. All endpoints live under `<base>/api/v4`.
2. **An access token** in an HTTP header.

| Token type | Header GITLABBOX sends |
|---|---|
| Personal Access Token (PAT) | `PRIVATE-TOKEN: <token>` |
| Project Access Token | `PRIVATE-TOKEN: <token>` |
| Group Access Token | `PRIVATE-TOKEN: <token>` |
| OAuth2 access token | `Authorization: Bearer <token>` |

GITLABBOX stores each URL + auth method combination as a **profile**.

## Instance types

| Type | URL | Notes |
|---|---|---|
| **GitLab.com (SaaS)** | `https://gitlab.com` (filled in automatically) | Strict rate limits without a token. Account scope `all` is blocked. |
| **Self-hosted (CE/EE)** | Your own server's URL | Internal certificates supported. Can live under a sub-path, e.g. `https://host/gitlab`. |
| **GitLab Dedicated** | `https://<tenant>.gitlab-dedicated.com` | Treated the same as self-hosted. |

## Setup wizard

```bash
./gitlabbox.sh setup        # or menu → 🔌 Set up a GitLab connection
```

The steps:

| # | Step | Details |
|---|---|---|
| 1 | **Where is your GitLab?** | GitLab.com / Self-hosted / Dedicated |
| 2 | **GitLab URL** (non-SaaS) | `https://` is added if you leave out the scheme. A trailing `/` or `/api/v4` is stripped. The URL is probed at `/api/v4/version`. A `200` or `401/403` response means a GitLab API was detected. |
| 3 | **SSL verification** (non-SaaS) | Normal (system CA) · Custom CA bundle (`.pem`/`.crt`) · Skip verification. If the probe in step 2 failed because of SSL, the custom CA option is pre-selected. |
| 4 | **Authentication method** | PAT · Project/Group token · OAuth2 · Env var · No token |
| 5 | **Token input** | Hidden. For a PAT, the wizard shows a token-creation link with the `read_api` scope pre-filled. |
| 6 | **Connection test** | Calls `/user`, `/version`, and `/personal_access_tokens/self`, then shows the user, version, and token name/scopes/expiry. If it fails, you can save anyway or cancel. |
| 7 | **Profile name** | Defaults to a name derived from the hostname, e.g. `gitlab.example.com` → `example`, `gitlab.com` → `gitlab-com`, an IP address → `self-hosted`. |
| 8 | **Make default?** | Asked when other profiles already exist. |

What it looks like:

```
  ✔ Where is your GitLab? › Self-hosted (CE / EE)
  ✔ GitLab URL › https://gitlab.example.com
  ✔ GitLab API detected (token required — expected)
  ✔ SSL verification › Normal (recommended)
  ✔ Authentication method › Personal Access Token (PAT)
    Create a token: https://gitlab.example.com/-/user_settings/personal_access_tokens?name=gitlabbox&scopes=read_api
  ✔ Token › glpat-•••••••••• (26 characters)
  ✔ Connected to https://gitlab.example.com
  ╭─ Connection OK ──────────────────────────────────╮
  │ ...                                              │
  ╰──────────────────────────────────────────────────╯
  ✔ Profile name › example
  ✔ Profile example saved to ~/.gitlabbox/config.json (chmod 600)
```

## Tokens: types, scopes, and roles

**Minimum scope: `read_api`.** GITLABBOX only issues `GET` requests, so the `api` scope (read-write) is unnecessary and best avoided.

| Token type | How to create it | Good for |
|---|---|---|
| **Personal Access Token** | Avatar → Preferences → Access Tokens. Direct URL: `<gitlab>/-/user_settings/personal_access_tokens` (GitLab < 16: `/-/profile/personal_access_tokens`) | Personal use. **Required** for "all repos my account can access" mode. |
| **Project Access Token** | Project → Settings → Access Tokens | Scanning one project from CI |
| **Group Access Token** | Group → Settings → Access Tokens | Scanning one group from CI |
| **OAuth2 token** | From an OAuth application | Integrating with SSO/other apps |

Minimum role on a project: **Reporter**. That is enough to read branches and commits in private/internal projects.

The connection test warns you when:
- the token has neither the `read_api` nor the `api` scope (branch/commit endpoints would return `403`),
- the token expires in fewer than 14 days.

## The "Read from an environment variable" method

With this method the token is **never written to disk**. The profile only stores the *name* of the variable, for example `GITLAB_TOKEN_WORK`, and the token is read from it on every run:

```bash
export GITLAB_TOKEN_WORK=glpat-xxxxxxxx    # e.g. from a password manager / keychain
./gitlabbox.sh
```

Example pulling the token from the macOS Keychain:

```bash
export GITLAB_TOKEN_WORK="$(security find-generic-password -s gitlabbox-work -w)"
```

## Resolution order

**Which profile is used** (when `-p` is not given):
1. the `default` profile from the config,
2. if there is exactly one profile, that one,
3. the virtual `env` profile, if `GITLAB_URL` / `CI_SERVER_URL` is set.

**Which token a profile uses:**
1. the env var named in `token_env` (if it is non-empty),
2. the `token` stored in the config,
3. `$GITLAB_TOKEN`,
4. no token, so only public projects are readable.

## Config file

Location: `~/.gitlabbox/config.json`, or `$GITLABBOX_HOME/config.json`. The folder is `700`, the file is `600`, and it is written atomically (to a temp file first, then `mv`).

```json
{
  "default": "work",
  "profiles": {
    "work": {
      "url": "https://gitlab.example.com",
      "kind": "self-hosted",
      "auth": "pat",
      "token": "",
      "token_env": "GITLAB_TOKEN_WORK",
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

| Field | Value |
|---|---|
| `url` | Base URL without `/api/v4` |
| `kind` | `saas` · `self-hosted` · `dedicated` |
| `auth` | `pat` (`PRIVATE-TOKEN` header) · `oauth` (`Authorization: Bearer` header) |
| `token` | Plain-text token. Leave empty when using `token_env`. |
| `token_env` | Name of the env var holding the token |
| `verify_ssl` | `false` = skip verification (`curl -k`) |
| `ca_bundle` | Custom CA path (`curl --cacert`) |

## Managing profiles

The **🗂 Manage profiles** menu shows a profile table, then lets you pick one and:

| Action | Effect |
|---|---|
| Test connection | Same as `whoami` |
| Make default | Sets `default` |
| Change token | Stores a new token (and clears `token_env`), then tests it right away |
| Delete profile | Removes it from the config. If it was the default, the default moves to another profile. |

```
     PROFILE          URL                                  TYPE         TOKEN            SSL
  ●  work             https://gitlab.example.com           self-hosted  env $GITLAB_...  custom CA
     gitlab-com       https://gitlab.com                   saas         stored           verify
```

## Multiple instances

When a repo is given as a **full URL**, e.g. `https://gitlab.com/acme/app` or `git@gitlab.example.com:team/svc.git`, its host is matched against the profile whose `url` has the same host. A single `.txt` file can therefore mix repos from several instances:

```text
team/payments                                  # → active profile
https://gitlab.com/acme/mobile-app             # → profile with host gitlab.com
git@gitlab.example.com:platform/infra.git      # → profile with host gitlab.example.com
account:member@gitlab.com                      # all your repos on gitlab.com
```

If a host has no profile yet, that repo is recorded as failed with `Host '...' has no profile yet`, and the scan moves on to the next repo.

**Self-hosted under a sub-path** (`https://host/gitlab`): the `/gitlab` prefix is stripped automatically from repo paths taken from URLs.

## No config (CI / one-off runs)

```bash
GITLAB_URL=https://gitlab.example.com GITLAB_TOKEN=glpat-xxx \
  ./gitlabbox.sh branches -r team/app -o -
```

GitLab CI job example. `CI_SERVER_URL` is set automatically, so you only need the token as a **CI/CD variable** (masked + protected):

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

> `CI_JOB_TOKEN` **does not work** here. It only has access to a small subset of API endpoints and uses a different header (`JOB-TOKEN`).

`|| [ $? -eq 3 ]` keeps the job green when only some repos failed. Exit codes are described in the [tool guide](03-branch-committer-report.md#exit-codes).
