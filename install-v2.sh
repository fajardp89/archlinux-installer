#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Arch Linux Auto Installer (NVMe optimized, ZEN kernel default)
# Final audited version with:
#  - logging to /tmp (copied to /mnt/root/install.log at end)
#  - UEFI mode check
#  - interactive passwd inside chroot (requires TTY)
#  - early Wi‑Fi connect (iwctl) before reflector/pacstrap
#  - dhcpcd for DHCP with iwd
#  - safe insertion of AppArmor into mkinitcpio HOOKS
#  - systemd-boot install + conditional microcode handling
#  - btrfs subvolumes with reusable function
#  - kernel LSM + AppArmor boot params
# -------------------------------------------------------------------

# -----------------------
# Logging (to /tmp, will copy to /mnt/root/install.log at end)
# -----------------------
LOGFILE="/tmp/arch-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

# -----------------------
# Utils & safety checks
# -----------------------
info(){ echo "[$(date '+%F %T')] [INFO] $*"; }
err(){ echo "[$(date '+%F %T')] [ERROR] $*" >&2; }

# Require interactive TTY for passwd prompts
if [ ! -t 0 ]; then
  err "This script requires an interactive TTY (for passwd prompts). Run from local live ISO terminal." 
  exit 1
fi

# Require UEFI
if [ ! -d /sys/firmware/efi ]; then
  err "System not booted in UEFI mode. systemd-boot requires UEFI. Aborting."
  exit 1
fi

# -----------------------
# Configurable variables
# -----------------------
DISK="/dev/nvme0n1"                 # NVMe device — change if needed
EFI_SIZE_MiB=1024
SWAP_SIZE_MiB=6144
BTRFS_LABEL="archlinux"
EFI_LABEL="EFI"
SWAP_LABEL="Swap"

# Predefined hostname and username — EDIT THESE
HOSTNAME="arch"   # change as desired
USERNAME="user"   # change as desired

# Kernel LSM parameter to append to kernel cmdline (includes AppArmor flags)
KERNEL_LSM_PARAMS="lsm=landlock,lockdown,yama,integrity,apparmor,bpf apparmor=1 security=apparmor"

info "Using hostname='$HOSTNAME' and username='$USERNAME'"

# -----------------------
# Interactive inputs
# -----------------------
read -rp "Optional: Wi‑Fi SSID (leave empty to skip): " WIFI_SSID
if [[ -n "$WIFI_SSID" ]]; then
  read -rsp "(Optional) Wi‑Fi passphrase (will be prompted by iwctl if required): " WIFI_PLAIN; echo
  info "Wi‑Fi passphrase recorded for interactive use (not passed on CLI)."
fi

# -----------------------
# Live-environment dependency checks
# -----------------------
REQUIRED=(parted mkfs.fat mkswap mkfs.btrfs btrfs pacstrap genfstab pacman blkid partprobe)
for c in "${REQUIRED[@]}"; do
  if ! command -v "$c" &>/dev/null; then
    err "Required command '$c' not found in live environment. Please run from an Arch live ISO (or install the tool)."
    exit 1
  fi
done
info "All required commands present in live environment."

# iwctl optional, reflector optional (we'll install if missing)

EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"

cat <<WARN
WARNING: This will ERASE ALL DATA on ${DISK}
Planned partitions:
  - ${EFI_PART}  : EFI (FAT32, ${EFI_SIZE_MiB} MiB)
  - ${SWAP_PART} : Swap (${SWAP_SIZE_MiB} MiB)
  - ${ROOT_PART} : Btrfs (remaining space)
Type the disk path again to confirm: ${DISK}
WARN
read -r CONFIRM
[[ "$CONFIRM" == "$DISK" ]] || { err "Confirmation mismatch — aborted."; exit 1; }

# Small safety pause
for i in 5 4 3 2 1; do echo "Proceeding in ${i}... (Ctrl+C to cancel)"; sleep 1; done

# -----------------------
# Early Wi‑Fi connect (so reflector/pacstrap can use network)
# -----------------------
if [[ -n "${WIFI_SSID}" ]]; then
  if command -v iwctl &>/dev/null; then
    info "Attempting interactive Wi‑Fi connect to '${WIFI_SSID}' using iwctl"
    IFACE=$(iwctl station list | awk '/Interface/ {print $2; exit}') || IFACE="wlan0"
    if [[ -n "$IFACE" ]]; then
      echo "You may be prompted by iwctl to enter the passphrase."
      iwctl station "$IFACE" connect "${WIFI_SSID}" || info "iwctl connect returned non-zero — continuing, but pacstrap/reflector may fail without network"
      if ping -c1 8.8.8.8 &>/dev/null; then
        info "Network appears up"
      else
        info "No network connectivity detected after iwctl"
      fi
    else
      info "No wireless interface reported by iwctl; skipping auto-connect"
    fi
  else
    info "iwctl not available in live env; skipping auto Wi‑Fi connect"
  fi
