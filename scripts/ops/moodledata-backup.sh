#!/usr/bin/env bash
# Nightly moodledata backup with a short writer pause (replatform runbook C8, J1, J2, J4, V801-V804).
#
# Each run, holding a Postgres advisory lock on its own session for the whole run (V803):
#   1. skip if any climaintenance.html exists (an operator's maintenance, or another run's)
#   2. space check and rotation (prune oldest sets, files-only first, never below the floor)
#   3. PAUSE: write climaintenance.html marked with this run; wait until Moodle's database role has had no session on
#      the moodle database for 10 consecutive seconds (no Moodle code is running then). Limit DRAIN_LIMIT seconds.
#      Counted by role and database, which the restricted backup role can see (backend_type it can't; V1001).
#   4. pg_create_restore_point('<set id>'): the set's database target, with its LSN and timeline; then pg_switch_wal()
#      closes its segment, and the live system identifier is read for the gate (V1002)
#   5. inventory: distinct contenthash of every non-directory file record (nothing has changed since step 4)
#   6. capture: copy each inventory hash the previous set lacks, from filedir or trashdir, checking its SHA-1;
#      a hash in neither is a SOURCE GAP (the live site lacks it). Copy secret/ and lang/. Limit CAPTURE_LIMIT.
#   7. REOPEN: remove our climaintenance.html (also on any exit, via trap)
#   8. complete: hard-link every other inventory hash from the previous set; check the SHA-1 of EVERY file in the set,
#      inherited ones included (V1010); a damaged inherited file is fetched again from the live site; coverage check
#   9. database gate (pgbackrest-gate.sh, V1002): this database's repository, a base backup on the restore point's
#      timeline chain, and every WAL segment from it to the restore point's closed segment
#  10. publish: manifest into the staging folder, then one rename into sets/; set files read-only
#  11. retention: mark sets whose database half has expired as files-only; prune above RETAIN; alerts
# During the pause every step is bounded by the time left (V1009), and the run is void if its maintenance file has gone
# (the cron loop removes a backup page older than 15 minutes; the pause is bounded well below that). Any exit that isn't
# a planned skip raises an alert, including shell errors (V1011). The newest usable pair's age is watched separately,
# by moodledata-pair-age.sh (J4).
# It never deletes anything in the live moodledata (J2).
set -euo pipefail
umask 007   # group (gid 0 under OpenShift's restricted SCC) can manage what the job creates; nobody else can

: "${MOODLEDATA:=/moodledata}"            # live dataroot, mounted read-write (only climaintenance.html is written)
: "${DEST:=/backup}"                      # the backup PVC (netapp-file-backup)
: "${APP_DB_USER:=moodle}"                # Moodle's own database role: its sessions mean Moodle code is running
: "${DRAIN_LIMIT:=300}" "${CAPTURE_LIMIT:=300}" "${GATE_LIMIT:=1800}" "${DRAIN_QUIET:=10}"
: "${RETAIN:=7}" "${FLOOR:=3}" "${ALERT_PCT:=70}" "${STALE_STAGING_MINUTES:=180}"
: "${OP_LIMIT:=60}"                      # seconds any single database call may take
: "${LOCK_NS:=1347633474}"               # pg advisory lock, two-integer form: namespace 0x50534142 ("PSAB") ...
: "${LOCK_KEY:=1}"                        # ... and key (V1202). Moodle's database sessions lock single bigint keys (their
                                          # session ids), a separate key space; Moodle's lock factory uses the two-integer
                                          # form under crc32("<dbname>:<prefix>") = 1289808297 for moodle:mdl_, not this.
