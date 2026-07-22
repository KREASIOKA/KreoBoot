#!/usr/bin/env bash
# ==============================================================================
#  KreoBoot — Universal Bootable Media Creator
#  Cross-platform (Linux & macOS) interactive TUI for building bootable USB /
#  external drives from any ISO/IMG source, converting drive filesystems, and
#  preparing Windows installers with optional setup-requirement bypasses.
#
#  Author:  generated for personal system-administration use
#  License: do whatever you want with it
#
#  Requires: bash >= 4.3 (namerefs, associative arrays). On macOS the shipped
#  /bin/bash is 3.2, so this script auto-relaunches itself under a modern bash
#  installed via Homebrew if one is available (see bootstrap section below).
# ==============================================================================

# We deliberately do NOT use `set -e`. This is an interactive, menu-driven
# application: a failed/declined step (e.g. a missing optional tool, a scan
# that finds nothing) must return the user to a menu, not kill the process.
set -u
set -o pipefail

# ------------------------------------------------------------------------------
# 0. BOOTSTRAP — guarantee a capable bash before anything else runs
# ------------------------------------------------------------------------------
# macOS ships bash 3.2 by default (Apple froze it for licensing reasons).
# This app relies on bash 4+ features (namerefs, associative arrays, mapfile).
# If we detect an old bash, we try to re-exec under a newer one before doing
# anything else. This must happen FIRST, before we use any 4+ syntax.
__bf_bootstrap() {
    if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
        return 0
    fi

    # Try well-known Homebrew locations for a modern bash.
    local candidate
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            local ver
            ver="$("$candidate" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
            if [ "${ver:-0}" -ge 4 ] 2>/dev/null; then
                exec "$candidate" "$0" "$@"
            fi
        fi
    done

    # No modern bash found — refuse to run in a way that would half-work.
    printf '\n'
    printf 'KreoBoot needs Bash 4.3 or newer. This system only has Bash %s.\n' "${BASH_VERSION:-unknown}"
    printf 'On macOS this is expected: Apple ships an ancient bash 3.2 by default.\n\n'
    printf 'Please install a modern bash and re-run this script:\n'
    printf '    brew install bash\n'
    printf '    sudo bash "%s"\n\n' "$0"
    exit 1
}
__bf_bootstrap "$@"

# ------------------------------------------------------------------------------
# 1. ROOT PRIVILEGES — acquire them up-front so nothing fails mid-way
# ------------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "KreoBoot needs Administrator (root) privileges to manage disks."
    echo "Re-launching with sudo..."
    exec sudo -E "$0" "$@"
fi

# ------------------------------------------------------------------------------
# 2. GLOBAL CONSTANTS
# ------------------------------------------------------------------------------
readonly BF_VERSION="1.0.0"
readonly BF_OS="$(uname -s)"                # Linux / Darwin
readonly BF_ARCH="$(uname -m)"
readonly BF_REAL_USER="${SUDO_USER:-$(id -un)}"
BF_REAL_HOME="$(eval echo "~${BF_REAL_USER}" 2>/dev/null || echo "$HOME")"
readonly BF_REAL_HOME
readonly BF_WORKDIR="$(mktemp -d /tmp/kreoboot.XXXXXX)"
readonly BF_LOGFILE="${BF_WORKDIR}/kreoboot.log"

# Runtime state (populated as the app runs)
declare -a BF_DEVICES_NAME=()
declare -a BF_DEVICES_SIZE=()
declare -a BF_DEVICES_SIZE_BYTES=()
declare -a BF_DEVICES_MODEL=()
declare -a BF_DEVICES_TRAN=()
declare -a BF_DEVICES_KIND=()      # disk / rom
declare -a BF_DEVICES_PATH=()      # full /dev/xxx or macOS /dev/diskN
declare -a BF_FOUND_IMAGES=()      # discovered iso/img paths
declare -a BF_FOUND_IMAGES_SIZE=()

SELECTED_SOURCE_PATH=""
SELECTED_SOURCE_SIZE=0
SELECTED_DEVICE_PATH=""
SELECTED_DEVICE_INDEX=0
SELECTED_DEVICE_KIND=""
SELECTED_FS="FAT32"
SELECTED_LABEL="KREOBOOT"
IS_WINDOWS_SOURCE=0
BF_LAST_FORMATTED_PART=""
declare -a WIN_TWEAKS_SELECTED=()   # holds chosen tweak keys

# ------------------------------------------------------------------------------
# 3. COLOR THEME — light-blue accent, used throughout the TUI
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_BLUE=$'\033[38;5;117m'        # primary light-blue accent
    C_BLUE_DEEP=$'\033[38;5;75m'    # secondary blue (borders)
    C_BLUE_PALE=$'\033[38;5;153m'   # pale blue (hints)
    C_WHITE=$'\033[97m'
    C_GRAY=$'\033[38;5;245m'
    C_GREEN=$'\033[38;5;120m'
    C_YELLOW=$'\033[38;5;221m'
    C_RED=$'\033[38;5;203m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_BLUE=""; C_BLUE_DEEP=""; C_BLUE_PALE=""
    C_WHITE=""; C_GRAY=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
readonly C_RESET C_BOLD C_DIM C_BLUE C_BLUE_DEEP C_BLUE_PALE C_WHITE C_GRAY C_GREEN C_YELLOW C_RED

# ------------------------------------------------------------------------------
# 4. TERMINAL LIFECYCLE — cursor, cleanup, signal handling
# ------------------------------------------------------------------------------
__bf_cleanup() {
    tput cnorm 2>/dev/null || printf '\033[?25h'   # show cursor again
    stty sane 2>/dev/null
    # Best-effort unmount / tempdir cleanup of anything we may have left mounted
    if [ -n "${MNT_ISO:-}" ] && mountpoint -q "${MNT_ISO}" 2>/dev/null; then
        umount "${MNT_ISO}" 2>/dev/null
    fi
    if [ -n "${MNT_USB:-}" ] && mountpoint -q "${MNT_USB}" 2>/dev/null; then
        umount "${MNT_USB}" 2>/dev/null
    fi
    rm -rf "${BF_WORKDIR}" 2>/dev/null
}
trap __bf_cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

bf_log() {
    # Everything interesting is written to a logfile instead of the screen —
    # the screen only ever shows spinners / progress bars, never raw logs.
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$BF_LOGFILE"
}

# ------------------------------------------------------------------------------
# 5. BANNER
# ------------------------------------------------------------------------------
bf_print_banner() {
    clear
    local cols
    cols="$(tput cols 2>/dev/null || echo 80)"
    
    if [ "$cols" -ge 86 ]; then
        printf '%s' "$C_BLUE"
        cat << 'BANNER'

 █████   ████                             ███████████                     █████   
░░███   ███░                             ░░███░░░░░███                   ░░███    
 ░███  ███    ████████   ██████   ██████  ░███    ░███  ██████   ██████  ███████  
 ░███████    ░░███░░███ ███░░███ ███░░███ ░██████████  ███░░███ ███░░███░░░███░   
 ░███░░███    ░███ ░░░ ░███████ ░███ ░███ ░███░░░░░███░███ ░███░███ ░███  ░███    
 ░███ ░░███   ░███     ░███░░░  ░███ ░███ ░███    ░███░███ ░███░███ ░███  ░███ ███
 █████ ░░████ █████    ░░██████ ░░██████  ███████████ ░░██████ ░░██████   ░░█████ 
░░░░░   ░░░░ ░░░░░      ░░░░░░   ░░░░░░  ░░░░░░░░░░░   ░░░░░░   ░░░░░░     ░░░░░  

BANNER
        printf '%s' "$C_RESET"
        printf '%s          Universal Bootable Media Creator  ·  v%s%s\n' "$C_BLUE_PALE" "$BF_VERSION" "$C_RESET"
        printf '%s          %s / %s  ·  Cross-platform (Linux & macOS)%s\n\n' "$C_GRAY" "$BF_OS" "$BF_ARCH" "$C_RESET"
    else
        printf '\n%s  KreoBoot%s — Universal Bootable Media Creator (v%s)\n' "${C_BOLD}${C_BLUE}" "$C_RESET" "$BF_VERSION"
        printf '%s  %s / %s  ·  Cross-platform (Linux & macOS)%s\n\n' "$C_GRAY" "$BF_OS" "$BF_ARCH" "$C_RESET"
    fi
}

# ------------------------------------------------------------------------------
# 6. INPUT / INTERACTIVE ENGINE
#    Everything the user does is arrow-keys + Enter (+ Space for checklists).
#    No external whiptail/dialog dependency — implemented in pure bash so it
#    behaves identically on Linux and macOS.
# ------------------------------------------------------------------------------
BF_MENU_RESULT=0
declare -a BF_CHECKLIST_RESULT=()
BF_TEXT_RESULT=""

bf_read_key() {
    local key rest
    IFS= read -rsn1 key
    if [ "$key" = $'\x1b' ]; then
        IFS= read -rsn2 -t 0.05 rest
        key+="$rest"
    fi
    printf '%s' "$key"
}

