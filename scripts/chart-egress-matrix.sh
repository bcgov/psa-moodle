#!/usr/bin/env bash
# Egress actually granted to each component of a rendered release (runbook C9, C15; review V1003). Local only.
#
#   chart-egress-matrix.sh [--expect precommit|review|commit] -- <helm template arguments...>
#
# Renders the chart, finds every pod template (Deployments, StatefulSets, Jobs, CronJobs), and lists for each component
# the egress its selected NetworkPolicies allow: in-release pods, CIDR blocks, and DNS (rules without `to`).
# With --expect, also fails unless the matrix is what that profile promises:
#   always     web: only php:9000 and DNS; install: only Postgres, Valkey and DNS; ops jobs (moodledata-backup,
#              backup-integrity, restore-rehearsal, present ones): the Kubernetes API port and SMTP; moodledata-backup
#              and backup-integrity also Postgres
#   precommit  php and cron reach no CIDR at all (C15 off)
#   review     php (and cron, if present) reach 443 and no other CIDR, never SMTP (CP3's SSO check, V1204)
#   commit     php and cron reach 443 and SMTP (C9, C15 on)
set -euo pipefail
EXPECT=""
if [ "${1:-}" = "--expect" ]; then EXPECT=${2:?profile}; shift 2; fi
[ "${1:-}" = "--" ] && shift
CHART=${CHART:-chart/psa-moodle}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
helm template t "$CHART" "$@" > "$work/r.yaml"
if yq --version 2>/dev/null | grep -q mikefarah; then
  yq -o=json -I=0 'select(. != null)' "$work/r.yaml"
else
  podman run --rm -i docker.io/mikefarah/yq:4.44.3 -o=json -I=0 'select(. != null)' < "$work/r.yaml"
fi | jq -s '.' > "$work/r.json"

jq -r --arg expect "$EXPECT" '
  def sel_match($sel; $labels):
    (($sel.matchLabels // {}) | to_entries | all(.value == ($labels[.key] // null)))
    and (($sel.matchExpressions // []) | all(
      .key as $k | .values as $vs | ($labels[$k] // null) as $v
      | if .operator == "In" then ($v != null and ($vs | index($v)) != null)
        elif .operator == "NotIn" then ($v == null or ($vs | index($v)) == null)
        elif .operator == "Exists" then ($labels | has($k))
        elif .operator == "DoesNotExist" then ($labels | has($k) | not)
        else false end));
  def comp_of($l): ($l["app.kubernetes.io/component"] // ($l["postgres-operator.crunchydata.com/cluster"] | if . then "postgres" else "?" end));
  def peer_desc: if .ipBlock then "cidr:\(.ipBlock.cidr)"
                 elif .podSelector then "pods:" + ((.podSelector.matchLabels // {})["app.kubernetes.io/component"]
                      // (.podSelector.matchLabels // {})["postgres-operator.crunchydata.com/cluster"] // "selector")
                 else "other" end;
  def port_desc: if . == null then "any" else (map("\(.port)") | join(",")) end;

  . as $all
  | [ $all[] | select(.kind | IN("Deployment","StatefulSet","Job","CronJob"))
      | (if .kind == "CronJob" then .spec.jobTemplate.spec.template.metadata.labels else .spec.template.metadata.labels end) // {} ] as $pods
  | [ $all[] | select(.kind == "NetworkPolicy" and ((.spec.policyTypes // []) | index("Egress"))) ] as $nps
  | [ $pods[] as $l | comp_of($l) as $c
      | { c: $c, grants: [ $nps[] | select(sel_match(.spec.podSelector; $l)) | .spec.egress[]?
          | if (.to // []) == [] then "dns/any:" + (.ports | port_desc)
            else (.ports | port_desc) as $p | .to[] | "\(peer_desc):\($p)" end ] | unique } ]
  | group_by(.c) | map({c: .[0].c, grants: (map(.grants) | add | unique)}) as $m
  | ($m[] | "\(.c)\t\(.grants | join("  "))"),
    (if $expect == "" then empty else
      def has_g($c; $re): ($m[] | select(.c == $c) | .grants | any(test($re))) // false;
      def cidrs($c): [ $m[] | select(.c == $c) | .grants[] | select(startswith("cidr:")) ];
      def present($c): any($m[]; .c == $c);
      [ (if present("web") and ([ $m[] | select(.c == "web") | .grants[] | select(test("^(pods:php:9000|dns/any:)") | not) ] | length) > 0
           then "web has egress beyond php:9000 and DNS" else empty end),
        (if present("install") and ([ $m[] | select(.c == "install") | .grants[] | select(test("^(pods:(postgres|psa-moodle-|valkey)|pods:[a-z0-9-]+:(5432|6379)|dns/any:)") | not) ] | length) > 0
           then "install has egress beyond Postgres, Valkey and DNS" else empty end),
        ( ("moodledata-backup","backup-integrity","restore-rehearsal") as $o | select(present($o))
          | (if has_g($o; "^cidr:[^:]*:(6443|443|6443,443|443,6443)$") then empty else "\($o) cannot reach the Kubernetes API (6443)" end),
            (if has_g($o; "^cidr:.*:25$") then empty else "\($o) cannot send alerts (SMTP)" end) ),
        ( ("moodledata-backup","backup-integrity") as $o | select(present($o))
          | if has_g($o; ":5432$") then empty else "\($o) cannot reach Postgres" end ),
        ( ("php","cron") as $a | select(present($a))
          | if $expect == "precommit" then (if (cidrs($a) | length) > 0 then "\($a) has external egress before the commit point: \(cidrs($a) | join(" "))" else empty end)
            elif $expect == "review" then
              (if has_g($a; "^cidr:.*:443$") then empty else "\($a) cannot reach HTTPS for the SSO exchange (review profile)" end),
              (if has_g($a; "^cidr:.*:25$") then "\($a) can send mail before the commit point (review profile)" else empty end),
              (if ([ cidrs($a)[] | select(test(":443$") | not) ] | length) > 0 then "\($a) has external egress beyond HTTPS (review profile): \([ cidrs($a)[] | select(test(":443$") | not) ] | join(" "))" else empty end)
            elif $expect == "commit" then
              (if has_g($a; "^cidr:.*:443$") then empty else "\($a) cannot reach HTTPS after the commit point" end),
              (if has_g($a; "^cidr:.*:25$") then empty else "\($a) cannot send mail after the commit point" end)
            else "unknown --expect \($expect)" end )
      ] as $bad
      | ($bad[] | "FAIL\t\(.)"),
        (if ($bad | length) == 0 then "PASS\t\($expect): every component has exactly the egress it should" else "RESULT\tFAIL" end)
    end)
' "$work/r.json" | tee "$work/out.txt" | column -t -s $'\t'
! grep -q '^FAIL' "$work/out.txt"
