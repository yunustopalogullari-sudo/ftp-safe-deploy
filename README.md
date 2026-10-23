# ftp-safe-deploy

[![test](https://github.com/yunustopalogullari-sudo/ftp-safe-deploy/actions/workflows/test.yml/badge.svg)](https://github.com/yunustopalogullari-sudo/ftp-safe-deploy/actions/workflows/test.yml)

**Reversible FTP/FTPS deploys for shared hosting, atomic per file.** One Bash file, only needs `curl`.

If you deploy to shared hosting (netcup, IONOS, Strato, Hostinger, cPanel/Plesk hosts ...) over FTP,
you have probably seen this: the connection drops halfway through a file, the server keeps the
half-written file, and the live site shows a blank page or a PHP parse error until you notice.

`ftp-safe-deploy` never writes over a live file directly:

1. **Backs up** every file it is about to replace (and remembers which ones did not exist yet).
2. **Uploads** each file under a random temp name, ideally into a folder **outside the web root**
   (`REMOTE_TEMP_DIR`), so an in-flight file is never reachable over HTTP.
3. **Checks the size** on the server. Only a complete upload is **renamed** into place.
4. Runs your **health check URLs**. If one fails, it **rolls back automatically**.
5. Any deploy can be undone later with **one command**, including deleting files it added.

```
$ ftp-safe-deploy
Deploy plan: 3 file(s) -> ftps://ftp.example.com/httpdocs
  - index.php
  - assets/style.css
  - lib/core.php
1/3 backing up live files -> .deploy-backups/20261023-141502-01
2/3 uploading (temp file + size check + rename)
  ✓ index.php (162992 bytes)
  ✓ assets/style.css (160594 bytes)
  ✓ lib/core.php (60913 bytes)
3/3 health check
  health 200 https://example.com/
Done: 3 file(s) deployed. Undo with: ftp-safe-deploy restore 20261023-141502-01
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/yunustopalogullari-sudo/ftp-safe-deploy/main/ftp-safe-deploy \
  -o /usr/local/bin/ftp-safe-deploy && chmod +x /usr/local/bin/ftp-safe-deploy
```

Works with the Bash that ships with macOS (3.2) and any Linux. Requirements: `bash`, `curl`,
`sha256sum` or `shasum`.

## Configure

Create `.ftpdeploy` in your project root (see [`.ftpdeploy.example`](.ftpdeploy.example)):

```ini
FTP_HOST=ftp.example.com
FTP_USER=web123
REMOTE_DIR=httpdocs
REMOTE_TEMP_DIR=fsd-tmp
PROTOCOL=ftps
HEALTH_URLS=https://example.com/ https://example.com/admin/login.php
EXCLUDE=*.log .env node_modules/* tests/*
PASSWORD_CMD=security find-generic-password -a web123 -s my-ftp -w
```

| Key | Default | Meaning |
|---|---|---|
| `FTP_HOST` | required | FTP server name. For FTPS use the name on its certificate. |
| `FTP_PORT` | `21` | |
| `FTP_USER` | required | |
| `REMOTE_DIR` | (login dir) | Folder on the server, relative to the FTP root. |
| `REMOTE_TEMP_DIR` | | **Recommended.** Folder for in-flight uploads, outside the web root (e.g. next to `httpdocs`). Must not be inside `REMOTE_DIR`; the tool checks it is writable before touching anything and stops with an error if not. |
| `LOCAL_DIR` | `.` | Folder to deploy. |
| `PROTOCOL` | `ftps` | `ftps` (explicit TLS) or `ftp`. |
| `PLAIN_FALLBACK_EXT` | | Extensions to send over plain FTP even when `PROTOCOL=ftps`, for hosts whose upload scanners stall FTPS transfers of e.g. `php`. |
| `HEALTH_URLS` | | Space-separated URLs that must answer 2xx/3xx after a deploy, or it rolls back. |
| `EXCLUDE` | | Space-separated glob patterns that are never uploaded. |
| `PASSWORD_CMD` | | Command that prints the password (Keychain, `pass`, Doppler, 1Password CLI ...). |
| `CURL_EXTRA` | | Extra curl flags, e.g. `--limit-rate 500k`. |

**Password lookup order:** `$FTP_PASSWORD` → `PASSWORD_CMD` → interactive prompt. The password is
passed to curl through a temporary `0600` config file, never on the command line, so it does not
show up in `ps` or shell history.

Add `.ftpdeploy-state` and `.deploy-backups/` to `.gitignore`.

## Use

```bash
ftp-safe-deploy                  # upload files changed since the last successful deploy
ftp-safe-deploy --dry-run        # show what would be uploaded, touch nothing
ftp-safe-deploy --all            # upload everything, ignoring the change state
ftp-safe-deploy index.php css/a.css   # upload just these files
ftp-safe-deploy list             # list deploy backups
ftp-safe-deploy restore          # undo the most recent deploy
ftp-safe-deploy restore 20261023-141502-01
```

Only files whose SHA-256 changed since the last **successful** deploy are uploaded. A failed or
rolled-back deploy does not update that state, and `restore` removes the restored files from it,
so the next normal run uploads them again.

## Guarantees and limits

- If the **backup** step fails, nothing is uploaded.
- If `REMOTE_TEMP_DIR` is set but unusable (missing and not creatable, not writable, or inside the
  web root), the deploy **stops before uploading** — it never silently falls back to the web root.
- If an **upload, size check or rename** fails, the live file is untouched. Already-renamed files
  stay live, and the tool prints the `restore` command for that deploy.
- **Temp files.** The tool tries to delete a temp file after any failure. If that also fails (for
  example the connection is gone), it prints the full remote path so you can delete it by hand.
  Leftovers are named `.fsd-<random>-...`; later runs ignore them and use new random names, so
  they never overwrite anything — but they stay on the server until you remove them.
- **Without `REMOTE_TEMP_DIR`** temp files sit next to their target for a few seconds and **may be
  reachable over HTTP**. A leading dot and a random name are *not* access control: on netcup a
  hidden temp file was served with HTTP 200 in our test. Keeping the extension (`.php`) means the
  server treats the file like the real one, which avoids serving PHP as plain-text source on
  typical setups, but whether PHP is executed depends entirely on the server configuration, and the
  file could still be requested while in flight. Use `REMOTE_TEMP_DIR` for anything sensitive; the
  tool prints a note on every deploy when it is not set.
- **Backups never leave your machine.** They are stored in `.deploy-backups/` (created `chmod 700`)
  and may contain old source code and old secrets. Keep that folder out of git (and out of the
  folder you deploy) and delete old backups you no longer need.
- A deploy is **not a transaction** across files: during the few seconds between renames, some new
  files are live while others are still old. For schema changes, deploy the backwards-compatible
  part first.
- It does not delete remote files that you deleted locally (on purpose).

## Host compatibility

Each row is one report: one provider, one plan, one tool version. Every scenario is marked
**worked**, **failed** or **not tried**. Failed results stay in the table with a link to the report,
and "not tried" is never counted as a success: a scenario that passes in the local test suite is
still "not tried" on a host until someone ran it there. A row means "this is what happened for this
person on this setup", not "this works on this provider".
Tried it on your host? Please [file a compatibility report](https://github.com/yunustopalogullari-sudo/ftp-safe-deploy/issues/new?template=host-compatibility.yml)
(no passwords, keys or customer files needed). Reports where something failed are just as useful.

| Provider | Plan / panel | Version | Connection | First upload | Change existing file | Restore | Interrupted upload | Health-check rollback | Report |
|---|---|---|---|---|---|---|---|---|---|
| netcup | shared web hosting, Plesk (package name not recorded) | pre-0.1.0 development build, 2026-10-23 | FTPS; `REMOTE_TEMP_DIR` outside `httpdocs` | ✅ worked | ✅ worked | ✅ worked (byte-exact) | ✅ worked (live file intact) | ➖ not tried | [#2](https://github.com/yunustopalogullari-sudo/ftp-safe-deploy/issues/2) (maintainer) |

✅ worked · ❌ failed (see linked report) · ➖ not tried

## Tests

```bash
python3 -m pip install pyftpdlib
bash tests/run.sh
```

The suite (37 checks) starts a real local FTP server and covers uploads, exclusions, incremental
deploys, dry runs, backups, byte-exact restore of a modified binary file, restore removing added
files, automatic health-check rollback, an upload cut off mid-transfer (live file intact, no temp
file left, retried on the next run), `REMOTE_TEMP_DIR` (nested paths, rename failure keeps the live
file, refusal of a temp dir inside the web root or an unusable one, no silent fallback),
owner-only backups, password secrecy and backup naming. CI runs it on Ubuntu and macOS.

Also verified by hand against netcup shared hosting over FTPS: modify → restore is byte-exact
(checked over FTPS and HTTP); an upload cut after 4 seconds leaves the live file untouched; a
file in `REMOTE_TEMP_DIR` (next to `httpdocs`) was not reachable via four different URL tricks,
and a nested file moved from there into the web root correctly.
Other hosts should work if they speak standard FTP/FTPS with `SIZE`, `RNFR/RNTO` and `DELE`;
reports welcome.

## License

MIT © Yunus Emre Topaloğulları. Born from deploying sites to netcup shared hosting, where a dropped
connection left a half-uploaded `style.css` (99,604 of 160,594 bytes) live on a staging site I maintain.
