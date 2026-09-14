#!/usr/bin/env bash
#
# disk-cleaner.sh (v3) — merged junk auditor + Kali system maintenance
#
# Combines two workflows into one tool, run as separate phases:
#
#   PHASE 1 — DISCOVERY  (from disk-cleaner.sh)
#     Scans known tool/browser/dev caches + a generic large/old file sweep.
#     Report-only by default; nothing deleted unless --clean is passed.
#
#   PHASE 2 — MAINTENANCE (from kalicleaner.sh)
#     Runs proper system commands rather than raw rm: apt clean/autoclean/
#     autoremove, journalctl --vacuum-time, age-based log cleanup in /var/log.
#     This phase always respects --dry-run.
#
# Usage:
#   ./disk-cleaner.sh                       # discovery report only (no changes)
#   ./disk-cleaner.sh --clean               # discovery phase, prompt before deleting
#   ./disk-cleaner.sh --clean --yes         # discovery phase, delete all non-CHECK items
#   ./disk-cleaner.sh --maintenance         # run system maintenance phase for real
#   ./disk-cleaner.sh --maintenance --dry-run   # show maintenance commands without running
#   ./disk-cleaner.sh --clean --yes --maintenance   # do both phases in one pass
#   ./disk-cleaner.sh --days N              # log/journal retention for maintenance phase (default 7)
#   ./disk-cleaner.sh --min-size 200M       # large-file threshold for discovery sweep (default 100M)
#   ./disk-cleaner.sh --old-days 90         # "old file" threshold for discovery sweep (default 180)
#   ./disk-cleaner.sh --no-largefiles       # skip the generic large/old file sweep (faster)
#   ./disk-cleaner.sh --list                # print known categories and exit
#
set -uo pipefail

HOME_DIR="${HOME}"
CLEAN=false
AUTO_YES=false
LIST_ONLY=false
SCAN_LARGEFILES=true
MIN_SIZE="100M"
OLD_DAYS=180
RUN_MAINTENANCE=false
DRY_RUN=false
RETENTION_DAYS=7

while [ $# -gt 0 ]; do
    case "$1" in
        --clean) CLEAN=true ;;
        --yes|-y) AUTO_YES=true ;;
        --list) LIST_ONLY=true ;;
        --no-largefiles) SCAN_LARGEFILES=false ;;
        --min-size) shift; MIN_SIZE="${1:-100M}" ;;
        --old-days) shift; OLD_DAYS="${1:-180}" ;;
        --maintenance) RUN_MAINTENANCE=true ;;
        --dry-run) DRY_RUN=true ;;
        --days) shift; RETENTION_DAYS="${1:-7}" ;;
        --help|-h) grep '^#' "$0" | sed 's/^#//'; exit 0 ;;
        *) echo "Unknown option: $1 (use --help)"; exit 1 ;;
    esac
    shift
done

# ════════════════════════════════════════════════════════════════════
# PHASE 1 — DISCOVERY
# ════════════════════════════════════════════════════════════════════