# bf_menu "Title" "hint or empty" opt1 opt2 ... -> BF_MENU_RESULT (0-based index, -1 = back/quit)
bf_menu() {
    local title="$1" hint="$2"; shift 2
    local -a options=("$@")
    local count=${#options[@]}
    [ "$count" -eq 0 ] && { BF_MENU_RESULT=-1; return; }
    local sel=0 key first=1 lines_drawn=0 i

    tput civis 2>/dev/null
    while true; do
        [ "$first" -eq 0 ] && printf '\033[%dA' "$lines_drawn"
        first=0; lines_drawn=0

        printf '\033[K%s%s%s\n' "${C_BOLD}${C_BLUE}" "$title" "$C_RESET"; lines_drawn=$((lines_drawn+1))
        printf '\033[K\n'; lines_drawn=$((lines_drawn+1))
        for i in "${!options[@]}"; do
            if [ "$i" -eq "$sel" ]; then
                printf '\033[K  %s❯ %s%s\n' "${C_BLUE}${C_BOLD}" "${options[$i]}" "$C_RESET"
            else
                printf '\033[K    %s%s%s\n' "$C_GRAY" "${options[$i]}" "$C_RESET"
            fi
            lines_drawn=$((lines_drawn+1))
        done
        printf '\033[K\n'; lines_drawn=$((lines_drawn+1))
        printf '\033[K%s%s%s\n' "$C_DIM" "${hint:-↑/↓ Navigate    Enter Select    Q Back}" "$C_RESET"
        lines_drawn=$((lines_drawn+1))

        key="$(bf_read_key)"
        case "$key" in
            $'\x1b[A') sel=$(( (sel - 1 + count) % count )) ;;
            $'\x1b[B') sel=$(( (sel + 1) % count )) ;;
            "")        break ;;
            q|Q)       sel=-1; break ;;
        esac
    done
    tput cnorm 2>/dev/null
    BF_MENU_RESULT=$sel
}

# bf_checklist "Title" "hint or empty" opt1 opt2 ... -> BF_CHECKLIST_RESULT=(indices...)
bf_checklist() {
    local title="$1" hint="$2"; shift 2
    local -a options=("$@")
    local count=${#options[@]}
    BF_CHECKLIST_RESULT=()
    [ "$count" -eq 0 ] && return
    local -a checked=()
    local i sel=0 key first=1 lines_drawn=0 cancelled=0
    for ((i = 0; i < count; i++)); do checked[i]=0; done

    tput civis 2>/dev/null
    while true; do
        [ "$first" -eq 0 ] && printf '\033[%dA' "$lines_drawn"
        first=0; lines_drawn=0

        printf '\033[K%s%s%s\n' "${C_BOLD}${C_BLUE}" "$title" "$C_RESET"; lines_drawn=$((lines_drawn+1))
        printf '\033[K\n'; lines_drawn=$((lines_drawn+1))
        for i in "${!options[@]}"; do
            local box="${C_GRAY}[ ]${C_RESET}"
            [ "${checked[$i]}" -eq 1 ] && box="${C_GREEN}[x]${C_RESET}"
            if [ "$i" -eq "$sel" ]; then
                printf '\033[K  %s❯%s %b %s%s\n' "${C_BLUE}${C_BOLD}" "$C_RESET" "$box" "${C_WHITE}${options[$i]}" "$C_RESET"
            else
                printf '\033[K    %b %s%s%s\n' "$box" "$C_GRAY" "${options[$i]}" "$C_RESET"
            fi
            lines_drawn=$((lines_drawn+1))
        done
        printf '\033[K\n'; lines_drawn=$((lines_drawn+1))
        printf '\033[K%s%s%s\n' "$C_DIM" "${hint:-↑/↓ Navigate    Space Toggle    Enter Confirm    Q Cancel}" "$C_RESET"
        lines_drawn=$((lines_drawn+1))

        key="$(bf_read_key)"
        case "$key" in
            $'\x1b[A') sel=$(( (sel - 1 + count) % count )) ;;
            $'\x1b[B') sel=$(( (sel + 1) % count )) ;;
            " ")       checked[$sel]=$(( 1 - checked[$sel] )) ;;
            "")        break ;;
            q|Q)       cancelled=1; break ;;
        esac
    done
    tput cnorm 2>/dev/null
    if [ "$cancelled" -eq 0 ]; then
        for i in "${!options[@]}"; do
            [ "${checked[$i]}" -eq 1 ] && BF_CHECKLIST_RESULT+=("$i")
        done
    fi
}

# bf_confirm "Question" -> return code 0 = yes, 1 = no/cancel
bf_confirm() {
    bf_menu "$1" "↑/↓ Navigate    Enter Select" "Yes" "No"
    [ "$BF_MENU_RESULT" -eq 0 ]
}

# bf_text_input "Prompt" "default" -> BF_TEXT_RESULT
bf_text_input() {
    local prompt="$1" default="$2"
    tput cnorm 2>/dev/null
    printf '\n%s%s%s' "${C_BOLD}${C_BLUE}" "$prompt" "$C_RESET"
    [ -n "$default" ] && printf ' %s(default: %s)%s' "$C_DIM" "$default" "$C_RESET"
    printf '\n%s> %s' "$C_BLUE" "$C_RESET"
    local input=""
    read -r input
    BF_TEXT_RESULT="${input:-$default}"
    tput civis 2>/dev/null
}

bf_pause() {
    printf '\n%s%s%s' "$C_DIM" "${1:-Press Enter to continue...}" "$C_RESET"
    read -r _dummy
}

# ------------------------------------------------------------------------------
# 7. SPINNERS & PROGRESS BARS — the visual stand-in for raw terminal logs
# ------------------------------------------------------------------------------
BF_SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

# bf_run_with_spinner "Message shown while running" cmd arg1 arg2 ...
# stdout/stderr of the command are redirected to the logfile — never shown raw.
bf_run_with_spinner() {
    local message="$1"; shift
    bf_log "START: $message :: $*"
    "$@" >> "$BF_LOGFILE" 2>&1 &
    local pid=$! i=0
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        local frame="${BF_SPIN_FRAMES[$(( i % ${#BF_SPIN_FRAMES[@]} ))]}"
        printf '\r%s%s%s  %s%s%s   ' "$C_BLUE" "$frame" "$C_RESET" "$C_WHITE" "$message" "$C_RESET"
        i=$((i + 1))
        sleep 0.08
    done
    wait "$pid"
    local status=$?
    tput cnorm 2>/dev/null
    if [ "$status" -eq 0 ]; then
        printf '\r%s✔%s  %s%s%s%*s\n' "$C_GREEN" "$C_RESET" "$C_WHITE" "$message" "$C_RESET" 6 ""
    else
        printf '\r%s✘%s  %s%s %s(exit %d — details in log)%s%*s\n' "$C_RED" "$C_RESET" "$C_WHITE" "$message" "$C_RED" "$status" "$C_RESET" 6 ""
    fi
    bf_log "END ($status): $message"
    return "$status"
}

# bf_progress_bar <percent 0-100> <label text>
bf_progress_bar() {
    local percent=${1:-0} label="${2:-}"
    [ "$percent" -lt 0 ] && percent=0
    [ "$percent" -gt 100 ] && percent=100
    local width=34
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar_filled="" bar_empty="" n
    for ((n = 0; n < filled; n++)); do bar_filled+="█"; done
    for ((n = 0; n < empty; n++)); do bar_empty+="░"; done
    printf '\r%s%s%s%s%s %s%3d%%%s  %s%s%s' \
        "$C_BLUE" "$bar_filled" "$C_GRAY" "$bar_empty" "$C_RESET" \
        "$C_WHITE" "$percent" "$C_RESET" "$C_DIM" "$label" "$C_RESET"
}

bf_section_header() {
    printf '\n%s%s── %s %s%s\n\n' "$C_BOLD" "$C_BLUE_DEEP" "$1" "$(printf -- '─%.0s' $(seq 1 $(( 50 > ${#1} ? 50 - ${#1} : 0 )) 2>/dev/null))" "$C_RESET"
}

# ------------------------------------------------------------------------------
# 8. GENERIC HELPERS
# ------------------------------------------------------------------------------
bf_bytes_human() {
    local bytes="${1:-0}"
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", units, " ");
        u = 1;
        if (b < 0) b = 0;
        while (b >= 1024 && u < 6) { b /= 1024; u++ }
        printf "%.1f %s", b, units[u]
    }'
}

bf_file_size_bytes() {
    # Cross-platform stat: GNU (-c) on Linux, BSD (-f) on macOS
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
}

bf_have_cmd() { command -v "$1" >/dev/null 2>&1; }

bf_is_linux()  { [ "$BF_OS" = "Linux" ]; }
bf_is_macos()  { [ "$BF_OS" = "Darwin" ]; }

# ------------------------------------------------------------------------------
# 9. DEPENDENCY MANAGEMENT — check tools exist, offer to install what's missing
# ------------------------------------------------------------------------------
declare -A BF_APT_PKG_FOR=(
    [parted]=parted
    [mkfs.fat]=dosfstools
    [mkfs.vfat]=dosfstools
    [mkfs.ntfs]=ntfs-3g
    [mkfs.exfat]=exfatprogs
    [mkfs.ext4]=e2fsprogs
    [mkfs.hfsplus]=hfsprogs
    [rsync]=rsync
    [wipefs]=util-linux
    [lsblk]=util-linux
    [blkid]=util-linux
    [findmnt]=util-linux
    [wimlib-imagex]=wimtools
    [udevadm]=udev
    [growisofs]=dvd+rw-tools
    [wodim]=wodim
)
declare -A BF_BREW_PKG_FOR=(
    [wimlib-imagex]=wimlib
    [rsync]=rsync
    [gsed]=gnu-sed
)

