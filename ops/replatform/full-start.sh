#!/usr/bin/env bash
# Reverse of full-shutdown.sh (replatform runbook S13). CHANGES THE CLUSTER: each run needs approval.
#
#   full-start.sh <namespace> <release> <chart dir>
#
# 1. `helm upgrade --reuse-values --set postgres.shutdown=false` (still fenced), and waits for a Ready primary.
# 2. writer-unfence.sh: the normal profile; web and php ready. Public Routes are restored separately, from the named
#    state capture, exactly as writer-unfence.sh says.
set -euo pipefail
NS=${1:?namespace}; REL=${2:?release}; CHART=${3:?chart dir}
HERE=$(cd "$(dirname "$0")" && pwd)
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

pg=$(oc get postgrescluster -n "$NS" -l "app.kubernetes.io/instance=$REL" -o jsonpath='{.items[0].metadata.name}')
[ -n "$pg" ] || { echo "no PostgresCluster for release $REL in $NS" >&2; exit 1; }
log "starting Postgres ($pg)"
helm upgrade "$REL" "$CHART" -n "$NS" --reuse-values --set postgres.shutdown=false
primary="postgres-operator.crunchydata.com/cluster=$pg,postgres-operator.crunchydata.com/role in (master,primary)"
for _ in $(seq 1 90); do
  oc get pods -n "$NS" -l "$primary" --no-headers 2>/dev/null | grep -q . && break
  sleep 10
done
oc wait pod -n "$NS" -l "$primary" --for=condition=Ready --timeout=10m
log "Postgres primary ready; lifting the writer fence"
"$HERE/writer-unfence.sh" "$NS" "$REL" "$CHART"
log "full start complete"
