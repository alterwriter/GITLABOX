# 8. Security

[← Troubleshooting](07-troubleshooting.md) · [README](../README.md)

## Summary

| Aspect | Handling |
|---|---|
| GitLab access | **Read-only**: every request is a `GET`. No endpoint that modifies data is ever called. |
| Token scope | `read_api` is enough. Avoid the `api` (read-write) scope. |
| Token in processes | Never appears on the command line. It is written to a temporary header file (`600`) that curl reads with `-H @file`, so it never shows up in `ps`. |
| Token in config | `~/.gitlabbox/config.json` with permission `600` (folder `700`), or not stored at all with the env var method |
| Token on screen | Input is hidden. Only the first 6 characters + `••••` are displayed. |
| Temp files | `mktemp -d` (`700`), removed automatically on exit or Ctrl+C |
| TLS | Verified by default. Custom CA bundles are supported. Verification is only skipped when explicitly chosen, and is always flagged as `insecure`. |
| Redirects | Not followed automatically, so the token header is never sent to another host |

## Token recommendations

1. Create a **dedicated PAT** for GITLABBOX, e.g. named `gitlabbox`. Don't reuse other tokens.
2. Scope: **`read_api`** only.
3. Set a short **expiry date**, e.g. 30–90 days. `whoami` warns you when fewer than 14 days are left.
4. Prefer the **env var** method and pull the token from a password manager/keychain:
   ```bash
   export GITLAB_TOKEN_WORK="$(security find-generic-password -s gitlabbox-work -w)"
   ```
5. In CI, store the token as a **masked + protected** variable.
6. Revoke the token as soon as you stop using it.

## Data in reports

Report files (`reports/*.json`, `*.csv`) contain:

- **repository** names and paths, including private/internal ones,
- **branch** names, which sometimes include ticket numbers or names of unannounced features,
- contributor **names and emails**. This is personal data.

Therefore:

- The `reports/` folder and `repos.txt` are already in **`.gitignore`**. Never commit scan results, especially to a public repo.
- Share reports only with people who are entitled to see the repo list and its contributors.
- If a report needs to be shared more widely, mask the emails first, for example:
  ```bash
  jq '(.. | objects | select(has("email")) | .email) |= (split("@") | .[0][:2] + "***@" + .[1])' report.json > report.masked.json
  ```
- Delete old reports you no longer need.

## Skipping SSL verification

The `Skip verification (insecure)` option, or `GITLAB_INSECURE=1`, leaves the connection open to interception (MITM), including the token sent with every request. Only use it for lab/internal instances on a network you trust. For servers with an internal CA certificate, the right choice is a **custom CA bundle**:

```bash
# fetch the CA chain from the server (verify the fingerprint with your infra team!)
openssl s_client -connect gitlab.example.com:443 -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERT/,/END CERT/' > ~/certs/gitlab-example-chain.pem
```

## Reporting security issues

If you find a security problem in this tool, for example a token leaking into logs or output, please don't open a public issue with exploit details. Contact the repo maintainer directly.
