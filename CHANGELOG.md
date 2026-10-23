# Changelog

## Unreleased
- Host compatibility report form and compatibility table in the README.

## 0.1.1 (2026-10-23)
- Fix #1: `restore` now removes restored files from `.ftpdeploy-state`, so the next normal deploy
  uploads them again instead of reporting "Nothing changed". Regression tests added.
- Docs: describe the tool as atomic *per file*, not across the whole deploy.

## 0.1.0 (2026-10-23)
- First release: backup before upload, hidden extension-preserving temp file + size check + rename (temp deleted on failure), health-check rollback,
  `restore` (re-uploads old files, deletes files the deploy added), incremental deploys by SHA-256,
  `--dry-run`, `--all`, `list`, `PASSWORD_CMD`, `PLAIN_FALLBACK_EXT`, `REMOTE_TEMP_DIR` (temp uploads
  outside the web root, checked before deploying), owner-only local backups, failed-cleanup reporting.
- Fix: random temp-name generation no longer hangs where SIGPIPE is ignored (found by CI on macOS).
