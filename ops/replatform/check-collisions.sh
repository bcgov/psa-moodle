#!/usr/bin/env bash
# Shared-namespace collision check (runbook §8.1 validation, §9, review focus 2). Read-only: `helm template` locally and
# `oc get` on the namespace. Run before every install or upgrade beside legacy, and for each Pass C fixture.
#
#   check-collisions.sh <namespace> <release> -- <helm template arguments...>
#   e.g. check-collisions.sh 950003-dev psa-moodle -- -f chart/psa-moodle/values-950003-dev.yaml --set backup.alerts.to=x@y
#
# Fails (exit 1) on any of:
#   NAME      a rendered object whose kind and name already exist and are not this release's;
#   PREFIX    a live object whose name starts with a rendered PostgresCluster's name + "-" (the operator's own names);
#   ADOPT     a rendered Service, Deployment, StatefulSet, PDB or NetworkPolicy whose selector matches a legacy pod or pod
#             template, or a legacy one whose selector matches a rendered pod (template, Job, CronJob or Postgres pod);
#   HOST      a rendered Route host already used by a live Route.
# Reports (no failure): legacy NetworkPolicies with an empty podSelector, which apply to every pod, the new ones included,
# and rendered NetworkPolicy peers that admit legacy pods.
set -euo pipefail
NS=${1:?namespace}; RELEASE=${2:?release}; shift 2; [ "${1:-}" = "--" ] && shift
CHART=${CHART:-chart/psa-moodle}
YQ_IMAGE=docker.io/mikefarah/yq:4.44.3
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

# Rendered objects as one JSON array (mikefarah yq; a container if the local yq isn't it).
helm template "$RELEASE" "$CHART" -n "$NS" "$@" > "$work/rendered.yaml"
if yq --version 2>/dev/null | grep -q mikefarah; then
  yq -o=json -I=0 'select(. != null)' "$work/rendered.yaml"
else
  podman run --rm -i "$YQ_IMAGE" -o=json -I=0 'select(. != null)' < "$work/rendered.yaml"
fi | jq -s '.' > "$work/rendered.json"

# Live objects (never Secrets' contents: names only).
kinds=deployments,statefulsets,daemonsets,replicasets,cronjobs,jobs,pods,services,networkpolicies,poddisruptionbudgets
oc get "$kinds" -n "$NS" -o json > "$work/live.json"
names_kinds=configmaps,secrets,persistentvolumeclaims,serviceaccounts,roles,rolebindings,routes,horizontalpodautoscalers,endpoints
# kind/name, Helm instance and Crunchy cluster labels: jsonpath, so no Secret contents are read.
names_tpl='{range .items[*]}{.kind}{"/"}{.metadata.name}{"\t"}{.metadata.labels.app\.kubernetes\.io/instance}{"\t"}{.metadata.labels.postgres-operator\.crunchydata\.com/cluster}{"\n"}{end}'
{ oc get "$kinds,$names_kinds" -n "$NS" -o jsonpath="$names_tpl"
  oc get postgresclusters -n "$NS" -o jsonpath="$names_tpl" 2>/dev/null || true; } | sort -u > "$work/live-names.txt"
oc get routes -n "$NS" -o json | jq -r '.items[].spec.host' | sort -u > "$work/live-hosts.txt"

