#!/usr/bin/env bash
set -Eeuo pipefail

# ====== KONFIGURASI YANG WAJIB DICEK ======
EFI_PART="/dev/nvme0n1p1"     # ESP (FAT32)
SWAP_PART="/dev/nvme0n1p2"    # Swap Partisi
ROOT_PART="/dev/nvme0n1p3"    # Root (BTRFS)
HOSTNAME="fajardp-archlinux-pc"
USERNAME="fajar"
ROOT_PASS="r!N4@O50689#25"
USER_PASS="050689"

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

echo "[+] Format Partisi SWAP di $SWAP_PART"
mkswap -L Swap "$SWAP_PART"

echo "[+] Format BTRFS di $ROOT_PART"
mkfs.btrfs -L ArchLinux "$ROOT_PART"

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
mkdir -p /mnt/{home,boot/efi,var/log,var/cache,var/tmp}
mount -o ${MNT_OPTS},subvol=@home "$ROOT_PART" /mnt/home
mount -o ${MNT_OPTS},subvol=@log "$ROOT_PART" /mnt/var/log
mount -o ${MNT_OPTS},subvol=@cache "$ROOT_PART" /mnt/var/cache
mount -o ${MNT_OPTS},subvol=@tmp "$ROOT_PART" /mnt/var/tmp

# ESP di-mount ke /boot
mount "$EFI_PART" /mnt/boot/efi

# AKtikan Partisi Swap
swapon "$SWAP_PART"

# ====== MIRRORLIST (host/live environment) ======
echo "[+] Atur mirror archlinux (host)"
pacman -Sy --noconfirm reflector
reflector --country Singapore --country China --age 6 --latest 5 --sort rate --save /etc/pacman.d/mirrorlist

# ====== INSTALL BASE ======
echo "[+] pacstrap base system"
pacstrap -K /mnt \
  base linux linux-firmware intel-ucode \
  grub efibootmgr btrfs-progs networkmanager \
  sudo neovim reflector firewalld
  
# Fstab gunakan UUID
genfstab -U /mnt > /mnt/etc/fstab

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

# ====== User & sudo ======
useradd -m -U -G wheel,audio,video,storage,optical,power,lp,scanner,ftp,http,sys,rfkill,tty,disk,input,network -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/00-wheel
chmod 0440 /etc/sudoers.d/00-wheel

# ====== Grub Bootloader ======
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchLinux
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager.service
systemctl enable firewalld.service
systemctl enable systemd-timesyncd.service

# (Opsional) mirrorlist di sistem terpasang
pacman -Sy --noconfirm reflector
reflector --country Singapore --country China --age 6 --latest 5 --sort rate --save /etc/pacman.d/mirrorlist || true
EOF

# ====== BERESKAN ======
echo "[+] Unmount & matikan"
umount -R /mnt
swapoff "$SWAP_PART"
trap - EXIT

# Ganti ke 'reboot' jika ingin restart
systemctl poweroff