# bf_ensure_tools "human description" tool1 tool2 ...
# Returns 0 if all tools end up available, 1 otherwise (caller decides how to proceed).
bf_ensure_tools() {
    local description="$1"; shift
    local -a wanted=("$@")
    local -a missing=()
    local t
    for t in "${wanted[@]}"; do
        bf_have_cmd "$t" || missing+=("$t")
    done
    [ "${#missing[@]}" -eq 0 ] && return 0

    bf_section_header "Missing dependencies"
    printf '%sThe following tools are required for: %s%s\n' "$C_WHITE" "$description" "$C_RESET"
    printf '  %s%s%s\n' "$C_YELLOW" "${missing[*]}" "$C_RESET"

    if bf_is_linux; then
        if ! bf_have_cmd apt-get; then
            printf '\n%sapt-get was not found — please install these manually.%s\n' "$C_RED" "$C_RESET"
            bf_pause
            return 1
        fi
        local -a pkgs=()
        for t in "${missing[@]}"; do
            local p="${BF_APT_PKG_FOR[$t]:-}"
            [ -n "$p" ] && pkgs+=("$p")
        done
        mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
        if ! bf_confirm "Install packages now via apt-get? (${pkgs[*]})"; then
            return 1
        fi
        bf_run_with_spinner "Updating package index..." apt-get update -qq || true
        bf_run_with_spinner "Installing: ${pkgs[*]}" apt-get install -y -qq "${pkgs[@]}"
    elif bf_is_macos; then
        if ! bf_have_cmd brew; then
            printf '\n%sHomebrew was not found. Install it from https://brew.sh then re-run KreoBoot.%s\n' "$C_RED" "$C_RESET"
            bf_pause
            return 1
        fi
        local -a pkgs=()
        for t in "${missing[@]}"; do
            local p="${BF_BREW_PKG_FOR[$t]:-}"
            [ -n "$p" ] && pkgs+=("$p")
        done
        mapfile -t pkgs < <(printf '%s\n' "${pkgs[@]}" | sort -u)
        if [ "${#pkgs[@]}" -eq 0 ]; then
            printf '\n%sSome required tools have no known Homebrew package and must be installed manually:%s\n' "$C_YELLOW" "$C_RESET"
            printf '  %s\n' "${missing[*]}"
            bf_pause
            return 1
        fi
        if ! bf_confirm "Install packages now via Homebrew? (${pkgs[*]})"; then
            return 1
        fi
        # brew must not run as root — drop back to the invoking user for this.
        local brew_user="${SUDO_USER:-$(whoami)}"
        bf_run_with_spinner "Installing: ${pkgs[*]}" sudo -u "$brew_user" brew install "${pkgs[@]}"
    fi

    # Re-check
    missing=()
    for t in "${wanted[@]}"; do
        bf_have_cmd "$t" || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf '\n%sStill missing: %s%s\n' "$C_RED" "${missing[*]}" "$C_RESET"
        bf_pause
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 10. DEVICE DETECTION — cross-platform, since scanning patterns differ
#     completely between Linux (lsblk/sysfs) and macOS (diskutil).
# ------------------------------------------------------------------------------
bf_extract_kv() {
    # bf_extract_kv "KEY=\"val\" OTHER=\"val2\"" "KEY" -> prints val
    local line="$1" key="$2"
    if [[ $line =~ ${key}=\"([^\"]*)\" ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

BF_ROOT_DISK=""
bf_detect_root_disk() {
    # Never let the user select the disk the OS itself is running from.
    local root_src root_disk
    if bf_is_linux; then
        root_src="$(findmnt -no SOURCE / 2>/dev/null)"
        root_disk="$(lsblk -no pkname "$root_src" 2>/dev/null | head -1)"
        [ -z "$root_disk" ] && root_disk="$(basename "$root_src" 2>/dev/null | sed -E 's/[0-9]+$//')"
        BF_ROOT_DISK="$root_disk"
    elif bf_is_macos; then
        root_src="$(diskutil info / 2>/dev/null | awk -F': +' '/Part of Whole:/{print $2; exit}')"
        BF_ROOT_DISK="$root_src"
    fi
}

bf_scan_devices_linux() {
    BF_DEVICES_NAME=(); BF_DEVICES_SIZE=(); BF_DEVICES_SIZE_BYTES=(); BF_DEVICES_MODEL=(); BF_DEVICES_TRAN=(); BF_DEVICES_KIND=(); BF_DEVICES_PATH=()
    bf_detect_root_disk
    local line name size_bytes model tran type rm
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        name="$(bf_extract_kv "$line" NAME)"
        size_bytes="$(bf_extract_kv "$line" SIZE)"
        model="$(bf_extract_kv "$line" MODEL)"
        tran="$(bf_extract_kv "$line" TRAN)"
        type="$(bf_extract_kv "$line" TYPE)"
        rm="$(bf_extract_kv "$line" RM)"
        [ -n "$BF_ROOT_DISK" ] && [ "$name" = "$BF_ROOT_DISK" ] && continue

        case "$type" in
            disk)
                # Only surface devices that look external/removable, for safety.
                if [ "$tran" = "usb" ] || [ "$rm" = "1" ]; then
                    BF_DEVICES_NAME+=("$name")
                    BF_DEVICES_SIZE+=("$(bf_bytes_human "${size_bytes:-0}")")
                    BF_DEVICES_SIZE_BYTES+=("${size_bytes:-0}")
                    BF_DEVICES_MODEL+=("${model:-Unnamed Drive}")
                    BF_DEVICES_TRAN+=("${tran:-unknown}")
                    BF_DEVICES_KIND+=("disk")
                    BF_DEVICES_PATH+=("/dev/$name")
                fi
                ;;
            rom)
                BF_DEVICES_NAME+=("$name")
                BF_DEVICES_SIZE+=("$(bf_bytes_human "${size_bytes:-0}")")
                BF_DEVICES_SIZE_BYTES+=("${size_bytes:-0}")
                BF_DEVICES_MODEL+=("${model:-Optical Drive}")
                BF_DEVICES_TRAN+=("${tran:-unknown}")
                BF_DEVICES_KIND+=("rom")
                BF_DEVICES_PATH+=("/dev/$name")
                ;;
        esac
    done < <(lsblk -dn -b -P -o NAME,SIZE,MODEL,TRAN,TYPE,RM 2>/dev/null)
}

bf_scan_devices_macos() {
    BF_DEVICES_NAME=(); BF_DEVICES_SIZE=(); BF_DEVICES_SIZE_BYTES=(); BF_DEVICES_MODEL=(); BF_DEVICES_TRAN=(); BF_DEVICES_KIND=(); BF_DEVICES_PATH=()
    bf_detect_root_disk
    local id info model size_bytes protocol
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        [ -n "$BF_ROOT_DISK" ] && [ "$id" = "$BF_ROOT_DISK" ] && continue
        info="$(diskutil info "$id" 2>/dev/null)"
        model="$(printf '%s\n' "$info" | awk -F': +' '/Media Name:/{print $2; exit}')"
        protocol="$(printf '%s\n' "$info" | awk -F': +' '/Protocol:/{print $2; exit}')"
        size_bytes="$(printf '%s\n' "$info" | grep -oE '\([0-9]+ Bytes\)' | grep -oE '[0-9]+' | head -1)"
        BF_DEVICES_NAME+=("$id")
        BF_DEVICES_SIZE+=("$(bf_bytes_human "${size_bytes:-0}")")
        BF_DEVICES_SIZE_BYTES+=("${size_bytes:-0}")
        BF_DEVICES_MODEL+=("${model:-Unnamed Drive}")
        BF_DEVICES_TRAN+=("${protocol:-unknown}")
        BF_DEVICES_KIND+=("disk")
        BF_DEVICES_PATH+=("/dev/$id")
    done < <(diskutil list external physical 2>/dev/null | grep -oE '^/dev/disk[0-9]+' | sed 's#/dev/##')

    # Optical drives, best-effort (most modern Macs have none).
    if bf_have_cmd drutil; then
        if drutil status 2>/dev/null | grep -qi 'Type:'; then
            BF_DEVICES_NAME+=("optical0")
            BF_DEVICES_SIZE+=("—")
            BF_DEVICES_SIZE_BYTES+=("0")
            BF_DEVICES_MODEL+=("External Optical Drive")
            BF_DEVICES_TRAN+=("usb")
            BF_DEVICES_KIND+=("rom")
            BF_DEVICES_PATH+=("optical0")
        fi
    fi
}

bf_scan_devices() {
    if bf_is_macos; then bf_scan_devices_macos; else bf_scan_devices_linux; fi
}

# ------------------------------------------------------------------------------
# 11. SYSTEM INFO SCREEN
# ------------------------------------------------------------------------------
bf_gather_system_info() {
    bf_scan_devices
    local usb_count=0 rom_count=0 i
    for i in "${!BF_DEVICES_KIND[@]}"; do
        if [ "${BF_DEVICES_KIND[$i]}" = "rom" ]; then
            rom_count=$((rom_count + 1))
        else
            usb_count=$((usb_count + 1))
        fi
    done
    BF_SYS_USB_COUNT=$usb_count
    BF_SYS_ROM_COUNT=$rom_count
}

bf_print_system_info() {
    local os_pretty kernel
    if bf_is_linux; then
        if [ -r /etc/os-release ]; then
            os_pretty="$(. /etc/os-release; echo "${PRETTY_NAME:-Linux}")"
        else
            os_pretty="Linux"
        fi
    else
        os_pretty="macOS $(sw_vers -productVersion 2>/dev/null)"
    fi
    kernel="$(uname -r)"

    printf '%s┌─────────────────────────────────────────────────────────────────┐%s\n' "$C_BLUE_DEEP" "$C_RESET"
    printf '%s│%s  %-20s %s%-42s%s%s│%s\n' "$C_BLUE_DEEP" "$C_RESET" "Operating System" "$C_WHITE" "$os_pretty" "$C_RESET" "$C_BLUE_DEEP" "$C_RESET"
    printf '%s│%s  %-20s %s%-42s%s%s│%s\n' "$C_BLUE_DEEP" "$C_RESET" "Kernel / Arch" "$C_WHITE" "$kernel ($BF_ARCH)" "$C_RESET" "$C_BLUE_DEEP" "$C_RESET"
    printf '%s│%s  %-20s %s%-42s%s%s│%s\n' "$C_BLUE_DEEP" "$C_RESET" "Removable drives" "$C_GREEN" "${BF_SYS_USB_COUNT:-0} detected" "$C_RESET" "$C_BLUE_DEEP" "$C_RESET"
    printf '%s│%s  %-20s %s%-42s%s%s│%s\n' "$C_BLUE_DEEP" "$C_RESET" "Optical (CD/DVD)" "$C_GREEN" "${BF_SYS_ROM_COUNT:-0} detected" "$C_RESET" "$C_BLUE_DEEP" "$C_RESET"
    printf '%s└─────────────────────────────────────────────────────────────────┘%s\n' "$C_BLUE_DEEP" "$C_RESET"
}

# ------------------------------------------------------------------------------
# 12. IMAGE SCANNING — quick (common folders) & full (whole filesystem)
#     Directory layout differs completely between Linux and macOS, so the
#     candidate search paths are branched per OS.
# ------------------------------------------------------------------------------
bf_quick_scan_dirs() {
    if bf_is_macos; then
        printf '%s\n' \
            "$BF_REAL_HOME/Downloads" "$BF_REAL_HOME/Desktop" "$BF_REAL_HOME/Documents" \
            "/Volumes" "$PWD"
    else
        printf '%s\n' \
            "$BF_REAL_HOME/Downloads" "$BF_REAL_HOME/Desktop" "$BF_REAL_HOME/Documents" \
            "/mnt" "/media" "/run/media/${BF_REAL_USER}" "/srv" "$PWD"
    fi
}

# bf_scan_images "quick"|"full" -> fills BF_FOUND_IMAGES / BF_FOUND_IMAGES_SIZE
bf_scan_images() {
    local mode="$1"
    BF_FOUND_IMAGES=(); BF_FOUND_IMAGES_SIZE=()
    local result_file="${BF_WORKDIR}/scan_results.txt"
    : > "$result_file"

    if [ "$mode" = "quick" ]; then
        (
            local d
            while IFS= read -r d; do
                [ -d "$d" ] || continue
                find "$d" -maxdepth 4 -type f \
                    \( -iname '*.iso' -o -iname '*.img' -o -iname '*.dmg' -o -iname '*.esd' \) \
                    -size +20M 2>/dev/null
            done < <(bf_quick_scan_dirs)
        ) >> "$result_file" &
    else
        local -a prune=()
        if bf_is_macos; then
            prune=( -path "/System" -o -path "/private/var/vm" -o -path "/private/var/db" -o -path "/dev" )
        else
            prune=( -path "/proc" -o -path "/sys" -o -path "/dev" -o -path "/run" -o -path "/snap" -o -path "/var/lib/docker" )
        fi
        find / \( "${prune[@]}" \) -prune -o -type f \
            \( -iname '*.iso' -o -iname '*.img' -o -iname '*.dmg' -o -iname '*.esd' \) \
            -size +20M -print 2>/dev/null >> "$result_file" &
    fi

    local pid=$! i=0 k=""
    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        local frame="${BF_SPIN_FRAMES[$(( i % ${#BF_SPIN_FRAMES[@]} ))]}"
        local found_count
        found_count="$(wc -l < "$result_file" 2>/dev/null | tr -d ' ')"
        printf '\r%s%s%s  %sScanning for bootable images%s %s(%s found so far · Q to stop early)%s    ' \
            "$C_BLUE" "$frame" "$C_RESET" "$C_WHITE" "$C_RESET" "$C_DIM" "${found_count:-0}" "$C_RESET"
        i=$((i + 1))
        IFS= read -rsn1 -t 0.1 k 2>/dev/null
        if [ "$k" = "q" ] || [ "$k" = "Q" ]; then
            kill "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid" 2>/dev/null
    tput cnorm 2>/dev/null
    sort -u -o "$result_file" "$result_file" 2>/dev/null
    local total
    total="$(wc -l < "$result_file" 2>/dev/null | tr -d ' ')"
    printf '\r%s✔%s  Scan complete — %s image(s) found.%*s\n' "$C_GREEN" "$C_RESET" "${total:-0}" 20 ""

    local line size
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        [ -f "$line" ] || continue
        size="$(bf_file_size_bytes "$line")"
        BF_FOUND_IMAGES+=("$line")
        BF_FOUND_IMAGES_SIZE+=("$size")
    done < "$result_file"
}

# ------------------------------------------------------------------------------
# 13. CUSTOM FILE BROWSER — navigate with arrows only, no manual typing needed
#     (manual path entry is offered too, purely as an optional convenience).
# ------------------------------------------------------------------------------
bf_file_browser() {
    local current_dir="${1:-$BF_REAL_HOME}"
    [ -d "$current_dir" ] || current_dir="$BF_REAL_HOME"
    BF_TEXT_RESULT=""

    while true; do
        local -a entries=() display=()
        entries+=(".."); display+=("⬑  .. (go up one level)")

        local f full icon suffix
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            full="$current_dir/$f"
            if [ -d "$full" ]; then
                entries+=("$f"); display+=("📁 ${f}/")
            elif [ -f "$full" ]; then
                case "${f,,}" in
                    *.iso|*.img|*.dmg|*.esd) icon="💿" ;;
                    *) icon="📄" ;;
                esac
                suffix="$(bf_bytes_human "$(bf_file_size_bytes "$full")")"
                entries+=("$f"); display+=("${icon} ${f}  (${suffix})")
            fi
        done < <(ls -1A "$current_dir" 2>/dev/null | sort)

        entries+=("__manual__"); display+=("✎  Type a path manually")
        entries+=("__cancel__"); display+=("✕  Cancel")

        bf_menu "Browse: ${current_dir}" "↑/↓ Navigate    Enter Open/Select    Q Cancel" "${display[@]}"
        if [ "$BF_MENU_RESULT" -eq -1 ]; then
            BF_TEXT_RESULT=""
            return 1
        fi

        local chosen="${entries[$BF_MENU_RESULT]}"
        case "$chosen" in
            "__cancel__")
                BF_TEXT_RESULT=""
                return 1
                ;;
            "__manual__")
                bf_text_input "Enter full path" "$current_dir/"
                if [ -f "$BF_TEXT_RESULT" ]; then
                    return 0
                elif [ -d "$BF_TEXT_RESULT" ]; then
                    current_dir="$BF_TEXT_RESULT"
                else
                    bf_pause "Path not found. Press Enter to keep browsing..."
                fi
                ;;
            "..")
                current_dir="$(dirname "$current_dir")"
                ;;
            *)
                if [ -d "$current_dir/$chosen" ]; then
                    current_dir="$current_dir/$chosen"
                else
                    BF_TEXT_RESULT="$current_dir/$chosen"
                    return 0
                fi
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 14. PARTITION & FORMAT ENGINE
#     One function per OS; both are called through bf_format_device() so the
#     rest of the app never has to branch on OS again.
# ------------------------------------------------------------------------------
bf_available_formats() {
    # Prints one format code per line, appropriate for the current OS.
    printf 'FAT32\n'
    printf 'EXFAT\n'
    printf 'NTFS\n'
    if bf_is_linux; then
        printf 'EXT4\n'
    else
        printf 'HFSPLUS\n'
    fi
}

