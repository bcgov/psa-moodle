#!/usr/bin/env bash
# Local forward conversion, legacy MariaDB -> Postgres (runbook §8.3 local-pipeline.sh, §8.4 steps 1-2).
#
# Runs entirely on the laptop, on a Podman network created with --internal (no internet).
# Data, code copies, logs and outputs stay in an owner-only work folder (S9); nothing goes to git.
#
#   local-pipeline.sh <env> <step>
#     env:  prod | test | dev
#     step: prepare-code | schema-check | clean-source | e7-uninstall | normalise-nulls | version-check |
#           start-postgres | migrate | dump | all
#
# Expects (made by the operator, see the runbook):
#   - container rp-mariadb-<env> on network replatform-local, with the environment's dump loaded into `moodle`;
#   - the exact legacy code tree in $CODE_SRC (default ~/Moodle/private-backups/legacy-code-20261125/<env>/html);
#   - the conversion image localhost/psa-moodle-convert:dev (ops/replatform/Containerfile.convert).
set -euo pipefail

ENV_NAME=${1:?env (prod|test|dev)}
STEP=${2:?step}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/Moodle/private-backups/replatform-local-20261125}
CODE_SRC=${CODE_SRC:-$HOME/Moodle/private-backups/legacy-code-20261125/$ENV_NAME/html}
CODE=$WORK/code-$ENV_NAME
SCRATCH=$WORK/dataroot-$ENV_NAME
LOGS=$WORK/logs
NET=replatform-local
MARIA=rp-mariadb-$ENV_NAME
PG=rp-postgres-$ENV_NAME
IMAGE=localhost/psa-moodle-convert:dev
PASS=$(cat "$WORK/.dbpass")
umask 077
mkdir -p "$LOGS" "$SCRATCH"

log() { printf '%s [%s %s] %s\n' "$(date -u +%FT%TZ)" "$ENV_NAME" "$STEP" "$*" | tee -a "$LOGS/pipeline-$ENV_NAME.log" >&2; }
# No -i: an exec that reads stdin would swallow the input of any surrounding `while read` loop.
maria() { podman exec "$MARIA" mariadb -uroot -p"$PASS" -N -B moodle "$@"; }

# Run PHP from the work copy of the exact code, against the source database.
php_src() {
  podman run --rm --network "$NET" --platform linux/arm64 --user 0 \
    -v "$CODE:/var/www/html" -v "$SCRATCH:/data/moodledata" \
    -e SRC_DBTYPE=mariadb -e SRC_DBHOST="$MARIA" -e SRC_DBUSER=root -e SRC_DBPASS="$PASS" -e SRC_PREFIX='' \
    "$IMAGE" php "$@"
}

prepare_code() {
  log "work copy of $CODE_SRC"
  rsync -a --delete "$CODE_SRC/" "$CODE/"
  cp "$HERE/migrate-config.php" "$CODE/config.php"
  podman run --rm --platform linux/arm64 "$IMAGE" sh -c 'php -v | head -1; php -m | tr "\n" " "' >> "$LOGS/runtime-versions.txt"
  log "code version: $(grep -E '^\s*\$release' "$CODE/version.php")"
}

schema_check() {
  log "check_database_schema.php (expect only the §5.2 items)"
  php_src admin/cli/check_database_schema.php > "$LOGS/schema-$ENV_NAME-before.txt" 2>&1 || true
  log "$(wc -l < "$LOGS/schema-$ENV_NAME-before.txt") lines -> $LOGS/schema-$ENV_NAME-before.txt"
}

clean_source() {
  # The reviewed extra tables and the trigger (§5.2, O4). In the LOCAL COPY only.
  local extra
  extra=$(maria -e "SELECT table_name FROM information_schema.tables WHERE table_schema='moodle' AND (
      table_name LIKE 'bht\\_%' OR table_name IN ('course_completion_criteria_log','local_psaelmsync_enrol',
      'local_psaelmsync_logs_backup','local_psaelmsync_logs_backup_20240522','local_psaelmsync_logs_backup2',
      'local_psaelmsync_logs_bad_restore','local_psaelmsync_logs_copy2','local_psaelmsync_logs_muckedup'))")
  log "dropping $(echo "$extra" | grep -c . || true) extra tables and the trigger"
  maria -e "DROP TRIGGER IF EXISTS trg_log_completion_criteria_delete"
  [ -n "$extra" ] && maria -e "DROP TABLE $(echo "$extra" | sed 's/.*/`&`/' | paste -sd, -)"
  log "tables now: $(maria -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='moodle'")"
}

e7_uninstall() {
  # G1/E7: remove local_githubsync with Moodle's own uninstaller, then drop its code (the new image excludes it).
  if [ -n "$(maria -e "SELECT 1 FROM config_plugins WHERE plugin='local_githubsync' LIMIT 1")" ]; then
    log "uninstalling local_githubsync (E7 commands, local copy)"
    php_src admin/cli/uninstall_plugins.php --plugins=local_githubsync --run 2>&1 | tee "$LOGS/e7-$ENV_NAME.txt" >&2
  else
    log "local_githubsync not installed in this copy"
  fi
  rm -rf "$CODE/local/githubsync"
  # uninstall_plugin() blanks allversionshash (lib/adminlib.php), which makes Moodle report "upgrade pending" and
  # stops cron until upgrade.php recomputes it. With every version unchanged, upgrade.php only refreshes the hashes,
  # the cache revision counters and registrationpending (verified on the prod copy, 2026-11-25). E7 needs this step too.
  php_src admin/cli/upgrade.php --non-interactive > "$LOGS/e7-upgrade-$ENV_NAME.txt" 2>&1
  log "$(grep -o 'Command line upgrade.*' "$LOGS/e7-upgrade-$ENV_NAME.txt" | tail -1)"
  log "githubsync rows left: $(maria -e "SELECT COUNT(*) FROM config_plugins WHERE plugin='local_githubsync'")"
}

