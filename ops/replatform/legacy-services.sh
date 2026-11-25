# shellcheck shell=bash
# Sourced: list the Services whose selector reaches legacy web or php pods (replatform runbook V704).
#   legacy_services <namespace>   prints one Service name per line
# A Service reaches legacy if its selector is a subset of the labels of a pod from legacy's `web` or `php` Deployment
# (selected by their own Deployment selectors, so it works while they are scaled to 0 too).
legacy_services() {
  local ns=$1 labels
  labels=$(for d in web php; do
    oc get deploy "$d" -n "$ns" -o json 2>/dev/null | jq -c '.spec.template.metadata.labels // empty'
  done | jq -s -c .)
  oc get svc -n "$ns" -o json | jq -r --argjson pods "$labels" '.items[]
    | select(.spec.selector != null)
    | . as $s | select(any($pods[]; . as $l | ($s.spec.selector | to_entries | all(.value == $l[.key]))))
    | .metadata.name'
}