jq -n -r --slurpfile R "$work/rendered.json" --slurpfile L "$work/live.json" --rawfile N "$work/live-names.txt" \
      --rawfile H "$work/live-hosts.txt" --arg rel "$RELEASE" '
  def sel_match($sel; $labels):
    ($sel == null) as $none
    | if $none then false else
      (($sel.matchLabels // {}) | to_entries | all(.value == ($labels[.key] // null)))
      and (($sel.matchExpressions // []) | all(
        .key as $k | .values as $vs | ($labels[$k] // null) as $v
        | if .operator == "In" then ($v != null and ($vs | index($v)) != null)
          elif .operator == "NotIn" then ($v == null or ($vs | index($v)) == null)
          elif .operator == "Exists" then ($labels | has($k))
          elif .operator == "DoesNotExist" then ($labels | has($k) | not)
          else false end))
      end;
  def as_sel: if . == null or . == {} then null else {matchLabels: .} end;   # Service selectors: a map; empty = none
  def pods_of: [ .[] |
      if (.kind | IN("Deployment","StatefulSet","DaemonSet","ReplicaSet","Job")) then
        {who: "\(.kind)/\(.metadata.name)", labels: (.spec.template.metadata.labels // {})}
      elif .kind == "CronJob" then
        {who: "CronJob/\(.metadata.name)", labels: (.spec.jobTemplate.spec.template.metadata.labels // {})}
      elif .kind == "Pod" then {who: "Pod/\(.metadata.name)", labels: (.metadata.labels // {})}
      elif .kind == "PostgresCluster" then
        {who: "PostgresCluster/\(.metadata.name) pods",
         labels: ((.spec.metadata.labels // {}) + {"postgres-operator.crunchydata.com/cluster": .metadata.name})}
      else empty end ];
  def selectors_of: [ .[] |
      if .kind == "Service" then {who: "Service/\(.metadata.name)", sel: (.spec.selector | as_sel)}
      elif (.kind | IN("Deployment","StatefulSet","DaemonSet","ReplicaSet")) then {who: "\(.kind)/\(.metadata.name)", sel: .spec.selector}
      elif .kind == "PodDisruptionBudget" then {who: "PodDisruptionBudget/\(.metadata.name)", sel: (.spec.selector // {})}
      elif .kind == "NetworkPolicy" then {who: "NetworkPolicy/\(.metadata.name)", sel: .spec.podSelector}
      else empty end ];
  def ours($pg): ((.metadata.labels // {})["app.kubernetes.io/instance"] == $rel)
      or (((.metadata.labels // {})["postgres-operator.crunchydata.com/cluster"] // "") as $c | ($pg | index($c)) != null and $c != "");

  ($R[0] | map(select(. != null))) as $rendered
  | [$rendered[] | select(.kind == "PostgresCluster") | .metadata.name] as $pg
  | ($L[0].items | map(select(ours($pg) | not))) as $legacy
  | ($N | split("\n") | map(select(length > 0) | split("\t")
      | select((.[1] // "") != $rel and ((.[2] // "") as $c | $c == "" or ($pg | index($c)) == null))
      | .[0] | (split("/") | "\(.[0] | ascii_downcase)/\(.[1])"))) as $livenames
  | ($H | split("\n") | map(select(length > 0))) as $livehosts
  | ($rendered | pods_of) as $newpods | ($legacy | pods_of) as $oldpods
  | [
      # NAME
      ($rendered[] | "\(.kind | ascii_downcase)/\(.metadata.name)" as $n
        | select($livenames | index($n)) | "NAME     \($n) already exists in the namespace"),
      # PREFIX
      ($pg[] as $p | $livenames[] | select(split("/")[1] | startswith($p + "-"))
        | "PREFIX   \(.) uses the PostgresCluster prefix \($p)-"),
      # ADOPT: new selectors over legacy pods
      (($rendered | selectors_of)[] as $s | $oldpods[] | select(sel_match($s.sel; .labels))
        | "ADOPT    new \($s.who) selects legacy \(.who)"),
      # ADOPT: legacy selectors over new pods (empty NetworkPolicy selectors are reported below instead)
      (($legacy | selectors_of)[] | select((.who | startswith("NetworkPolicy/")) and (.sel == {} or .sel == null) | not) as $s
        | $newpods[] | select(sel_match($s.sel; .labels)) | "ADOPT    legacy \($s.who) selects new \(.who)"),
      # HOST
      ($rendered[] | select(.kind == "Route") | .spec.host as $h | select($livehosts | index($h))
        | "HOST     Route/\(.metadata.name) host \($h) is already in use")
    ] as $fail
  | [
      ($legacy[] | select(.kind == "NetworkPolicy" and ((.spec.podSelector // {}) == {}))
        | "NOTE     legacy NetworkPolicy/\(.metadata.name) has an empty podSelector: it applies to the new pods too (policies are additive)"),
      ($rendered[] | select(.kind == "NetworkPolicy") | .metadata.name as $np
        | [.spec.ingress[]?.from[]?, .spec.egress[]?.to[]?] | .[] | select(.namespaceSelector == null and .podSelector != null)
        | .podSelector as $ps | $oldpods[] | select(sel_match($ps; .labels))
        | "NOTE     new NetworkPolicy/\($np) has a peer that matches legacy \(.who)")
    ] as $notes
  | ($fail | unique[]), ($notes | unique[]),
    "SUMMARY  \($rendered | length) rendered objects, \($legacy | length) legacy workload/pod/selector objects, \($livenames | length) live names: \($fail | unique | length) collision(s)",
    (if ($fail | length) > 0 then "RESULT   FAIL" else "RESULT   PASS" end)
' | tee "$work/report.txt"
grep -q '^RESULT   PASS' "$work/report.txt"
