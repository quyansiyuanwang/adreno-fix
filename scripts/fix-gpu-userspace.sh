#!/bin/sh
# Safely disable common global Adreno/Mesa overrides that force Zink or a
# vendor GBM backend, then verify the kernel and Mesa renderer.
#
# This script intentionally does not install/remove packages, rebuild kernels,
# edit GRUB, or reboot the machine.

set -u

SCRIPT_NAME=${0##*/}
BACKUP_ROOT=${GPU_FIX_BACKUP_ROOT:-/var/backups/gpu-driver-fix}
LOG_FILE=${GPU_FIX_LOG:-"${HOME:-/tmp}/gaokun-kernel-build/build.log"}

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME [--check | --fix | --rollback DIR | --help]

  --check          Diagnose GPU, overrides, firmware, and Mesa renderer.
  --fix            Backup and disable unsafe global graphics overrides.
  --rollback DIR  Restore files saved in a backup directory from --fix.
  --help           Show this help.

Environment:
  GPU_FIX_BACKUP_ROOT  Backup root (default: $BACKUP_ROOT)
  GPU_FIX_LOG          Log file (default: $LOG_FILE)

Run --fix and --rollback as root, for example:
  sudo $SCRIPT_NAME --fix
  sudo $SCRIPT_NAME --rollback /var/backups/gpu-driver-fix/20260908T190000+0800
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

is_adreno_machine() {
    found=1
    for dev in /sys/bus/platform/devices/*gpu /sys/bus/platform/devices/*adreno*; do
        [ -e "$dev" ] || continue
        if grep -qE 'DRIVER=adreno|OF_COMPATIBLE_0=.*adreno|OF_COMPATIBLE_1=.*adreno' "$dev/uevent" 2>/dev/null; then
            found=0
        fi
    done
    for dev in /sys/class/drm/card*/device; do
        [ -e "$dev" ] || continue
        if grep -qE 'DRIVER=msm_dpu|OF_COMPATIBLE_0=qcom,.*dpu' "$dev/uevent" 2>/dev/null; then
            found=0
        fi
    done
    return "$found"
}

print_file_status() {
    for file in /etc/environment.d/adreno.conf /etc/profile.d/adreno.sh; do
        if [ -f "$file" ]; then
            printf 'active override: %s\n' "$file"
            sed -n '1,80p' "$file"
        else
            printf 'not active: %s\n' "$file"
        fi
    done
    for file in /etc/environment.d/*.conf /etc/profile.d/*.sh; do
        [ -f "$file" ] || continue
        case "$file" in
            */adreno.conf) continue ;;
            */adreno.sh) continue ;;
        esac
        if grep -qE 'MESA_LOADER_DRIVER_OVERRIDE[[:space:]]*=[[:space:]]*.*zink|GBM_BACKENDS_PATH[[:space:]]*=[[:space:]]*.*adreno|VK_DRIVER_FILES[[:space:]]*=[[:space:]]*.*(freedreno|adreno)' "$file" 2>/dev/null; then
            printf 'matching override: %s\n' "$file"
            grep -nE 'MESA_LOADER_DRIVER_OVERRIDE|GBM_BACKENDS_PATH|VK_DRIVER_FILES' "$file"
        fi
    done
}

print_renderer() {
    if command -v glxinfo >/dev/null 2>&1; then
        echo '--- GLX renderer (override variables removed) ---'
        env -u MESA_LOADER_DRIVER_OVERRIDE -u GBM_BACKENDS_PATH -u VK_DRIVER_FILES \
            glxinfo -B 2>&1 | grep -E 'OpenGL (vendor|renderer)|DRI3|Error' || true
    else
        echo 'glxinfo: not installed'
    fi
    if command -v eglinfo >/dev/null 2>&1; then
        echo '--- EGL renderer (override variables removed) ---'
        env -u MESA_LOADER_DRIVER_OVERRIDE -u GBM_BACKENDS_PATH -u VK_DRIVER_FILES \
            eglinfo -B 2>&1 | grep -E 'OpenGL .*renderer|EGL vendor|MESA: error|libEGL warning' || true
    else
        echo 'eglinfo: not installed'
    fi
}

