#!/usr/bin/env bash
# Build context for Containerfile.php-exact (runbook C10): the legacy code copy, minus what the new stack doesn't carry.
#   prepare-exact-context.sh <legacy html copy> <output folder>
# Removed: local/githubsync (G1, E7) and the top-level entries that aren't part of upstream Moodle at legacy's commit
# (checked 2026-11-25 against moodle/moodle 32d78752): config/, example.versions.env, info/ (a PHP config checker),
# last_migration_timestamp, migrate-courses/, openshift/ and vendor/ (Composer dev files; Moodle loads it only for
# developer-mode error pages). favicon.ico is kept. config.php is psa-moodle's config.openshift.php.
set -euo pipefail
SRC=${1:?legacy html copy}
OUT=${2:?output folder}
HERE=$(cd "$(dirname "$0")" && pwd)
umask 077
mkdir -p "$OUT/html"
rsync -a --delete \
  --exclude=/local/githubsync --exclude=/config --exclude=/example.versions.env --exclude=/info \
  --exclude=/last_migration_timestamp --exclude=/migrate-courses --exclude=/openshift --exclude=/vendor \
  --exclude=/config.php "$SRC/" "$OUT/html/"
cp "$HERE/../../config/moodle/config.openshift.php" "$OUT/config.php"
(cd "$OUT/html" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) > "$OUT/code.sha256"
echo "$(wc -l < "$OUT/code.sha256" | tr -d ' ') files in $OUT/html; release: $(grep -E '^\s*\$release' "$OUT/html/version.php")"
