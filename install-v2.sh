#!/bin/bash
set -e

# --- Konfigurasi ---
DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"
HOSTNAME="fajardp-archlinux-pc"
USERNAME="fajar"
ROOT_PASS="passwd"
USER_PASS="passwd"

echo "[+] Format BTRFS on $ROOT_PART"
mkfs.btrfs -f -L archlinux $ROOT_PART

echo "[+] Buat subvolume BTRFS"
mount $ROOT_PART /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@swap
umount /mnt

echo "[+] Mount subvolumes"
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@ $ROOT_PART /mnt
mkdir -p /mnt/{home,tmp,srv,swap,var/log,var/cache}
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@home  $ROOT_PART /mnt/home
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@tmp   $ROOT_PART /mnt/tmp
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@srv   $ROOT_PART /mnt/srv
mount -o noatime,nodatacow,compress=no,subvol=@swap $ROOT_PART /mnt/swap
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@log   $ROOT_PART /mnt/var/log
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@cache $ROOT_PART /mnt/var/cache

echo "[+] Mount EFI System Partition ke /boot"
mkdir -p /mnt/boot
mount $EFI_PART /mnt/boot

echo "[+] Enable swap"
swapon $SWAP_PART

echo "[+] Update mirrorlist"
pacman -Sy reflector --noconfirm
reflector --country Indonesia --latest 5 --sort rate --save /etc/pacman.d/mirrorlist

echo "[+] Install base system + kernel Zen + iwd + dhcpcd + firewalld"
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware intel-ucode \
    vim sudo btrfs-progs git bash tzdata lz4 zstd iwd dhcpcd firewalld

echo "[+] Generate fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "[+] Chroot untuk konfigurasi"
arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
cat <<EOL > /etc/hosts
127.0.0.1       localhost
::1             localhost
127.0.1.1       $HOSTNAME.localdomain $HOSTNAME
EOL

echo "[+] Set root password"
echo "root:$ROOT_PASS" | chpasswd

echo "[+] Install systemd-boot"
bootctl install

cat <<EOL > /boot/loader/loader.conf
default arch.conf
timeout 5
console-mode max
editor no
auto-firmware yes
EOL

# Entry utama kernel Zen
cat <<EOL > /boot/loader/entries/arch.conf
title   Arch Linux (Zen Kernel)
linux   /vmlinuz-linux-zen
initrd  /intel-ucode.img
initrd  /initramfs-linux-zen.img
options root=UUID=$(blkid -s UUID -o value $ROOT_PART) rw rootflags=subvol=@
EOL

# Entry fallback kernel Zen
cat <<EOL > /boot/loader/entries/arch-fallback.conf
title   Arch Linux (Zen Kernel - Fallback Initramfs)
linux   /vmlinuz-linux-zen
initrd  /intel-ucode.img
initrd  /initramfs-linux-zen-fallback.img
options root=UUID=$(blkid -s UUID -o value $ROOT_PART) rw rootflags=subvol=@
EOL

echo "[+] Buat user: $USERNAME"
useradd -m -G wheel,audio,video,network,storage,optical,power,lp,scanner -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

echo "[+] Enable iwd, dhcpcd, dan firewalld"
systemctl enable iwd
systemctl enable dhcpcd
systemctl enable firewalld
EOF

echo "[✓] Instalasi selesai! Sistem akan dimatikan dalam 5 detik..."
umount -R /mnt
swapoff $SWAP_PART
sleep 5
shutdown now