normalise_nulls() {
  # §5.2 nullable drift: legacy left some XMLDB NOT NULL columns nullable, and a few rows hold NULL. The target is
  # built from XMLDB, so fill those NULLs with Moodle's own default, in the LOCAL COPY only, and record each change
  # for compare-content's expected differences. A NOT NULL column with no default and NULL rows stops the pipeline.
  local out="$LOGS/normalised-nulls-$ENV_NAME.tsv" nullable stop=0
  : > "$out"
  nullable=$(maria -e "SELECT CONCAT(table_name, '.', column_name) FROM information_schema.columns
                       WHERE table_schema='moodle' AND is_nullable='YES'")
  while IFS=$'\t' read -r t c type def; do
    grep -qxF "$t.$c" <<< "$nullable" || continue
    n=$(maria -e "SELECT COUNT(*) FROM \`$t\` WHERE \`$c\` IS NULL" < /dev/null)
    [ "$n" -gt 0 ] || continue
    if [ "$def" = NODEFAULT ]; then
      log "STOP: $t.$c has $n NULL rows and no XMLDB default; decide by hand"; stop=1; continue
    fi
    maria -e "UPDATE \`$t\` SET \`$c\` = '${def//\'/\'\'}' WHERE \`$c\` IS NULL" < /dev/null
    printf '%s\t%s\t%s\t%s\n' "$t" "$c" "$n" "$def" >> "$out"
    log "$t.$c: $n NULL -> '$def'"
  done < <(python3 "$HERE/xmldb-notnull.py" "$CODE")
  [ "$stop" -eq 0 ] || exit 1
  log "normalised $(wc -l < "$out" | tr -d ' ') columns -> $out"
}

version_check() {
  # S7: stop if the database and the code disagree on any version.
  log "upgrade.php --is-pending (exit 0 = nothing pending)"
  if php_src admin/cli/upgrade.php --is-pending > "$LOGS/version-$ENV_NAME.txt" 2>&1; then
    log "versions match"
  else
    log "VERSION MISMATCH, stop (see $LOGS/version-$ENV_NAME.txt)"; exit 1
  fi
}

start_postgres() {
  podman rm -f "$PG" >/dev/null 2>&1 || true
  podman volume rm -f "$PG" >/dev/null 2>&1 || true
  podman run -d --name "$PG" --network "$NET" --platform linux/arm64 -v "$PG:/var/lib/postgresql/data" \
    -e POSTGRES_USER=moodle -e POSTGRES_PASSWORD="$PASS" -e POSTGRES_DB=moodle \
    -e POSTGRES_INITDB_ARGS="--encoding=UTF8 --locale=en_US.UTF-8" \
    docker.io/library/postgres:15.15 -c shared_buffers=1GB -c maintenance_work_mem=512MB \
    -c max_wal_size=4GB -c synchronous_commit=off >/dev/null
  for _ in $(seq 1 60); do podman exec "$PG" pg_isready -U moodle -d moodle >/dev/null 2>&1 && break; sleep 2; done
  sleep 3
  log "postgres: $(podman exec "$PG" psql -U moodle -d moodle -Atc "select version()" | cut -c1-40), collation $(podman exec "$PG" psql -U moodle -d moodle -Atc "select datcollate from pg_database where datname='moodle'")"
}

migrate() {
  log "tool_dbtransfer migrate.php -> pgsql, prefix mdl_"
  local start=$SECONDS
  php_src admin/tool/dbtransfer/cli/migrate.php --dbtype=pgsql --dbhost="$PG" --dbname=moodle \
    --dbuser=moodle --dbpass="$PASS" --prefix=mdl_ > "$LOGS/migrate-$ENV_NAME.txt" 2>&1 \
    || { log "MIGRATE FAILED after $((SECONDS - start))s (see $LOGS/migrate-$ENV_NAME.txt)"; exit 1; }
  log "migrate done in $((SECONDS - start))s"
}

dump() {
  local out="$WORK/$ENV_NAME-postgres-$(date -u +%Y%m%dT%H%M%SZ).dump"
  podman exec "$PG" pg_dump -U moodle -d moodle -Fc > "$out"
  shasum -a 256 "$out" >> "$WORK/SHA256SUMS.txt"
  log "pg_dump -Fc -> $out ($(du -h "$out" | cut -f1))"
}

case "$STEP" in
  prepare-code)   prepare_code ;;
  schema-check)   schema_check ;;
  clean-source)   clean_source ;;
  e7-uninstall)   e7_uninstall ;;
  normalise-nulls) normalise_nulls ;;
  version-check)  version_check ;;
  start-postgres) start_postgres ;;
  migrate)        migrate ;;
  dump)           dump ;;
  all) prepare_code; schema_check; clean_source; e7_uninstall; normalise_nulls; version_check; start_postgres; migrate; dump ;;
  *) echo "unknown step: $STEP" >&2; exit 2 ;;
esac
