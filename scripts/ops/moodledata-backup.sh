#!/usr/bin/env bash
# Nightly moodledata backup with a short writer pause (replatform runbook C8, J1, J2, J4, V801-V804).
#
# Each run, holding a Postgres advisory lock on its own session for the whole run (V803):
#   1. skip if any climaintenance.html exists (an operator's maintenance, or another run's)
#   2. space check and rotation (prune oldest sets, files-only first, never below the floor)
#   3. PAUSE: write climaintenance.html marked with this run; wait until Moodle's database role has had no session for
#      10 consecutive seconds (no Moodle code is running then). Limit DRAIN_LIMIT seconds.
#   4. pg_create_restore_point('<set id>'): the set's database target, with its LSN and timeline
#   5. inventory: distinct contenthash of every non-directory file record (nothing has changed since step 4)
#   6. capture: copy each inventory hash the previous set lacks, from filedir or trashdir, checking its SHA-1;
#      a hash in neither is a SOURCE GAP (the live site lacks it). Copy secret/ and lang/. Limit CAPTURE_LIMIT.
#   7. REOPEN: remove our climaintenance.html (also on any exit, via trap)
#   8. complete: hard-link every other inventory hash from the previous set; coverage check
#   9. database gate: pgBackRest shows a backup that finished before the restore point and archived WAL past it
#  10. publish: manifest into the staging folder, then one rename into sets/; set files read-only
#  11. retention: mark sets whose database half has expired as files-only; prune above RETAIN; alerts
# It never deletes anything in the live moodledata (J2).
set -euo pipefail
umask 007   # group (gid 0 under OpenShift's restricted SCC) can manage what the job creates; nobody else can

: "${MOODLEDATA:=/moodledata}"            # live dataroot, mounted read-write (only climaintenance.html is written)
: "${DEST:=/backup}"                      # the backup PVC (netapp-file-backup)
: "${APP_DB_USER:=moodle}"                # Moodle's own database role: its sessions mean Moodle code is running
: "${DRAIN_LIMIT:=300}" "${CAPTURE_LIMIT:=300}" "${GATE_LIMIT:=1800}" "${DRAIN_QUIET:=10}"
: "${RETAIN:=7}" "${FLOOR:=3}" "${ALERT_PCT:=70}" "${STALE_STAGING_MINUTES:=180}"
: "${ALERT_DAYS:=3}" "${ESCALATE_DAYS:=5}"
: "${LOCK_KEY:=727368}"                   # pg advisory lock key shared by every run
# pgBackRest repository information, as JSON. Default: the Crunchy repo host, like backup-integrity.sh.
: "${PGBACKREST_INFO_CMD:=oc -n ${TARGET_NAMESPACE:-} exec \$(oc -n ${TARGET_NAMESPACE:-} get pod -l postgres-operator.crunchydata.com/cluster=${POSTGRES_CLUSTER:-},postgres-operator.crunchydata.com/pgbackrest= -o name | head -1) -c pgbackrest -- pgbackrest --output=json info}"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SET_ID="rp-set-$RUN_ID"
MARK="<!-- rp-backup-fence run=$RUN_ID -->"
FENCE="$MOODLEDATA/climaintenance.html"
STAGE="$DEST/incoming/$RUN_ID"
SETS="$DEST/sets"
log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$RUN_ID" "$*"; }
alert() { log "ALERT: $1"; command -v alert.sh >/dev/null && [ -n "${ALERT_TO:-}" ] && alert.sh "psa-moodle moodledata backup: $1" "${2:-$1}" || true; }
die() { alert "$1" "${2:-}"; exit 1; }

# ---- one Postgres session for the whole run, holding the advisory lock (V803) ----------------------------------------
# The lock lives on one long session (a coprocess). Its file descriptors don't exist inside $(...), so lock_q returns its
# single-line result in R instead of printing it. Every other query uses its own short session (pq).
coproc PSQL { exec psql -X -q -A -t -v ON_ERROR_STOP=0 2>&1; }
lock_q() {
  local line; R=""
  # The ';' matters: psql runs a backslash command at once but holds an unterminated query, so the marker would
  # otherwise come back before the result.
  printf '%s;\n\\echo __RP_END__\n' "$1" >&"${PSQL[1]}" 2>/dev/null || return 1
  while IFS= read -r -t 60 line <&"${PSQL[0]}"; do
    [ "$line" = "__RP_END__" ] && return 0
    R="$line"
  done
  return 1
}
pq() { psql -X -q -A -t -v ON_ERROR_STOP=1 -c "$1"; }
holds_lock() { lock_q "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=$LOCK_KEY AND pid=pg_backend_pid() AND granted" && [ "$R" = 1 ]; }
lock_q "SELECT pg_try_advisory_lock($LOCK_KEY)" && [ "$R" = "t" ] || { log "another run holds the lock; exiting"; exit 0; }
guard() { holds_lock || { log "lost the database session or the lock: stopping before '$1'"; exit 1; }; }

