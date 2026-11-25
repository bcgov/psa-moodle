#!/usr/bin/env bash
# Check a return dump before it goes anywhere near legacy (replatform runbook §8.3 Return, RB13, §8.4 step 6).
#
#   bailout-dump-check.sh <dump.sql[.gz]>
#
# Accepts only what `mariadb-dump <one database>` writes (no --databases): every statement outside row data must be one
# of the allowed forms below, with unqualified table names. Rejected: USE, CREATE/DROP DATABASE, triggers, routines,
# views, events, DEFINER clauses, GRANTs, DELIMITER, and any schema-qualified name. Row data inside INSERTs is never
# inspected or printed. Reports the table count, the table list and the file's SHA-256. Exit 0 = accepted, 1 = rejected.
set -euo pipefail
DUMP=${1:?dump file}
case "$DUMP" in *.gz) CAT=(gzip -dc) ;; *) CAT=(cat) ;; esac

"${CAT[@]}" "$DUMP" | LC_ALL=C awk '
  function reject(why) {
    printf "REJECT line %d: %s: %s\n", NR, why, substr($0, 1, 60)
    bad++
  }
  BEGIN { T = "`[A-Za-z0-9_]+`" }                    # an unqualified table name
  increate {                                         # inside CREATE TABLE ( ... ) ENGINE=...;
    if ($0 ~ /^\) ENGINE=[A-Za-z0-9_= ]+.*;$/) { increate = 0; next }
    if ($0 ~ /^  (`[A-Za-z0-9_]+` |PRIMARY KEY |UNIQUE KEY |KEY |FULLTEXT KEY )/) next
    reject("unexpected line inside CREATE TABLE"); next
  }
  /^$/ || /^--/ { next }
  /^INSERT INTO `/ {
    if ($0 ~ ("^INSERT INTO " T " (\\([^)]*\\) )?VALUES ")) { inserts++; next }
    reject("INSERT into a qualified or unexpected target"); next
  }
  /^\/\*M!999999\\- enable the sandbox mode \*\/ *$/ { next }
  /^\/\*![0-9]+ / {                                    # versioned comments: only session SETs and DISABLE/ENABLE KEYS
    if ($0 ~ /(DATABASE|TRIGGER|DEFINER|PROCEDURE|FUNCTION|EVENT|VIEW|GRANT|USE )/) { reject("forbidden statement in versioned comment"); next }
    if ($0 ~ /^\/\*![0-9]+ SET [A-Za-z0-9_@ =,()'\''+:.-]*\*\/;$/) next
    if ($0 ~ ("^/\\*![0-9]+ ALTER TABLE " T " (DISABLE|ENABLE) KEYS \\*/;$")) next
    reject("unexpected versioned comment"); next
  }
  $0 ~ ("^DROP TABLE IF EXISTS " T ";$")        { next }
  $0 ~ ("^CREATE TABLE " T " \\($")              { increate = 1; tables[++ntables] = $3; next }
  $0 ~ ("^LOCK TABLES " T " WRITE;$")            { next }
  /^UNLOCK TABLES;$/                             { next }
  { reject("statement not allowed in a single-database dump") }
  END {
    if (increate) { print "REJECT: dump ends inside a CREATE TABLE"; bad++ }
    for (i = 1; i <= ntables; i++) { gsub(/`/, "", tables[i]); print "table\t" tables[i] > "/dev/stderr" }
    printf "tables: %d, INSERT statements: %d, problems: %d\n", ntables, inserts, bad
    exit (bad > 0 || ntables == 0) ? 1 : 0
  }' 2> >(cut -f2 > "${DUMP%.gz}.tables.txt")
status=$?
echo "sha256: $(shasum -a 256 "$DUMP" | cut -d' ' -f1)"
[ "$status" -eq 0 ] && echo "ACCEPTED" || echo "REJECTED"
exit "$status"
