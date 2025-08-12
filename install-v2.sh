#!/bin/bash
set -euo pipefail

# === Konfigurasi (sesuaikan jika perlu) ===
DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"
HOSTNAME="fajardp-archlinux-pc"
USERNAME="fajar"
ROOT_PASS="r!N4@O50689#25"
USER_PASS="050689"

# Kernel params yang diminta (termasuk audit=1)
KERNEL_PARAMS="lsm=landlock,lockdown,yama,integrity,apparmor,bpf audit=1"

# -----------------------------------------
echo "[!] PERINGATAN: Script ini akan memformat $ROOT_PART (dan bisa format $EFI_PART jika kamu setuju)."
echo "    Periksa variabel di awal script: DISK, EFI_PART, SWAP_PART, ROOT_PART."
read -p "Lanjutkan? (ketik 'yes' untuk melanjutkan) " CONF
if [[ "$CONF" != "yes" ]]; then
  echo "Dibatalkan."
  exit 1
fi

# Pastikan lingkungan UEFI (systemd-boot memerlukan UEFI)
if [ ! -d /sys/firmware/efi ]; then
  echo "ERROR: Sistem live tidak boot dalam mode UEFI. systemd-boot membutuhkan UEFI. Hentikan."
  exit 1
fi

# Pilihan format EFI (opsional)
read -p "Format EFI partition $EFI_PART sebagai FAT32? (ketik 'yes' untuk format, 'no' untuk skip) " EFI_FMT
if [[ "$EFI_FMT" == "yes" ]]; then
  if ! command -v mkfs.fat >/dev/null 2>&1 && ! command -v mkfs.vfat >/dev/null 2>&1; then
    echo "ERROR: mkfs.fat/mkfs.vfat tidak ditemukan di environment live. Install dosfstools dulu atau format manual."
    exit 1
  fi
  echo "[+] Formatting $EFI_PART as FAT32 (label: EFI)"
  mkfs.fat -F32 -n EFI "$EFI_PART"
fi

echo "[+] Format BTRFS on $ROOT_PART and label 'archlinux'"
mkfs.btrfs -f -L archlinux "$ROOT_PART"

echo "[+] Buat subvolume BTRFS"
mount "$ROOT_PART" /mnt
for subvol in @ @home @log @cache @tmp @srv @swap; do
    btrfs subvolume create "/mnt/$subvol"
done
umount /mnt

echo "[+] Mount subvolumes (root = subvol=@)"
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{home,tmp,srv,swap,var/log,var/cache}
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@home  "$ROOT_PART" /mnt/home
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@tmp   "$ROOT_PART" /mnt/tmp
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@srv   "$ROOT_PART" /mnt/srv
mount -o noatime,nodatacow,compress=no,subvol=@swap "$ROOT_PART" /mnt/swap
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@log   "$ROOT_PART" /mnt/var/log
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@cache "$ROOT_PART" /mnt/var/cache

echo "[+] Mount EFI System Partition -> /boot"
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

echo "[+] Enable swap"
swapon "$SWAP_PART"

echo "[+] Update mirrorlist (reflector) and install packages needed to run reflector if missing"
pacman -Sy --noconfirm reflector
reflector --country Indonesia --latest 5 --sort rate --save /etc/pacman.d/mirrorlist

echo "[+] Install base system + kernel Zen + tools security & network"
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware intel-ucode \
    vim sudo btrfs-progs git bash tzdata lz4 zstd iwd dhcpcd firewalld apparmor audit

echo "[+] Generate fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# ----------------------------
# Chroot config (everything executed inside chroot)
# ----------------------------
arch-chroot /mnt /bin/bash <<'CHROOT_EOF'
set -euo pipefail

# ---------- variables inside chroot ----------
HOSTNAME="fajardp-archlinux-pc"
USERNAME="fajar"
ROOT_PASS="passwd"
USER_PASS="passwd"
KERNEL_PARAMS="lsm=landlock,lockdown,yama,integrity,apparmor,bpf audit=1"

ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
cat <<EOHOSTS > /etc/hosts
127.0.0.1       localhost
::1             localhost
127.0.1.1       $HOSTNAME.localdomain $HOSTNAME
EOHOSTS

echo "root:$ROOT_PASS" | chpasswd

# Ensure mkinitcpio creates images appropriate for this setup
if command -v mkinitcpio >/dev/null 2>&1; then
  echo "[+] Regenerate initramfs for installed kernels (mkinitcpio -P)"
  mkinitcpio -P || true
fi

# Install systemd-boot
bootctl install

cat <<EOLOADER > /boot/loader/loader.conf
default arch.conf
timeout 5
console-mode max
editor no
auto-firmware yes
EOLOADER

