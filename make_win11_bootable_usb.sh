#!/usr/bin/env bash
# ==============================================================================
# Windows 11 USB Maker (macOS)
# ------------------------------------------------------------------------------
# Purpose
#   Create a bootable Windows 11 installer USB on macOS—no Windows PC needed.
#
# What it does
#   1) Lets you pick a Windows 11 ISO (defaults to ~/Downloads).
#   2) Lets you pick a target external *whole disk* (will be ERASED).
#   3) Erases the disk as GPT + FAT32 (label WIN11) for broad UEFI boot.
#   4) Robustly mounts the ISO using `hdiutil -plist` (handles UDF/CD9660).
#   5) Copies all files except sources/install.wim.
#   6) If install.wim is present, splits it into install.swm chunks (<= 3800 MB)
#      via wimlib-imagex so the USB can stay FAT32; Windows Setup reads it natively.
#   7) Ejects the USB when done.
#
# Requirements
#   - macOS with: bash, diskutil, hdiutil, rsync, awk, plutil, stat (preinstalled).
#   - 16 GB+ USB drive, visible as an external whole disk (/dev/diskN).
#   - wimlib-imagex (auto-installed via Homebrew if missing).
#
# Usage (interactive)
#   chmod +x make_win11_bootable_usb.sh
#   bash ./make_win11_bootable_usb.sh
#
# Usage (non-interactive / CI)
#   ISO_PATH="/Users/you/Downloads/Win11_24H2_x64.iso" \
#   USB_DISK="/dev/disk4" \
#   bash ./make_win11_usb_v5.sh
#
# Quick automation
#   AUTO=1 bash ./make_win11_usb_v5.sh
#   # Picks the most recent ISO in ~/Downloads and the only external disk if just one exists.
#
# Safety
#   This script PERMANENTLY ERASES the selected disk. Triple-check the disk id.
#
# References
#   - Official Windows 11 ISO: https://www.microsoft.com/software-download/windows11
#   - Split WIM (FAT32 4 GB limit): https://learn.microsoft.com/windows-hardware/manufacture/desktop/split-a-windows-image-file
#   - hdiutil attach -plist: https://ss64.com/osx/hdiutil.html
#
# Note
#   Prompts are sent to /dev/tty so function outputs can be safely captured.
#   Logs go to stderr; nonzero exit means failure.
#
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

