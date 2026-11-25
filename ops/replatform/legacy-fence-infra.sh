#!/usr/bin/env bash
# Infrastructure-only legacy fence for an abandoned return (replatform runbook V601, H3, §14 "Abandon and resume").
# OpenShift API only: works with legacy PHP or Galera down. CHANGES THE CLUSTER. Dry run unless --apply.
#
#   legacy-fence-infra.sh <namespace> <fence Service> [--apply]
#
# Points every Route that reaches legacy web or php (primary or alternate backend) at the fence Service, scales legacy
# cron to 0, then runs verify-legacy-fenced.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/legacy-services.sh"
NS=${1:?namespace}
FENCE=${2:?fence Service}
APPLY=0; [ "${3:-}" = "--apply" ] && APPLY=1
run() { echo "   $(printf '%q ' "$@")"; if [ "$APPLY" -eq 1 ]; then "$@"; fi; }

oc get svc "$FENCE" -n "$NS" >/dev/null || { echo "fence Service $FENCE not found" >&2; exit 1; }
port=$(oc get svc "$FENCE" -n "$NS" -o jsonpath='{.spec.ports[0].targetPort}')
[[ $port =~ ^[0-9]+$ ]] || port="\"$port\""
services=$(legacy_services "$NS")

while IFS=$'\t' read -r route backends; do
  hit=0; for b in $backends; do grep -qx "$b" <<< "$services" && hit=1; done
  [ "$hit" -eq 1 ] || continue
  echo "Route $route reaches legacy ($backends) -> $FENCE"
  run oc patch route "$route" -n "$NS" --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/to\",\"value\":{\"kind\":\"Service\",\"name\":\"$FENCE\",\"weight\":100}},
    {\"op\":\"replace\",\"path\":\"/spec/port\",\"value\":{\"targetPort\":$port}}]"
  if [ "$APPLY" -eq 1 ]; then
    oc patch route "$route" -n "$NS" --type=json -p '[{"op":"remove","path":"/spec/alternateBackends"}]' 2>/dev/null || true
  fi
done < <(oc get routes -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.to.name}{" "}{range .spec.alternateBackends[*]}{.name}{" "}{end}{"\n"}{end}')

[ "$(oc get deploy cron -n "$NS" -o jsonpath='{.spec.replicas}')" = 0 ] || run oc scale -n "$NS" deploy/cron --replicas=0

if [ "$APPLY" -eq 1 ]; then
  for _ in $(seq 1 30); do
    csel=$(oc get deploy cron -n "$NS" -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
    [ "$(oc get pods -n "$NS" -l "$csel" --no-headers 2>/dev/null | wc -l | tr -d ' ')" = 0 ] && break; sleep 5
  done
  "$HERE/verify-legacy-fenced.sh" "$NS"
else
  echo "dry run: nothing changed"
fi
