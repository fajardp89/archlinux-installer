#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Arch Linux Auto Installer (NVMe optimized, ZEN kernel default)
# - GPT: EFI (1GiB), swap (6GiB), btrfs (rest)
# - Btrfs subvolumes: @, @home, @log, @cache, @tmp, @srv
# - Install systemd-boot (replace GRUB if present)
# - Use iwd (iwctl) instead of NetworkManager
# - Add pacman hooks for kernel/systemd-boot updates (linux-zen)
# - Include optional initial Wi-Fi setup with iwctl
# - Set linux-zen as the only kernel (remove other kernels)
# -----------------------------

DISK="/dev/nvme0n1"
EFI_SIZE_MiB=1024
SWAP_SIZE_MiB=6144
BTRFS_LABEL="archlinux"
EFI_LABEL="EFI"
SWAP_LABEL="Swap"

read -rp "Hostname (default: arch): " HOSTNAME
HOSTNAME=${HOSTNAME:-arch}
read -rp "Username (default: user): " USERNAME
USERNAME=${USERNAME:-user}

read -rsp "Set root password: " ROOT_PASS; echo
read -rsp "Set $USERNAME password: " USER_PASS; echo

read -rp "Optional: Wi-Fi SSID (leave empty to skip): " WIFI_SSID
read -rsp "Wi-Fi Password: " WIFI_PASS; echo

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
[[ "$CONFIRM" == "$DISK" ]] || { echo "Aborted."; exit 1; }

# --- Partitioning ---
parted -s "$DISK" mklabel gpt
EFI_END=$((1 + EFI_SIZE_MiB))
SWAP_END=$((EFI_END + SWAP_SIZE_MiB))
parted -s "$DISK" mkpart primary fat32 1MiB ${EFI_END}MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary linux-swap ${EFI_END}MiB ${SWAP_END}MiB
parted -s "$DISK" mkpart primary btrfs ${SWAP_END}MiB 100%
partprobe "$DISK" || true

# --- Format ---
mkfs.fat -F32 -n "$EFI_LABEL" "$EFI_PART"
mkswap -L "$SWAP_LABEL" "$SWAP_PART"
swapon "$SWAP_PART"
mkfs.btrfs -f -L "$BTRFS_LABEL" "$ROOT_PART"

# --- Btrfs subvolumes & mount ---
mount "$ROOT_PART" /mnt
for sub in @ @home @log @cache @tmp @srv; do btrfs subvolume create /mnt/$sub; done
umount /mnt
MNT_OPTS="noatime,compress=zstd,ssd,discard=async,space_cache=v2"
mount -o ${MNT_OPTS},subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{home,tmp,srv,var/log,var/cache}
mount -o ${MNT_OPTS},subvol=@home  "$ROOT_PART" /mnt/home
mount -o ${MNT_OPTS},subvol=@tmp   "$ROOT_PART" /mnt/tmp
mount -o ${MNT_OPTS},subvol=@srv   "$ROOT_PART" /mnt/srv
mount -o ${MNT_OPTS},subvol=@log   "$ROOT_PART" /mnt/var/log
mount -o ${MNT_OPTS},subvol=@cache "$ROOT_PART" /mnt/var/cache
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# --- Mirrors & base install (install linux-zen instead of linux) ---
echo "[+] Updating mirrorlist (reflector)"
pacman -Sy --noconfirm reflector
yes | reflector --country Indonesia --latest 5 --sort rate --save /etc/pacman.d/mirrorlist || true

# Install linux-zen as default kernel, do NOT install 'linux'
pacstrap -K /mnt base base-devel linux-zen linux-firmware intel-ucode vim sudo btrfs-progs git bash tzdata lz4 zstd iwd

# --- fstab ---
genfstab -U /mnt > /mnt/etc/fstab

# --- Chroot configuration ---
arch-chroot /mnt /bin/bash <<'EOCHROOT'
set -euo pipefail

ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOFHOSTS
127.0.0.1	localhost
::1		localhost
127.0.1.1	${HOSTNAME}.localdomain ${HOSTNAME}
EOFHOSTS

# Set passwords and user (passwords passed via envsubst in outer script)
echo "root:${ROOT_PASS}" | chpasswd
useradd -m -G wheel,audio,video,storage -s /bin/bash ${USERNAME}
echo "${USERNAME}:${USER_PASS}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Remove any existing generic linux kernel (if present) and ensure only linux-zen exists
pacman -Rns --noconfirm linux || true
pacman -S --noconfirm linux-zen || true

# Install and configure systemd-boot
pacman -Rns --noconfirm grub || true
bootctl --path=/boot install

# Determine PARTUUID for root to use in loader entry
ROOT_PARTUUID=$(blkid -s PARTUUID -o value ${ROOT_PART} || true)

cat > /boot/loader/loader.conf <<LOADER
default arch-zen
timeout 3
editor no
LOADER

# Create loader entry for linux-zen
KERNEL_NAME="vmlinuz-linux-zen"
INITRAMFS_NAME="initramfs-linux-zen.img"
MCU_NAME="intel-ucode.img"
INITRAMFS_LINES=""
if [ -f /boot/${MCU_NAME} ]; then
  INITRAMFS_LINES="initrd /${MCU_NAME}
initrd /${INITRAMFS_NAME}"
else
  INITRAMFS_LINES="initrd /${INITRAMFS_NAME}"
fi
OPTIONS_LINE="options root=PARTUUID=${ROOT_PARTUUID} rw rootflags=subvol=@"

cat > /boot/loader/entries/arch-zen.conf <<ENTRY
title   Arch Linux (zen)
linux   /${KERNEL_NAME}
${INITRAMFS_LINES}
${OPTIONS_LINE}
ENTRY

# Enable iwd and disable NetworkManager
systemctl disable NetworkManager || true
systemctl enable iwd

# Pacman hook: on linux-zen upgrade, update initramfs and systemd-boot
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

# Also ensure systemd package updates will update systemd-boot
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

# Generate initramfs for installed kernels
mkinitcpio -P
EOCHROOT

# --- Optional: quick iwctl connect (on live environment) ---
if [[ -n "${WIFI_SSID}" ]]; then
  echo "[+] Attempting temporary Wi-Fi connect (live env)"
  # Detect wireless interface name via iwctl
  IFACE=$(iwctl station list | awk '/Interface/ {print $2; exit}') || IFACE="wlan0"
  if [[ -n "$IFACE" ]]; then
    iwctl --passphrase "${WIFI_PASS}" station $IFACE connect "${WIFI_SSID}" || true
  else
    echo "[!] Wi-Fi interface not found; skipping iwctl connect"
  fi
fi

echo "[✓] Instalasi selesai! Rebooting..."
umount -R /mnt || true
swapoff ${SWAP_PART} || true
reboot