reopen() {   # remove OUR maintenance file only
  if [ -f "$FENCE" ] && grep -qF "$MARK" "$FENCE"; then rm -f "$FENCE" && log "reopened"; fi
}
trap 'reopen' EXIT
trap 'reopen; exit 143' TERM INT

mkdir -p "$SETS" "$DEST/incoming"
prev=$(ls -1 "$SETS" 2>/dev/null | sort | tail -1 || true)
prev_dir=${prev:+$SETS/$prev}
log "previous set: ${prev:-none}"

# ---- 1. someone else's maintenance: skip ------------------------------------------------------------------------------
if [ -f "$FENCE" ]; then log "climaintenance.html already present (operator or another run): skipping tonight"; exit 0; fi

# ---- stale staging from dead runs (older than any run's deadline) ----------------------------------------------------
find "$DEST/incoming" -mindepth 1 -maxdepth 1 -type d -mmin +"$STALE_STAGING_MINUTES" -exec rm -rf {} + 2>/dev/null || true

# ---- 2. space and rotation ----------------------------------------------------------------------------------------------
guard rotation
pq "SELECT DISTINCT contenthash, filesize FROM mdl_files WHERE filename <> '.'" | tr '|' '\t' | sort > "$DEST/incoming/.sizes-$RUN_ID"
if [ -n "$prev_dir" ]; then
  # (awk, not join/comm: the ops image's busybox has neither)
  delta=$(awk -F'\t' 'NR == FNR { seen[$1] = 1; next } !($1 in seen) { s += $2 } END { print s + 0 }' \
    "$prev_dir/inventory.txt" "$DEST/incoming/.sizes-$RUN_ID")
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
pause_start=$SECONDS; quiet=0
log "paused; draining (sessions of $APP_DB_USER)"
while :; do
  n=$(pq "SELECT count(*) FROM pg_stat_activity WHERE usename = '$APP_DB_USER' AND backend_type = 'client backend'")
  if [ "$n" = 0 ]; then quiet=$((quiet + 1)); else quiet=0; fi
  [ "$quiet" -ge "$DRAIN_QUIET" ] && break
  [ $((SECONDS - pause_start)) -ge "$DRAIN_LIMIT" ] && { reopen; die "drain limit reached ($n Moodle sessions still open): skipped tonight"; }
  sleep 1
done
drained=$((SECONDS - pause_start)); log "drained in ${drained}s"

