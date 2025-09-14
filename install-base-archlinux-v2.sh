#!/usr/bin/env bash
set -Eeuo pipefail

###############################################
# Arch Linux Auto Install (BTRFS + systemd-boot)
# - Wi‑Fi via iwd
# - IP/DNS via systemd-networkd + systemd-resolved
# - ESP di-mount ke /boot
###############################################

# ====== KONFIGURASI YANG WAJIB DICEK ======
EFI_PART="/dev/nvme0n1p1"     # ESP (FAT32)
ROOT_PART="/dev/nvme0n1p2"    # Root (BTRFS)
HOSTNAME="fajardp-archlinux-pc"
USERNAME="fajar"
ROOT_PASS="password"
USER_PASS="password"

# Opsi format partisi (ubah ke true/false sesuai kebutuhan)
FORMAT_EFI=true         # true jika ingin format ulang ESP

# ====== CEK PRASYARAT ======
if [[ $EUID -ne 0 ]]; then
  echo "[!] Skrip ini harus dijalankan sebagai root" >&2
  exit 1
fi
if [[ ! -d /sys/firmware/efi ]]; then
  echo "[!] Sistem tidak boot dalam mode UEFI. systemd-boot butuh UEFI." >&2
  exit 1
fi

# ====== PERSIAPAN DISK ======
echo "[+] Siapkan partisi"

if [[ "$FORMAT_EFI" == "true" ]]; then
  echo "[+] Format ESP (${EFI_PART}) ke FAT32"
  mkfs.fat -F32 -n ESP "$EFI_PART"
fi

echo "[+] Format BTRFS di $ROOT_PART"
mkfs.btrfs -f -L ArchLinux "$ROOT_PART"

# ====== LAYOUT SUBVOLUME ======
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp
umount /mnt

# ====== MOUNT DENGAN OPSI YANG BAIK ======
MNT_OPTS="noatime,compress=zstd,ssd,discard=async,space_cache=v2"
mount -o ${MNT_OPTS},subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{home,boot,var/log,var/cache,var/tmp}
mount -o ${MNT_OPTS},subvol=@home "$ROOT_PART" /mnt/home
mount -o ${MNT_OPTS},subvol=@log "$ROOT_PART" /mnt/var/log
mount -o ${MNT_OPTS},subvol=@cache "$ROOT_PART" /mnt/var/cache
mount -o ${MNT_OPTS},subvol=@tmp "$ROOT_PART" /mnt/var/tmp

# ESP di-mount ke /boot
mount "$EFI_PART" /mnt/boot

# ====== MIRRORLIST (host/live environment) ======
echo "[+] Atur mirror archlinux (host)"
pacman -Sy --noconfirm reflector
reflector --country Singapore --country Indonesia --age 6 --sort rate --save /etc/pacman.d/mirrorlist

# ====== INSTALL BASE ======
echo "[+] pacstrap base system"
pacstrap -K /mnt \
  base base-devel linux-zen linux-zen-headers linux-firmware intel-ucode \
  btrfs-progs iwd sudo neovim reflector firewalld

# Fstab gunakan UUID
genfstab -U /mnt > /mnt/etc/fstab

# Ambil UUID root untuk entri boot
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# ====== KONFIGURASI DALAM CHROOT ======
echo "[+] Konfigurasi dalam chroot"
arch-chroot /mnt <<EOF
set -Eeuo pipefail

timedatectl set-ntp true
ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
hwclock --systohc
# Uncomment locale en_US.UTF-8
sed -i 's/^[[:space:]]*#[[:space:]]*\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOL
127.0.0.1       localhost
::1             localhost
127.0.1.1       $HOSTNAME.localdomain $HOSTNAME
EOL

echo "root:$ROOT_PASS" | chpasswd

# ====== Bootloader: systemd-boot ======
bootctl install
cat >/boot/loader/loader.conf <<EOL
default arch-zen.conf
timeout 3
editor 0
console-mode 1
EOL

cat >/boot/loader/entries/arch-zen.conf <<EOL
title   Arch Linux (Zen Kernel)
linux   /vmlinuz-linux-zen
initrd  /intel-ucode.img
initrd  /initramfs-linux-zen.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@
EOL

cat >/boot/loader/entries/arch-zen-fallback.conf <<EOL
title   Arch Linux (Zen Kernel fallback)
linux   /vmlinuz-linux-zen
initrd  /intel-ucode.img
initrd  /initramfs-linux-zen-fallback.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@
EOL

# ====== User & sudo ======
useradd -m -U -G wheel,audio,video,storage,optical,power,lp,scanner,ftp,http,sys,rfkill,tty,disk,input,network -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/00-wheel
chmod 0440 /etc/sudoers.d/00-wheel

# ====== Networking: iwd + networkd/resolved ======
mkdir -p /etc/systemd/network
cat >/etc/systemd/network/20-wired.network <<EOL
[Match]
Name=en*

[Network]
DHCP=yes
IPv6PrivacyExtensions=yes
EOL

cat >/etc/systemd/network/30-wlan.network <<EOL
[Match]
Name=wl*

[Network]
DHCP=yes
IPv6PrivacyExtensions=yes
EOL

ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf || true

systemctl enable iwd.service
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service
systemctl enable firewalld.service
systemctl enable systemd-timesyncd.service

# Pastikan initramfs up-to-date
mkinitcpio -P

# (Opsional) mirrorlist di sistem terpasang
pacman -Sy --noconfirm reflector
reflector --country Indonesia --age 6 --sort rate --save /etc/pacman.d/mirrorlist || true
EOF

# ====== BERESKAN ======
echo "[+] Unmount & matikan"
umount -R /mnt
trap - EXIT

# Ganti ke 'reboot' jika ingin restart
systemctl poweroff
