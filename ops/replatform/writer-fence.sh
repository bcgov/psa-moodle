#!/usr/bin/env bash
# Writer fence for the new stack (replatform runbook S13, DR04, V501). CHANGES THE CLUSTER: each run needs approval.
#
#   writer-fence.sh <namespace> <release> <chart dir> <fence Service> [<public Route> ...]
#
# 1. Points each named public Route (legacy-owned objects that currently send traffic to the new stack) at the fence
#    Service, dropping alternate backends. The chart's own Route moves with the fenced profile in step 2.
# 2. `helm upgrade --reuse-values` with migration.state=fenced and the fence Service. If Helm fails, scales web, php
#    and cron to 0, suspends the release's CronJobs and deletes its HPAs imperatively, then retries the upgrade once.
# 3. Waits for the pods to go, then runs verify-fenced.sh. Exit 1 unless the fence verifies.
# Postgres keeps running. Nothing here needs the new application to respond.
set -euo pipefail
NS=${1:?namespace}
REL=${2:?release}
CHART=${3:?chart dir}
FENCE=${4:?fence Service}
shift 4
HERE=$(cd "$(dirname "$0")" && pwd)
SEL="app.kubernetes.io/instance=$REL"

oc get svc "$FENCE" -n "$NS" >/dev/null || { echo "fence Service $FENCE not found in $NS" >&2; exit 1; }
port=$(oc get svc "$FENCE" -n "$NS" -o jsonpath='{.spec.ports[0].targetPort}')

for route in "$@"; do
  echo "Route $route -> $FENCE:$port"
  oc patch route "$route" -n "$NS" --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/to\",\"value\":{\"kind\":\"Service\",\"name\":\"$FENCE\",\"weight\":100}},
    {\"op\":\"replace\",\"path\":\"/spec/port\",\"value\":{\"targetPort\":$( [[ $port =~ ^[0-9]+$ ]] && echo "$port" || echo "\"$port\"" )}}]"
  oc patch route "$route" -n "$NS" --type=json -p '[{"op":"remove","path":"/spec/alternateBackends"}]' 2>/dev/null || true
done

upgrade() {
  helm upgrade "$REL" "$CHART" -n "$NS" --reuse-values \
    --set migration.state=fenced --set migration.fenceService="$FENCE" --set migration.fencePort="$port"
}
if ! upgrade; then
  echo "helm upgrade failed: fencing imperatively, then retrying" >&2
  for c in web php cron; do oc scale deploy -n "$NS" -l "$SEL,app.kubernetes.io/component=$c" --replicas=0; done
  for cj in $(oc get cronjobs -n "$NS" -l "$SEL" -o name); do oc patch "$cj" -n "$NS" --type=merge -p '{"spec":{"suspend":true}}'; done
  oc delete hpa -n "$NS" -l "$SEL" --ignore-not-found
  upgrade || echo "helm upgrade failed again: the imperative fence stands; fix Helm before any further upgrade" >&2
fi

for _ in $(seq 1 60); do
  [ "$(oc get pods -n "$NS" -l "$SEL,app.kubernetes.io/component in (web,php,cron)" --no-headers 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && break
  sleep 5
done
"$HERE/verify-fenced.sh" "$NS" "$REL"
