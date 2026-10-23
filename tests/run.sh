#!/usr/bin/env bash
# End-to-end tests against a real local FTP server (pyftpdlib). Requires: python3 -m pip install pyftpdlib
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/ftp-safe-deploy"
WORK="$(mktemp -d)"; SERVER="$WORK/server"; SITE="$WORK/site"
PORT="${FSD_TEST_PORT:-2121}"
mkdir -p "$SERVER/www" "$SITE"
pass=0; fail=0

python3 -m pyftpdlib -p "$PORT" -u tester -P secret -d "$SERVER" -w >"$WORK/ftpd.log" 2>&1 &
FTPD=$!
trap 'kill $FTPD 2>/dev/null; wait $FTPD 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 1 50); do (echo >"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break; sleep 0.1; done

ok()   { pass=$((pass + 1)); echo "  ok   $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cd "$SITE" || exit 1
cat > .ftpdeploy <<EOF
FTP_HOST=127.0.0.1
FTP_PORT=$PORT
FTP_USER=tester
REMOTE_DIR=www
PROTOCOL=ftp
EXCLUDE=*.log secret/*
EOF
export FTP_PASSWORD=secret
echo "<?php echo 'v1';" > index.php
mkdir -p css secret; echo "body{color:red}" > css/app.css; echo "x" > debug.log; echo "key" > secret/k.txt

echo "first deploy"
"$TOOL" > "$WORK/out1" 2>&1
check "uploads files"                 '[ "$(cat "$SERVER/www/index.php")" = "<?php echo '"'"'v1'"'"';" ]'
check "creates nested dirs"           '[ -f "$SERVER/www/css/app.css" ]'
check "honours EXCLUDE"               '[ ! -e "$SERVER/www/debug.log" ] && [ ! -e "$SERVER/www/secret/k.txt" ]'
check "leaves no temp files"           '[ -z "$(find "$SERVER" -name ".fsd-*")" ]'
check "records absent files"          'grep -q "^absent	index.php" .deploy-backups/*/manifest'

echo "incremental deploy"
"$TOOL" > "$WORK/out2" 2>&1
check "nothing changed -> no upload"  'grep -q "Nothing changed" "$WORK/out2"'
echo "<?php echo 'v2';" > index.php
"$TOOL" --dry-run > "$WORK/out3" 2>&1
check "dry run uploads nothing"       'grep -q "v1" "$SERVER/www/index.php"'
check "dry run lists only the change" 'grep -q "index.php" "$WORK/out3" && ! grep -q "app.css" "$WORK/out3"'
"$TOOL" > "$WORK/out4" 2>&1
check "uploads only changed file"     'grep -q "v2" "$SERVER/www/index.php" && ! grep -q "app.css" "$WORK/out4"'
check "backs up previous live file"   'grep -rq "v1" .deploy-backups/*/files/index.php'

echo "restore"
"$TOOL" restore > "$WORK/out5" 2>&1
check "restore brings back v1"        'grep -q "v1" "$SERVER/www/index.php"'

echo "health check rollback"
echo "<?php echo 'v3';" > index.php
echo "HEALTH_URLS=http://127.0.0.1:9/never-up" >> .ftpdeploy
"$TOOL" > "$WORK/out6" 2>&1
# shellcheck disable=SC2034  # rc is read inside the eval in check()
rc=$?
check "failing health exits non-zero" '[ $rc -ne 0 ]'
check "auto rollback restores live"   'grep -q "v1" "$SERVER/www/index.php"'
sed -i.bak '/HEALTH_URLS/d' .ftpdeploy && rm -f .ftpdeploy.bak

echo "new file removed on restore"
echo "new" > added.txt
"$TOOL" added.txt > "$WORK/out7" 2>&1
check "new file uploaded"             '[ -f "$SERVER/www/added.txt" ]'
"$TOOL" restore > "$WORK/out8" 2>&1
check "restore removes new file"      '[ ! -e "$SERVER/www/added.txt" ]'

echo "byte-exact restore of an existing (binary) file"
head -c 300000 /dev/urandom > blob.bin; cp blob.bin "$WORK/blob.A"
"$TOOL" blob.bin > "$WORK/out10" 2>&1
head -c 300000 /dev/urandom > blob.bin
"$TOOL" blob.bin > "$WORK/out11" 2>&1
check "B is live after update"        '! cmp -s "$SERVER/www/blob.bin" "$WORK/blob.A"'
"$TOOL" restore > "$WORK/out12" 2>&1
check "restore gives byte-exact A"    'cmp -s "$SERVER/www/blob.bin" "$WORK/blob.A"'

echo "interrupted upload"
printf 'A' > big.bin; "$TOOL" big.bin > "$WORK/out13" 2>&1
head -c 2000000 /dev/urandom > big.bin
echo "CURL_EXTRA=--limit-rate 100k --max-time 3" >> .ftpdeploy
"$TOOL" big.bin > "$WORK/out14" 2>&1
# shellcheck disable=SC2034  # rc2 is read inside the eval in check()
rc2=$?
sed -i.bak '/CURL_EXTRA/d' .ftpdeploy && rm -f .ftpdeploy.bak
check "cut upload exits non-zero"     '[ $rc2 -ne 0 ] && grep -q "upload failed" "$WORK/out14"'
check "live file stays intact"        '[ "$(cat "$SERVER/www/big.bin")" = "A" ]'
check "no temp file left on server"   '[ -z "$(find "$SERVER" -name ".fsd-*")" ]'
check "failed deploy is retried"      '"$TOOL" > "$WORK/out15" 2>&1 && grep -q "big.bin" "$WORK/out15" && cmp -s "$SERVER/www/big.bin" big.bin'

echo "REMOTE_TEMP_DIR outside the web root"
echo "REMOTE_TEMP_DIR=tmp" >> .ftpdeploy
mkdir -p sub/deep; echo "nested" > sub/deep/n.txt
"$TOOL" sub/deep/n.txt > "$WORK/out16" 2>&1
check "lands in place via temp dir"   '[ "$(cat "$SERVER/www/sub/deep/n.txt")" = nested ]'
check "no temp files in web root"     '[ -z "$(find "$SERVER/www" -name ".fsd-*")" ]'
check "temp dir left empty"           '[ -z "$(find "$SERVER/tmp" -type f)" ]'
check "no web-root warning when set"  '! grep -q "REMOTE_TEMP_DIR is not set" "$WORK/out16"'

echo "rename failure keeps live file"
mkdir -p locked; echo "old" > locked/x.txt; "$TOOL" locked/x.txt > "$WORK/out17" 2>&1
echo "new" > locked/x.txt; chmod 555 "$SERVER/www/locked"
"$TOOL" locked/x.txt > "$WORK/out18" 2>&1
chmod 755 "$SERVER/www/locked"
check "rename failure is reported"    'grep -q "rename into place failed" "$WORK/out18"'
check "live file unchanged"           '[ "$(cat "$SERVER/www/locked/x.txt")" = old ]'
check "temp cleaned after failure"    '[ -z "$(find "$SERVER" -name ".fsd-*")" ]'

echo "unsafe or unusable temp dir is refused"
sed -i.bak 's#^REMOTE_TEMP_DIR=.*#REMOTE_TEMP_DIR=www/tmp#' .ftpdeploy && rm -f .ftpdeploy.bak
echo "v9" > locked/x.txt
"$TOOL" locked/x.txt > "$WORK/out19" 2>&1
check "temp dir inside web root fails" 'grep -q "inside REMOTE_DIR" "$WORK/out19" && [ "$(cat "$SERVER/www/locked/x.txt")" = old ]'
printf 'file' > "$SERVER/blocked"
sed -i.bak 's#^REMOTE_TEMP_DIR=.*#REMOTE_TEMP_DIR=blocked/tmp#' .ftpdeploy && rm -f .ftpdeploy.bak
"$TOOL" locked/x.txt > "$WORK/out20" 2>&1
check "unusable temp dir fails"       'grep -q "not usable" "$WORK/out20" && [ "$(cat "$SERVER/www/locked/x.txt")" = old ]'
check "no silent fallback to web root" '[ -z "$(find "$SERVER/www" -name ".fsd-*")" ]'
sed -i.bak '/REMOTE_TEMP_DIR/d' .ftpdeploy && rm -f .ftpdeploy.bak
echo "old" > locked/x.txt
check "backups are owner-only (700)"  '[ "$(ls -ld .deploy-backups | cut -c1-10)" = drwx------ ]'

echo "safety"
check "password not in process args"  '! grep -q secret "$WORK/out1"'
"$TOOL" list > "$WORK/out9" 2>&1
check "one backup per deploy"         '[ "$(grep -c "file(s)" "$WORK/out9")" -ge 10 ]'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