bf_format_label_for() {
    case "$1" in
        FAT32)   echo "FAT32  (best UEFI compatibility, 4GB per-file limit)" ;;
        EXFAT)   echo "exFAT  (no size limit, works on Win/macOS/Linux)" ;;
        NTFS)    echo "NTFS   (no size limit, native to Windows)" ;;
        EXT4)    echo "ext4   (Linux native — persistence / Linux-only media)" ;;
        HFSPLUS) echo "Mac OS Extended (Journaled) — classic macOS format" ;;
        *)       echo "$1" ;;
    esac
}

bf_linux_partition_suffix() {
    # /dev/sda -> /dev/sda1   |   /dev/nvme0n1 -> /dev/nvme0n1p1
    local device="$1"
    if [[ "$device" =~ [0-9]$ ]]; then
        printf '%sp1' "$device"
    else
        printf '%s1' "$device"
    fi
}

bf_settle_device() {
    # bf_settle_device <device>
    # Forces the kernel to drop stale partition cache and waits for udev to
    # finish processing all pending events.  Called at every critical boundary
    # in the format pipeline so that the next tool always sees a clean state.
    local device="$1"
    # 1. Wait for any pending udev events to finish
    bf_have_cmd udevadm && udevadm settle --timeout=5 2>/dev/null
    # 2. Force the kernel to re-read the partition table (drops stale entries)
    if bf_have_cmd partprobe; then
        partprobe "$device" 2>/dev/null
    elif bf_have_cmd blockdev; then
        blockdev --rereadpt "$device" 2>/dev/null
    fi
    # 3. Wait again — partprobe/blockdev may have generated new udev events
    bf_have_cmd udevadm && udevadm settle --timeout=5 2>/dev/null
    # 4. Small grace period for any slow daemons (udisks2, gvfs, etc.)
    sleep 1
}

