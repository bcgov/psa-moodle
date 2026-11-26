#!/usr/bin/env bash
# moodledata copy (runbook O1, RB07, §13.2, §14.4): legacy moodle-data → the new stack's moodledata volume, per
# ops/replatform/dataroot-inventory.md. Runs in the ops image as a Job (ops/replatform/moodledata-copy-job.yaml), or
# locally against two directories. Never writes to the source: the Job mounts it read-only.
#
#   SRC=/src DST=/dst LIST=/list/referenced.tsv KNOWN=/list/known-missing.txt moodledata-copy.sh
#
#   LIST   referenced-files.sql's output against the final dump (hash, min size, max size)
#   KNOWN  the frozen source's own missing hashes (expected-differences.md, "Files"); they are not copied
#
# 1. Refuses if the source's top level has an entry dataroot-inventory.md doesn't list.
# 2. Copies referenced filedir content only (rsync --files-from), then lang/, secret/ and
#    psaelmsync_apitest_state.json when present; key files stay 0400. Re-running resumes: rsync skips what is already there.
# 3. Checks: lang/ and secret/ checksums equal on both sides; check-filedir.sh on the target with KNOWN.
# Prints hashes and counts only. Exit 0 only if every check passes.
set -euo pipefail
SRC=${SRC:-/src}; DST=${DST:-/dst}; LIST=${LIST:-/list/referenced.tsv}; KNOWN=${KNOWN:-/list/known-missing.txt}
HERE=$(cd "$(dirname "$0")" && pwd)
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "FAIL: $*"; exit 1; }
[ -d "$SRC/filedir" ] || die "no filedir under $SRC"
[ -d "$DST" ] && [ -w "$DST" ] || die "target $DST is not a writable directory"

# 1. Reviewed top-level entries (dataroot-inventory.md, 2026-11-26). climaintenance.html is legacy's CLI maintenance
#    page, present at every freeze (E1): allowed and never copied (Pass B window 1 stopped here without it).
allowed=" filedir lang secret psaelmsync_apitest_state.json antivirus_quarantine .quarantine-20260826T190745Z muc climaintenance.html \
trashdir cache localcache temp sessions lock .htaccess vendor cdata_tools persistent cdata.json models \
8a67be2eed31256bcc24e02d4b9ab5ad "
unlisted=$(cd "$SRC" && ls -A | while IFS= read -r e; do case "$allowed" in *" $e "*) ;; *) printf '%s ' "$e" ;; esac; done)
[ -z "$unlisted" ] || die "source has entries not in dataroot-inventory.md: $unlisted(review them first)"
log "source top level: every entry is in the inventory"

# 2. Copy.
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
grep -v '^\s*#' "$KNOWN" 2>/dev/null | awk 'NF {print $1}' | sort -u > "$work/known" || true
awk -v K="$work/known" 'FILENAME == K {k[$1] = 1; next} NF && !($1 in k) {
  printf "filedir/%s/%s/%s\n", substr($1, 1, 2), substr($1, 3, 2), $1 }' "$work/known" "$LIST" > "$work/paths"
log "filedir: copying $(wc -l < "$work/paths" | tr -d ' ') referenced files ($(wc -l < "$work/known" | tr -d ' ') known missing at the source, skipped)"
rsync -rlt --files-from="$work/paths" "$SRC/" "$DST/"
for d in lang secret; do
  if [ -d "$SRC/$d" ]; then mkdir -p "$DST/$d"; rsync -rlt "$SRC/$d/" "$DST/$d/"; fi
done
# Moodle keeps its key in secret/key/<method>.key, mode 0400 (lib/classes/encryption.php); keep it so.
[ ! -d "$DST/secret" ] || find "$DST/secret" -type f -name '*.key' -exec chmod 0400 {} +
[ ! -f "$SRC/psaelmsync_apitest_state.json" ] || rsync -t "$SRC/psaelmsync_apitest_state.json" "$DST/"
log "copied lang/, secret/ (*.key 0400) and the psaelmsync API-test state if present"

# 3. Checks.
sums() { (cd "$1" && find lang secret psaelmsync_apitest_state.json -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"; done); }
[ "$(sums "$SRC")" = "$(sums "$DST")" ] || die "lang/, secret/ or the API-test state differ between source and target"
log "lang/, secret/ and the API-test state: $(sums "$DST" | wc -l | tr -d ' ') file(s), identical on both sides"
"$HERE/check-filedir.sh" "$DST/filedir" "$LIST" "$work/known" || die "check-filedir on the target"
log "moodledata copy complete and verified"