# Fetch UUID from label 'archlinux' (created by mkfs.btrfs -L archlinux)
ROOT_UUID=$(blkid -s UUID -o value /dev/disk/by-label/archlinux || true)
if [ -z "$ROOT_UUID" ]; then
  echo "WARNING: tidak menemukan /dev/disk/by-label/archlinux — pastikan label filesystem dibuat."
fi

# Write main entry (Zen) and fallback; include kernel params
cat <<EOENTRY > /boot/loader/entries/arch.conf
title   Arch Linux (Zen Kernel)
linux   /vmlinuz-linux-zen
initrd  /intel-ucode.img
initrd  /initramfs-linux-zen.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@ $KERNEL_PARAMS
EOENTRY

cat <<EOFALL > /boot/loader/entries/arch-fallback.conf
title   Arch Linux (Zen Kernel - Fallback Initramfs)
linux   /vmlinuz-linux-zen
initrd  /intel-ucode.img
initrd  /initramfs-linux-zen-fallback.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@ $KERNEL_PARAMS
EOFALL

# --- AppArmor ---
systemctl enable apparmor

# Load any available profiles now (best-effort)
if command -v apparmor_parser >/dev/null 2>&1; then
  for p in /etc/apparmor.d/*; do
    [ -e "$p" ] || continue
    apparmor_parser -r "$p" || true
  done
fi

# If aa-enforce exists, set profiles to enforce (best effort)
if command -v aa-enforce >/dev/null 2>&1; then
  aa-enforce /etc/apparmor.d/* 2>/dev/null || true
fi

# --- audit ---
systemctl enable auditd

mkdir -p /etc/audit/rules.d
cat <<'AUDITRULES' > /etc/audit/rules.d/99-security.rules
# Basic audit rules (arch + b32/b64)
-a always,exit -F arch=b64 -S execve -k exec
-a always,exit -F arch=b32 -S execve -k exec

# File and identity monitoring
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/ssh/sshd_config -p wa -k ssh

# Mounts / modules
-a always,exit -F arch=b64 -S mount -k mounts
-a always,exit -F arch=b32 -S mount -k mounts
-a always,exit -F arch=b64 -S init_module,delete_module -k modules

# Network socket binds & listens
-a always,exit -F arch=b64 -S bind -k net
-a always,exit -F arch=b32 -S bind -k net
-a always,exit -F arch=b64 -S listen -k net
-a always,exit -F arch=b32 -S listen -k net

# AppArmor directory changes
-w /etc/apparmor.d/ -p wa -k apparmor

# xattr changes
-a always,exit -F arch=b64 -S setxattr -k xattr
AUDITRULES

# Load audit rules (try augenrules)
if command -v augenrules >/dev/null 2>&1; then
  augenrules --load || true
else
  systemctl restart auditd || true
fi

# --- user + sudoers ---
useradd -m -G wheel,audio,video,network,storage,optical,power,lp,scanner -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

# --- Enable network and firewall services ---
systemctl enable iwd
systemctl enable dhcpcd
systemctl enable firewalld

# --- Pacman hook to keep systemd-boot entries updated on kernel/microcode updates ---
mkdir -p /etc/pacman.d/hooks
cat <<'HOOK' > /etc/pacman.d/hooks/95-systemd-boot-entry.hook
[Trigger]
Type = Path
Target = boot/vmlinuz-linux-zen
Target = boot/initramfs-linux-zen.img
Target = boot/initramfs-linux-zen-fallback.img
Target = boot/intel-ucode.img

[Action]
Description = Updating systemd-boot loader entries for linux-zen...
When = PostTransaction
Exec = /usr/bin/bash -c '
KERNEL_PARAMS="lsm=landlock,lockdown,yama,integrity,apparmor,bpf audit=1"
ROOT_PART_UUID=$(blkid -s UUID -o value /dev/disk/by-label/archlinux || true)
if [ -z "$ROOT_PART_UUID" ]; then
  echo "Warning: cannot find /dev/disk/by-label/archlinux"
fi

cat <<EOE > /boot/loader/entries/arch.conf
title   Arch Linux (Zen Kernel)
linux   /vmlinuz-linux-zen
initrd  /intel-ucode.img
initrd  /initramfs-linux-zen.img
options root=UUID=$ROOT_PART_UUID rw rootflags=subvol=@ $KERNEL_PARAMS
EOE

cat <<EOE > /boot/loader/entries/arch-fallback.conf
title   Arch Linux (Zen Kernel - Fallback Initramfs)
linux   /vmlinuz-linux-zen
initrd  /intel-ucode.img
initrd  /initramfs-linux-zen-fallback.img
options root=UUID=$ROOT_PART_UUID rw rootflags=subvol=@ $KERNEL_PARAMS
EOE
'
HOOK

echo "[+] Chroot configuration finished."
CHROOT_EOF

# -----------
echo "[✓] Instalasi selesai! Sistem akan dimatikan dalam 5 detik..."
umount -R /mnt || true
swapoff "$SWAP_PART" || true
sleep 5
shutdown now
