#!/bin/sh
# Issue #280: a modem that re-enumerates on another USB port must keep its qmodem
# section, its user settings and its single dial instance instead of producing a
# duplicate section that can never dial and floods the log.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
REPO=$(CDPATH= cd -- "$ROOT/../.." && pwd)
SCAND="$REPO/application/modem_scan/src/modem_scand.c"

fail=0

check()
{
    if grep -Fq "$2" "$SCAND"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 (missing: $2)"
        fail=1
    fi
}

check_absent()
{
    if grep -Fq "$2" "$SCAND"; then
        echo "FAIL: $1 (unexpected: $2)"
        fail=1
    else
        echo "PASS: $1"
    fi
}

# Body of add_modem() only, so structural assertions cannot be satisfied elsewhere.
add_modem_body()
{
    awk '/^static int add_modem\(/{f=1} f{print} f&&/^}$/{exit}' "$SCAND"
}

check_order()
{
    first=$(add_modem_body | grep -nF "$2" | head -1 | cut -d: -f1)
    second=$(add_modem_body | grep -nF "$3" | head -1 | cut -d: -f1)
    if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 (order: '$2'=$first '$3'=$second)"
        fail=1
    fi
}

# --- physical device identity -------------------------------------------------

check "identity is built from vid/pid and the physical USB port" \
    'scan_format(id->id, sizeof(id->id), "usb:%s:%s@%s",'
check "the USB serial number is read from the physical port, not the interface" \
    '"/sys/bus/usb/devices/%s/serial"'
check "placeholder serials such as 0123456789ABCDEF are rejected" \
    '!strcasecmp(s, "0123456789ABCDEF")'
check "short or all-zero/all-F serials are rejected" \
    'return !all_zero && !all_f;'
check "a valid serial is stored separately from the section name" \
    'scan_set_option(section, "scan_serial", id->serial)'
check "PCIe identity is the device slot" \
    'return scan_format(id->id, sizeof(id->id), "pcie:%s", slot);'

# --- ownership arbitration ----------------------------------------------------

check "only modem-device sections take part in arbitration" \
    'strcmp(eq + 1, "modem-device")'
check "the scanned slot keeps its own section when it still owns the device" \
    'if (self && !scan_serial_conflicts(self, id) &&'
check "a recorded identity is preferred over a resource match" \
    '!scan_matches_identity(s, id))'
check "resource ownership is compared per whole token" \
    'scan_list_hits_words(&res->net_devices, s->network)'
check "two different live serials can never be merged" \
    'return id->serial[0] && s->scan_serial[0] && strcmp(s->scan_serial, id->serial);'
check "a section whose device path is gone counts as stale" \
    'return n && !is_dir(path);'
check "a stale section is adopted before a new one is created" \
    '!scan_matches_resources(s, res) || !scan_section_stale(s)'
check "a section that took over a name keeps owning the device" \
    'if (strcmp(owner->name, section)) {'
check "the section that was just scanned is never retired as a duplicate" \
    '} else if (!strcmp(s->name, section)) {'
check "a section without an identity still needs a stale path and a claim" \
    '!scan_matches_resources(s, &res) || !scan_section_stale(s))'
check "a live section wins over a stale one sharing the same serial" \
    'if (!best || (scan_section_stale(best) && !scan_section_stale(s)) ||'

# --- migration instead of duplication ----------------------------------------

check "a section owned by an older path is migrated" \
    'migrate modem section=%s slot=%s type=%s'
check "migration refreshes only the scan derived fields" \
    'static int scan_migrate_fields(const char *section, const char *slot_type,'
check "migration rewrites the device path" \
    'scan_set_option(section, "path", res->modem_path)'
check "a rescan of a known section refreshes its scan fields too" \
    'if (existed) {'
check_absent "the migrated and rescanned cases do not diverge" \
    '} else if (existed) {'
check_order "the new-section branch is only reached when nothing is migrated" \
    'scan_migrate_fields(section, slot_type, &res)' \
    'modem_count++;'
if add_modem_body | sed -n '/scan_migrate_fields(section, slot_type, &res)/,/modem_count++;/p' \
        | grep -Fq '} else {'; then
    echo "PASS: migration never increments modem_count"
