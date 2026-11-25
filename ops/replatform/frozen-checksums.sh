#!/usr/bin/env bash
# Per-table CHECKSUM TABLE of legacy's frozen `moodle` (replatform runbook §8.3 frozen-checksums, V504, V702).
# Read-only. Taken at `prereturn` (§14.0); compared after any abandoned return, AFTER the consumers are switched back.
#
#   TARGET=galera:<ns>/<pod> frozen-checksums.sh record  <file>
#   TARGET=galera:<ns>/<pod> frozen-checksums.sh compare <file>     exit 1 if any table differs
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/rp-mariadb-target.sh"
MODE=${1:?record|compare}
FILE=${2:?file}
DB=${DB:-moodle}

current() {
  local tables
  tables=$(admin_sql -N -B -e "SELECT CONCAT('\`$DB\`.\`', table_name, '\`') FROM information_schema.tables
                               WHERE table_schema='$DB' AND table_type='BASE TABLE' ORDER BY table_name" | paste -sd, -)
  admin_sql -N -B -e "CHECKSUM TABLE $tables EXTENDED" | sed "s/^$DB\.//" | LC_ALL=C sort
}

case "$MODE" in
  record)
    umask 077; current > "$FILE"
    echo "recorded $(wc -l < "$FILE" | tr -d ' ') tables of $DB in $FILE" ;;
  compare)
    if diff <(LC_ALL=C sort "$FILE") <(current) > "$FILE.diff"; then
      echo "frozen $DB matches the record ($(wc -l < "$FILE" | tr -d ' ') tables)"; rm -f "$FILE.diff"
    else
      echo "FROZEN $DB DIFFERS from the record: $(grep -c '^>' "$FILE.diff") table(s); see $FILE.diff"; exit 1
    fi ;;
  *) echo "record|compare" >&2; exit 2 ;;
esac
