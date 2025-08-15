#!/usr/bin/env bash
set -Eeuo pipefail

###############################################
# Arch Linux Auto Install (BTRFS + systemd-boot)
# - Wi‑Fi via iwd (tanpa NetworkManager)
# - IP/DNS via systemd-networkd + systemd-resolved
# - ESP di-mount ke /boot
###############################################

# ====== KONFIGURASI YANG WAJIB DICEK ======
EFI_PART="/dev/sdX1"     # ESP (FAT32)
SWAP_PART="/dev/sdX2"    # Swap partition
ROOT_PART="/dev/sdX3"    # Root (BTRFS)
HOSTNAME="archlinux"
USERNAME="user"
ROOT_PASS="password"
USER_PASS="password"

# Opsi format partisi (ubah ke true/false sesuai kebutuhan)
FORMAT_EFI=false         # true jika ingin format ulang ESP
FORMAT_SWAP=true         # true agar mkswap sebelum swapon

# ====== CEK PRASYARAT ======
if [[ $EUID -ne 0 ]]; then
  echo "[!] Skrip ini harus dijalankan sebagai root" >&2
  exit 1
fi
if [[ ! -d /sys/firmware/efi ]]; then
  echo "[!] Sistem tidak boot dalam mode UEFI. systemd-boot butuh UEFI." >&2
  exit 1
fi

cleanup() {
  set +e
  echo "[*] Cleanup: unmount & swapoff bila masih terpasang…"
  umount -R /mnt 2>/dev/null || true
  swapoff "$SWAP_PART" 2>/dev/null || true
}
trap cleanup EXIT

# ====== PERSIAPAN DISK ======
echo "[+] Siapkan partisi"

if [[ "$FORMAT_EFI" == "true" ]]; then
  echo "[+] Format ESP (${EFI_PART}) ke FAT32"
  mkfs.fat -F32 -n ESP "$EFI_PART"
fi

if [[ "$FORMAT_SWAP" == "true" ]]; then
  echo "[+] Buat swap di ${SWAP_PART}"
  mkswap -f "$SWAP_PART"
fi

echo "[+] Format BTRFS di $ROOT_PART"
mkfs.btrfs -f -L archlinux "$ROOT_PART"

# ====== LAYOUT SUBVOLUME ======
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@srv
umount /mnt

# ====== MOUNT DENGAN OPSI YANG BAIK ======
MNT_OPTS="noatime,compress=zstd,ssd,discard=async,space_cache=v2"
mount -o ${MNT_OPTS},subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/{home,tmp,srv,var/log,var/cache,boot}
mount -o ${MNT_OPTS},subvol=@home  "$ROOT_PART" /mnt/home
mount -o ${MNT_OPTS},subvol=@tmp   "$ROOT_PART" /mnt/tmp
mount -o ${MNT_OPTS},subvol=@srv   "$ROOT_PART" /mnt/srv
mount -o ${MNT_OPTS},subvol=@log   "$ROOT_PART" /mnt/var/log
mount -o ${MNT_OPTS},subvol=@cache "$ROOT_PART" /mnt/var/cache

# ESP di-mount ke /boot
mount "$EFI_PART" /mnt/boot

# Aktifkan swap
swapon "$SWAP_PART"

# ====== MIRRORLIST (host/live environment) ======
echo "[+] Atur mirror Indonesia (host)"
pacman -Sy --noconfirm reflector
reflector --country Indonesia --latest 5 --sort rate --save /etc/pacman.d/mirrorlist

# ====== INSTALL BASE ======
echo "[+] pacstrap base system"
pacstrap -K /mnt \
  base base-devel linux linux-firmware intel-ucode \
  btrfs-progs iwd sudo vim reflector firewalld

# Fstab gunakan UUID
genfstab -U /mnt >> /mnt/etc/fstab

# Ambil UUID & PARTUUID root untuk entri boot
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")

# ====== KONFIGURASI DALAM CHROOT ======
echo "[+] Konfigurasi dalam chroot"
arch-chroot /mnt /bin/bash <<EOF
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
default arch
timeout 3
editor 0
console-mode max
EOL

cat >/boot/loader/entries/arch.conf <<EOL
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@
EOL

cat >/boot/loader/entries/arch-fallback.conf <<EOL
title   Arch Linux (fallback)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux-fallback.img
options root=UUID=$ROOT_UUID rw rootflags=subvol=@
EOL

# ====== User & sudo ======
useradd -m -U -G wheel,audio,video,storage,optical,power,lp,scanner -s /bin/bash "$USERNAME"
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
reflector --country Indonesia --latest 5 --sort rate --save /etc/pacman.d/mirrorlist || true
EOF

# ====== BERESKAN ======
echo "[+] Unmount & matikan"
umount -R /mnt
swapoff "$SWAP_PART"
trap - EXIT

# Ganti ke 'reboot' jika ingin restart
shutdown now
