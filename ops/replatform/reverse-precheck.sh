#!/usr/bin/env bash
# Return precheck (runbook RB08, §14.0): find values that are distinct in Postgres but would collide in a unique index
# under legacy's utf8mb4_unicode_ci, which ignores case and accents ('cafe' = 'Café'). Such rows make the reverse
# tool_dbtransfer stop (proven 2026-11-25: "Duplicate entry ... for key 'tag_tagnam_uix'").
#
#   reverse-precheck.sh <postgres container> [database]
#
# Uses an ICU collation at primary strength, the closest Postgres equivalent of utf8mb4_unicode_ci. It is an early
# warning, not proof: the two implement different Unicode versions, so the reverse import itself remains the final check.
# Output: index, the colliding key with values masked to their length, and the number of rows; never the values.
# Exit 1 if any collision is found.
set -euo pipefail
PG=${1:?postgres container}
DB=${2:-moodle}
psql() { podman exec -i "$PG" psql -U moodle -d "$DB" -v ON_ERROR_STOP=1 -AtF $'\t' "$@"; }

psql -c "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_collation WHERE collname = 'rp_ci_ai') THEN
    CREATE COLLATION rp_ci_ai (provider = icu, locale = 'und-u-ks-level1', deterministic = false);
  END IF; END \$\$;" >/dev/null

# Unique indexes (not the primary key) with at least one text-like column.
INDEXES=()
while IFS= read -r l; do INDEXES+=("$l"); done < <(psql -c "
  SELECT i.relname, t.relname,
         string_agg(CASE WHEN ty.typcategory = 'S' THEN quote_ident(a.attname) || ' COLLATE rp_ci_ai'
                         ELSE quote_ident(a.attname) END, ', ' ORDER BY k.ord),
         string_agg(quote_ident(a.attname) || ' IS NOT NULL', ' AND ' ORDER BY k.ord)
  FROM pg_index x
  JOIN pg_class i ON i.oid = x.indexrelid
  JOIN pg_class t ON t.oid = x.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = 'public'
  CROSS JOIN LATERAL unnest(x.indkey) WITH ORDINALITY AS k(attnum, ord)
  JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
  JOIN pg_type ty ON ty.oid = a.atttypid
  WHERE x.indisunique AND NOT x.indisprimary
  GROUP BY i.relname, t.relname
  HAVING bool_or(ty.typcategory = 'S')
  ORDER BY 1")

found=0
for line in "${INDEXES[@]}"; do
  IFS=$'\t' read -r index table cols notnull <<< "$line"
  # A unique index never conflicts on NULL, in either database, so rows with a NULL key column are left out.
  n=$(psql -c "SELECT count(*) FROM (SELECT 1 FROM $table WHERE $notnull GROUP BY $cols HAVING count(*) > 1) d")
  if [ "$n" -gt 0 ]; then
    found=1
    echo "COLLISION  $index on $table ($cols): $n key(s)"
  fi
done
[ "$found" -eq 0 ] && echo "no collisions in ${#INDEXES[@]} unique indexes with text columns"
exit "$found"