# pgBackRest repository information, as JSON, from the Crunchy repository host by its fixed name: the
# pgbackrest label also matches the backup Jobs' pods, and this job may exec into the repo host only (C8 RBAC).
: "${PGBACKREST_INFO_CMD:=oc -n ${TARGET_NAMESPACE:-} exec ${POSTGRES_CLUSTER:-}-repo-host-0 -c pgbackrest -- pgbackrest --output=json info}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SET_ID="rp-set-$RUN_ID"
MARK="<!-- rp-backup-fence run=$RUN_ID -->"
FENCE="$MOODLEDATA/climaintenance.html"
STAGE="$DEST/incoming/$RUN_ID"
SETS="$DEST/sets"
# Lines of file $1 whose first field is not a line of file $2. Safe when $2 is empty or missing, unlike busybox
# `grep -vxF -f` (which then matches everything) and awk's two-file idiom (which breaks on an empty first file).
minus() { awk -v ex="$2" 'BEGIN { while ((getline l < ex) > 0) x[l] = 1 } !($1 in x)' "$1"; }
log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$RUN_ID" "$*"; }
alert() { log "ALERT: $1"; command -v alert.sh >/dev/null && [ -n "${ALERT_TO:-}" ] && alert.sh "psa-moodle moodledata backup: $1" "${2:-$1}" || true; }
die() { ALERTED=1; alert "$1" "${2:-}"; exit 1; }
# V1011: an exit that no die() reported (a shell error under set -e, a timeout, a killed command) still alerts.
LAST_ERR=""
trap 'LAST_ERR="line $LINENO: $BASH_COMMAND"' ERR

# ---- one Postgres session for the whole run, holding the advisory lock (V803) ----------------------------------------
# The lock lives on one long session (a coprocess). Its file descriptors don't exist inside $(...), so lock_q returns its
# single-line result in R instead of printing it. Every other query uses its own short session (pq).
coproc PSQL { exec psql -X -q -A -t -v ON_ERROR_STOP=0 2>&1; }
lock_q() {
  local line; R=""
  # The ';' matters: psql runs a backslash command at once but holds an unterminated query, so the marker would
  # otherwise come back before the result.
  printf '%s;\n\\echo __RP_END__\n' "$1" >&"${PSQL[1]}" || return 1
  while IFS= read -r -t 60 line <&"${PSQL[0]}"; do
    [ "$line" = "__RP_END__" ] && return 0
    R="$line"
  done
  return 1
}
pq() { PGOPTIONS="-c statement_timeout=$((OP_LIMIT * 1000))" timeout "$OP_LIMIT" psql -X -q -A -t -v ON_ERROR_STOP=1 -c "$1"; }
# The two-integer form shows in pg_locks as classid=namespace, objid=key, objsubid=2 (a bigint key has objsubid=1).
holds_lock() { lock_q "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=$LOCK_NS AND objid=$LOCK_KEY AND objsubid=2 AND pid=pg_backend_pid() AND granted" && [ "$R" = 1 ]; }
lock_q "SELECT pg_try_advisory_lock($LOCK_NS, $LOCK_KEY)" && [ "$R" = "t" ] || { log "another run holds the lock; exiting"; exit 0; }
guard() { holds_lock || { log "lost the database session or the lock: stopping before '$1'"; exit 1; }; }

reopen() {   # remove OUR maintenance file only
  if [ -f "$FENCE" ] && grep -qF "$MARK" "$FENCE"; then rm -f "$FENCE" && log "reopened"; fi
}
fence_ok() { [ -f "$FENCE" ] && grep -qF "$MARK" "$FENCE"; }
# V1009: run a command bounded by the pause's remaining time (and OP_LIMIT); a lost fence voids the run.
bounded() {   # bounded <label> <command...>
  local what=$1 left=$((pause_deadline - SECONDS)); shift
  [ "$left" -gt "$OP_LIMIT" ] && left=$OP_LIMIT
  [ "$left" -gt 0 ] || { reopen; die "pause limit reached during '$what': skipped tonight"; }
  fence_ok || die "maintenance fence lost during the pause (the site reopened): run void, nothing published"
  timeout "$left" "$@" || { reopen; die "'$what' failed or exceeded its time during the pause: skipped tonight"; }
}
on_exit() {
  local rc=$?
  reopen
  if [ "$rc" != 0 ] && [ -z "${ALERTED:-}" ]; then
    alert "run ended unexpectedly (exit $rc${LAST_ERR:+, $LAST_ERR}): nothing published"
  fi
}
trap on_exit EXIT
trap 'reopen; exit 143' TERM INT

mkdir -p "$SETS" "$DEST/incoming"
prev=$(ls -1 "$SETS" 2>/dev/null | sort | tail -1 || true)
prev_dir=${prev:+$SETS/$prev}
log "previous set: ${prev:-none}"

