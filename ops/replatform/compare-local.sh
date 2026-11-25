#!/usr/bin/env bash
# Run compare-content.php against the local conversion containers (runbook §8.3, §8.4 step 2 and 5).
#
#   compare-local.sh <env> forward   source: the prepared MariaDB copy (rp-mariadb-<env>), target: Postgres
#   compare-local.sh <env> reverse   source: Postgres, target: the returned MariaDB `moodle_bailout`
#
# Output goes to the owner-only work folder: summary.tsv, rows.tsv, tables.tsv (names and ids only, no values).
set -euo pipefail
ENV_NAME=${1:?env}
DIR=${2:?forward|reverse}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/Moodle/private-backups/replatform-local-20261125}
CODE=$WORK/code-$ENV_NAME
PASS=$(cat "$WORK/.dbpass")
OUT=$WORK/compare-$ENV_NAME-$DIR
umask 077
mkdir -p "$OUT"
cp "$HERE/compare-content.php" "$CODE/compare-content.php"

case "$DIR" in
  forward) SRC=(-e SRC_DBTYPE=mariadb -e SRC_DBHOST="rp-mariadb-$ENV_NAME" -e SRC_DBUSER=root -e SRC_PREFIX=)
           TGT=(--tgttype=pgsql --tgthost="rp-postgres-$ENV_NAME" --tgtname=moodle --tgtuser=moodle --tgtprefix=mdl_) ;;
  reverse) SRC=(-e SRC_DBTYPE=pgsql -e SRC_DBHOST="rp-postgres-$ENV_NAME" -e SRC_DBUSER=moodle -e SRC_PREFIX=mdl_)
           TGT=(--tgttype=mariadb --tgthost="rp-mariadb-$ENV_NAME-return" --tgtname=moodle_bailout --tgtuser=root
                --tgtprefix=) ;;
  *) echo "forward|reverse" >&2; exit 2 ;;
esac

podman run --rm --network replatform-local --platform linux/arm64 --user 0 \
  -v "$CODE:/var/www/html" -v "$WORK/dataroot-$ENV_NAME:/data/moodledata" -v "$OUT:/data/out" \
  "${SRC[@]}" -e SRC_DBPASS="$PASS" localhost/psa-moodle-convert:dev \
  php compare-content.php "${TGT[@]}" --tgtpass="$PASS" --out=/data/out
rm -f "$CODE/compare-content.php"

echo "tables on one side only:"; sed 's/^/  /' "$OUT/tables.tsv"
echo "tables with differing rows:"
awk -F'\t' '$4>0 || $2!=$3 {printf "  %s: %s vs %s rows, %s differ\n", $1, $2, $3, $4}' "$OUT/summary.tsv"
echo "differing columns (by table):"
awk -F'\t' '{print "  " $1 ": " $3 " " $4}' "$OUT/rows.tsv" | sort | uniq -c | sort -rn | head -30
