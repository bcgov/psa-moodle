#!/usr/bin/env bash
# moodledata-snapshot.sh — daily VolumeSnapshot of the moodledata PVC.
#
# Skips with a warning email (not a hard fail) if the storage class has no
# VolumeSnapshotClass — that's a cluster-config gap, not an application fault,
# and we don't want it to flap during operator-side changes.

set -euo pipefail

: "${TARGET_NAMESPACE:?TARGET_NAMESPACE not set}"
: "${SOURCE_PVC:?SOURCE_PVC not set}"
: "${SNAPSHOT_CLASS:?SNAPSHOT_CLASS not set}"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
SNAP_NAME="${SOURCE_PVC}-${STAMP}"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" ; }

# Verify the snapshot class exists before we try to create against it.
if ! oc get volumesnapshotclass "$SNAPSHOT_CLASS" >/dev/null 2>&1; then
  log "WARN: VolumeSnapshotClass $SNAPSHOT_CLASS not found"
  /usr/local/bin/alert.sh \
    "psa-moodle [$TARGET_NAMESPACE]: moodledata snapshot SKIPPED (no snapshot class)" \
    "VolumeSnapshotClass $SNAPSHOT_CLASS does not exist in the cluster. moodledata snapshots are not being taken. Confirm storage class supports snapshots, or set moodledata.snapshot.enabled=false in values."
  exit 0
fi

log "Creating VolumeSnapshot $SNAP_NAME for PVC $SOURCE_PVC"
cat <<EOF | oc -n "$TARGET_NAMESPACE" apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $SNAP_NAME
  labels:
    app.kubernetes.io/instance: psa-moodle
    app.kubernetes.io/component: moodledata-snapshot
    psa-moodle/source-pvc: $SOURCE_PVC
spec:
  volumeSnapshotClassName: $SNAPSHOT_CLASS
  source:
    persistentVolumeClaimName: $SOURCE_PVC
EOF

log "Submitted. (Snapshot completes asynchronously; check with 'oc get volumesnapshot $SNAP_NAME')"