declare -a CATEGORIES=(
    "Generic cache dir|$HOME_DIR/.cache|Regenerates automatically, always safe"
    "Thumbnail cache|$HOME_DIR/.cache/thumbnails|Regenerates as needed"
    "Firefox backup profile|$HOME_DIR/.mozilla_backup|Old profile backup, check before deleting"
    "Chrome/Chromium cache|$HOME_DIR/.config/google-chrome/*/Cache $HOME_DIR/.config/chromium/*/Cache|Regenerates automatically"
    "Brave cache|$HOME_DIR/.config/BraveSoftware/*/Cache|Regenerates automatically"
    "Burp Suite bundled Chromium|$HOME_DIR/.BurpSuite/burpbrowser|Re-downloads on next Burp launch"
    "Burp Suite pre-wired browser|$HOME_DIR/.BurpSuite/pre-wired-browser|Re-downloads on next Burp launch"
    "Burp Suite chromium extension|$HOME_DIR/.BurpSuite/burp-chromium-extension|Re-downloads on next Burp launch"
    "ZAP session data|$HOME_DIR/.ZAP/session|Old scan sessions — check before bulk delete, may hold evidence"
    "Metasploit local DB/loot|$HOME_DIR/.msf4/loot $HOME_DIR/.msf4/logs|Old exploit loot/logs — check before deleting"
    "Wireshark recent captures list|$HOME_DIR/.config/wireshark/recent|Just UI history, safe"
    "npm cache|$HOME_DIR/.npm/_cacache|Rebuilds on next npm install"
    "pip cache|$HOME_DIR/.cache/pip|Rebuilds on next pip install"
    "pipx cache|$HOME_DIR/.local/pipx/.cache|Rebuilds as needed"
    "Cargo registry cache|$HOME_DIR/.cargo/registry|Rebuilds on next cargo build"
    "Rustup downloads|$HOME_DIR/.rustup/downloads|Rebuilds on next toolchain install"
    "Go module cache|$HOME_DIR/go/pkg/mod/cache|Rebuilds on next go build"
    "Conda package cache|$HOME_DIR/.conda/pkgs $HOME_DIR/miniconda3/pkgs|Rebuilds as needed"
    "yarn cache|$HOME_DIR/.cache/yarn|Rebuilds on next yarn install"
    "Old/removed kernel packages|/boot/vmlinuz-* /boot/initrd.img-*|CHECK — remove via apt autoremove, not by hand"
    "Old rotated logs|/var/log/*.gz /var/log/*.1|Compressed old logs, generally safe"
    "Crash dumps (core files)|$HOME_DIR/core.* /core.*|Debug crash dumps, safe unless actively debugging"
    "Trash|$HOME_DIR/.local/share/Trash|Already-deleted files sitting in trash"
    "Snap package cache|/var/lib/snapd/cache|Old snap revisions, safe"
    "Flatpak unused runtimes|$HOME_DIR/.local/share/flatpak/repo/tmp|Safe, flatpak rebuilds as needed"
    "Docker unused images/build cache|/var/lib/docker|CHECK — use 'docker system prune' instead"
    "VirtualBox old snapshots|$HOME_DIR/VirtualBox VMs/*/Snapshots|CHECK — only delete snapshots you don't need"
    "Vagrant boxes|$HOME_DIR/.vagrant.d/boxes|CHECK — only if not reusing these VM images"
    "Downloads folder|$HOME_DIR/Downloads|CHECK contents first"
    "Desktop temp clutter|$HOME_DIR/Desktop/*.tmp $HOME_DIR/Desktop/*.part|Leftover partial downloads, safe"
)

human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }
bytes() { du -sb "$1" 2>/dev/null | awk '{print $1}'; }

TOTAL_RECLAIMABLE=0
declare -a FOUND_PATHS=() FOUND_LABELS=() FOUND_NOTES=() FOUND_SIZES_H=() FOUND_SIZES_B=()

echo "===================================================================================="
echo " PHASE 1: Discovery scan — $(date '+%Y-%m-%d %H:%M')"
echo "===================================================================================="
printf "%-40s %10s   %s\n" "CATEGORY" "SIZE" "NOTE"
echo "------------------------------------------------------------------------------------"

for entry in "${CATEGORIES[@]}"; do
    IFS='|' read -r label rawpath note <<< "$entry"
    for path in $rawpath; do
        [ -e "$path" ] || continue
        sz_b=$(bytes "$path")
        [ -z "$sz_b" ] && continue
        [ "$sz_b" -eq 0 ] 2>/dev/null && continue
        sz_h=$(human "$path")
        printf "%-40s %10s   %s\n" "$label" "$sz_h" "$note"
        FOUND_PATHS+=("$path"); FOUND_LABELS+=("$label")
        FOUND_NOTES+=("$note"); FOUND_SIZES_H+=("$sz_h"); FOUND_SIZES_B+=("$sz_b")
        TOTAL_RECLAIMABLE=$((TOTAL_RECLAIMABLE + sz_b))
    done
done

