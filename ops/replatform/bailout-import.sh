#!/usr/bin/env bash
# Load a checked return dump into `moodle_bailout` through a restricted account (replatform runbook §8.3 Return, RB13,
# E5, §14.3). CHANGES THE TARGET DATABASE SERVER: each run is an approved E5 step.
#
#   TARGET=galera:<ns>/<pod> bailout-import.sh <dump.sql.gz>     import
#   TARGET=galera:<ns>/<pod> bailout-import.sh --abort           recover an interrupted import: drop moodle_bailout
#                                                                and the import account (the frozen `moodle` is untouched)
# Steps:
#   1. bailout-dump-check.sh must accept the dump.
#   2. Create `moodle_bailout` (utf8mb4_unicode_ci) and the account `moodle_bailout_import`, with privileges on
#      `moodle_bailout`.* ONLY. Refuse if `moodle_bailout` already holds tables this run didn't record creating.
#   3. Load the dump as that account, with `moodle_bailout` as the default database.
#   4. Drop the account.
# Progress is recorded in a private file keyed by target and dump checksum, so a retry can't run against the wrong
# database or a different dump.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/rp-mariadb-target.sh"
STATE_DIR="$HOME/Moodle/private-backups/bailout-import-state"
umask 077; mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/$(echo "$TARGET" | tr '/:' '__').txt"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$STATE"; }

if [ "${1:-}" = "--abort" ]; then
  log "abort: dropping moodle_bailout and moodle_bailout_import"
  admin_sql <<'SQL'
DROP DATABASE IF EXISTS moodle_bailout;
DROP USER IF EXISTS 'moodle_bailout_import'@'%';
SQL
  log "aborted"; exit 0
fi

DUMP=${1:?dump.sql.gz}
"$HERE/bailout-dump-check.sh" "$DUMP" | tail -3
SUM=$(shasum -a 256 "$DUMP" | cut -d' ' -f1)
if [ -s "$STATE" ] && ! grep -q "dump $SUM" "$STATE" && ! grep -q '^.* aborted$' <(tail -1 "$STATE"); then
  echo "progress file $STATE belongs to another dump; finish or --abort that import first" >&2; exit 1
fi
log "dump $SUM target $TARGET"

existing=$(admin_sql -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='moodle_bailout'")
if [ "$existing" != "0" ] && ! grep -q "dump $SUM created moodle_bailout" "$STATE"; then
  echo "moodle_bailout already holds $existing tables that this import didn't create; --abort first if they are disposable" >&2
  exit 1
fi

PW=$(openssl rand -hex 24)
admin_sql <<SQL
CREATE DATABASE IF NOT EXISTS moodle_bailout DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
DROP USER IF EXISTS 'moodle_bailout_import'@'%';
CREATE USER 'moodle_bailout_import'@'%' IDENTIFIED BY '$PW';
GRANT ALL PRIVILEGES ON moodle_bailout.* TO 'moodle_bailout_import'@'%';
SQL
log "dump $SUM created moodle_bailout and moodle_bailout_import (privileges on moodle_bailout.* only)"

printf '[client]\nuser=moodle_bailout_import\npassword=%s\n' "$PW" | put_file /tmp/rp-import.cnf
start=$SECONDS
if gzip -dc "$DUMP" | target_mariadb --defaults-extra-file=/tmp/rp-import.cnf --database=moodle_bailout; then
  log "dump $SUM loaded in $((SECONDS - start))s"
else
  target_rm /tmp/rp-import.cnf
  log "dump $SUM LOAD FAILED after $((SECONDS - start))s; recover with --abort"; exit 1
fi
target_rm /tmp/rp-import.cnf
admin_sql -e "DROP USER IF EXISTS 'moodle_bailout_import'@'%'"
log "dump $SUM import account dropped; moodle_bailout has $(admin_sql -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='moodle_bailout'") tables"