else
    echo "FAIL: migration never increments modem_count"
    fail=1
fi
check_absent "add_modem never removes the owner section" \
    'remove_modem(section)'
check "a real migration or retirement triggers a network reload" \
    'if (migrated || retired || !existed || strcmp(orig_network, net_join) ||'
check "a fixed_device owner blocks the migration" \
    'skip fixed modem migration slot=%s owner=%s'
# 'slot' belongs to modem-slot sections; writing it here would make
# find_slot_section() resolve modem-device sections as slot presets.
check_absent "the scanner does not claim the modem-slot 'slot' option" \
    'scan_set_option(section, "slot"'

# --- retiring the duplicate section ------------------------------------------

check "the duplicate's dial interface is deleted" \
    '"network.%s", "network.%sv6",'
check "the duplicate's IPv6 DHCP interface is deleted" \
    '"dhcp.%s", "dhcp.%sv6"'
check "the duplicate's qmodem section is deleted" \
    '"qmodem.%s", "network.%s", "network.%sv6",'
check "modem_count is decremented, never below zero" \
    'count > 0 ? count - 1 : 0'
check "a section is never retired into itself" \
    'if (!strcmp(ghost, keep))'
check "the duplicate's procd dial instance is stopped before its config is dropped" \
    '"{\"name\":\"qmodem_network\",\"instance\":\"%s\"}", instance)'
check "an instance that is not running is not reported as a failure" \
    'if (!present)'
check "a failed stop keeps the configuration so it can be retried" \
    'cannot stop dial instance=%s'
check "a plain removal also stops the dial instance first" \
    'if (scan_stop_instance(section)) {'
check "the survivor is committed before any duplicate is retired" \
    'for (size_t i = 0; i < ghost_len; i++) {'
check "a duplicate is only retired after the owner section is written" \
    'uci_commit("qmodem");'
check "the section existence check and the delete share one lock" \
    'if (uci_get(key, existing, sizeof(existing)) || !existing[0]) {'
check "a migrated section is re-enabled so it can dial again" \
    'scan_set_option(section, "state", "enabled")'
check "a plain rescan also follows the device to its new path" \
    'migrated = strcmp(orig_path, res.modem_path) != 0;'
check "a duplicate is only retired when it carries this device's identity" \
    'if (scan_matches_identity(s, &identity)) {'
check "a leftover without an identity is stopped, never deleted" \
    'stopped leftover modem section=%s keep=%s'
check "a section whose device is present at another port is never adopted" \
    'static int scan_section_elsewhere(const struct modem_section *s, const struct scan_result *res)'
check "an option that fills its buffer is refused, not compared" \
    'option too long to compare section=%s option=%s'
check "a failed retirement still reconciles the network" \
    'retire_failed = 1;'
check "a truncated config listing is refused instead of guessed" \
    'qmodem config listing truncated, skipping ownership check'
check "a failed option read is not mistaken for a missing option" \
    'static int scan_option_known(const char *listing, const char *section, const char *option)'
check "the removed slot is matched against the recorded device path" \
    'if ((strcmp(path, removed[0]) && strcmp(path, removed[1])) || is_dir(path))'
check "both the USB and the PCIe sysfs path of the slot are considered" \
    'snprintf(removed[1], sizeof(removed[1]), "/sys/bus/pci/devices/%s", slot);'
check "a late remove never disables a modem that moved to another port" \
    'no section owns removed slot=%s'
check "fixed sections are never retired" \
    'if (s->fixed || scan_serial_conflicts(s, &identity) ||'
check "a live modem at another port is never retired as a duplicate" \
    'scan_section_elsewhere(s, &res))'

# --- the duplicate must be recognised as a duplicate -------------------------

check "a duplicate is only retired when it claims this scan's interfaces" \
    '!scan_matches_resources(s, &res) || !scan_section_stale(s)'
check "duplicate retirement is logged with both section names" \
    'retired duplicate modem section=%s keep=%s'

if [ "$fail" -eq 0 ]; then
    echo 'PASS: modem_scand merges a re-enumerated modem into its existing section'
else
    exit 1
fi
