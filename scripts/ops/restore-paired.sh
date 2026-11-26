#!/usr/bin/env bash
# Combined restore of a nightly recovery set onto EMPTY storage (replatform runbook S12, C8, V603, V804). DEV ONLY.
# Dry run unless --apply: prints every object it would create.
#
#   restore-paired.sh <namespace> <release> <manifest.json> <restore name> [--apply]
#
# <manifest.json> is the set's manifest, taken from the backup volume or from the off-site copy.
#   1. refuses unless the namespace ends in -dev (CLAUDE.md: no restore drills in test or prod)
#   2. checks the repository's database system identifier equals the manifest's (pgbackrest info on the repo host)
#   3. a new PostgresCluster <restore name>, restored from the release's repository to the manifest's restore point:
#      --type=name --target=<set> --set=<base backup> --target-timeline=<timeline> --target-action=promote
#   4. a new, empty moodledata PVC, filled by a Job running restore-set-files.sh from the backup PVC (read-only)
#   5. a Job from the php image against the restored database and files (V1012): the missing referenced files are
#      EXACTLY the set's recorded source gaps (source-gaps.txt beside the manifest), by hash; SHA-1s correct; no
#      upgrade pending; and the encryption canary stored at load time (encryption-canary.php create, §13.2) decrypts
#      with the restored key, which proves the files' key and the database are a pair
# Clean up with: oc delete postgrescluster/<name> pvc/<name>-moodledata job -l rp-restore=<name>
set -euo pipefail
NS=${1:?namespace}; REL=${2:?release}; MAN=${3:?manifest.json}; NAME=${4:?restore name}
APPLY=0; [ "${5:-}" = "--apply" ] && APPLY=1
case "$NS" in *-dev) ;; *) echo "refusing: restore drills run in a -dev namespace only (CLAUDE.md)" >&2; exit 1 ;; esac
# The chart's fullname: the release name when it already contains "psa-moodle", else <release>-psa-moodle.
case "$REL" in *psa-moodle*) FULL=${FULLNAME:-$REL} ;; *) FULL=${FULLNAME:-$REL-psa-moodle} ;; esac
PG=${POSTGRES_CLUSTER:-$FULL-pg}
SIZE_DB=${SIZE_DB:-10Gi}; SIZE_FILES=${SIZE_FILES:-6Gi}
IMAGE_OPS=${IMAGE_OPS:?set IMAGE_OPS to the ops image (by digest)}
IMAGE_PHP=${IMAGE_PHP:?set IMAGE_PHP to the exact-code php image (by digest)}
set_id=$(jq -r .set "$MAN"); base=$(jq -r .database.base_backup "$MAN"); tl=$(jq -r .database.timeline "$MAN")
GAPS_FILE="$(dirname "$MAN")/source-gaps.txt"
[ -f "$GAPS_FILE" ] || { echo "no source-gaps.txt beside the manifest ($GAPS_FILE)" >&2; exit 1; }
gaps_php=$(grep -E '^[0-9a-f]{40}$' "$GAPS_FILE" | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))' | sed "s/\"/'/g")
[ "$(jq '.inventory.source_gaps' "$MAN")" = "$(grep -cE '^[0-9a-f]{40}$' "$GAPS_FILE" || true)" ] \
  || { echo "source-gaps.txt does not match the manifest's count" >&2; exit 1; }
sysid=$(jq -r .database.system_identifier "$MAN")
echo "set $set_id: base backup $base, timeline $tl, system $sysid"
out() { if [ "$APPLY" -eq 1 ]; then oc apply -n "$NS" -f -; else sed 's/^/   /'; fi; }

echo "== 2. repository identity"
if [ "$APPLY" -eq 1 ]; then
  have=$(oc -n "$NS" exec "$PG-repo-host-0" -c pgbackrest -- pgbackrest --output=json info | jq -r '.[0].db[-1]."system-id" | tostring')
  [ "$have" = "$sysid" ] || { echo "refusing: repository system identifier $have != manifest $sysid" >&2; exit 1; }
  echo "   repository system identifier matches"
else echo "   would compare pgbackrest info system-id with $sysid"; fi

echo "== 3. PostgresCluster $NAME at restore point $set_id"
out <<EOF
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: $NAME
  labels: { rp-restore: "$NAME" }
spec:
  postgresVersion: 15
  dataSource:
    postgresCluster:
      clusterName: $PG
      repoName: repo1
      options:
        - --type=name
        - --target=$set_id
        - --set=$base
        - --target-timeline=$tl
        - --target-action=promote
  instances:
    - name: restore
      replicas: 1
      dataVolumeClaimSpec:
        accessModes: [ReadWriteOnce]
        storageClassName: netapp-block-standard
        resources: { requests: { storage: $SIZE_DB } }
  users:
    - name: moodle
      databases: [moodle]
  backups:
    pgbackrest:
      repos:
        - name: repo1
          volume:
            volumeClaimSpec:
              accessModes: [ReadWriteOnce]
              storageClassName: netapp-file-backup
              resources: { requests: { storage: 1Gi } }
EOF

echo "== 4. empty moodledata PVC and the file restore Job"
out <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NAME-moodledata
  labels: { rp-restore: "$NAME" }