echo "------------------------------------------------------------------------------------"
TOTAL_H=$(numfmt --to=iec --suffix=B "$TOTAL_RECLAIMABLE" 2>/dev/null || echo "${TOTAL_RECLAIMABLE}B")
echo "Total reclaimable (known categories): ${TOTAL_H}"
echo
df -h "$HOME_DIR" | awk 'NR==1 || NR==2'

if $SCAN_LARGEFILES; then
    echo
    echo "Individual files over ${MIN_SIZE} (top 20):"
    echo "------------------------------------------------------------------------------------"
    find "$HOME_DIR" -xdev -type f -size "+${MIN_SIZE}" -printf '%s\t%p\n' 2>/dev/null \
        | sort -rn | head -20 \
        | awk -F'\t' '{printf "%-12s %s\n", $1, $2}'
    echo
    echo "Same, but untouched in ${OLD_DAYS}+ days (archive candidates):"
    echo "------------------------------------------------------------------------------------"
    find "$HOME_DIR" -xdev -type f -size "+${MIN_SIZE}" -atime "+${OLD_DAYS}" -printf '%s\t%p\n' 2>/dev/null \
        | sort -rn | head -20 \
        | awk -F'\t' '{printf "%-12s %s\n", $1, $2}'
    echo "(Listed for review only — not auto-deleted; may be report evidence or VM images.)"
fi

if $LIST_ONLY; then
    exit 0
fi

if [ ${#FOUND_PATHS[@]} -gt 0 ] && $CLEAN; then
    echo
    for i in "${!FOUND_PATHS[@]}"; do
        path="${FOUND_PATHS[$i]}"; label="${FOUND_LABELS[$i]}"
        size="${FOUND_SIZES_H[$i]}"; note="${FOUND_NOTES[$i]}"

        if $AUTO_YES; then
            if [[ "$note" == CHECK* ]]; then
                echo "  -> SKIPPED (flagged CHECK): ${label}"
                continue
            fi
            do_delete=true
        else
            read -r -p "Delete '${label}' (${size}) — ${path}? [${note}] (y/N): " ans
            case "$ans" in y|Y) do_delete=true ;; *) do_delete=false ;; esac
        fi

        if $do_delete; then
            if [[ "$path" == *"/.cache"* || "$path" == *"apt/archives"* || "$path" == *"/Cache" ]]; then
                find "$path" -mindepth 1 -delete 2>/dev/null
            else
                rm -rf -- "$path"
            fi
            echo "  -> cleared ${label} (${size})"
        else
            echo "  -> skipped ${label}"
        fi
    done
elif [ ${#FOUND_PATHS[@]} -gt 0 ]; then
    echo
    echo "Discovery report only — nothing deleted. Add --clean to remove items."
fi

# ════════════════════════════════════════════════════════════════════
# PHASE 2 — SYSTEM MAINTENANCE (kalicleaner logic)
# ════════════════════════════════════════════════════════════════════

if $RUN_MAINTENANCE; then
    run() {
        if $DRY_RUN; then
            echo "  [dry-run] $*"
        else
            eval "$@"
        fi
    }

    echo
    echo "===================================================================================="
    echo " PHASE 2: System maintenance (dry-run: $DRY_RUN, retention: ${RETENTION_DAYS}d)"
    echo "===================================================================================="

    echo "[*] Cleaning APT cache..."
    run "sudo apt clean"
    run "sudo apt autoclean"
    run "sudo apt autoremove -y"

    echo "[*] Cleaning systemd journal logs older than ${RETENTION_DAYS} days..."
    run "sudo journalctl --vacuum-time=${RETENTION_DAYS}d"

    echo "[*] Removing *.log files in /var/log older than ${RETENTION_DAYS} days..."
    run "sudo find /var/log -type f -name '*.log' -mtime +${RETENTION_DAYS} -exec rm -f {} \\;"

    echo "[+] Maintenance phase complete."
else
    echo
    echo "(Maintenance phase skipped — add --maintenance to run apt/journal/log cleanup,"
    echo " optionally with --dry-run to preview first.)"
fi

echo
echo "Final disk usage:"
df -h "$HOME_DIR" | awk 'NR==1 || NR==2'
