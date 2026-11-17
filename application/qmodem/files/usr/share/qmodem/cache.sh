#!/bin/sh
# Shared by rpcd and modem_ctrl.sh; keep the existing cache names and JSON shape.
qmodem_cache_fresh()
{
    local qcache_file="$1" qcache_ttl="$2" qcache_mtime qcache_age
    [ -s "$qcache_file" ] || return 1
    qcache_mtime=$(stat -c %Y "$qcache_file" 2>/dev/null) || return 1
    qcache_age=$(( $(date +%s) - qcache_mtime ))
    [ "$qcache_age" -ge 0 ] && [ "$qcache_age" -le "$qcache_ttl" ] || return 1
    jq -e 'type == "object" and (.modem_info | type == "array")' "$qcache_file" >/dev/null 2>&1
}

qmodem_cached_query()
(
    local qcache_ttl="$1" qcache_file="$2" qcache_function="$3" qcache_tmp=
    if qmodem_cache_fresh "$qcache_file" "$qcache_ttl"; then
        cat "$qcache_file"
        exit $?
    fi

    # Never unlink this lock: waiters must continue to use the same inode.
    # FD 7 is separate from the AT transport lock on FD 6.
    exec 7>"${qcache_file}.lock" || exit 1
    flock -x 7 || exit 1
    # Another CLI/rpcd request may already have completed the refresh.
    if qmodem_cache_fresh "$qcache_file" "$qcache_ttl"; then
        cat "$qcache_file"
        exit $?
    fi

    qcache_tmp=$(mktemp "${qcache_file}.XXXXXX") || exit 1
    trap '[ -z "$qcache_tmp" ] || rm -f "$qcache_tmp"' EXIT
    trap 'exit 1' HUP INT TERM
    json_add_array modem_info
    "$qcache_function"
    json_close_array
    if ! json_dump > "$qcache_tmp" ||
       ! jq -e 'type == "object" and (.modem_info | type == "array")' "$qcache_tmp" >/dev/null 2>&1; then
        printf '%s\n' '{"error":"invalid modem query result"}'
        exit 1
    fi
    # Same-directory rename publishes only a complete result. Failed writes
    # leave the previous cache and its timestamp untouched.
    mv -f "$qcache_tmp" "$qcache_file" || exit 1
    qcache_tmp=
    cat "$qcache_file"
)