bf_format_device_linux() {
    # bf_format_device_linux <device> <FS> <label> <scheme: gpt|msdos>
    local device="$1" fs="$2" label="$3" scheme="${4:-gpt}"
    local part
    part="$(bf_linux_partition_suffix "$device")"

    # Phase 1: Release the device completely
    bf_settle_device "$device"
    bf_run_with_spinner "Unmounting any mounted partitions on ${device}..." \
        bash -c "umount ${device}?* 2>/dev/null; exit 0" || true
    bf_settle_device "$device"

    # Phase 2: Wipe signatures — partitions first, then the whole disk
    bf_run_with_spinner "Wiping old filesystem signatures..." \
        bash -c "wipefs -a -f ${device}?* 2>/dev/null; wipefs -a -f $device" || return 1

    # Phase 3: Force kernel to forget stale partitions BEFORE creating new table
    bf_settle_device "$device"

    # Phase 4: Create new partition table and partition
    bf_run_with_spinner "Creating ${scheme^^} partition table..." parted -s "$device" mklabel "$scheme" || return 1
    bf_run_with_spinner "Creating primary partition..." parted -s "$device" mkpart primary 1MiB 100% || return 1
    bf_settle_device "$device"

    # Phase 5: Format the new partition
    case "$fs" in
        FAT32)
            bf_ensure_tools "FAT32 formatting" mkfs.fat || return 1
            bf_run_with_spinner "Formatting ${part} as FAT32..." mkfs.fat -F 32 -n "${label:0:11}" "$part"
            ;;
        EXFAT)
            bf_ensure_tools "exFAT formatting" mkfs.exfat || return 1
            bf_run_with_spinner "Formatting ${part} as exFAT..." mkfs.exfat -n "$label" "$part"
            ;;
        NTFS)
            bf_ensure_tools "NTFS formatting" mkfs.ntfs || return 1
            bf_run_with_spinner "Formatting ${part} as NTFS..." mkfs.ntfs -f -L "$label" "$part"
            ;;
        EXT4)
            bf_ensure_tools "ext4 formatting" mkfs.ext4 || return 1
            bf_run_with_spinner "Formatting ${part} as ext4..." mkfs.ext4 -F -L "${label:0:16}" "$part"
            ;;
        *)
            printf '%sUnsupported filesystem: %s%s\n' "$C_RED" "$fs" "$C_RESET"
            return 1
            ;;
    esac
    BF_LAST_FORMATTED_PART="$part"
}

bf_format_device_macos() {
    # bf_format_device_macos <device e.g. /dev/disk4> <FS> <label> <scheme: GPT|MBR>
    local device="$1" fs="$2" label="$3" scheme="${4:-GPT}"
    local diskutil_name=""
    case "$fs" in
        FAT32)   diskutil_name="MS-DOS FAT32" ;;
        EXFAT)   diskutil_name="ExFAT" ;;
        HFSPLUS) diskutil_name="JHFS+" ;;
        NTFS)    diskutil_name="ExFAT" ;;   # placeholder scheme, reformatted below if mkntfs exists
        *)
            printf '%sUnsupported filesystem: %s%s\n' "$C_RED" "$fs" "$C_RESET"
            return 1
            ;;
    esac

    bf_run_with_spinner "Unmounting ${device}..." diskutil unmountDisk "$device" || true
    bf_run_with_spinner "Creating ${scheme} partition table + ${diskutil_name}..." \
        diskutil eraseDisk "$diskutil_name" "${label:-KREOBOOT}" "$scheme" "$device" || return 1

    local part="${device}s1"
    if [ "$fs" = "NTFS" ]; then
        if bf_have_cmd mkntfs; then
            bf_run_with_spinner "Re-formatting ${part} as NTFS via mkntfs..." mkntfs -f -L "$label" "$part"
        elif bf_have_cmd newfs_ntfs; then
            bf_run_with_spinner "Re-formatting ${part} as NTFS via newfs_ntfs..." newfs_ntfs -L "$label" "$part"
        else
            printf '\n%smacOS has no built-in NTFS writer. Install one first:%s\n' "$C_YELLOW" "$C_RESET"
            printf '    brew install ntfs-3g-mac\n'
            printf '%sThe drive has been left formatted as exFAT instead (fully usable, no 4GB limit).%s\n' "$C_DIM" "$C_RESET"
        fi
    fi
    BF_LAST_FORMATTED_PART="$part"
}

bf_format_device() {
    # Unified entry point used by both the "create bootable" and
    # "format / convert" flows.
    local device="$1" fs="$2" label="$3" scheme="$4"
    if bf_is_macos; then
        bf_format_device_macos "$device" "$fs" "$label" "$scheme"
    else
        bf_format_device_linux "$device" "$fs" "$label" "$scheme"
    fi
}

# ------------------------------------------------------------------------------
# 15. COPY ENGINE — progress bar instead of raw rsync logs, plus >4GB handling
# ------------------------------------------------------------------------------
readonly BF_FAT32_MAX_FILE=4294967295   # 4GB - 1 byte

bf_detect_windows_iso() {
    # bf_detect_windows_iso <mounted_iso_dir> -> return 0 if it looks like Windows install media
    local m="$1"
    [ -f "$m/sources/install.wim" ] && return 0
    [ -f "$m/sources/install.esd" ] && return 0
    [ -f "$m/bootmgr" ] && return 0
    return 1
}

bf_copy_with_progress() {
    # bf_copy_with_progress <src_dir> <dst_dir> [rsync extra args...]
    local src="$1" dst="$2"; shift 2
    local -a extra=("$@")
    local -a flags=(-a --no-owner --no-group --no-perms)

    if rsync --version 2>/dev/null | head -1 | grep -qE 'version 3\.[1-9]|version [4-9]'; then
        flags+=(--info=progress2)
    else
        flags+=(--progress)   # older rsync (e.g. stock macOS 2.6.9): per-file progress only
    fi

    local logf="${BF_WORKDIR}/rsync_$$_$RANDOM.log"
    tput civis 2>/dev/null
    rsync "${flags[@]}" "${extra[@]}" "${src}/" "${dst}/" > "$logf" 2>&1 &
    local pid=$!
    local percent
    while kill -0 "$pid" 2>/dev/null; do
        percent="$(tail -c 300 "$logf" 2>/dev/null | tr '\r' '\n' | grep -oE '[0-9]{1,3}%' | tail -1 | tr -d '%')"
        [ -z "$percent" ] && percent=0
        bf_progress_bar "$percent" "Copying installation files..."
        sleep 0.2
    done
    wait "$pid"
    local status=$?
    bf_progress_bar 100 "Copy complete."
    printf '\n'
    tput cnorm 2>/dev/null
    cat "$logf" >> "$BF_LOGFILE" 2>/dev/null
    rm -f "$logf"
    return "$status"
}

# bf_handle_large_windows_files <src_mount> <dst_mount> <target_fs>
# Return codes: 0 = handled here (split copy already done), 1 = fatal error,
#               2 = nothing to do, caller should do a normal full copy.
bf_handle_large_windows_files() {
    local src="$1" dst="$2" fs="$3"
    local big=""
    if [ -f "$src/sources/install.wim" ] && [ "$(bf_file_size_bytes "$src/sources/install.wim")" -gt "$BF_FAT32_MAX_FILE" ]; then
        big="$src/sources/install.wim"
    elif [ -f "$src/sources/install.esd" ] && [ "$(bf_file_size_bytes "$src/sources/install.esd")" -gt "$BF_FAT32_MAX_FILE" ]; then
        big="$src/sources/install.esd"
    fi

    [ -z "$big" ] && return 2
    [ "$fs" != "FAT32" ] && return 2   # exFAT / NTFS have no 4GB ceiling

    bf_section_header "Large file detected"
    printf '%s%s%s is %s%s%s — larger than the 4GB FAT32 limit.\n' \
        "$C_WHITE" "$(basename "$big")" "$C_RESET" "$C_YELLOW" "$(bf_bytes_human "$(bf_file_size_bytes "$big")")" "$C_RESET"
    printf 'It will be split into smaller .swm parts (the standard method Windows Setup\n'
    printf 'itself understands), so the rest of the media stays on FAT32 for UEFI boot.\n\n'

    bf_ensure_tools "splitting install.wim/.esd for FAT32 (>4GB) support" wimlib-imagex || return 1

    bf_copy_with_progress "$src" "$dst" --exclude "sources/install.wim" --exclude "sources/install.esd" || return 1
    mkdir -p "${dst}/sources"
    bf_run_with_spinner "Splitting $(basename "$big") into FAT32-sized parts..." \
        wimlib-imagex split "$big" "${dst}/sources/$(basename "${big%.*}").swm" 3800 || return 1
    return 0
}

