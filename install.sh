#!/bin/bash
set -e

# --- Konfigurasi ---
DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"
HOSTNAME="fajardp-archlinux"
USERNAME="fajar"
ROOT_PASS="r!N4@O50689"
USER_PASS="050689"

echo "[+] Format BTRFS on $ROOT_PART"
mkfs.btrfs -f -L archlinux $ROOT_PART

echo "[+] Mount root untuk buat subvolume"
mount $ROOT_PART /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@var_tmp
btrfs subvolume create /mnt/@swap
umount /mnt

echo "[+] Mounting subvolumes"
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@ $ROOT_PART /mnt
mkdir -p /mnt/{home,var,tmp,opt,srv,swap}
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@home $ROOT_PART /mnt/home
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@var $ROOT_PART /mnt/var
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@tmp $ROOT_PART /mnt/tmp
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@opt $ROOT_PART /mnt/opt
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@srv $ROOT_PART /mnt/srv
mount -o noatime,nodatacow,compress=no,subvol=@swap $ROOT_PART /mnt/swap
mkdir -p /mnt/var/{log,cache,tmp}
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@log $ROOT_PART /mnt/var/log
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@cache $ROOT_PART /mnt/var/cache
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@var_tmp $ROOT_PART /mnt/var/tmp
mkdir -p /mnt/var/cache/pacman/pkg
mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@pkg $ROOT_PART /mnt/var/cache/pacman/pkg

echo "[+] Mount EFI partition"
mkdir -p /mnt/boot/efi
mount $EFI_PART /mnt/boot/efi

echo "[+] Enable swap"
swapon $SWAP_PART

echo "[+] Update mirrorlist"
pacman -Sy reflector --noconfirm
reflector --country Indonesia --latest 5 --sort rate --save /etc/pacman.d/mirrorlist

echo "[+] Install base system"
pacstrap -K /mnt base base-devel linux linux-firmware intel-ucode nano sudo networkmanager grub efibootmgr btrfs-progs git bash tzdata lz4 zstd

echo "[+] Generate fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "[+] Chroot into system for config"
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

echo "[+] Install GRUB"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

echo "[+] Create user: $USERNAME"
useradd -m -G wheel,audio,video,network,storage,optical,power,lp,scanner -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

echo "[+] Enable NetworkManager"
systemctl enable NetworkManager
EOF

echo "[✓] Instalasi selesai! Sistem akan dimatikan dalam 5 detik..."
umount -R /mnt
swapoff $SWAP_PART
sleep 5
shutdown now