spec:
  accessModes: [ReadWriteMany]
  storageClassName: netapp-file-standard
  resources: { requests: { storage: $SIZE_FILES } }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: $NAME-files
  labels: { rp-restore: "$NAME" }
spec:
  backoffLimit: 0
  template:
    metadata: { labels: { rp-restore: "$NAME" } }
    spec:
      restartPolicy: Never
      activeDeadlineSeconds: 3600
      securityContext: { runAsNonRoot: true }
      containers:
        - name: files
          image: $IMAGE_OPS
          command: ["/usr/local/bin/restore-set-files.sh", "/backup/sets/$set_id", "/target"]
          volumeMounts:
            - { name: backup, mountPath: /backup, readOnly: true }
            - { name: target, mountPath: /target }
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
      volumes:
        - name: backup
          persistentVolumeClaim: { claimName: $FULL-moodledata-backup, readOnly: true }
        - name: target
          persistentVolumeClaim: { claimName: $NAME-moodledata }
EOF

if [ "$APPLY" -eq 1 ]; then
  echo "== waiting for the file restore and the database"
  oc -n "$NS" wait --for=condition=complete "job/$NAME-files" --timeout=3600s
  oc -n "$NS" logs "job/$NAME-files" | tail -3
  for _ in $(seq 1 120); do
    oc -n "$NS" get pod -l "postgres-operator.crunchydata.com/cluster=$NAME,postgres-operator.crunchydata.com/role=master" \
      -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="database")].ready}' 2>/dev/null | grep -q true && break
    sleep 15
  done
fi

echo "== 5. checks on the restored site"
out <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $NAME-check
  labels: { rp-restore: "$NAME" }
spec:
  backoffLimit: 0
  template:
    metadata: { labels: { rp-restore: "$NAME" } }
    spec:
      restartPolicy: Never
      activeDeadlineSeconds: 1800
      securityContext: { runAsNonRoot: true }
      containers:
        - name: check
          image: $IMAGE_PHP
          env:
            - { name: MOODLE_WWWROOT, value: "https://$NAME.invalid" }
            - { name: MOODLE_INSTALL_ENABLED, value: "false" }
            - { name: MOODLE_OUTBOUND, value: "off" }
            - { name: CACHE_HOST, value: "127.0.0.1" }
$(for k in DB_HOST:host DB_PORT:port DB_NAME:dbname DB_USER:user DB_PASSWORD:password; do printf '            - name: %s\n              valueFrom: { secretKeyRef: { name: %s-pguser-moodle, key: %s } }\n' "${k%%:*}" "$NAME" "${k#*:}"; done)
          command:
            - php
            - -r
            - |
              define("CLI_SCRIPT", true); require "/var/www/html/config.php";
              \$gaps = $gaps_php;
              \$rs = \$DB->get_recordset_sql("SELECT DISTINCT contenthash FROM {files} WHERE filename <> ?", ["."]);
              \$n = \$bad = 0; \$missing = [];
              foreach (\$rs as \$r) { \$n++; \$h = \$r->contenthash; \$f = "\$CFG->dataroot/filedir/".substr(\$h,0,2)."/".substr(\$h,2,2)."/\$h";
                if (!is_readable(\$f)) { \$missing[] = \$h; continue; } if (sha1_file(\$f) !== \$h) \$bad++; }
              \$rs->close();
              \$unexpected = array_diff(\$missing, \$gaps); \$stale = array_diff(\$gaps, \$missing);
              \$enc = \$DB->get_field("config", "value", ["name" => "rp_encryption_canary"]);
              try { \$canary = \$enc !== false && \core\encryption::decrypt(\$enc) === "psa-moodle encryption canary v1"; } catch (\Throwable \$e) { \$canary = false; }
              printf("referenced %d; missing %d (unexpected %d, recorded gaps not missing %d); SHA-1 mismatches %d; upgrade pending %s; stored canary %s\n",
                \$n, count(\$missing), count(\$unexpected), count(\$stale), \$bad, moodle_needs_upgrading() ? "YES" : "no",
                \$enc === false ? "ABSENT" : (\$canary ? "decrypts" : "DOES NOT DECRYPT"));
              foreach (array_slice(\$unexpected, 0, 20) as \$h) echo "unexpected missing \$h\n";
              exit(\$unexpected || \$stale || \$bad || !\$canary || moodle_needs_upgrading() ? 1 : 0);
          volumeMounts:
            - { name: moodledata, mountPath: /var/www/moodledata }
            - { name: localcache, mountPath: /mnt/ramdisk }
          securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
      volumes:
        - name: moodledata
          persistentVolumeClaim: { claimName: $NAME-moodledata }
        - name: localcache
          emptyDir: { medium: Memory }
EOF
if [ "$APPLY" -eq 1 ]; then
  oc -n "$NS" wait --for=condition=complete "job/$NAME-check" --timeout=1800s && oc -n "$NS" logs "job/$NAME-check" | tail -2
  echo "restored and checked. A login check needs a temporary release on this database and PVC (Pass C)."
else
  echo "dry run: nothing created"
fi
