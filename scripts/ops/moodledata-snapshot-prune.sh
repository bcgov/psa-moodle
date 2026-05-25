#!/usr/bin/env bash
# moodledata-snapshot-prune.sh — delete VolumeSnapshots older than RETENTION_DAYS.

set -euo pipefail

: "${TARGET_NAMESPACE:?TARGET_NAMESPACE not set}"
: "${SOURCE_PVC:?SOURCE_PVC not set}"
: "${RETENTION_DAYS:=14}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" ; }

cutoff_epoch=$(( $(date -u +%s) - RETENTION_DAYS * 86400 ))

# List snapshots labeled as ours, with creationTimestamp.
oc -n "$TARGET_NAMESPACE" get volumesnapshot \
  -l "psa-moodle/source-pvc=$SOURCE_PVC" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}' \
  | while IFS=$'\t' read -r name created; do
    [ -z "$name" ] && continue
    created_epoch="$(date -u -d "$created" +%s)"
    if [ "$created_epoch" -lt "$cutoff_epoch" ]; then
      log "Deleting $name (created $created, older than ${RETENTION_DAYS}d)"
      oc -n "$TARGET_NAMESPACE" delete volumesnapshot "$name" --ignore-not-found
    fi
  done

log "Prune complete."
