# Replay recorded fixtures instead of touching hardware.
# Requires FIXTURE_LOOKUP: response variants grouped by command hash.

at() { _fixture_send at "$@"; }
fastat() { _fixture_send fastat "$@"; }

_fixture_send()
{
    _fs_cmd=$3
    _fs_h=$(printf '%s' "$_fs_cmd" | md5sum | cut -c1-8)
    _fs_index=0
    [ ! -f "$FIXTURE_LOOKUP/selected/$_fs_h" ] || _fs_index=$(cat "$FIXTURE_LOOKUP/selected/$_fs_h")
    _fs_variant="$FIXTURE_LOOKUP/$_fs_h.responses/$_fs_index"
    if [ -f "$_fs_variant.response" ]; then
        printf '%s\n' "$_fs_h" >> "$FIXTURE_LOOKUP/hits.log"
        cat "$_fs_variant.response"
        _fs_rc=0
        [ -f "$_fs_variant.rc" ] && _fs_rc=$(cat "$_fs_variant.rc")
        return "$_fs_rc"
    fi
    echo "$_fs_cmd" >> "$FIXTURE_LOOKUP/misses.log"
    return 0
}
