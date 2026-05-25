#!/usr/bin/env bash
# restore-rehearsal.sh — Phase 6 weekly restore rehearsal.
#
# Provisions a temporary PostgresCluster CR (`<cluster>-rehearsal`) that
# restores from the primary's pgBackRest repo, waits for it to come up, runs
# a SQL-level smoke test, then tears it down. Catches the failure mode where
# the live DB looks fine but the *backup pipeline* has been silently broken
# (the April 2026 incident).
#
# On any failure: email + exit non-zero.
# On success: email a single-line OK so the team has a heartbeat in the inbox
# and the rehearsal can't go silently stale (the worst-case "we stopped checking").

set -euo pipefail

: "${POSTGRES_CLUSTER:?POSTGRES_CLUSTER not set}"
: "${POSTGRES_USER_NAME:?POSTGRES_USER_NAME not set}"
: "${TARGET_NAMESPACE:?TARGET_NAMESPACE not set}"
: "${POSTGRES_VERSION:?POSTGRES_VERSION not set}"
: "${REHEARSAL_TIMEOUT_SECONDS:=1800}"   # 30 min default

REHEARSAL_NAME="${POSTGRES_CLUSTER}-rehearsal"

REQUIRED_TABLES=(mdl_user mdl_course mdl_sessions mdl_task_adhoc mdl_task_scheduled mdl_task_log mdl_config)
NONZERO_TABLES=(mdl_user mdl_config mdl_task_scheduled)

log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" ; }
fail() {
  log "FAIL: $*"
  /usr/local/bin/alert.sh \
    "psa-moodle [$TARGET_NAMESPACE]: restore rehearsal FAIL" \
    "$(date -u): $*

Recent log:
$(tail -80 "$LOGFILE" 2>/dev/null || echo "(no log)")
"
  cleanup
  exit 1
}

cleanup() {
  log "Cleaning up temporary cluster $REHEARSAL_NAME"
  oc -n "$TARGET_NAMESPACE" delete postgrescluster "$REHEARSAL_NAME" --ignore-not-found --wait=false || true
}
trap 'cleanup' EXIT

LOGFILE="$(mktemp)"

log "Phase 6 restore rehearsal starting (source=$POSTGRES_CLUSTER, target=$REHEARSAL_NAME, ns=$TARGET_NAMESPACE)"

# --- 1. Apply the rehearsal PostgresCluster CR --------------------------------
cat <<EOF | tee -a "$LOGFILE" | oc -n "$TARGET_NAMESPACE" apply -f -
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: $REHEARSAL_NAME
  labels:
    app.kubernetes.io/instance: psa-moodle
    app.kubernetes.io/component: postgres-rehearsal
    psa-moodle/ephemeral: "true"
spec:
  postgresVersion: $POSTGRES_VERSION
  # Restore from the live cluster's pgBackRest repo.
  dataSource:
    postgresCluster:
      clusterName: $POSTGRES_CLUSTER
      repoName: repo1
  instances:
    - name: rehearsal
      replicas: 1
      dataVolumeClaimSpec:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 10Gi
  backups:
    pgbackrest:
      repos:
        - name: repo1
          volume:
            volumeClaimSpec:
              accessModes: [ReadWriteOnce]
              resources:
                requests:
                  storage: 10Gi
EOF

# --- 2. Wait for the rehearsal cluster's primary to be Ready ------------------
log "Waiting up to ${REHEARSAL_TIMEOUT_SECONDS}s for $REHEARSAL_NAME primary..."
deadline=$(( $(date -u +%s) + REHEARSAL_TIMEOUT_SECONDS ))
primary_pod=""
while [ "$(date -u +%s)" -lt "$deadline" ]; do
  primary_pod="$(oc -n "$TARGET_NAMESPACE" get pod \
    -l "postgres-operator.crunchydata.com/cluster=$REHEARSAL_NAME,postgres-operator.crunchydata.com/role=master" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$primary_pod" ]; then
    ready="$(oc -n "$TARGET_NAMESPACE" get pod "$primary_pod" \
      -o jsonpath='{.status.containerStatuses[?(@.name=="database")].ready}' 2>/dev/null || echo false)"
    if [ "$ready" = "true" ]; then
      log "Rehearsal primary ready: $primary_pod"
      break
    fi
  fi
  sleep 15
done
[ -n "$primary_pod" ] || fail "no primary pod appeared within ${REHEARSAL_TIMEOUT_SECONDS}s"

# --- 3. Smoke test inside the rehearsal primary -------------------------------
psql_in_rehearsal() {
  oc -n "$TARGET_NAMESPACE" exec "$primary_pod" -c database -- \
    psql -X -A -t -d "$POSTGRES_USER_NAME" -c "$1"
}

log "Checking required tables exist in restored DB"
for t in "${REQUIRED_TABLES[@]}"; do
  exists="$(psql_in_rehearsal "SELECT to_regclass('public.$t') IS NOT NULL" || true)"
  if [ "$exists" != "t" ]; then
    fail "required table missing in restored DB: $t  (this is exactly the April 2026 failure mode)"
  fi
done

log "Checking canonical tables are non-empty in restored DB"
for t in "${NONZERO_TABLES[@]}"; do
  n="$(psql_in_rehearsal "SELECT count(*) FROM $t" || echo 0)"
  if [ "${n:-0}" -lt 1 ]; then
    fail "canonical table $t has 0 rows in restored DB"
  fi
  log "  $t: $n rows"
done

DURATION=$(( $(date -u +%s) - $(date -u -d "$(oc -n "$TARGET_NAMESPACE" get postgrescluster "$REHEARSAL_NAME" -o jsonpath='{.metadata.creationTimestamp}')" +%s) ))
log "OK: restored cluster came up and passed smoke tests in ${DURATION}s"

# Heartbeat email on success — once a week, intentional.
/usr/local/bin/alert.sh \
  "psa-moodle [$TARGET_NAMESPACE]: restore rehearsal OK (${DURATION}s)" \
  "Weekly restore rehearsal completed.
Source:   $POSTGRES_CLUSTER
Target:   $REHEARSAL_NAME (now being torn down)
Duration: ${DURATION}s

Required tables present, canonical tables non-empty.
"
