#!/bin/sh
# Volatile presence proof, never a cross-slot identity or configuration mapping.
script_dir="${QMODEM_HOME:-/usr/share/qmodem}"
sys="${QMODEM_SYSFS:-/sys}"
run="${QMODEM_RUN_DIR:-/var/run/qmodem}"
uci_cmd="${QMODEM_UCI:-uci}"
action="$1"
section="$2"
case "$section" in ''|*[!A-Za-z0-9_]*) exit 2;; esac
get() { "$uci_cmd" -q get "qmodem.$1"; }

snapshot() {
    [ "$(get "$section")" = modem-device ] || return 1
    configured=$(get "$section.path") || return 1
    root=$(readlink -f "$configured") || return 1
    case "$root" in "$sys"/devices/*) ;; *) return 1;; esac
    [ -d "$root" ] || return 1
    port=$(get "$section.at_port") || return 1
    [ -c "$port" ] || return 1
    numbers=$(stat -L -c '%t:%T' "$port") || return 1
    devnum=$(printf '%d:%d' "0x${numbers%:*}" "0x${numbers#*:}") || return 1
    control=$(readlink -f "$sys/dev/char/$devnum") || return 1
    [ -d "$control" ] || return 1
    control_root="$root"
    case "$control" in
        "$root"/*) ;;
        *)
            # A PCIe data slot may explicitly own a separate USB control slot.
            [ "$(get "$section.data_interface")" = pcie ] || return 1
            slot=${configured%/}; slot=${slot##*/}
            associated=""
            for cfg in $("$uci_cmd" -q show qmodem | sed -n 's/^qmodem\.\([A-Za-z0-9_]*\)=modem-slot$/\1/p'); do
                [ "$(get "$cfg.type")" = pcie ] || continue
                [ "$(get "$cfg.slot")" = "$slot" ] || continue
                usb=$(get "$cfg.associated_usb") || continue
                [ -z "$associated" ] || [ "$associated" = "$usb" ] || return 1
                associated="$usb"
            done
            case "$associated" in ''|*[!A-Za-z0-9.-]*) return 1;; esac
            control_root=$(readlink -f "$sys/bus/usb/devices/$associated") || return 1
            [ -d "$control_root" ] || return 1
            case "$control" in "$control_root"/*) ;; *) return 1;; esac
            ;;
    esac
    net=$("$script_dir/modem_netdev.sh" "$section") || return 1
    netpath=$(readlink -f "$sys/class/net/$net") || return 1
    [ -d "$netpath" ] || return 1
    case "$netpath" in "$root"/*) ;; *) return 1;; esac
    # Inodes distinguish a new enumeration at the same path in this boot.
    printf '%s\n' "$configured" "$port" "$net" "$root" "$control" "$netpath"
    stat -L -c '%i' "$root" "$control_root" "$control" "$netpath"
}

case "$action" in
    snapshot) snapshot;;
    check)
        [ -f "$run/${section}_dir/ready" ] || exit 1
        current=$(snapshot) || exit 1
        [ "$current" = "$(cat "$run/${section}_dir/ready")" ]
        ;;
    confirm)
        current=$(snapshot) || exit 1
        mkdir -p "$run/${section}_dir" || exit 1
        tmp="$run/${section}_dir/ready.$$"
        trap 'rm -f "$tmp"' EXIT HUP INT TERM
        printf '%s\n' "$current" > "$tmp" && mv "$tmp" "$run/${section}_dir/ready"
        ;;
    *) exit 2;;
esac