pq "SELECT 1 FROM mdl_files LIMIT 1" >/dev/null 2>&1 \
  || die "cannot read mdl_files as $(pq 'SELECT current_user' 2>/dev/null || echo 'the backup role'): GRANT SELECT ON mdl_files TO it (the cutover's load step does this)"

# ---- 1. someone else's maintenance: skip ------------------------------------------------------------------------------
if [ -f "$FENCE" ]; then log "climaintenance.html already present (operator or another run): skipping tonight"; exit 0; fi

# ---- stale staging from dead runs (older than any run's deadline) ----------------------------------------------------
find "$DEST/incoming" -mindepth 1 -maxdepth 1 -type d -mmin +"$STALE_STAGING_MINUTES" -exec rm -rf {} + 2>/dev/null || true

# ---- 2. space and rotation ----------------------------------------------------------------------------------------------
guard rotation
pq "SELECT DISTINCT contenthash, filesize FROM mdl_files WHERE filename <> '.'" | tr '|' '\t' | sort > "$DEST/incoming/.sizes-$RUN_ID"
if [ -n "$prev_dir" ]; then
  # (awk, not join/comm: the ops image's busybox has neither)
  delta=$(minus "$DEST/incoming/.sizes-$RUN_ID" "$prev_dir/inventory.txt" | awk -F'\t' '{ s += $2 } END { print s + 0 }')
else
  delta=$(awk -F'\t' '{s+=$2} END{print s+0}' "$DEST/incoming/.sizes-$RUN_ID")
fi
rm -f "$DEST/incoming/.sizes-$RUN_ID"
need() { df -Pk "$DEST" | awk -v d="$delta" 'NR==2 {total=$2*1024; free=$4*1024; exit !(free >= d + total/10)}'; }
while ! need; do
  n=$(ls -1 "$SETS" | wc -l)
  [ "$n" -gt "$FLOOR" ] || die "not enough space for tonight's delta ($delta bytes) even at the floor of $FLOOR sets; grow the backup PVC"
  victim=$(for s in $(ls -1 "$SETS" | sort); do [ -f "$SETS/$s/FILES-ONLY" ] && echo "$s"; done | head -1)
  victim=${victim:-$(ls -1 "$SETS" | sort | head -1)}
  [ "$victim" = "$prev" ] && die "space: would have to prune the newest set"
  chmod -R u+w "$SETS/$victim"; rm -rf "${SETS:?}/$victim"; alert "pruned $victim to make room (retention now below $RETAIN)"
done

# ---- 3. pause and drain -------------------------------------------------------------------------------------------------
guard pause
printf '%s\n<!DOCTYPE html><html><head><title>Back shortly</title></head><body><h1>Nightly backup in progress</h1><p>The site will be back in a few minutes.</p></body></html>\n' "$MARK" > "$FENCE.$RUN_ID.tmp"
mv "$FENCE.$RUN_ID.tmp" "$FENCE"
pause_start=$SECONDS; quiet=0; pause_deadline=$((SECONDS + DRAIN_LIMIT + CAPTURE_LIMIT))
log "paused; draining (sessions of $APP_DB_USER)"
while :; do
  fence_ok || die "maintenance fence lost while draining (the site reopened): skipped tonight"
  # usename and datname are visible to the restricted backup role; backend_type is not (V1001). This session is the
  # backup role's own, so it is never counted.
  n=$(pq "SELECT count(*) FROM pg_stat_activity WHERE usename = '$APP_DB_USER' AND datname = current_database()")
  if [ "$n" = 0 ]; then quiet=$((quiet + 1)); else quiet=0; fi
  [ "$quiet" -ge "$DRAIN_QUIET" ] && break
  [ $((SECONDS - pause_start)) -ge "$DRAIN_LIMIT" ] && { reopen; die "drain limit reached ($n Moodle sessions still open): skipped tonight"; }
  sleep 1
done
drained=$((SECONDS - pause_start)); log "drained in ${drained}s"

