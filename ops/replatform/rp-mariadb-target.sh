# shellcheck shell=bash
# Sourced by the return scripts: how to reach the MariaDB that holds legacy's frozen `moodle`.
#
#   TARGET=galera:<namespace>/<pod>   legacy Galera; admin credentials stay inside the pod (Bitnami password file)
#   TARGET=local:<container>          a local stand-in for rehearsals; root password from $RP_LOCAL_PASS_FILE
#
# Provides:
#   admin_sql [mariadb args]   run SQL from stdin as the database administrator
#   put_file <path>            write stdin to <path> inside the target (mode 600), e.g. a client defaults file
#   target_mariadb [args]      run the mariadb client inside the target with the given arguments, SQL on stdin
#   target_rm <path>           remove a file inside the target
# Nothing here prints a password, and none is passed on a command line.
case "${TARGET:?set TARGET=galera:<ns>/<pod> or local:<container>}" in
  galera:*)
    _ns=${TARGET#galera:}; _ns=${_ns%%/*}; _pod=${TARGET#*/}
    _exec() { oc exec -i -n "$_ns" "$_pod" -c mariadb-galera -- "$@"; }
    admin_sql() { _exec sh -c 'exec mariadb -u"$MARIADB_ROOT_USER" -p"$(cat "$MARIADB_ROOT_PASSWORD_FILE")" "$@"' sh "$@"; }
    ;;
  local:*)
    _c=${TARGET#local:}
    _exec() { podman exec -i "$_c" "$@"; }
    admin_sql() {
      { printf '[client]\nuser=root\npassword=%s\n' "$(cat "${RP_LOCAL_PASS_FILE:?}")"; } | _exec sh -c 'umask 077; cat > /tmp/rp-admin.cnf'
      _exec mariadb --defaults-extra-file=/tmp/rp-admin.cnf "$@"; local s=$?
      _exec rm -f /tmp/rp-admin.cnf; return $s
    }
    ;;
  *) echo "TARGET must be galera:<ns>/<pod> or local:<container>" >&2; exit 2 ;;
esac
put_file() { _exec sh -c 'umask 077; cat > "$1"' sh "$1"; }
target_mariadb() { _exec mariadb "$@"; }
target_rm() { _exec rm -f "$1"; }
