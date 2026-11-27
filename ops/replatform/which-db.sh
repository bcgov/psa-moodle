#!/usr/bin/env bash
# Shared proof helpers for bailout-switch.sh and bailout-unswitch.sh (runbook §14.6, V506, DR01). Sourced, not run.
# Needs NS and HERE. Read-only except the short-lived `oc debug` probe pod.
#
#   prove_php <db>    wait until no php pod is terminating, then which-db.php in every php pod; 1 if any is not on <db>
#   prove_cron <db>   a probe pod from cron's own template (cron stays at 0); 1 unless it connects to <db>
#
# Pass B run 2 (2026-11-27) found both proofs broken: the pod list included a pod still terminating after
# `rollout status` returned, and `oc debug -- <command>` does not pass stdin, so the probe's php never got its script.
# The probe now passes which-db.php as `php -r` code (opening tag removed).

prove_php() {
  local want=$1 bad=0 pod out pods
  for _ in $(seq 1 60); do
    [ "$(oc get pods -n "$NS" -l deployment=php -o json | jq '[.items[] | select(.metadata.deletionTimestamp != null)] | length')" = 0 ] && break
    sleep 5
  done
  pods=$(oc get pods -n "$NS" -l deployment=php -o json | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name')
  [ -n "$pods" ] || { echo "   php: no running pod" >&2; return 1; }
  for pod in $pods; do
    out=$(oc exec -i -n "$NS" "$pod" -c php -- php < "$HERE/which-db.php"); echo "   php $pod: $out"
    grep -q "^dbname=$want .*connected=yes" <<< "$out" || bad=1
  done
  return $bad
}

prove_cron() {
  local want=$1 code out
  code=$(sed '1{/^<?php/d;}' "$HERE/which-db.php")
  out=$(oc debug -n "$NS" deploy/cron --one-container -- php -r "$code" 2>/dev/null | grep '^dbname=' || true)
  echo "   cron probe: ${out:-no output}"
  grep -q "^dbname=$want .*connected=yes" <<< "$out"
}