# bf_perform_copy <src_mount> <dst_mount> <target_fs>
bf_perform_copy() {
    local src="$1" dst="$2" fs="$3"
    bf_handle_large_windows_files "$src" "$dst" "$fs"
    local rc=$?
    case "$rc" in
        0) return 0 ;;
        2) bf_copy_with_progress "$src" "$dst"; return $? ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# 16. WINDOWS SETUP TWEAKS — optional, Windows-source-only, all default OFF
#     Generates a standard autounattend.xml using Microsoft's own documented
#     RunSynchronous / LabConfig mechanism. Nothing here touches or exploits
#     any protection system — it only pre-fills the same answer-file fields
#     Windows Setup already knows how to read.
# ------------------------------------------------------------------------------
bf_win_tweak_menu_labels() {
    printf 'Bypass TPM 2.0 requirement\n'
    printf 'Bypass Secure Boot requirement\n'
    printf 'Bypass RAM minimum requirement\n'
    printf 'Bypass storage minimum requirement\n'
    printf 'Bypass CPU compatibility requirement\n'
    printf 'Skip Microsoft account / force local account (BypassNRO)\n'
}
bf_win_tweak_keys() {
    printf 'tpm\n'
    printf 'secureboot\n'
    printf 'ram\n'
    printf 'storage\n'
    printf 'cpu\n'
    printf 'local_account\n'
}

# bf_generate_autounattend <target_root_dir> key1 key2 ...
bf_generate_autounattend() {
    local target="$1"; shift
    local -a tweaks=("$@")
    [ "${#tweaks[@]}" -eq 0 ] && return 0

    local order=1
    local labconfig_cmds="" t

    __bf_add_labconfig_cmd() {
        labconfig_cmds+="                <RunSynchronousCommand wcm:action=\"add\">
                    <Order>${order}</Order>
                    <Description>${1}</Description>
                    <Path>cmd /c reg add \"HKLM\\SYSTEM\\Setup\\LabConfig\" /v \"${1}\" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
"
        order=$((order + 1))
    }

    for t in "${tweaks[@]}"; do
        case "$t" in
            tpm)        __bf_add_labconfig_cmd "BypassTPMCheck" ;;
            secureboot) __bf_add_labconfig_cmd "BypassSecureBootCheck" ;;
            ram)        __bf_add_labconfig_cmd "BypassRAMCheck" ;;
            storage)    __bf_add_labconfig_cmd "BypassStorageCheck" ;;
            cpu)        __bf_add_labconfig_cmd "BypassCPUCheck" ;;
        esac
    done

    local want_local=0
    for t in "${tweaks[@]}"; do [ "$t" = "local_account" ] && want_local=1; done

    local windowspe_block="" specialize_block=""
    if [ -n "$labconfig_cmds" ]; then
        windowspe_block="    <settings pass=\"windowsPE\">
        <component name=\"Microsoft-Windows-Setup\" processorArchitecture=\"amd64\"
            publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\"
            xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\"
            xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">
            <RunSynchronous>
${labconfig_cmds}            </RunSynchronous>
        </component>
    </settings>
"
    fi
    if [ "$want_local" -eq 1 ]; then
        specialize_block="    <settings pass=\"specialize\">
        <component name=\"Microsoft-Windows-Deployment\" processorArchitecture=\"amd64\"
            publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\"
            xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\"
            xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action=\"add\">
                    <Order>1</Order>
                    <Description>BypassNRO</Description>
                    <Path>cmd /c reg add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE\" /v \"BypassNRO\" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
"
    fi

    cat > "${target}/autounattend.xml" << XMLEOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
${windowspe_block}${specialize_block}</unattend>
XMLEOF

    bf_log "Wrote autounattend.xml (${target}) with tweaks: ${tweaks[*]}"
    return 0
}

# ------------------------------------------------------------------------------
# 17. LABEL HANDLING & MOUNT HELPERS
# ------------------------------------------------------------------------------
bf_derive_label() {
    local src="$1" fs="$2" base
    base="$(basename "$src")"
    base="${base%.*}"
    base="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]' | tr -cs 'A-Z0-9' '_')"
    base="${base#_}"; base="${base%_}"
    base="${base:-KREOBOOT}"
    case "$fs" in
        FAT32) printf '%s' "${base:0:11}" ;;
        EXT4)  printf '%s' "${base:0:16}" ;;
        *)     printf '%s' "${base:0:32}" ;;
    esac
}

MNT_ISO=""
MNT_USB=""

bf_mount_iso() {
    local iso="$1"
    if bf_is_macos; then
        MNT_ISO="${BF_WORKDIR}/iso_mount"
        mkdir -p "$MNT_ISO"
        hdiutil attach -mountpoint "$MNT_ISO" -nobrowse -readonly "$iso" >> "$BF_LOGFILE" 2>&1
    else
        MNT_ISO="${BF_WORKDIR}/iso_mount"
        mkdir -p "$MNT_ISO"
        mount -o loop,ro "$iso" "$MNT_ISO" >> "$BF_LOGFILE" 2>&1
    fi
}

bf_unmount_iso() {
    [ -z "$MNT_ISO" ] && return 0
    if bf_is_macos; then
        hdiutil detach "$MNT_ISO" >> "$BF_LOGFILE" 2>&1
    else
        umount "$MNT_ISO" >> "$BF_LOGFILE" 2>&1
    fi
    rmdir "$MNT_ISO" 2>/dev/null
    MNT_ISO=""
}

bf_mount_target() {
    local part="$1"
    if bf_is_macos; then
        MNT_USB="$(diskutil info "$part" 2>/dev/null | awk -F': +' '/Mount Point:/{print $2; exit}')"
        if [ -z "$MNT_USB" ]; then
            diskutil mount "$part" >> "$BF_LOGFILE" 2>&1
            MNT_USB="$(diskutil info "$part" 2>/dev/null | awk -F': +' '/Mount Point:/{print $2; exit}')"
        fi
    else
        MNT_USB="${BF_WORKDIR}/usb_mount"
        mkdir -p "$MNT_USB"
        mount "$part" "$MNT_USB" >> "$BF_LOGFILE" 2>&1
    fi
}

bf_unmount_target() {
    [ -z "$MNT_USB" ] && return 0
    if bf_is_macos; then
        diskutil unmount "$MNT_USB" >> "$BF_LOGFILE" 2>&1
    else
        umount "$MNT_USB" >> "$BF_LOGFILE" 2>&1
        rmdir "$MNT_USB" 2>/dev/null
    fi
    MNT_USB=""
}

# ------------------------------------------------------------------------------
# 18. OPTICAL (CD/DVD) BURNING — a lighter path than partition+format+copy
# ------------------------------------------------------------------------------
bf_burn_optical_linux() {
    local iso="$1" device="$2"
    if ! bf_have_cmd growisofs && ! bf_have_cmd wodim; then
        bf_ensure_tools "burning to optical media" growisofs || return 1
    fi
    if bf_have_cmd growisofs; then
        bf_run_with_spinner "Burning image to ${device}..." growisofs -dvd-compat -Z "${device}=${iso}"
    else
        bf_run_with_spinner "Burning image to ${device}..." wodim -v "dev=${device}" -eject "$iso"
    fi
}

bf_burn_optical_macos() {
    local iso="$1"
    bf_run_with_spinner "Burning image to disc..." hdiutil burn "$iso" -noverifyburn
}

bf_burn_optical() {
    local iso="$1" device="$2"
    if bf_is_macos; then bf_burn_optical_macos "$iso" "$device"; else bf_burn_optical_linux "$iso" "$device"; fi
}