# ---- 4. target ------------------------------------------------------------------------------------------------------------
guard target
fence_ok || die "maintenance fence lost before the restore point: skipped tonight"
IFS='|' read -r rp_lsn rp_wal < <(pq "SELECT lsn, pg_walfile_name(lsn) FROM (SELECT pg_create_restore_point('$SET_ID') AS lsn) r")
[ -n "$rp_wal" ] || die "could not create the restore point: skipped tonight"
timeline=$((16#${rp_wal:0:8}))
# Close the segment so it is archived now, not when it fills (V1002). pg_walfile_name maps the returned boundary to the
# segment just completed.
need_wal=$(pq "SELECT pg_walfile_name(pg_switch_wal())")
sysid=$(pq "SELECT system_identifier FROM pg_control_system()")
segsize=$(pq "SELECT setting::bigint * CASE unit WHEN 'B' THEN 1 WHEN 'kB' THEN 1024 WHEN 'MB' THEN 1048576 ELSE 1 END FROM pg_settings WHERE name = 'wal_segment_size'")
log "restore point $SET_ID at $rp_lsn, timeline $timeline, WAL $rp_wal (closed through $need_wal), system $sysid"

# ---- 5. inventory ---------------------------------------------------------------------------------------------------------
mkdir -p "$STAGE/filedir"
pq "SELECT DISTINCT contenthash FROM mdl_files WHERE filename <> '.' ORDER BY 1" > "$STAGE/inventory.txt"
log "inventory: $(wc -l < "$STAGE/inventory.txt") hashes"

# ---- 6. capture -------------------------------------------------------------------------------------------------------------
cap_start=$SECONDS; copied=0; : > "$STAGE/source-gaps.txt"
# To copy: every inventory hash the previous set doesn't actually hold (its inventory minus its source gaps), so a
# hash that was a gap last night is looked for again tonight.
if [ -n "$prev_dir" ]; then
  minus "$prev_dir/inventory.txt" "$prev_dir/source-gaps.txt" > "$STAGE/.prevheld"
  minus "$STAGE/inventory.txt" "$STAGE/.prevheld" > "$STAGE/.new"; rm -f "$STAGE/.prevheld"
else cp "$STAGE/inventory.txt" "$STAGE/.new"; fi
while read -r h; do
  [ $((SECONDS - cap_start)) -ge "$CAPTURE_LIMIT" ] && { reopen; die "capture limit reached after $copied files: skipped tonight"; }
  rel="${h:0:2}/${h:2:2}/$h"; src=""
  [ -f "$MOODLEDATA/filedir/$rel" ] && src="$MOODLEDATA/filedir/$rel"
  [ -z "$src" ] && [ -f "$MOODLEDATA/trashdir/$rel" ] && src="$MOODLEDATA/trashdir/$rel"
  if [ -z "$src" ]; then echo "$h" >> "$STAGE/source-gaps.txt"; continue; fi
  mkdir -p "$STAGE/filedir/${h:0:2}/${h:2:2}"
  bounded "copy $h" cp "$src" "$STAGE/filedir/$rel"
  [ "$(bounded "sha1 $h" sha1sum "$STAGE/filedir/$rel" | cut -d' ' -f1)" = "$h" ] || { reopen; die "SHA-1 mismatch copying $h"; }
  copied=$((copied + 1))
done < "$STAGE/.new"
rm -f "$STAGE/.new"
# tar keeps modes and times without trying to keep the owner (the job isn't root).
for d in secret lang; do
  [ -d "$MOODLEDATA/$d" ] && bounded "copy $d/" sh -c 'tar -C "$1" -cf - "$2" | tar -C "$3" -xf -' _ "$MOODLEDATA" "$d" "$STAGE"
done
captured=$((SECONDS - cap_start))

# ---- 7. reopen ------------------------------------------------------------------------------------------------------------
# The capture counts only if our maintenance file was still in place all through it (V1009).
fence_ok || die "maintenance fence lost during the capture (the site reopened): run void, nothing published"
reopen
pause_total=$((SECONDS - pause_start))
log "pause ${pause_total}s (drain ${drained}s, capture ${captured}s); copied $copied new files"

# ---- 8. complete and check coverage -------------------------------------------------------------------------------------
guard complete
if [ -n "$prev_dir" ]; then
  while read -r h; do
    rel="${h:0:2}/${h:2:2}/$h"
    [ -e "$STAGE/filedir/$rel" ] && continue
    if [ -e "$prev_dir/filedir/$rel" ]; then mkdir -p "$STAGE/filedir/${h:0:2}/${h:2:2}"; ln "$prev_dir/filedir/$rel" "$STAGE/filedir/$rel"; fi
  done < "$STAGE/inventory.txt"
fi
# V1010: check the SHA-1 of every file now in the set, inherited links included. A mismatch is a damaged file in the
# previous set: unlink it here (the previous set is left as it is, and marked) and fetch it again below.
(cd "$STAGE/filedir" && find . -type f -exec sha1sum {} +) | awk '{ n = split($2, p, "/"); if ($1 != p[n]) print p[n] }' \
  | sort -u > "$STAGE/.damaged"
if [ -s "$STAGE/.damaged" ]; then
  while read -r h; do rm -f "$STAGE/filedir/${h:0:2}/${h:2:2}/$h"; done < "$STAGE/.damaged"
  # Sets share content by hard link, so every set holding a damaged hash holds the same damaged bytes: mark each one.
  for s in $(ls -1 "$SETS" | sort); do
    hit=$(while read -r h; do [ -e "$SETS/$s/filedir/${h:0:2}/${h:2:2}/$h" ] && echo "$h"; done < "$STAGE/.damaged")
    [ -n "$hit" ] || continue
    chmod u+w "$SETS/$s"; { date -u +%FT%TZ; echo "$hit"; } >> "$SETS/$s/DAMAGED"; chmod u-w "$SETS/$s"
  done
  alert "$(wc -l < "$STAGE/.damaged" | tr -d ' ') damaged file(s) inherited from ${prev:-the previous set} (every set holding them is marked DAMAGED); fetching them again"
fi
rm -f "$STAGE/.damaged"
while read -r h; do [ -e "$STAGE/filedir/${h:0:2}/${h:2:2}/$h" ] || echo "$h"; done < "$STAGE/inventory.txt" > "$STAGE/.absent"
# A hash the previous set should have held but doesn't (a damaged set) is fetched from the live site now. Content is
# fixed by its hash, so a copy taken after the pause is the same bytes; the SHA-1 check proves it.
healed=0
for h in $(minus "$STAGE/.absent" "$STAGE/source-gaps.txt"); do
  rel="${h:0:2}/${h:2:2}/$h"
  for src in "$MOODLEDATA/filedir/$rel" "$MOODLEDATA/trashdir/$rel"; do
    [ -f "$src" ] || continue
    mkdir -p "$STAGE/filedir/${h:0:2}/${h:2:2}"; cp "$src" "$STAGE/filedir/$rel"
    if [ "$(sha1sum "$STAGE/filedir/$rel" | cut -d' ' -f1)" = "$h" ]; then healed=$((healed + 1)); break; fi
    rm -f "$STAGE/filedir/$rel"
  done
done
[ "$healed" = 0 ] || alert "the previous set lacked $healed file(s) it should hold; fetched from the live site and verified"
while read -r h; do [ -e "$STAGE/filedir/${h:0:2}/${h:2:2}/$h" ] || echo "$h"; done < "$STAGE/inventory.txt" > "$STAGE/.absent"
missing=$(minus "$STAGE/.absent" "$STAGE/source-gaps.txt" | wc -l | tr -d ' '); rm -f "$STAGE/.absent"
[ "$missing" = 0 ] || die "coverage: $missing inventory hashes missing from the set (not source gaps): not published; staging kept at $STAGE"
gaps=$(wc -l < "$STAGE/source-gaps.txt" | tr -d ' ')
known=${KNOWN_GAPS_FILE:-/dev/null}
# Configured but absent (its ConfigMap not created at cutover, Pass B run 2): every source gap then counts as new.
[ -z "${KNOWN_GAPS_FILE:-}" ] || [ -r "$KNOWN_GAPS_FILE" ] \
  || alert "the known-gaps list is configured but missing ($KNOWN_GAPS_FILE): create its ConfigMap from the cutover's list (runbook §13.2)"
newgaps=$(minus "$STAGE/source-gaps.txt" "$known" | wc -l | tr -d ' ')
[ "$newgaps" = 0 ] || alert "live site lacks $newgaps referenced file(s) not in the known list (source gaps; set still published)"

# ---- 9. database gate (V804, V1002) -----------------------------------------------------------------------------------------
gate_start=$SECONDS
while :; do
  verdict=$(pgbackrest-gate.sh "$sysid" "$rp_lsn" "$need_wal" "$segsize" 2>/dev/null || echo "wait gate error")
  case "$verdict" in
    ok*) break ;;
    fail*) die "database gate: ${verdict#fail }: set not published; previous set kept" ;;
  esac
  [ $((SECONDS - gate_start)) -ge "$GATE_LIMIT" ] && die "database gate not met within ${GATE_LIMIT}s (${verdict#wait }): set not published; previous set kept"
  sleep 30
