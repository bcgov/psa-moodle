#!/usr/bin/env bash
# Verify the writer fence WITHOUT SQL (replatform runbook S13 step 3, V502). Read-only: only `oc get`.
#
#   verify-fenced.sh <namespace> <release>
#
# Passes only if, for this Helm release:
#   - web, php and cron Deployments are desired at 0 and have no pods;
#   - no HorizontalPodAutoscaler exists;
#   - no Job is active (the moodledata backup included);
#   - every CronJob is suspended;
#   - no Route in the namespace sends traffic to this release's Services (primary or alternate backends).
# Crunchy's pods and Jobs carry the operator's labels, not the release's, so the database keeps running and isn't
# counted. Repeat after every upgrade made while fenced (V501). Exit 1 on any failure.
set -euo pipefail
NS=${1:?namespace}
REL=${2:?release}
SEL="app.kubernetes.io/instance=$REL"
fail=0
check() { # description, ok(0/1), detail
  if [ "$2" -eq 0 ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s: %s\n' "$1" "$3"; fail=1; fi
}

for c in web php cron; do
  desired=$(oc get deploy -n "$NS" -l "$SEL,app.kubernetes.io/component=$c" -o jsonpath='{range .items[*]}{.spec.replicas}{"\n"}{end}')
  pods=$(oc get pods -n "$NS" -l "$SEL,app.kubernetes.io/component=$c" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  check "$c desired 0, no pods" "$([ -n "$desired" ] && [ -z "$(echo "$desired" | grep -v '^0$')" ] && [ "$pods" -eq 0 ]; echo $?)" \
    "desired=[$(echo $desired)] pods=$pods"
done

hpas=$(oc get hpa -n "$NS" -l "$SEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')
check "no HPA" "$([ "$hpas" -eq 0 ]; echo $?)" "$hpas HPA(s)"

active=$(oc get jobs -n "$NS" -l "$SEL" -o jsonpath='{range .items[?(@.status.active)]}{.metadata.name}{" "}{end}')
check "no active Job" "$([ -z "$active" ]; echo $?)" "$active"

unsuspended=$(oc get cronjobs -n "$NS" -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.suspend}{"\n"}{end}' | grep -v '=true$' || true)
check "every CronJob suspended" "$([ -z "$unsuspended" ]; echo $?)" "$(echo $unsuspended)"

services=$(oc get svc -n "$NS" -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
routed=""
while IFS=$'\t' read -r route backends; do
  for b in $backends; do
    if grep -qx "$b" <<< "$services"; then routed="$routed $route->$b"; fi
  done
done < <(oc get routes -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.to.name}{" "}{range .spec.alternateBackends[*]}{.name}{" "}{end}{"\n"}{end}')
check "no Route reaches the release" "$([ -z "$routed" ]; echo $?)" "$routed"

echo "Not checked here: a leftover backup climaintenance.html needs a pod that mounts moodledata; writer-unfence checks it."
[ "$fail" -eq 0 ] && echo "FENCED" || { echo "NOT FENCED"; exit 1; }