check() {
    log "GPU userspace diagnostic started"
    printf '%s\n' '--- system ---'
    uname -a
    printf 'cmdline: '; cat /proc/cmdline 2>/dev/null || true
    printf '%s\n' '--- GPU detection ---'
    if is_adreno_machine; then
        echo 'Adreno/Freedreno platform detected.'
    else
        echo 'Adreno/Freedreno platform not confirmed; no changes will be proposed automatically.'
    fi
    for dev in /sys/bus/platform/devices/*gpu /sys/bus/platform/devices/*adreno*; do
        [ -e "$dev" ] || continue
        printf '%s: ' "$dev"
        readlink -f "$dev/driver" 2>/dev/null || echo 'no driver binding'
        grep -E 'DRIVER=|OF_COMPATIBLE_' "$dev/uevent" 2>/dev/null || true
    done
    printf '%s\n' '--- current process overrides ---'
    env | grep -E '^(MESA|LIBGL|EGL|GBM|DRI|VK_|GALLIUM|__GL)' || echo 'no graphics override variables'
    printf '%s\n' '--- configured overrides ---'
    print_file_status
    printf '%s\n' '--- firmware ---'
    for fw in /lib/firmware/qcom/a660_sqe.fw /lib/firmware/qcom/a660_gmu.bin; do
        [ -f "$fw" ] && ls -l "$fw" || echo "missing: $fw"
    done
    printf '%s\n' '--- renderer ---'
    print_renderer
    log "GPU userspace diagnostic finished"
}

matches_bad_override() {
    grep -qE 'MESA_LOADER_DRIVER_OVERRIDE[[:space:]]*=[[:space:]]*.*zink|GBM_BACKENDS_PATH[[:space:]]*=[[:space:]]*.*adreno|VK_DRIVER_FILES[[:space:]]*=[[:space:]]*.*(freedreno|adreno)' "$1" 2>/dev/null
}

disable_file() {
    file=$1
    [ -f "$file" ] || return 0
    if ! matches_bad_override "$file"; then
        log "skip (no recognized forced override): $file"
        return 0
    fi
    disabled="$file.disabled.$timestamp"
    if [ -e "$disabled" ] || [ -L "$disabled" ]; then
        warn "refusing to overwrite existing disabled file: $disabled"
        return 1
    fi
    if ! mkdir -p "$(dirname "$session_dir${file}")"; then
        warn "cannot create backup directory for: $file"
        return 1
    fi
    if ! cp -a "$file" "$session_dir${file}"; then
        warn "cannot back up: $file"
        return 1
    fi
    if ! mv "$file" "$disabled"; then
        warn "cannot disable: $file (backup was kept at $session_dir${file})"
        return 1
    fi
    printf '%s\n' "$file" >>"$session_dir/manifest"
    log "disabled: $file -> $disabled"
}

fix() {
    need_root
    if ! is_adreno_machine; then
        warn 'Adreno/Freedreno was not detected; refusing automatic changes.'
        exit 1
    fi
    timestamp=$(date +%Y%m%dT%H%M%S%z)-$$
    session_dir="$BACKUP_ROOT/$timestamp"
    if ! mkdir -p "$session_dir" || ! : >"$session_dir/manifest"; then
        echo "ERROR: cannot create backup directory: $session_dir" >&2
        exit 1
    fi
    log "GPU userspace repair started; backup=$session_dir"
    log 'No kernel, package, GRUB, or reboot operation will be performed.'

    # Known locations used by the gaokun/Adreno setup, plus other matching
    # environment files in the same standard directories.
    files='/etc/environment.d/adreno.conf /etc/profile.d/adreno.sh'
    for file in /etc/environment.d/*.conf /etc/profile.d/*.sh; do
        [ -f "$file" ] || continue
        case " $files " in *" $file "*) continue ;; esac
        if matches_bad_override "$file"; then files="$files $file"; fi
    done
    failures=0
    for file in $files; do
        if ! disable_file "$file"; then failures=1; fi
    done
    if [ "$failures" -ne 0 ]; then
        warn "one or more files could not be disabled; backup=$session_dir"
        exit 1
    fi

    log 'Configuration files after change:'
    print_file_status >>"$LOG_FILE" 2>&1 || true
    log 'A logout/login or reboot is required for already-running desktop processes.'
    log "GPU userspace repair finished; rollback with: sudo $SCRIPT_NAME --rollback $session_dir"
    printf '\nBackup directory: %s\n' "$session_dir"
    printf 'Log file: %s\n' "$LOG_FILE"
    printf 'Log out/in before judging the desktop renderer.\n'
}

rollback() {
    need_root
    dir=$1
    [ -d "$dir" ] || { echo "ERROR: backup directory not found: $dir" >&2; exit 2; }
    log "GPU userspace rollback started from $dir"
    restored=1
    skipped=0
    manifest="$dir/manifest"
    if [ -f "$manifest" ]; then
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            case "$file" in
                /etc/environment.d/*|/etc/profile.d/*) ;;
                *) warn "ignoring unsafe manifest path: $file"; skipped=1; continue ;;
            esac
            backup="$dir$file"
            if [ ! -f "$backup" ]; then
                warn "backup file missing: $backup"
                skipped=1
                continue
            fi
            if [ -e "$file" ] || [ -L "$file" ]; then
                warn "active file already exists; refusing to overwrite: $file"
                skipped=1
                continue
            fi
            mkdir -p "$(dirname "$file")"
            cp -a "$backup" "$file"
            log "restored: $file"
            restored=0
        done <"$manifest"
    else
        # Compatibility with backups made before the manifest was added.
        for file in /etc/environment.d/adreno.conf /etc/profile.d/adreno.sh; do
            backup="$dir$file"
            if [ -f "$backup" ] && [ ! -e "$file" ] && [ ! -L "$file" ]; then
                mkdir -p "$(dirname "$file")"
                cp -a "$backup" "$file"
                log "restored: $file"
                restored=0
            elif [ -e "$file" ] || [ -L "$file" ]; then
                warn "active file already exists; refusing to overwrite: $file"
                skipped=1
            fi
        done
    fi
    if [ "$restored" -ne 0 ] || [ "$skipped" -ne 0 ]; then
        warn "rollback did not restore every file from: $dir"
        exit 1
    fi
    log 'Rollback finished; logout/login is required.'
}

case "${1:---check}" in
    --check) check ;;
    --fix) fix ;;
    --rollback)
        [ $# -eq 2 ] || { usage >&2; exit 2; }
        rollback "$2"
        ;;
    --help|-h) usage ;;
    *) usage >&2; exit 2 ;;
esac
