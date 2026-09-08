#!/bin/sh
# Tune the Himax HX83121A touchscreen used by Huawei MateBook E Go/gaokun3.
#
# The patched driver exposes frame-based filtering through sysfs.  At a low
# touch/reporting rate, waiting for multiple stable frames can discard a very
# short tap before BTN_LEFT/pointer emulation is generated.  This script
# applies a responsive profile without replacing the kernel or touchscreen
# module, and can install a small systemd service to reapply it after reboot.

set -u

SCRIPT_NAME=${0##*/}
BACKUP_ROOT=${TOUCH_FIX_BACKUP_ROOT:-/var/backups/gpu-driver-fix}
if [ -n "${TOUCH_FIX_LOG:-}" ]; then
    LOG_FILE=$TOUCH_FIX_LOG
elif [ -n "${GPU_FIX_LOG:-}" ]; then
    LOG_FILE=$GPU_FIX_LOG
elif [ -n "${SUDO_USER:-}" ] && command -v getent >/dev/null 2>&1; then
    sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    LOG_FILE=${sudo_home:-/tmp}/gaokun-kernel-build/build.log
else
    LOG_FILE=${HOME:-/tmp}/gaokun-kernel-build/build.log
fi
INSTALL_DIR=${TOUCH_FIX_INSTALL_DIR:-/usr/local/libexec}
INSTALLED_HELPER="$INSTALL_DIR/gaokun3-touch-responsive"
UNIT_FILE=${TOUCH_FIX_UNIT_FILE:-/etc/systemd/system/gaokun3-touch-responsive.service}
# Balanced profile: preserve the fast press path, but tolerate several missing
# reports while a finger is moving.  The latter is what prevents drag breaks.
DEFAULT_DEBOUNCE_BASE=${TOUCH_DEBOUNCE_BASE:-0}
DEFAULT_START_DEBOUNCE=${TOUCH_START_DEBOUNCE:-0}
DEFAULT_LOST_FRAMES=${TOUCH_LOST_FRAMES:-8}

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [--check | --fix | --apply | --rollback DIR | --uninstall | --help]

  --check          Show Himax touchscreen nodes and current filtering values.
  --fix            Apply the responsive profile now and persist it with systemd.
  --apply          Apply the profile once (used by the systemd service).
  --rollback DIR  Restore values saved by --fix from DIR.
  --uninstall      Remove the persistent systemd service; keep current values.
  --help           Show this help.

The balanced profile changes only these runtime sysfs attributes:
  debounce_base=0
  track_start_debounce=0
  track_lost_frames=8

The first two values keep a short press responsive.  track_lost_frames keeps a
moving contact alive across several missing reports, which prevents a drag
from being released too easily at low refresh/reporting rates.  A larger value
can delay release after a real finger lift; use --rollback if that occurs.

Environment:
  TOUCH_DEBOUNCE_BASE   Override debounce_base (default: $DEFAULT_DEBOUNCE_BASE)
  TOUCH_START_DEBOUNCE  Override track_start_debounce (default: $DEFAULT_START_DEBOUNCE)
  TOUCH_LOST_FRAMES     Override track_lost_frames (default: $DEFAULT_LOST_FRAMES)
  TOUCH_FIX_BACKUP_ROOT Backup root (default: $BACKUP_ROOT)
  TOUCH_FIX_LOG         Log file (default: $LOG_FILE)

Examples:
  $SCRIPT_NAME --check
  sudo $SCRIPT_NAME --fix
  sudo $SCRIPT_NAME --rollback /var/backups/gpu-driver-fix/20260908T200000+0800-touch
USAGE
}

