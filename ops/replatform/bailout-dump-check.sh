#!/usr/bin/env bash
# Check a return dump before it goes anywhere near legacy (replatform runbook §8.3 Return, RB13, §8.4 step 6).
#
#   bailout-dump-check.sh <dump.sql[.gz]>
#
# Accepts only what `mariadb-dump <one database>` writes (no --databases): every statement outside row data must be one
# of the allowed forms below, with unqualified table names. Rejected: USE, CREATE/DROP DATABASE, triggers, routines,
# views, events, DEFINER clauses, GRANTs, DELIMITER, and any schema-qualified name. Each INSERT line must parse as
# exactly one complete statement with literal values (V1014), so nothing can ride after the row data. Row data is
# never printed. Reports the table count, the table list and the file's SHA-256. Exit 0 = accepted, 1 = rejected.
set -euo pipefail
DUMP=${1:?dump file}
case "$DUMP" in *.gz) CAT=(gzip -dc) ;; *) CAT=(cat) ;; esac

# Every statement is parsed whole (dump-statements.py, V1014): an INSERT line must be one complete statement.
HERE=$(cd "$(dirname "$0")" && pwd)
set +e
"${CAT[@]}" "$DUMP" | python3 -I "$HERE/dump-statements.py" "${DUMP%.gz}.tables.txt"
status=${PIPESTATUS[1]}
set -e
echo "sha256: $(shasum -a 256 "$DUMP" | cut -d' ' -f1)"
[ "$status" -eq 0 ] && echo "ACCEPTED" || echo "REJECTED"
exit "$status"