fi

# -----------------------
# Partitioning
# -----------------------
info "Creating GPT partition table and partitions on $DISK"
parted -s "$DISK" mklabel gpt
EFI_END=$((1 + EFI_SIZE_MiB))
SWAP_END=$((EFI_END + SWAP_SIZE_MiB))
parted -s "$DISK" mkpart primary fat32 1MiB ${EFI_END}MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary linux-swap ${EFI_END}MiB ${SWAP_END}MiB
parted -s "$DISK" mkpart primary btrfs ${SWAP_END}MiB 100%
partprobe "$DISK" || true
udevadm settle || true

# -----------------------
# Formatting
# -----------------------
info "Formatting partitions"
mkfs.fat -F32 -n "$EFI_LABEL" "$EFI_PART"
mkswap -L "$SWAP_LABEL" "$SWAP_PART"
swapon "$SWAP_PART"
mkfs.btrfs -f -L "$BTRFS_LABEL" "$ROOT_PART"

# -----------------------
# Btrfs subvolumes & mount
# -----------------------
info "Creating btrfs subvolumes"
mount "$ROOT_PART" /mnt
for sub in @ @home @log @cache @tmp @srv; do
  if ! btrfs subvolume list /mnt | awk '{print $NF}' | grep -qx "$sub"; then
    btrfs subvolume create /mnt/$sub
  fi
done
umount /mnt

mount_subvol() {
  local sub=$1 target=$2
  mount -o noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvol=${sub} "$ROOT_PART" "$target"
}

mount_subvol @ /mnt
mkdir -p /mnt/{home,tmp,srv,var/log,var/cache}
mount_subvol @home /mnt/home
mount_subvol @tmp /mnt/tmp
mount_subvol @srv /mnt/srv
mount_subvol @log /mnt/var/log
mount_subvol @cache /mnt/var/cache
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# Ensure /mnt/root exists so we can copy logs and place helper scripts
mkdir -p /mnt/root

# -----------------------
# Mirrors: ensure reflector available and run it
# -----------------------
if ! command -v reflector &>/dev/null; then
  info "reflector not installed; attempting to install in live environment"
  pacman -Sy --noconfirm reflector || info "Failed to install reflector; continuing with existing mirrorlist"
fi
if command -v reflector &>/dev/null; then
  info "Updating mirrorlist with reflector"
  reflector --country Indonesia --latest 5 --sort rate --save /etc/pacman.d/mirrorlist || info "reflector failed — continuing"
fi

# -----------------------
# Install base system (include dhcpcd so iwd can get DHCP)
# -----------------------
info "Installing base system and required packages (this may take a while)"
pacstrap -K /mnt base base-devel linux-zen linux-firmware intel-ucode vim sudo btrfs-progs git bash tzdata lz4 zstd iwd dhcpcd firewalld apparmor pipewire pipewire-pulse pipewire-alsa wireplumber pipewire-jack sof-firmware --noconfirm --needed

# -----------------------
# Generate fstab
# -----------------------
info "Generating /etc/fstab"
genfstab -U /mnt > /mnt/etc/fstab

# -----------------------
# Prepare chroot helper scripts (safe variable passing)
# -----------------------
info "Writing chroot helper scripts"
cat > /mnt/root/installer_vars.sh <<VARS
# installer variables (auto-generated)
HOSTNAME='${HOSTNAME}'
USERNAME='${USERNAME}'
EFI_PART='${EFI_PART}'
ROOT_PART='${ROOT_PART}'
KERNEL_LSM_PARAMS='${KERNEL_LSM_PARAMS}'
KERNEL_NAME='vmlinuz-linux-zen'
INITRAMFS_NAME='initramfs-linux-zen.img'
MCU_INTEL='intel-ucode.img'
VARS
chmod 600 /mnt/root/installer_vars.sh

cat > /mnt/root/setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail

# Load installer variables created from live environment
. /root/installer_vars.sh

info(){ echo "[$(date '+%F %T')] [CHROOT INFO] $*"; }
err(){ echo "[$(date '+%F %T')] [CHROOT ERROR] $*" >&2; }

info "Configuring system (inside chroot)"