done
read -r _ base_label system_id <<< "$verdict"
log "database gate: base backup $base_label of system $system_id; WAL archived through $need_wal"

# ---- 10. publish --------------------------------------------------------------------------------------------------------------
guard publish
jq -n --arg set "$SET_ID" --arg run "$RUN_ID" --arg sys "$system_id" --argjson tl "$timeline" --arg lsn "$rp_lsn" \
  --arg wal "$rp_wal" --arg need "$need_wal" --arg base "$base_label" --arg inv "$(sha256sum "$STAGE/inventory.txt" | cut -d' ' -f1)" \
  --argjson count "$(wc -l < "$STAGE/inventory.txt")" --argjson gaps "$gaps" --argjson copied "$copied" \
  --argjson pause "$pause_total" --argjson drain "$drained" --argjson capture "$captured" \
  --arg secret "$( [ -d "$STAGE/secret" ] && (cd "$STAGE" && find secret -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1) )" \
  --arg lang "$( [ -d "$STAGE/lang" ] && (cd "$STAGE" && find lang -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1) )" \
  '{set: $set, run: $run, database: {system_identifier: $sys, timeline: $tl, restore_point: $set, lsn: $lsn, wal: $wal,
    wal_archived_through: $need, base_backup: $base, restore: "--type=name --target=\($set) --set=\($base) --target-timeline=\($tl)"},
    inventory: {count: $count, sha256: $inv, source_gaps: $gaps, newly_copied: $copied},
    durable: {secret_sha256: $secret, lang_sha256: $lang},
    pause_seconds: {total: $pause, drain: $drain, capture: $capture}}' > "$STAGE/manifest.json"
