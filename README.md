# Windows 11 USB Maker (macOS)

**macOS script to create a UEFI‑bootable Windows 11 USB (FAT32) from an ISO by auto‑splitting `install.wim`—no Windows PC needed.**

> TL;DR: Point it at a Win11 ISO, pick your USB stick, it erases the stick, copies files, splits `install.wim` into `install.swm`, and you’re done.

---

## Features
- ✅ **All‑macOS** workflow (Apple silicon & Intel)
- ✅ **FAT32 + GPT** for broad UEFI boot
- ✅ **Auto‑split `install.wim`** → `install.swm` (Windows Setup reads this natively)
- ✅ **Robust ISO mounting** via `hdiutil -plist` (handles UDF/CD9660 edge cases)
- ✅ **Safe prompts** to `/dev/tty`; logs to stderr
- ✅ **Non‑interactive mode** for automation/CI (`ISO_PATH`, `USB_DISK`, `AUTO=1`)
- ✅ **Homebrew auto‑install** of `wimlib` if missing

---

## Requirements
- macOS with: `bash`, `diskutil`, `hdiutil`, `rsync`, `awk`, `plutil`, `stat` (preinstalled on macOS)
- A **16 GB+ USB stick** that shows up as an **external whole disk** (`/dev/diskN`)
- Windows 11 ISO (**download from Microsoft**)

---

## Quick Start

```bash
# 1) Clone and enter the repo
git clone <your-repo-url>
cd <your-repo-folder>

# 2) Make the script executable
chmod +x make_win11_usb_v5.sh

# 3) Run (interactive)
bash ./make_win11_usb_v5.sh
```

**Non‑interactive / CI:**
```bash
ISO_PATH="$HOME/Downloads/Win11_24H2_EnglishInternational_x64.iso" USB_DISK="/dev/disk4" bash ./make_win11_usb_v5.sh
```

**Auto‑pick latest ISO + single external disk:**
```bash
AUTO=1 bash ./make_win11_usb_v5.sh
```

---

## Safety ⚠️

**This script PERMANENTLY ERASES the selected disk.**  
Double‑check with:

```bash
diskutil list external physical
# Expect: /dev/diskN (external, physical)
```

---

## How It Works (short)
- Formats the USB **GPT + FAT32** for broad UEFI compatibility.
- Copies all ISO files **except** `sources/install.wim`.
- If `install.wim` > 4 GiB exists, **splits** it with `wimlib-imagex` into `install.swm` (≤ 3.8 GiB each). Windows Setup automatically loads split images.
- If the ISO ships `install.esd` (typically <4 GiB), it copies that directly.
- Ejects the USB when finished.

---

## Options & Environment Variables

| Variable     | Description                                                       | Example                                                |
|--------------|-------------------------------------------------------------------|--------------------------------------------------------|
| `ISO_PATH`   | Full path to the Windows 11 ISO (skips ISO picker)                | `ISO_PATH="$HOME/Downloads/Win11_24H2_x64.iso"`        |
| `USB_DISK`   | Target disk id (skips disk picker)                                | `USB_DISK="/dev/disk4"`                                |
| `AUTO`       | `1` = pick **latest** ISO in `~/Downloads` and only external disk | `AUTO=1`                                               |

> Notes:  
> • `wimlib-imagex` is installed via Homebrew if missing.  
> • Prompts go to `/dev/tty`; function outputs are captured cleanly.

---

## Troubleshooting

**USB not listed**  
- Plug the stick **directly** into the Mac (avoid docks/hubs for setup).  
- Re‑run: `diskutil list external physical`  
- If still missing: try another port/adapter/stick.

**ISO fails to mount**  
- Re‑download from Microsoft (the script uses a robust plist mount, but a corrupt ISO won’t mount).  
- Sanity check size: `stat -f%z ~/Downloads/Win11_*.iso` (Win11 x64 ISOs are typically several GB).

**Copy/split errors**  
- Ensure Homebrew works: `brew --version`  
- Install/repair wimlib: `brew install wimlib` / `brew reinstall wimlib`

**Boot fails on target PC**  
- Use **UEFI boot** (disable Legacy/CSM).  
- If the PC’s firmware is picky, recreate the USB on another stick (some controllers are finicky).  
- For unsupported PCs (no TPM/SB): use a Windows tool (e.g., Rufus) on a Windows machine/VM if needed. This script does not modify Windows checks.

---

## Verification

After creation, you should see on the USB:
```
/sources/
   boot.wim
   install.swm  (and possibly install2.swm, …)
```
On the target PC: choose the USB in the UEFI boot menu and proceed with Windows Setup.

---

## FAQ

**Why FAT32 and not exFAT/NTFS?**  
FAT32 boots reliably across UEFI implementations. The 4 GiB limit is handled by **split WIMs** (`install.swm`), which Windows Setup supports.

**Apple silicon support?**  
Yes. This runs entirely on macOS (M‑series or Intel). It **creates** media for a PC; it is not for installing Windows on the Mac itself.

**Can I use this for Windows 10 or Server?**  
Yes—same idea. If `install.wim` is >4 GiB, it will be split.

**What about Secure Boot / TPM bypass?**  
This script doesn’t modify installation checks. If you need customizations, build media in Windows with tools like Rufus.

---

## Probability & Assumptions

- **USB created successfully on macOS:** ~98%  
- **Boots on a typical UEFI PC (GPT/FAT32):** ~95%  
- **Needs alternative media (quirky firmware/USB):** ~5–10%

**Assumptions/guesses:**  
- Your ISO is valid and contains either `install.wim` or `install.esd`.  
- Homebrew installs cleanly for `wimlib`.  
- Target PC uses UEFI boot with USB enabled.

*(Engineer humor: FAT32 is the small doorway; split WIM is how we get the sofa through.)*

---

## Sources
- Microsoft — **Windows 11 ISO Download**: https://www.microsoft.com/software-download/windows11  
- Microsoft Learn — **Split a Windows image (.wim)**: https://learn.microsoft.com/windows-hardware/manufacture/desktop/split-a-windows-image-file  
- Apple `hdiutil` reference: https://ss64.com/osx/hdiutil.html

---
