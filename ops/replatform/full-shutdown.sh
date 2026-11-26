#!/usr/bin/env bash
# Full shutdown of the new stack (replatform runbook S13, DR04). CHANGES THE CLUSTER: each run needs approval.
#
#   full-shutdown.sh <namespace> <release> <chart dir> <fence Service> [<public Route> ...]
#
# 1. writer-fence.sh with the same arguments: Routes to the fence, web/php/cron to 0, CronJobs suspended, verified.
# 2. `helm upgrade --reuse-values --set postgres.shutdown=true`: the operator scales every Postgres workload (instances,
#    repo host) to zero and suspends its backup CronJobs. PVCs and data are kept.
# 3. Waits until no pod of the PostgresCluster remains, then checks spec.shutdown and runs verify-fenced.sh again.
# Reverse: full-start.sh.
set -euo pipefail
NS=${1:?namespace}; REL=${2:?release}; CHART=${3:?chart dir}; FENCE=${4:?fence Service}; shift 4
HERE=$(cd "$(dirname "$0")" && pwd)
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

"$HERE/writer-fence.sh" "$NS" "$REL" "$CHART" "$FENCE" "$@"
pg=$(oc get postgrescluster -n "$NS" -l "app.kubernetes.io/instance=$REL" -o jsonpath='{.items[0].metadata.name}')
[ -n "$pg" ] || { echo "no PostgresCluster for release $REL in $NS" >&2; exit 1; }
log "stopping Postgres ($pg)"
helm upgrade "$REL" "$CHART" -n "$NS" --reuse-values --set postgres.shutdown=true
for _ in $(seq 1 120); do
  # Live pods only: the operator's finished backup Jobs keep their pods, with the same cluster label (Pass A, 2026-11-26).
  n=$(oc get pods -n "$NS" -l "postgres-operator.crunchydata.com/cluster=$pg" \
        --field-selector=status.phase!=Succeeded,status.phase!=Failed --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 0 ] && break
  sleep 5
done
[ "$n" = 0 ] || { echo "Postgres pods still present after 10 minutes: $n" >&2; exit 1; }
[ "$(oc get postgrescluster "$pg" -n "$NS" -o jsonpath='{.spec.shutdown}')" = true ] || { echo "spec.shutdown is not true" >&2; exit 1; }
"$HERE/verify-fenced.sh" "$NS" "$REL"
log "full shutdown: writers fenced and Postgres stopped ($pg); data volumes kept"