chmod -R a-w "$STAGE/filedir"
mv "$STAGE" "$SETS/$SET_ID"
log "published $SET_ID"

# ---- 11. retention and pairing (J4) -----------------------------------------------------------------------------------------
labels=$(eval "$PGBACKREST_INFO_CMD" 2>/dev/null | jq -r '.[0].backup[]?.label' || true)
for s in $(ls -1 "$SETS" | sort); do
  b=$(jq -r .database.base_backup "$SETS/$s/manifest.json" 2>/dev/null || echo "")
  if [ -n "$b" ] && ! grep -qx "$b" <<< "$labels" && [ ! -f "$SETS/$s/FILES-ONLY" ]; then
    chmod u+w "$SETS/$s"; echo "base backup $b expired $(date -u +%FT%TZ)" > "$SETS/$s/FILES-ONLY"; log "$s is now files-only"
  fi
done
while [ "$(ls -1 "$SETS" | wc -l)" -gt "$RETAIN" ]; do
  oldest=$(ls -1 "$SETS" | sort | head -1); chmod -R u+w "$SETS/$oldest"; rm -rf "${SETS:?}/$oldest"; log "rotated out $oldest"
done
used=$(df -Pk "$DEST" | awk 'NR==2 {printf "%d", $3*100/$2}')
[ "$used" -lt "$ALERT_PCT" ] || alert "backup volume ${used}% full (alert at ${ALERT_PCT}%)"
[ "$(ls -1 "$SETS" | wc -l)" -ge "$RETAIN" ] || log "retention: $(ls -1 "$SETS" | wc -l) of $RETAIN sets so far"
log "done: $SET_ID, ${used}% of the volume used"