# ------------------------------------------------------------------------------
# 19. SOURCE & TARGET SELECTION (shared sub-flows)
# ------------------------------------------------------------------------------
bf_select_source_image() {
    # On success: sets SELECTED_SOURCE_PATH / SELECTED_SOURCE_SIZE, returns 0.
    # On cancel:  returns 1.
    while true; do
        bf_print_banner
        bf_menu "Create Bootable Device — Step 1: Choose a source image" \
            "↑/↓ Navigate    Enter Select    Q Back to Main Menu" \
            "Quick scan (Downloads, Desktop, Documents, mounted volumes)" \
            "Full system scan (slower, thorough — scans the whole filesystem)" \
            "Browse for the file myself"
        local mode=$BF_MENU_RESULT
        [ "$mode" -eq -1 ] && return 1

        if [ "$mode" -eq 2 ]; then
            bf_file_browser "$BF_REAL_HOME"
            if [ $? -eq 0 ] && [ -n "$BF_TEXT_RESULT" ]; then
                SELECTED_SOURCE_PATH="$BF_TEXT_RESULT"
                SELECTED_SOURCE_SIZE="$(bf_file_size_bytes "$SELECTED_SOURCE_PATH")"
                return 0
            fi
            continue
        fi

        bf_print_banner
        [ "$mode" -eq 0 ] && bf_scan_images quick
        [ "$mode" -eq 1 ] && bf_scan_images full

        if [ "${#BF_FOUND_IMAGES[@]}" -eq 0 ]; then
            printf '\n%sNo ISO / IMG / DMG files were found.%s\n' "$C_YELLOW" "$C_RESET"
            bf_pause "Press Enter to try again..."
            continue
        fi

        local -a display=() i
        for i in "${!BF_FOUND_IMAGES[@]}"; do
            display+=("${BF_FOUND_IMAGES[$i]}   ${C_DIM}(${C_RESET}${C_BLUE_PALE}$(bf_bytes_human "${BF_FOUND_IMAGES_SIZE[$i]}")${C_RESET}${C_DIM})${C_RESET}")
        done
        display+=("✎  Browse for a different file")

        bf_menu "Select a source image" "↑/↓ Navigate    Enter Select    Q Back" "${display[@]}"
        local sel=$BF_MENU_RESULT
        if [ "$sel" -ge 0 ] && [ "$sel" -lt "${#BF_FOUND_IMAGES[@]}" ]; then
            SELECTED_SOURCE_PATH="${BF_FOUND_IMAGES[$sel]}"
            SELECTED_SOURCE_SIZE="${BF_FOUND_IMAGES_SIZE[$sel]}"
            return 0
        elif [ "$sel" -eq "${#BF_FOUND_IMAGES[@]}" ]; then
            bf_file_browser "$BF_REAL_HOME"
            if [ $? -eq 0 ] && [ -n "$BF_TEXT_RESULT" ]; then
                SELECTED_SOURCE_PATH="$BF_TEXT_RESULT"
                SELECTED_SOURCE_SIZE="$(bf_file_size_bytes "$SELECTED_SOURCE_PATH")"
                return 0
            fi
        fi
        # -1 (Q) or fallthrough -> loop back to the scan-method menu
    done
}

bf_select_target_device() {
    # On success: sets SELECTED_DEVICE_PATH / SELECTED_DEVICE_KIND / index globals, returns 0.
    # On cancel or "no devices": returns 1.
    while true; do
        bf_print_banner
        printf '%sScanning for connected drives...%s\n' "$C_DIM" "$C_RESET"
        bf_scan_devices

        if [ "${#BF_DEVICES_NAME[@]}" -eq 0 ]; then
            bf_print_banner
            printf '\n%sNo removable USB drives or optical burners were detected.%s\n' "$C_YELLOW" "$C_RESET"
            printf '%sPlug in a device and choose "Rescan", or go back.%s\n\n' "$C_DIM" "$C_RESET"
            bf_menu "No devices found" "" "Rescan" "Back to Main Menu"
            if [ "$BF_MENU_RESULT" -eq 0 ]; then continue; else return 1; fi
        fi

        local -a display=() i
        for i in "${!BF_DEVICES_NAME[@]}"; do
            local kindtag="USB"
            [ "${BF_DEVICES_KIND[$i]}" = "rom" ] && kindtag="Optical"
            display+=("${BF_DEVICES_PATH[$i]}   ${C_WHITE}${BF_DEVICES_MODEL[$i]}${C_RESET}  ${C_DIM}(${BF_DEVICES_SIZE[$i]} · ${kindtag} · ${BF_DEVICES_TRAN[$i]})${C_RESET}")
        done

        bf_menu "Select the target device" "↑/↓ Navigate    Enter Select    Q Back" "${display[@]}"
        local sel=$BF_MENU_RESULT
        [ "$sel" -eq -1 ] && return 1
        if [ "$sel" -ge 0 ] && [ "$sel" -lt "${#BF_DEVICES_NAME[@]}" ]; then
            SELECTED_DEVICE_PATH="${BF_DEVICES_PATH[$sel]}"
            SELECTED_DEVICE_INDEX=$sel
            SELECTED_DEVICE_KIND="${BF_DEVICES_KIND[$sel]}"
            return 0
        fi
    done
}

# ------------------------------------------------------------------------------
# 20. FLOW — CREATE BOOTABLE DEVICE
# ------------------------------------------------------------------------------
bf_flow_create_bootable() {
    bf_select_source_image || return 0

    bf_select_target_device || return 0

    # ---- Optical media: much simpler burn-only path ----
    if [ "$SELECTED_DEVICE_KIND" = "rom" ]; then
        bf_print_banner
        bf_section_header "Confirm"
        printf 'Source:  %s%s%s\n' "$C_WHITE" "$SELECTED_SOURCE_PATH" "$C_RESET"
        printf 'Target:  %s%s%s (optical drive)\n\n' "$C_WHITE" "$SELECTED_DEVICE_PATH" "$C_RESET"
        if ! bf_confirm "Burn this image to the disc in ${SELECTED_DEVICE_PATH}?"; then
            return 0
        fi
        bf_burn_optical "$SELECTED_SOURCE_PATH" "$SELECTED_DEVICE_PATH"
        bf_pause "Done. Press Enter to return to the Main Menu..."
        return 0
    fi

    # ---- USB / external disk: full partition + format + copy path ----
    local dev_size_bytes="${BF_DEVICES_SIZE_BYTES[$SELECTED_DEVICE_INDEX]}"
    local dev_model="${BF_DEVICES_MODEL[$SELECTED_DEVICE_INDEX]}"
    local dev_size_h="${BF_DEVICES_SIZE[$SELECTED_DEVICE_INDEX]}"

    bf_print_banner
    printf '%s╔═══════════════════════════════════════════════════════════════╗%s\n' "$C_RED" "$C_RESET"
    printf '%s║  WARNING — ALL DATA ON THE TARGET DEVICE WILL BE PERMANENTLY   ║%s\n' "$C_RED" "$C_RESET"
    printf '%s║  ERASED. THIS CANNOT BE UNDONE.                                ║%s\n' "$C_RED" "$C_RESET"
    printf '%s╚═══════════════════════════════════════════════════════════════╝%s\n\n' "$C_RED" "$C_RESET"
    printf 'Source image:   %s%s%s  %s(%s)%s\n' "$C_WHITE" "$SELECTED_SOURCE_PATH" "$C_RESET" "$C_DIM" "$(bf_bytes_human "$SELECTED_SOURCE_SIZE")" "$C_RESET"
    printf 'Target device:  %s%s%s  %s(%s · %s)%s\n\n' "$C_WHITE" "$SELECTED_DEVICE_PATH" "$C_RESET" "$C_DIM" "$dev_model" "$dev_size_h" "$C_RESET"

    if [ "$dev_size_bytes" -gt 0 ] 2>/dev/null && [ "$SELECTED_SOURCE_SIZE" -gt "$dev_size_bytes" ] 2>/dev/null; then
        printf '%sThe source image is LARGER than this device. It will not fit.%s\n\n' "$C_RED" "$C_RESET"
        bf_pause "Press Enter to choose a different device..."
        return 0
    fi

    if ! bf_confirm "Erase ${SELECTED_DEVICE_PATH} (${dev_model}) and continue?"; then
        return 0
    fi

    # -- Filesystem --
    local -a fs_codes=() fs_display=()
    while IFS= read -r f; do
        fs_codes+=("$f"); fs_display+=("$(bf_format_label_for "$f")")
    done < <(bf_available_formats)
    bf_print_banner
    bf_menu "Choose a target filesystem" "" "${fs_display[@]}"
    [ "$BF_MENU_RESULT" -eq -1 ] && return 0
    SELECTED_FS="${fs_codes[$BF_MENU_RESULT]}"

    # -- Partition scheme --
    bf_print_banner
    bf_menu "Choose a partition scheme" "" \
        "GPT — recommended (required for UEFI boot on Windows 10/11 & modern Macs)" \
        "MBR — legacy BIOS-only systems"
    [ "$BF_MENU_RESULT" -eq -1 ] && return 0
    local scheme_linux="gpt" scheme_macos="GPT"
    if [ "$BF_MENU_RESULT" -eq 1 ]; then scheme_linux="msdos"; scheme_macos="MBR"; fi

    # -- Label (optional) --
    local default_label
    default_label="$(bf_derive_label "$SELECTED_SOURCE_PATH" "$SELECTED_FS")"
    bf_print_banner
    bf_text_input "Volume label (optional — press Enter to accept the default)" "$default_label"
    SELECTED_LABEL="$BF_TEXT_RESULT"

    # -- Format --
    bf_print_banner
    bf_section_header "Formatting ${SELECTED_DEVICE_PATH}"
    if bf_is_macos; then
        bf_format_device "$SELECTED_DEVICE_PATH" "$SELECTED_FS" "$SELECTED_LABEL" "$scheme_macos"
    else
        bf_format_device "$SELECTED_DEVICE_PATH" "$SELECTED_FS" "$SELECTED_LABEL" "$scheme_linux"
    fi
    if [ $? -ne 0 ]; then
        printf '\n%sFormatting failed — see the activity log for details.%s\n' "$C_RED" "$C_RESET"
        bf_pause
        return 0
    fi

    # -- Mount both sides --
    bf_section_header "Preparing to copy"
    bf_mount_iso "$SELECTED_SOURCE_PATH"
    if [ -z "$(ls -A "$MNT_ISO" 2>/dev/null)" ]; then
        printf '\n%sCould not mount the source image. Is it a valid ISO/IMG?%s\n' "$C_RED" "$C_RESET"
        bf_unmount_iso
        bf_pause
        return 0
    fi
    bf_mount_target "$BF_LAST_FORMATTED_PART"
    if [ -z "$MNT_USB" ] || [ ! -d "$MNT_USB" ]; then
        printf '\n%sCould not mount the freshly formatted device.%s\n' "$C_RED" "$C_RESET"
        bf_unmount_iso
        bf_pause
        return 0
    fi

    IS_WINDOWS_SOURCE=0
    bf_detect_windows_iso "$MNT_ISO" && IS_WINDOWS_SOURCE=1

    # -- Copy --
    bf_perform_copy "$MNT_ISO" "$MNT_USB" "$SELECTED_FS"
    local copy_rc=$?

    # -- Optional Windows setup tweaks --
    WIN_TWEAKS_SELECTED=()
    if [ "$copy_rc" -eq 0 ] && [ "$IS_WINDOWS_SOURCE" -eq 1 ]; then
        bf_print_banner
        printf '%sThis looks like Windows installation media.%s\n' "$C_BLUE_PALE" "$C_RESET"
        printf '%sThe options below are entirely optional — skip them for a stock installer.%s\n\n' "$C_DIM" "$C_RESET"
        local -a tw_keys=() tw_labels=()
        while IFS= read -r k; do tw_keys+=("$k"); done < <(bf_win_tweak_keys)
        while IFS= read -r l; do tw_labels+=("$l"); done < <(bf_win_tweak_menu_labels)
        bf_checklist "Windows Setup options (all optional)" "" "${tw_labels[@]}"
        local -a chosen_keys=()
        local idx
        for idx in "${BF_CHECKLIST_RESULT[@]}"; do
            chosen_keys+=("${tw_keys[$idx]}")
        done
        if [ "${#chosen_keys[@]}" -gt 0 ]; then
            bf_generate_autounattend "$MNT_USB" "${chosen_keys[@]}"
            WIN_TWEAKS_SELECTED=("${chosen_keys[@]}")
        fi
    fi

    bf_run_with_spinner "Flushing write cache to disk (do not remove the drive)..." sync

    bf_unmount_target
    bf_unmount_iso

    bf_print_banner
    if [ "$copy_rc" -eq 0 ]; then
        bf_section_header "Done"
        printf '%s✔  Bootable device created successfully.%s\n\n' "$C_GREEN" "$C_RESET"
        printf '  Device:      %s%s%s\n' "$C_WHITE" "$SELECTED_DEVICE_PATH" "$C_RESET"
        printf '  Filesystem:  %s%s%s\n' "$C_WHITE" "$SELECTED_FS" "$C_RESET"
        printf '  Label:       %s%s%s\n' "$C_WHITE" "$SELECTED_LABEL" "$C_RESET"
        [ "${#WIN_TWEAKS_SELECTED[@]}" -gt 0 ] && printf '  Setup tweaks: %s%s%s\n' "$C_WHITE" "${WIN_TWEAKS_SELECTED[*]}" "$C_RESET"
        printf '\nIt is now safe to remove the drive.\n'
    else
        bf_section_header "Something went wrong"
        printf '%sThe copy did not finish successfully. Check the activity log for details.%s\n' "$C_RED" "$C_RESET"
    fi
    bf_pause "Press Enter to return to the Main Menu..."
}