# timezone & locale
ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
hwclock --systohc
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# hostname & hosts
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOFHOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME}.localdomain ${HOSTNAME}
EOFHOSTS

# create user and set passwords interactively
useradd -m -G wheel,audio,video,storage,lp,optical,scanner -s /bin/bash "${USERNAME}"

echo "Please set the root password now:"
passwd root

echo "Please set the password for ${USERNAME} now:"
passwd "${USERNAME}"

# sudoers
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# ensure systemd-boot available
if ! command -v bootctl &>/dev/null; then
  echo "bootctl not found — installing systemd package to get systemd-boot"
  pacman -Sy --noconfirm systemd || true
fi

# check EFI partition type
if ! blkid -s TYPE -o value "$EFI_PART" | grep -iq 'vfat'; then
  echo "[!] Warning: EFI partition ($EFI_PART) is not detected as vfat. bootctl may fail."
fi

# Install systemd-boot
if ! bootctl --path=/boot install &>/dev/null; then
  echo "[!] systemd-boot installation reported a non-fatal issue"
fi

# Ensure AppArmor in mkinitcpio HOOKS (insert before filesystems, safe)
if ! grep -q "apparmor" /etc/mkinitcpio.conf; then
  if grep -q "filesystems" /etc/mkinitcpio.conf; then
    sed -i "s/\(filesystems\)/apparmor \1/" /etc/mkinitcpio.conf || true
  else
    echo "HOOKS=(base udev autodetect modconf block filesystems keyboard fsck apparmor)" >> /etc/mkinitcpio.conf
  fi
fi

# kernel and boot loader entry (conditional microcode)
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART" || true)
ENTRY_FILE=/boot/loader/entries/arch-zen.conf
mkdir -p /boot/loader/entries
cat > "$ENTRY_FILE" <<EOF
title   Arch Linux (zen)
linux   /${KERNEL_NAME}
EOF
# add microcode if present
if [ -f "/boot/\${MCU_INTEL#'/'}" ]; then
  printf 'initrd /%s\n' "${MCU_INTEL}" >> "$ENTRY_FILE"
fi
# add initramfs
printf 'initrd /%s\n' "${INITRAMFS_NAME}" >> "$ENTRY_FILE"
# add options
printf 'options root=PARTUUID=%s rw rootflags=subvol=@ %s\n' "$ROOT_PARTUUID" "$KERNEL_LSM_PARAMS" >> "$ENTRY_FILE"

# enable services
systemctl enable iwd || true
systemctl enable dhcpcd || true
systemctl enable firewalld || true
systemctl enable apparmor || true
# enable PipeWire user units globally so new users auto-run them
systemctl --global enable pipewire.service pipewire-pulse.service wireplumber.service || true

# pacman hooks
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/90-linux-zen.hook <<HOOK
[Trigger]
Type = Package
Operation = Upgrade
Target = linux-zen

[Action]
Description = Regenerate initramfs and update systemd-boot
When = PostTransaction
Exec = /usr/bin/mkinitcpio -P
Exec = /usr/bin/bootctl update
HOOK

cat > /etc/pacman.d/hooks/100-systemd-boot.hook <<HOOK
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Updating systemd-boot...
When = PostTransaction
Exec = /usr/bin/bootctl update
HOOK

mkinitcpio -P || true

info "Chroot configuration complete"
CHROOT

chmod +x /mnt/root/setup.sh

# -----------------------
# Run chroot setup
# -----------------------
info "Entering arch-chroot to run setup script"
arch-chroot /mnt /root/setup.sh

# copy installer log into installed system for debugging
if [[ -f "$LOGFILE" ]]; then
  cp "$LOGFILE" /mnt/root/install.log || info "Could not copy log to /mnt/root — continuing"
fi

# -----------------------
# Finalize network (attempt once more from live env if needed)
# -----------------------
if [[ -n "${WIFI_SSID}" ]]; then
  if command -v iwctl &>/dev/null; then
    info "Final attempt to ensure Wi‑Fi connected before finishing"
    IFACE=$(iwctl station list | awk '/Interface/ {print $2; exit}') || IFACE="wlan0"
    if [[ -n "$IFACE" ]]; then
      iwctl station "$IFACE" connect "${WIFI_SSID}" || true
    fi
  fi
fi

# -----------------------
# Wrap up
# -----------------------
info "Installation finished — syncing and shutting down"
sync
umount -R /mnt || true
swapoff ${SWAP_PART} || true
info "Logfile saved to /root/install.log on installed system (if copy succeeded)."
poweroff