# ---- 4. target ------------------------------------------------------------------------------------------------------------
guard target
IFS='|' read -r rp_lsn rp_wal < <(pq "SELECT lsn, pg_walfile_name(lsn) FROM (SELECT pg_create_restore_point('$SET_ID') AS lsn) r")
timeline=$((16#${rp_wal:0:8}))
log "restore point $SET_ID at $rp_lsn, timeline $timeline, WAL $rp_wal"

# ---- 5. inventory ---------------------------------------------------------------------------------------------------------
mkdir -p "$STAGE/filedir"
pq "SELECT DISTINCT contenthash FROM mdl_files WHERE filename <> '.' ORDER BY 1" > "$STAGE/inventory.txt"
log "inventory: $(wc -l < "$STAGE/inventory.txt") hashes"

# ---- 6. capture -------------------------------------------------------------------------------------------------------------
cap_start=$SECONDS; copied=0; : > "$STAGE/source-gaps.txt"
if [ -n "$prev_dir" ]; then awk 'NR == FNR { seen[$1] = 1; next } !($1 in seen)' "$prev_dir/inventory.txt" "$STAGE/inventory.txt" > "$STAGE/.new"; else cp "$STAGE/inventory.txt" "$STAGE/.new"; fi
while read -r h; do
  [ $((SECONDS - cap_start)) -ge "$CAPTURE_LIMIT" ] && { reopen; die "capture limit reached after $copied files: skipped tonight"; }
  rel="${h:0:2}/${h:2:2}/$h"; src=""
  [ -f "$MOODLEDATA/filedir/$rel" ] && src="$MOODLEDATA/filedir/$rel"
  [ -z "$src" ] && [ -f "$MOODLEDATA/trashdir/$rel" ] && src="$MOODLEDATA/trashdir/$rel"
  if [ -z "$src" ]; then echo "$h" >> "$STAGE/source-gaps.txt"; continue; fi
  mkdir -p "$STAGE/filedir/${h:0:2}/${h:2:2}"
  cp "$src" "$STAGE/filedir/$rel"
  [ "$(sha1sum "$STAGE/filedir/$rel" | cut -d' ' -f1)" = "$h" ] || { reopen; die "SHA-1 mismatch copying $h"; }
  copied=$((copied + 1))
done < "$STAGE/.new"
rm -f "$STAGE/.new"
# tar keeps modes and times without trying to keep the owner (the job isn't root).
for d in secret lang; do [ -d "$MOODLEDATA/$d" ] && tar -C "$MOODLEDATA" -cf - "$d" | tar -C "$STAGE" -xf -; done
captured=$((SECONDS - cap_start))

# ---- 7. reopen ------------------------------------------------------------------------------------------------------------
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
missing=$(while read -r h; do [ -e "$STAGE/filedir/${h:0:2}/${h:2:2}/$h" ] || echo "$h"; done < "$STAGE/inventory.txt" \
  | { grep -vxF -f "$STAGE/source-gaps.txt" || true; } | wc -l | tr -d ' ')   # grep finding nothing is success here
[ "$missing" = 0 ] || die "coverage: $missing inventory hashes missing from the set (not source gaps): not published; staging kept at $STAGE"
gaps=$(wc -l < "$STAGE/source-gaps.txt" | tr -d ' ')
known=${KNOWN_GAPS_FILE:-/dev/null}
newgaps=$({ grep -vxF -f "$known" "$STAGE/source-gaps.txt" 2>/dev/null || true; } | wc -l | tr -d ' ')
[ "$newgaps" = 0 ] || alert "live site lacks $newgaps referenced file(s) not in the known list (source gaps; set still published)"

# ---- 9. database gate (V804) ------------------------------------------------------------------------------------------------
gate_start=$SECONDS
while :; do
  info=$(eval "$PGBACKREST_INFO_CMD" 2>/dev/null || echo '[]')
  verdict=$(jq -r --arg wal "$rp_wal" --arg lsn "$rp_lsn" --argjson tl "$timeline" '
    def lsnnum: split("/") | (.[0] | ascii_downcase | explode | reduce .[] as $c (0; .*16 + (if $c >= 97 then $c - 87 else $c - 48 end))) as $hi
              | (.[1] | ascii_downcase | explode | reduce .[] as $c (0; .*16 + (if $c >= 97 then $c - 87 else $c - 48 end))) as $lo
              | $hi * 4294967296 + $lo;
    (.[0] // {}) as $s
    | ([$s.backup[]? | select((.lsn.stop // "FFFFFFFF/FFFFFFFF" | lsnnum) <= ($lsn | lsnnum))] | last) as $base
    | ([$s.archive[]?.max // empty] | max) as $amax
    | if $base == null then "wait no-base"
      elif ($amax // "") < $wal then "wait archive \($amax // "none") < \($wal)"
      else "ok \($base.label) \($s.db[0]."system-id" // "")" end' <<< "$info")
  case "$verdict" in ok*) break ;; esac
  [ $((SECONDS - gate_start)) -ge "$GATE_LIMIT" ] && die "database gate not met within ${GATE_LIMIT}s ($verdict): set not published; previous set kept"
  sleep 30
done
read -r _ base_label system_id <<< "$verdict"
log "database gate: base backup $base_label, archive covers $rp_wal"

# ---- 10. publish --------------------------------------------------------------------------------------------------------------
guard publish
jq -n --arg set "$SET_ID" --arg run "$RUN_ID" --arg sys "$system_id" --argjson tl "$timeline" --arg lsn "$rp_lsn" \
  --arg wal "$rp_wal" --arg base "$base_label" --arg inv "$(sha256sum "$STAGE/inventory.txt" | cut -d' ' -f1)" \
  --argjson count "$(wc -l < "$STAGE/inventory.txt")" --argjson gaps "$gaps" --argjson copied "$copied" \
  --argjson pause "$pause_total" --argjson drain "$drained" --argjson capture "$captured" \
  --arg secret "$( [ -d "$STAGE/secret" ] && (cd "$STAGE" && find secret -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1) )" \
  --arg lang "$( [ -d "$STAGE/lang" ] && (cd "$STAGE" && find lang -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1) )" \
  '{set: $set, run: $run, database: {system_identifier: $sys, timeline: $tl, restore_point: $set, lsn: $lsn, wal: $wal,
    base_backup: $base, restore: "--type=name --target=\($set) --set=\($base) --target-timeline=\($tl)"},
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