mkdir_log() {
    log_dir=${LOG_FILE%/*}
    [ "$log_dir" = "$LOG_FILE" ] && log_dir=.
    mkdir -p "$log_dir" 2>/dev/null || true
}

log() {
    mkdir_log
    printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
    log "WARNING: $*"
}

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: this operation requires root; rerun with sudo." >&2
        exit 2
    fi
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_values() {
    if ! is_uint "$DEFAULT_DEBOUNCE_BASE" || \
       ! is_uint "$DEFAULT_START_DEBOUNCE" || \
       ! is_uint "$DEFAULT_LOST_FRAMES"; then
        echo 'ERROR: touch tuning values must be non-negative integers.' >&2
        exit 2
    fi
}

# Print matching algo directories.  The driver is identified by its bound
# driver name or HX83121A modalias, rather than by a hard-coded spi bus number.
find_nodes() {
    find /sys/devices /sys/bus/spi/drivers 2>/dev/null \
        -type f -name debounce_base -path '*/algo/debounce_base' -print |
    while IFS= read -r node; do
        [ -f "$node" ] || continue
        algo_dir=${node%/debounce_base}
        device_dir=${algo_dir%/algo}
        driver=$(readlink -f "$device_dir/driver" 2>/dev/null || true)
        modalias=$(cat "$device_dir/modalias" 2>/dev/null || true)
        case "$(basename "$driver"):$modalias" in
            himax*:*|*:spi:hx83121a*|*:spi:hx83121a-ts*)
                printf '%s\n' "$algo_dir"
                ;;
        esac
    done | sort -u
}

node_count() {
    find_nodes | wc -l | tr -d ' '
}

print_node() {
    algo=$1
    device_dir=${algo%/algo}
    driver=$(readlink -f "$device_dir/driver" 2>/dev/null || true)
    printf 'node: %s\n' "$algo"
    printf '  device: %s\n' "$device_dir"
    printf '  driver: %s\n' "${driver:-unbound}"
    printf '  modalias: %s\n' "$(cat "$device_dir/modalias" 2>/dev/null || echo unknown)"
    for attr in debounce_base track_start_debounce track_lost_frames track_smoothing pressure_enabled; do
        if [ -r "$algo/$attr" ]; then
            printf '  %-21s %s\n' "$attr" "$(cat "$algo/$attr")"
        fi
    done
}

check() {
    log 'Low-FPS touchscreen diagnostic started'
    printf '%s\n' '--- touchscreen detection ---'
    count=$(node_count)
    if [ "$count" -eq 0 ]; then
        echo 'Himax HX83121A tuning sysfs node not found.'
        echo 'This script only supports the frame-tuned Himax driver; no changes proposed.'
        log 'No supported Himax tuning node found'
        return 1
    fi
    echo "Found $count Himax tuning node(s)."
    for algo in $(find_nodes); do
        print_node "$algo"
    done
    printf '%s\n' '--- interpretation ---'
    echo 'debounce_base and track_start_debounce are frame counts, not milliseconds.'
    echo 'A value above zero can discard a press/release completed before enough frames arrive.'
    echo "balanced target: debounce_base=$DEFAULT_DEBOUNCE_BASE, track_start_debounce=$DEFAULT_START_DEBOUNCE, track_lost_frames=$DEFAULT_LOST_FRAMES"
    printf '%s\n' '--- display modes (context only) ---'
    found_mode=1
    for modes in /sys/class/drm/card*-DSI-*/modes /sys/class/drm/card*-eDP-*/modes; do
        [ -f "$modes" ] || continue
        found_mode=0
        printf '%s:\n' "$modes"
        sed -n '1,12p' "$modes"
    done
    [ "$found_mode" -eq 0 ] || echo 'No DSI/eDP mode file found.'
    log 'Low-FPS touchscreen diagnostic finished'
}

write_attr() {
    file=$1
    value=$2
    if [ ! -w "$file" ]; then
        warn "not writable, skipped: $file"
        return 1
    fi
    printf '%s\n' "$value" >"$file" 2>/dev/null || {
        warn "failed to write $file"
        return 1
    }
    return 0
}

