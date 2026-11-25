#!/usr/bin/env bash
# Restore the FILE half of a nightly recovery set onto EMPTY storage (replatform runbook S12, C8, V602, V603).
#
#   restore-set-files.sh <set dir> <empty target dataroot>
#
# Copies the set's filedir into <target>/filedir and its secret/ and lang/ into <target>, never from a running site.
# Checks: the target was empty; every copied file's SHA-1 equals its name; every hash in the set's inventory is present
# apart from the set's recorded source gaps; secret/ and lang/ match the manifest's checksums. Exit 1 on any failure.
# The database half is restored separately to the manifest's restore point (restore-paired.sh).
set -euo pipefail
SET=${1:?set dir}
T=${2:?empty target dataroot}
[ -f "$SET/manifest.json" ] || { echo "no manifest in $SET" >&2; exit 1; }
mkdir -p "$T"
[ -z "$(ls -A "$T" 2>/dev/null)" ] || { echo "target $T is not empty: restore only onto empty storage" >&2; exit 1; }
umask 007
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

log "restoring $(jq -r .set "$SET/manifest.json") into $T"
# The set's directories are read-only by design: create writable ones first, then stream the files alone, so tar
# never recreates a read-only directory before filling it.
(cd "$SET" && find filedir -type d) | while read -r d; do mkdir -p "$T/$d"; done
(cd "$SET" && find filedir -type f) | tar -C "$SET" -T - -cf - | tar -C "$T" -xf -
chmod -R u+w "$T/filedir"
for d in secret lang; do [ -d "$SET/$d" ] && tar -C "$SET" -cf - "$d" | tar -C "$T" -xf -; done

bad=0
n=$(find "$T/filedir" -type f | wc -l | tr -d ' ')
mism=$(find "$T/filedir" -type f -exec sha1sum {} + | awk '{k=split($2,p,"/"); if ($1 != p[k]) print p[k]}' | wc -l | tr -d ' ')
[ "$mism" = 0 ] || { log "FAIL: $mism files whose SHA-1 doesn't match their name"; bad=1; }
# (awk, not busybox `grep -vxF -f`, which matches everything when the gap list is empty)
missing=$(while read -r h; do [ -f "$T/filedir/${h:0:2}/${h:2:2}/$h" ] || echo "$h"; done < "$SET/inventory.txt" \
  | awk -v ex="$SET/source-gaps.txt" 'BEGIN { while ((getline l < ex) > 0) x[l] = 1 } !($1 in x)' | wc -l | tr -d ' ')
[ "$missing" = 0 ] || { log "FAIL: $missing inventory hashes missing (beyond recorded source gaps)"; bad=1; }
for d in secret lang; do
  want=$(jq -r ".durable.${d}_sha256" "$SET/manifest.json")
  have=$( [ -d "$T/$d" ] && (cd "$T" && find "$d" -type f -exec sha256sum {} + | sort | sha256sum | cut -d' ' -f1) || echo "")
  [ "$want" = "$have" ] || { log "FAIL: $d/ differs from the manifest"; bad=1; }
done
log "$n files restored, SHA-1 mismatches $mism, missing beyond source gaps $missing, source gaps $(wc -l < "$SET/source-gaps.txt" | tr -d ' ')"
[ "$bad" = 0 ] && log "files restored and verified" || exit 1
