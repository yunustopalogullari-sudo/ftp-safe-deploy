# Changelog

## 0.1.0 (2026-10-23)
- First release: backup before upload, hidden extension-preserving temp file + size check + rename (temp deleted on failure), health-check rollback,
  `restore` (re-uploads old files, deletes files the deploy added), incremental deploys by SHA-256,
  `--dry-run`, `--all`, `list`, `PASSWORD_CMD`, `PLAIN_FALLBACK_EXT`.