apply_values() {
    validate_values
    count=0
    changed=0
    for algo in $(find_nodes); do
        count=$((count + 1))
        for attr_value in \
            "debounce_base:$DEFAULT_DEBOUNCE_BASE" \
            "track_start_debounce:$DEFAULT_START_DEBOUNCE" \
            "track_lost_frames:$DEFAULT_LOST_FRAMES"; do
            attr=${attr_value%%:*}
            value=${attr_value#*:}
            file="$algo/$attr"
            if [ -f "$file" ]; then
                before=$(cat "$file" 2>/dev/null || echo '?')
                if write_attr "$file" "$value"; then
                    after=$(cat "$file" 2>/dev/null || echo '?')
                    if [ "$after" = "$value" ]; then
                        log "set $file: $before -> $after"
                        changed=$((changed + 1))
                    else
                        warn "write was not retained: $file (read back $after)"
                    fi
                fi
            else
                warn "missing attribute, skipped: $file"
            fi
        done
    done
    if [ "$count" -eq 0 ]; then
        return 1
    fi
    log "Applied balanced touchscreen profile to $count node(s), $changed attribute write(s)."
    return 0
}

backup_values() {
    session_dir=$1
    manifest="$session_dir/values.tsv"
    : >"$manifest"
    for algo in $(find_nodes); do
        for attr in debounce_base track_start_debounce track_lost_frames; do
            file="$algo/$attr"
            [ -r "$file" ] || continue
            value=$(cat "$file" 2>/dev/null || true)
            printf '%s\t%s\t%s\n' "$algo" "$attr" "$value" >>"$manifest"
        done
    done
    [ -s "$manifest" ]
}

install_persistent() {
    need_root
    source_path=$0
    case "$source_path" in
        /*) ;;
        *) source_path=$(pwd)/$source_path ;;
    esac
    mkdir -p "$INSTALL_DIR"
    cp "$source_path" "$INSTALLED_HELPER"
    chmod 0755 "$INSTALLED_HELPER"
    cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=Apply responsive Himax touchscreen filtering for low refresh rates
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
Environment=TOUCH_DEBOUNCE_BASE=$DEFAULT_DEBOUNCE_BASE
Environment=TOUCH_START_DEBOUNCE=$DEFAULT_START_DEBOUNCE
Environment=TOUCH_LOST_FRAMES=$DEFAULT_LOST_FRAMES
Environment=TOUCH_FIX_LOG=$LOG_FILE
ExecStart=$INSTALLED_HELPER --apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl enable gaokun3-touch-responsive.service >/dev/null
    else
        warn 'systemctl not found; runtime fix remains active but was not persisted.'
        return 1
    fi
    log "persistent service installed: $UNIT_FILE"
    log "installed helper: $INSTALLED_HELPER"
}

fix() {
    need_root
    count=$(node_count)
    if [ "$count" -eq 0 ]; then
        warn 'Himax HX83121A tuning node not found; refusing automatic changes.'
        exit 1
    fi
    timestamp=$(date +%Y%m%dT%H%M%S%z)
    session_dir="$BACKUP_ROOT/${timestamp}-touch"
    mkdir -p "$session_dir"
    if ! backup_values "$session_dir"; then
        warn "could not save current values in $session_dir"
        exit 1
    fi
    log "Low-FPS touchscreen repair started; backup=$session_dir"
    if ! apply_values; then
        warn 'runtime profile could not be applied'
        exit 1
    fi
    install_persistent || true
    log 'No kernel, package, firmware, GRUB, or reboot operation was performed.'
    log "Touchscreen repair finished; rollback with: sudo $SCRIPT_NAME --rollback $session_dir"
    printf '\nTouchscreen backup directory: %s\n' "$session_dir"
    printf 'Persistent service: %s\n' "$UNIT_FILE"
    printf 'Log file: %s\n' "$LOG_FILE"
}

rollback() {
    need_root
    dir=$1
    manifest="$dir/values.tsv"
    [ -f "$manifest" ] || {
        echo "ERROR: values manifest not found: $manifest" >&2
        exit 2
    }
    log "Low-FPS touchscreen rollback started from $dir"
    restored=0
    failed=0
    tab=$(printf '\t')
    while IFS="$tab" read -r algo attr value; do
        [ -n "$algo" ] || continue
        file="$algo/$attr"
        if write_attr "$file" "$value"; then
            log "restored $file -> $value"
            restored=$((restored + 1))
        else
            failed=$((failed + 1))
        fi
    done <"$manifest"
    log "Rollback finished: restored=$restored failed=$failed"
    [ "$failed" -eq 0 ]
}

uninstall() {
    need_root
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now gaokun3-touch-responsive.service >/dev/null 2>&1 || true
        systemctl daemon-reload
    fi
    rm -f "$UNIT_FILE" "$INSTALLED_HELPER"
    log 'Persistent touchscreen service removed; current sysfs values were not changed.'
}

validate_values
case "${1:---check}" in
    --check) check ;;
    --fix) fix ;;
    --apply)
        need_root
        log 'Applying persistent touchscreen profile'
        apply_values || exit 1
        ;;
    --rollback)
        [ "$#" -eq 2 ] || { usage >&2; exit 2; }
        rollback "$2"
        ;;
    --uninstall) uninstall ;;
    --help|-h) usage ;;
    *) usage >&2; exit 2 ;;
esac
