#!/usr/bin/env bash
# Verify the legacy fence for an abandoned return WITHOUT PHP or SQL (replatform runbook V504, V601, V704, H3).
# Read-only: only `oc get`.
#
#   verify-legacy-fenced.sh <namespace>
#
# The invariant is by backend: no Route in the namespace reaches a Service that selects legacy web or php pods
# (Routes on the fence page or on the new stack both satisfy it); legacy cron is desired at 0 with 0 pods; and no legacy
# Job that runs Moodle code is active. It stops NEW ingress only: requests legacy already accepted may still be running
# (V702), which is why legacy-cleanup.sh starts with a drain.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/legacy-services.sh"
NS=${1:?namespace}
fail=0
check() { if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s: %s\n' "$1" "$3"; fail=1; fi; }

services=$(legacy_services "$NS")
echo "Services reaching legacy web/php: $(echo $services)"
routed=""
while IFS=$'\t' read -r route backends; do
  for b in $backends; do grep -qx "$b" <<< "$services" && routed="$routed $route->$b"; done
done < <(oc get routes -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.to.name}{" "}{range .spec.alternateBackends[*]}{.name}{" "}{end}{"\n"}{end}')
check "no Route reaches legacy" "$([ -z "$routed" ]; echo $?)" "$routed"

desired=$(oc get deploy cron -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo missing)
# Count pods by the Deployment's own selector: legacy's pod labels differ between Deployments.
csel=$(oc get deploy cron -n "$NS" -o json 2>/dev/null | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')
pods=$( [ -n "$csel" ] && oc get pods -n "$NS" -l "$csel" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
check "legacy cron desired 0, no pods" "$([ "$desired" = 0 ] && [ "$pods" = 0 ]; echo $?)" "desired=$desired pods=$pods"

# Legacy Jobs that run Moodle code are the ones using legacy's code volume.
active=$(oc get jobs -n "$NS" -o json | jq -r '.items[] | select((.status.active // 0) > 0)
  | select(any(.spec.template.spec.volumes[]?; .persistentVolumeClaim.claimName == "moodle-app-data")) | .metadata.name')
check "no active legacy Moodle Job" "$([ -z "$active" ]; echo $?)" "$(echo $active)"

[ "$fail" -eq 0 ] && echo "LEGACY FENCED (new ingress stopped)" || { echo "LEGACY NOT FENCED"; exit 1; }
