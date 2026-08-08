# Replay recorded fixtures instead of touching hardware.
# Requires FIXTURE_LOOKUP: ordered responses grouped by command hash and scenario.

at() { _fixture_send at "$@"; }
fastat() { _fixture_send fastat "$@"; }

_fixture_send()
{
    _fs_cmd=$3
    _fs_h=$(printf '%s' "$_fs_cmd" | md5sum | cut -c1-8)
    _fs_cursor="$FIXTURE_LOOKUP/cursors/$_fs_h"
    _fs_index=0
    [ ! -f "$_fs_cursor" ] || _fs_index=$(cat "$_fs_cursor")
    _fs_variant="$FIXTURE_LOOKUP/$_fs_h.responses/${FIXTURE_SCENARIO:-default}/$_fs_index"
    if [ -f "$_fs_variant.response" ]; then
        printf '%s\n' "$_fs_h" >> "$FIXTURE_LOOKUP/hits.log"
        printf '%s\n' "$((_fs_index + 1))" > "$_fs_cursor"
        cat "$_fs_variant.response"
        _fs_rc=0
        [ -f "$_fs_variant.rc" ] && _fs_rc=$(cat "$_fs_variant.rc")
        return "$_fs_rc"
    fi
    printf '%s\t%s\t%s\n' "${FIXTURE_SCENARIO:-default}" "$_fs_index" "$_fs_cmd" \
        >> "$FIXTURE_LOOKUP/misses.log"
    return 127
}
