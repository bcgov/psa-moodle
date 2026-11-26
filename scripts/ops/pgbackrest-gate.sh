#!/usr/bin/env bash
# Database gate for a nightly set (runbook C8, V804; review V1002): is the named restore point recoverable from THIS
# database's pgBackRest repository? Prints one line:
#   ok <base backup label> <system identifier>     every check passed
#   wait <reason>                                    not yet (WAL still being archived, or no base backup yet): retry
#   fail <reason>                                    can never pass for this restore point: stop
#
#   pgbackrest-gate.sh <system identifier> <restore point LSN> <last needed WAL segment> <WAL segment size in bytes>
#
# The caller reads the identifier from pg_control_system() on the live primary, and the last needed segment as
# pg_walfile_name(pg_switch_wal()) right after creating the restore point, so that segment is closed and on its way to
# the archive. Checks:
#   1. identity: the repository holds a database with that system identifier; only its archive and backups count;
#   2. base: the newest full or differential backup of that database that stopped at or before the restore point, whose
#      timeline is the restore point's timeline or an ancestor of it (per the timeline's .history file in the archive),
#      and which stopped before that ancestor's switch point;
#   3. WAL chain: every segment from the base backup's archive start to the last needed segment exists in the archive,
#      following the timeline history across any failover.
# Repository access, as commands (defaults: the Crunchy repo host, as the backup job does):
#   GATE_INFO_CMD   prints `pgbackrest --output=json info`
#   GATE_LS_CMD     prints `pgbackrest repo-ls --recurse --output=json archive/<stanza>/<archive id>`; the archive id is
#                   appended as the last argument
#   GATE_GET_CMD    prints a file from the archive (`pgbackrest repo-get archive/<stanza>/<archive id>/<file>`); the
#                   archive id and file name are appended
set -euo pipefail
SYSID=${1:?system identifier}; RP_LSN=${2:?restore point LSN}; NEED=${3:?last needed WAL segment}; SEGSIZE=${4:?segment size}
STANZA=${STANZA:-db}
repo="oc -n ${TARGET_NAMESPACE:-} exec ${POSTGRES_CLUSTER:-}-repo-host-0 -c pgbackrest -- pgbackrest --stanza=$STANZA"
: "${GATE_INFO_CMD:=$repo --output=json info}"
: "${GATE_LS_CMD:=ls_archive}"
: "${GATE_GET_CMD:=get_archive}"
ls_archive() { eval "$repo repo-ls --recurse --output=json archive/$STANZA/$1"; }
get_archive() { eval "$repo repo-get archive/$STANZA/$1/$2"; }
say() { echo "$*"; exit 0; }

[[ "$NEED" =~ ^[0-9A-F]{24}$ ]] || say "fail bad segment name $NEED"
info=$(eval "$GATE_INFO_CMD" 2>/dev/null) || say "wait repository unreachable"
jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<< "$info" || say "wait no repository information"

# 1. identity
dbid=$(jq -r --arg s "$SYSID" '[.[0].db[]? | select((."system-id" | tostring) == $s) | .id] | max // empty' <<< "$info")
[ -n "$dbid" ] || say "fail the repository holds no database with system identifier $SYSID"
archid=$(jq -r --argjson d "$dbid" '[.[0].archive[]? | select(.database.id == $d) | .id] | first // empty' <<< "$info")
[ -n "$archid" ] || say "wait no archive yet for database $dbid"

# Timeline history of the needed segment's timeline: "<parent tli> <switch LSN> <reason>" per ancestor.
tl_need=$((16#${NEED:0:8}))
hist=""
if [ "$tl_need" -gt 1 ]; then
  hist=$(eval "$GATE_GET_CMD $archid ${NEED:0:8}.history" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1, $2}') \
    || say "wait timeline history ${NEED:0:8}.history not readable"
  [ -n "$hist" ] || say "fail timeline $tl_need has no readable history in the archive"
fi
segs=$(eval "$GATE_LS_CMD $archid" 2>/dev/null | jq -r 'keys[]' | grep -oE '[0-9A-F]{24}-' | tr -d - | sort -u) \
  || say "wait archive listing failed"

jq -n -r --argjson info "$info" --argjson dbid "$dbid" --arg lsn "$RP_LSN" --arg need "$NEED" --argjson segsize "$SEGSIZE" \
      --arg hist "$hist" --arg segs "$segs" '
  def hexnum: ascii_upcase | explode | reduce .[] as $c (0; . * 16 + (if $c >= 65 then $c - 55 else $c - 48 end));
  def lsnnum: split("/") | (.[0] | hexnum) * 4294967296 + (.[1] | hexnum);
  def per: 4294967296 / $segsize;
  def segno: (.[8:16] | hexnum) * per + (.[16:24] | hexnum);
  def hex8: . as $v | [range(7; -1; -1)] | map((($v / pow(16; .)) | floor) % 16)
            | map(if . < 10 then 48 + . else 55 + . end) | implode;
  def segname($tl; $n): ($tl | hex8) + ((($n / per) | floor) | hex8) + (($n % per) | hex8);
  ($lsn | lsnnum) as $rp
  | ($need[0:8] | hexnum) as $tl
  # ancestors: [{tl, switch}] from the history file, then the needed timeline itself (no switch)
  | ([$hist | split("\n")[] | select(length > 0) | split(" ") | {tl: (.[0] | tonumber), switch: (.[1] | lsnnum)}]
      + [{tl: $tl, switch: null}]) as $chain
  | ([$info[0].backup[]? | select(.database.id == $dbid and (.type == "full" or .type == "diff" or .type == "incr"))
       | select(.lsn.stop != null and (.lsn.stop | lsnnum) <= $rp)
       | . as $b | ($b.archive.stop[0:8] | hexnum) as $btl
       | ($chain | map(select(.tl == $btl)) | first) as $link
       | select($link != null and ($link.switch == null or ($b.lsn.stop | lsnnum) <= $link.switch))
       | . + {btl: $btl}] | sort_by(.lsn.stop | lsnnum) | last) as $base
  | if $base == null then "wait no base backup of this database before the restore point on its timeline chain"
    else
      ($segs | split("\n") | map(select(length == 24)) | map({key: ., value: true}) | from_entries) as $have
      # required segments, per timeline in the chain from the base timeline on
      | ($chain | map(.tl) | index($base.btl)) as $from
      | ($base.archive.start | segno) as $start
      # At a switch point S, the old timeline is needed up to the segment before S: the segment holding S is archived
      # on the old timeline only as .partial, and the new timeline segment of that number carries its content.
      | [ range($from; $chain | length) as $i | $chain[$i] as $c
          | (if $i == $from then $start else ($chain[$i - 1].switch / $segsize | floor) end) as $lo
          | (if $c.switch == null then ($need | segno) else (($c.switch / $segsize | floor) - 1) end) as $hi
          | range($lo; $hi + 1) | segname($c.tl; .) ] as $required
      | [ $required[] | select($have[.] | not) ] as $missing
      | if ($missing | length) == 0 then "ok \($base.label) \($info[0].db[] | select(.id == $dbid) | ."system-id")"
        elif ($missing | length) == 1 and $missing[0] == $need then "wait segment \($need) not archived yet"
        else "wait \($missing | length) segment(s) missing from the archive, first \($missing[0])" end
    end'
