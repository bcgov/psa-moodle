#!/usr/bin/env bash
# Undo restrict-routes.sh (replatform runbook S15). CHANGES THE CLUSTER with --apply.
#
#   unrestrict-routes.sh <namespace> <state dir> <route> [<route> ...] [--apply]
#
# Puts each Route's ip_whitelist back exactly as restrict-routes.sh recorded it: the old value, or no annotation at all.
# The record is renamed to .restored once the Route reads back correctly. Without --apply: shows the change only.
set -euo pipefail
NS=${1:?namespace}; STATE=${2:?state dir}; shift 2
APPLY=0; routes=()
for a in "$@"; do if [ "$a" = --apply ]; then APPLY=1; else routes+=("$a"); fi; done
[ "${#routes[@]}" -gt 0 ] || { echo "no Routes named" >&2; exit 2; }
KEY=haproxy.router.openshift.io/ip_whitelist
for r in "${routes[@]}"; do
  rec="$STATE/$r.ip_whitelist"
  [ -f "$rec" ] || { echo "no record for $r in $STATE" >&2; exit 1; }
  read -r kind value < "$rec" || true
  case "$kind" in
    ABSENT) arg="$KEY-"; want="" ;;
    VALUE) arg="$KEY=$value"; want="$value" ;;
    *) echo "unreadable record $rec" >&2; exit 1 ;;
  esac
  if [ "$APPLY" -eq 0 ]; then echo "Route $r: would set ${arg}"; continue; fi
  oc annotate route "$r" -n "$NS" "$arg" --overwrite
  got=$(oc get route "$r" -n "$NS" -o jsonpath="{.metadata.annotations.haproxy\.router\.openshift\.io/ip_whitelist}")
  [ "$got" = "$want" ] || { echo "Route $r: annotation reads back as '$got', expected '$want'" >&2; exit 1; }
  mv "$rec" "$rec.restored"
  echo "Route $r: ip_whitelist restored ($kind)"
done
[ "$APPLY" -eq 1 ] || echo "dry run only: rerun with --apply to change the Routes"
