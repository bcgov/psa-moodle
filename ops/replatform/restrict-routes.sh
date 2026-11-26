#!/usr/bin/env bash
# Restrict named Routes to reviewer addresses (replatform runbook S15, DR08, DR09). CHANGES THE CLUSTER with --apply.
#
#   restrict-routes.sh <namespace> <state dir> "<reviewer IPs or CIDRs, space-separated>" <route> [<route> ...] [--apply]
#
# Sets haproxy.router.openshift.io/ip_whitelist on each Route. Hostnames don't change, so SSO callbacks keep working.
# First records each Route's current value (or its absence) in <state dir>/<route>.ip_whitelist; refuses if a record
# already exists, so the original is never overwritten. Without --apply: shows each change (client-side dry run) only.
# Reverse: unrestrict-routes.sh with the same state dir.
set -euo pipefail
NS=${1:?namespace}; STATE=${2:?state dir}; IPS=${3:?reviewer addresses}; shift 3
APPLY=0; routes=()
for a in "$@"; do if [ "$a" = --apply ]; then APPLY=1; else routes+=("$a"); fi; done
[ "${#routes[@]}" -gt 0 ] || { echo "no Routes named" >&2; exit 2; }
KEY=haproxy.router.openshift.io/ip_whitelist
for ip in $IPS; do
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]] || { echo "not an IPv4 address or CIDR: $ip" >&2; exit 2; }
  case "$ip" in 0.0.0.0/0|0.0.0.0) echo "refusing $ip: that admits everyone" >&2; exit 2 ;; esac
done
umask 077; mkdir -p "$STATE"
for r in "${routes[@]}"; do
  oc get route "$r" -n "$NS" >/dev/null
  if [ "$APPLY" -eq 0 ]; then
    printf 'Route %s: %s="%s" (now: %s)\n' "$r" "$KEY" "$IPS" \
      "$(oc get route "$r" -n "$NS" -o jsonpath="{.metadata.annotations.haproxy\.router\.openshift\.io/ip_whitelist}" || true)"
    oc annotate route "$r" -n "$NS" "$KEY=$IPS" --overwrite --dry-run=client -o name
    continue
  fi
  rec="$STATE/$r.ip_whitelist"
  [ ! -e "$rec" ] || { echo "a record for $r already exists ($rec): unrestrict first, or use a new state dir" >&2; exit 1; }
  oc get route "$r" -n "$NS" -o json | jq -r --arg k "$KEY" 'if .metadata.annotations[$k] == null then "ABSENT" else "VALUE " + .metadata.annotations[$k] end' > "$rec"
  oc annotate route "$r" -n "$NS" "$KEY=$IPS" --overwrite
  got=$(oc get route "$r" -n "$NS" -o jsonpath="{.metadata.annotations.haproxy\.router\.openshift\.io/ip_whitelist}")
  [ "$got" = "$IPS" ] || { echo "Route $r: annotation reads back as '$got'" >&2; exit 1; }
  echo "Route $r restricted to: $IPS (previous value recorded in $rec)"
done
[ "$APPLY" -eq 1 ] || echo "dry run only: rerun with --apply to change the Routes"