# ------------------------------------------------------------------------------
# 21. FLOW — FORMAT / CONVERT A DEVICE
# ------------------------------------------------------------------------------
bf_flow_format_device() {
    while true; do
        bf_print_banner
        printf '%sScanning for connected drives...%s\n' "$C_DIM" "$C_RESET"
        bf_scan_devices

        local -a idxs=()
        local i
        for i in "${!BF_DEVICES_NAME[@]}"; do
            [ "${BF_DEVICES_KIND[$i]}" = "disk" ] && idxs+=("$i")
        done

        if [ "${#idxs[@]}" -eq 0 ]; then
            bf_print_banner
            printf '\n%sNo removable drives were detected.%s\n' "$C_YELLOW" "$C_RESET"
            bf_menu "No devices found" "" "Rescan" "Back to Main Menu"
            if [ "$BF_MENU_RESULT" -eq 0 ]; then continue; else return 0; fi
        fi

        local -a display=()
        for i in "${idxs[@]}"; do
            display+=("${BF_DEVICES_PATH[$i]}   ${C_WHITE}${BF_DEVICES_MODEL[$i]}${C_RESET}  ${C_DIM}(${BF_DEVICES_SIZE[$i]} · ${BF_DEVICES_TRAN[$i]})${C_RESET}")
        done
        bf_menu "Format / Convert — select a device" "↑/↓ Navigate    Enter Select    Q Back" "${display[@]}"
        [ "$BF_MENU_RESULT" -eq -1 ] && return 0
        local chosen_idx="${idxs[$BF_MENU_RESULT]}"
        local device="${BF_DEVICES_PATH[$chosen_idx]}"
        local model="${BF_DEVICES_MODEL[$chosen_idx]}"
        local size_h="${BF_DEVICES_SIZE[$chosen_idx]}"

        bf_print_banner
        printf '%s╔═══════════════════════════════════════════════════════════════╗%s\n' "$C_RED" "$C_RESET"
        printf '%s║  WARNING — ALL DATA ON THIS DEVICE WILL BE PERMANENTLY ERASED  ║%s\n' "$C_RED" "$C_RESET"
        printf '%s╚═══════════════════════════════════════════════════════════════╝%s\n\n' "$C_RED" "$C_RESET"
        printf 'Device:  %s%s%s  %s(%s · %s)%s\n\n' "$C_WHITE" "$device" "$C_RESET" "$C_DIM" "$model" "$size_h" "$C_RESET"
        if ! bf_confirm "Erase ${device} and reformat it?"; then
            continue
        fi

        local -a fs_codes=() fs_display=()
        while IFS= read -r f; do
            fs_codes+=("$f"); fs_display+=("$(bf_format_label_for "$f")")
        done < <(bf_available_formats)
        bf_print_banner
        bf_menu "Choose the new filesystem" "" "${fs_display[@]}"
        [ "$BF_MENU_RESULT" -eq -1 ] && continue
        local fs="${fs_codes[$BF_MENU_RESULT]}"

        bf_print_banner
        bf_menu "Choose a partition scheme" "" \
            "GPT — recommended (UEFI / modern systems)" \
            "MBR — legacy BIOS-only systems"
        [ "$BF_MENU_RESULT" -eq -1 ] && continue
        local scheme_linux="gpt" scheme_macos="GPT"
        if [ "$BF_MENU_RESULT" -eq 1 ]; then scheme_linux="msdos"; scheme_macos="MBR"; fi

        bf_print_banner
        bf_text_input "Volume label (optional)" "NEW_VOLUME"
        local label="$BF_TEXT_RESULT"

        bf_print_banner
        bf_section_header "Formatting ${device}"
        if bf_is_macos; then
            bf_format_device "$device" "$fs" "$label" "$scheme_macos"
        else
            bf_format_device "$device" "$fs" "$label" "$scheme_linux"
        fi
        if [ $? -eq 0 ]; then
            printf '\n%s✔  %s is now formatted as %s.%s\n' "$C_GREEN" "$device" "$fs" "$C_RESET"
        else
            printf '\n%sFormatting failed — see the activity log for details.%s\n' "$C_RED" "$C_RESET"
        fi
        bf_pause "Press Enter to return to the Main Menu..."
        return 0
    done
}

# ------------------------------------------------------------------------------
# 22. ACTIVITY LOG VIEWER
# ------------------------------------------------------------------------------
bf_view_log() {
    bf_print_banner
    bf_section_header "Activity Log (most recent entries)"
    if [ -s "$BF_LOGFILE" ]; then
        tail -n 40 "$BF_LOGFILE"
    else
        printf '%s(empty — nothing has run yet)%s\n' "$C_DIM" "$C_RESET"
    fi
    bf_pause "Press Enter to return to the Main Menu..."
}

# ------------------------------------------------------------------------------
# 23. MAIN MENU & ENTRY POINT
# ------------------------------------------------------------------------------
bf_main_menu() {
    while true; do
        bf_print_banner
        bf_print_system_info
        printf '\n'
        bf_menu "Main Menu" "" \
            "Create Bootable Device (USB / CD / DVD)" \
            "Format / Convert a Device" \
            "Rescan System" \
            "View Activity Log" \
            "Exit KreoBoot"
        case "$BF_MENU_RESULT" in
            0) bf_flow_create_bootable ;;
            1) bf_flow_format_device ;;
            2) bf_gather_system_info ;;
            3) bf_view_log ;;
            *)
                bf_print_banner
                if bf_confirm "Exit KreoBoot?"; then
                    clear
                    printf '%sGoodbye!%s\n' "$C_BLUE" "$C_RESET"
                    exit 0
                fi
                ;;
        esac
    done
}

main() {
    bf_print_banner
    printf '%sInitializing — checking core tools and connected devices...%s\n\n' "$C_DIM" "$C_RESET"

    # Core tools needed just to run device detection / scanning at all.
    if bf_is_linux; then
        bf_ensure_tools "core device detection" lsblk findmnt wipefs blkid
    fi

    bf_gather_system_info
    bf_print_banner
    bf_print_system_info
    bf_pause "Press Enter to continue to the Main Menu..."
    bf_main_menu
}

if [[ "${BASH_SOURCE[0]:-${0}}" == "${0}" ]]; then
    main "$@"
fi
