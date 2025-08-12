#!/bin/bash
set -euo pipefail

# === Konfigurasi (sesuaikan jika perlu) ===
DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"
HOSTNAME="fajardp-archlinux-pc"
USERNAME="fajar"
ROOT_PASS="passwd"
USER_PASS="passwd"

# Kernel params yang diminta (termasuk audit=1 untuk auditd)
KERNEL_PARAMS="lsm=landlock,lockdown,yama,integrity,apparmor,bpf audit=1"

# -----------------------------------------
echo "[+] Pastikan device benar:"
echo "    DISK = $DISK"
echo "    EFI_PART = $EFI_PART"
echo "    SWAP_PART = $SWAP_PART"
echo "    ROOT_PART = $ROOT_PART"
read -p "Lanjutkan? (ketik 'yes' untuk melanjutkan) " CONF
if [[ "$CONF" != "yes" ]]; then
  echo "Dibatalkan."
  exit 1
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

echo "[+] Update mirrorlist (reflector)"
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

# --- inside chroot ---
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

# Install systemd-boot
bootctl install

cat <<EOLOADER > /boot/loader/loader.conf
default arch.conf
timeout 5
console-mode max
editor no
auto-firmware yes
EOLOADER

# Ambil UUID root berdasarkan filesystem label 'archlinux'
ROOT_UUID=$(blkid -s UUID -o value /dev/disk/by-label/archlinux || true)
if [ -z "$ROOT_UUID" ]; then
  echo "Warning: tidak dapat menemukan /dev/disk/by-label/archlinux — periksa label filesystem."
fi

# Tulis entry utama dan fallback, sertakan kernel params
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

# --- AppArmor: enable service + load profiles ---
systemctl enable apparmor

# try to load default profiles now (apparmor-parser exists in package apparmor)
if command -v apparmor_parser >/dev/null 2>&1; then
  echo "[+] Loading AppArmor profiles (if any bundled by package)"
  for p in /etc/apparmor.d/*; do
    [ -e "$p" ] || continue
    # load or replace profile
    apparmor_parser -r "$p" || true
  done
fi

# If apparmor-utils installed, try set enforce mode for installed profiles (best-effort)
if command -v aa-enforce >/dev/null 2>&1; then
  aa-enforce /etc/apparmor.d/* 2>/dev/null || true
fi

# --- audit: enable service + basic rules ---
systemctl enable auditd

# Create basic audit rule set to monitor key events
mkdir -p /etc/audit/rules.d
cat <<'AUDITRULES' > /etc/audit/rules.d/99-security.rules
# Basic audit rules
# log audit failures
-a always,exit -F arch=b64 -S execve -k exec
-a always,exit -F arch=b32 -S execve -k exec

# Monitor file attribute changes & important files
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/ssh/sshd_config -p wa -k ssh

# Monitor mounts/unmounts and modules
-a always,exit -F arch=b64 -S mount -k mounts
-a always,exit -F arch=b32 -S mount -k mounts
-a always,exit -F arch=b64 -S init_module,delete_module -k modules

# Monitor network socket binds and listening
-a always,exit -F arch=b64 -S bind -k net
-a always,exit -F arch=b32 -S bind -k net
-a always,exit -F arch=b64 -S listen -k net
-a always,exit -F arch=b32 -S listen -k net

# watch for changes to /etc/apparmor.d/
-w /etc/apparmor.d/ -p wa -k apparmor

# keep logs from auditd
-a always,exit -F arch=b64 -S setxattr -k xattr
AUDITRULES

# load audit rules (augenrules is provided by audit package)
if command -v augenrules >/dev/null 2>&1; then
  augenrules --load || true
else
  # fallback reload
  systemctl restart auditd || true
fi

# --- create user and sudoers ---
useradd -m -G wheel,audio,video,network,storage,optical,power,lp,scanner -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

# --- Enable network and firewall services ---
systemctl enable iwd
systemctl enable dhcpcd
systemctl enable firewalld

# --- Enable auditd (already enabled), ensure apparmor enabled & audit active ---
systemctl enable auditd
systemctl enable apparmor

# --- Pacman hook to update systemd-boot entries when kernel/microcode change ---
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

# Attempt to reload piped services to ensure profiles/rules applied now
if command -v apparmor_parser >/dev/null 2>&1; then
  for p in /etc/apparmor.d/*; do
    [ -e "$p" ] || continue
    apparmor_parser -r "$p" || true
  done
fi

if command -v augenrules >/dev/null 2>&1; then
  augenrules --load || true
fi

echo "[+] Chroot configuration finished."
CHROOT_EOF

# -----------
echo "[✓] Instalasi selesai! Sistem akan dimatikan dalam 5 detik..."
umount -R /mnt || true
swapoff "$SWAP_PART" || true
sleep 5
shutdown now