log(){ printf "==> %s\n" "$*" >&2; }
err(){ printf "ERROR: %s\n" "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || err "Missing: $1"; }
say_tty(){ printf "%s\n" "$*" > /dev/tty; }
ask_tty(){ local __out=$1; shift; printf "%s" "$*" > /dev/tty; IFS= read -r "$__out" < /dev/tty; }

latest_by_mtime(){ # prints latest file among args
  local latest="" latest_m=0 f m
  for f in "$@"; do
    [[ -e "$f" ]] || continue
    m=$(stat -f '%m' "$f" 2>/dev/null || echo 0)
    if (( m > latest_m )); then latest_m=$m; latest="$f"; fi
  done
  [[ -n "$latest" ]] && printf '%s\n' "$latest"
}

pick_iso(){
  if [[ -n "${ISO_PATH:-}" ]]; then
    [[ -r "$ISO_PATH" ]] || err "ISO not readable: $ISO_PATH"
    printf '%s\n' "$ISO_PATH"; return
  fi
  local dl="$HOME/Downloads"
  shopt -s nullglob nocaseglob; local -a files=( "$dl"/*.iso ); shopt -u nullglob nocaseglob

  if (( ${#files[@]} == 0 )); then
    ask_tty path "Enter full ISO path: "
    [[ -r "$path" ]] || err "ISO not readable: $path"
    printf '%s\n' "$path"; return
  fi

  if [[ "${AUTO:-0}" == "1" ]]; then
    local latest; latest=$(latest_by_mtime "${files[@]}")
    [[ -n "$latest" ]] || err "No ISO candidates."
    log "AUTO=1 -> Using latest ISO: $latest"
    printf '%s\n' "$latest"; return
  fi

  say_tty "Found ISOs:"
  local i=1
  for f in "${files[@]}"; do printf "  %2d) %s\n" "$i" "$f" > /dev/tty; ((i++)); done
  printf "  0) Enter a different path\n" > /dev/tty
  ask_tty sel "Select ISO [1-$((i-1)) or 0]: "

  local path
  if [[ "$sel" == "0" ]]; then
    ask_tty path "Enter full ISO path: "
    [[ -r "$path" ]] || err "ISO not readable: $path"
  else
    [[ "$sel" =~ ^[0-9]+$ ]] || err "Bad choice."
    (( sel>=1 && sel<i )) || err "Bad choice."
    path="${files[$((sel-1))]}"
  fi
  printf '%s\n' "$path"
}

list_ext_disks(){ diskutil list external physical | awk '/^\/dev\/disk[0-9]+/ {print $1}'; }

pick_disk(){
  if [[ -n "${USB_DISK:-}" ]]; then
    diskutil info "$USB_DISK" >/dev/null 2>&1 || err "Bad disk id: $USB_DISK"
    printf '%s\n' "$USB_DISK"; return
  fi

  mapfile -t ids < <(list_ext_disks)
  (( ${#ids[@]} )) || err "No external disks detected. Plug the stick directly."

  if [[ "${AUTO:-0}" == "1" && ${#ids[@]} -eq 1 ]]; then
    log "AUTO=1 -> Using ${ids[0]}"
    printf '%s\n' "${ids[0]}"; return
  fi

  say_tty "External disks:"
  local i=1
  for d in "${ids[@]}"; do
    local info size name
    info="$(diskutil info "$d")"
    size=$(echo "$info" | awk -F: '/Total Size:/ {gsub(/^ *| *$/,"",$2); print $2; exit}')
    name=$(echo "$info" | awk -F: '/(Media Name|Device \/ Media Name|Device Name):/ {gsub(/^ *| *$/,"",$2); print $2; exit}')
    printf "  %2d) %-12s  %-18s  %s\n" "$i" "$d" "${size:-unknown}" "${name:-media}" > /dev/tty
    ((i++))
  done
  printf "  0) Enter disk id manually\n" > /dev/tty
  ask_tty sel "Select target DISK (WILL BE ERASED) [1-$((i-1)) or 0]: "

  local picked
  if [[ "$sel" == "0" ]]; then
    ask_tty picked "Enter /dev/diskN (e.g., /dev/disk4): "
  else
    [[ "$sel" =~ ^[0-9]+$ ]] || err "Bad choice."
    (( sel>=1 && sel<i )) || err "Bad choice."
    picked="${ids[$((sel-1))]}"
  fi

  # Safety checks
  diskutil info "$picked" >/dev/null 2>&1 || err "Bad disk id: $picked"
  local whole internal bus
  whole=$(diskutil info -plist "$picked" | plutil -extract WholeDisk raw -o - - 2>/dev/null || echo "")
  internal=$(diskutil info -plist "$picked" | plutil -extract Internal  raw -o - - 2>/dev/null || echo "")
  bus=$(diskutil info -plist "$picked" | plutil -extract BusProtocol raw -o - - 2>/dev/null || echo "")
  [[ "$whole" == "true" ]] || err "$picked is not a whole disk."
  [[ "$internal" != "true" ]] || err "$picked is INTERNAL."
  [[ "$bus" != "Disk Image" ]] || err "$picked is a disk image."
  printf '%s\n' "$picked"
}

mount_iso(){
  local iso="$1" plist mp dev ent
  plist=$(hdiutil attach -nobrowse -noverify -plist "$iso") || err "hdiutil attach failed."
  mp=$(echo "$plist" | plutil -p - | awk -F'"' '/mount-point/ {print $4; exit}')
  if [[ -n "$mp" && -d "$mp" ]]; then printf '%s\n' "$mp"; return; fi
  dev=$(echo "$plist" | plutil -p - | awk -F'"' '/dev-entry/ {print $4; exit}')
  if [[ -n "$dev" ]]; then
    diskutil mountDisk "$dev" >/dev/null || true
    mp=$(mount | awk -v d="$dev" '$1 ~ d {print $3; exit}')
    if [[ -n "$mp" && -d "$mp" ]]; then printf '%s\n' "$mp"; return; fi
    ent=$(echo "$plist" | plutil -p - | awk -F'"' '
      $2=="content-hint" && ($4=="udf" || $4=="cd9660"){want=1}
      $2=="dev-entry" && want==1 {print $4; exit}')
    if [[ -n "$ent" ]]; then
      diskutil mount "$ent" >/dev/null || true
      mp=$(mount | awk -v e="$ent" '$1 == e {print $3; exit}')
      if [[ -n "$mp" && -d "$mp" ]]; then printf '%s\n' "$mp"; return; fi
    fi
  fi
  err "Failed to mount ISO."
}

ensure_wimlib(){
  if command -v wimlib-imagex >/dev/null 2>&1; then return; fi
  if ! command -v brew >/dev/null 2>&1; then
    ask_tty yn "Homebrew is needed for wimlib. Install now? [Y/n]: "
    [[ "${yn:-Y}" =~ ^[Yy]$ ]] || err "wimlib not installed."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)" || true
  fi
  log "Installing wimlib..."
  brew install wimlib
}

iso_quick_check(){ # warn if ISO looks unusually small
  local iso="$1"; [[ -r "$iso" ]] || return 0
  local sz; sz=$(stat -f%z "$iso" 2>/dev/null || echo 0)
  (( sz < 1000000000 )) && say_tty "WARNING: ISO looks small ($sz bytes)." || true
}

main(){
  need diskutil; need hdiutil; need rsync; need awk; need plutil; need stat
  local ISO; ISO=$(pick_iso); iso_quick_check "$ISO"
  local USB; USB=$(pick_disk)

  log "ISO:  ${ISO}"
  log "DISK: ${USB}"
  ask_tty ans "Erase ${USB} and create Windows 11 installer? [y/N]: "
  [[ "$ans" == [yY] ]] || err "Cancelled."

  sudo -v
  log "Unmounting anything on ${USB}..."; sudo diskutil unmountDisk force "${USB}" >/dev/null || true
  log "Erasing as GPT + FAT32 (label WIN11)..."; sudo diskutil eraseDisk "MS-DOS FAT32" WIN11 GPT "${USB}"

  log "Mounting ISO..."
  ISOMOUNT=$(mount_iso "${ISO}")
  log "ISO mounted at: ${ISOMOUNT}"

  log "Copying files (excluding sources/install.wim)..."
  rsync -av --progress --exclude='sources/install.wim' "${ISOMOUNT}/" "/Volumes/WIN11/"

  if [[ -f "${ISOMOUNT}/sources/install.wim" ]]; then
    ensure_wimlib
    log "Splitting install.wim -> install.swm (<= 3800MB)..."
    wimlib-imagex split "${ISOMOUNT}/sources/install.wim" "/Volumes/WIN11/sources/install.swm" 3800
  elif [[ -f "${ISOMOUNT}/sources/install.esd" ]]; then
    log "Copying install.esd..."
    rsync -av --progress "${ISOMOUNT}/sources/install.esd" "/Volumes/WIN11/sources/install.esd"
  else
    err "Neither install.wim nor install.esd found."
  fi

  log "Finalizing..."
  sync
  hdiutil detach "$ISOMOUNT" >/dev/null || true
  sudo diskutil eject "${USB}" >/dev/null || true
  log "Done. Windows 11 installer USB is ready."
}

main "$@"
