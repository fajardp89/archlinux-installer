#!/usr/bin/env bash
set -Eeuo pipefail

###############################################
# Arch Linux Auto Install (XFS + systemd-boot)
###############################################

# ====== KONFIGURASI YANG WAJIB DICEK ======
EFI_PART="/dev/nvme0n1p1"     # ESP (FAT32)
SWAP_PART="/dev/nvme0n1p2"    # Swap Partisi
ROOT_PART="/dev/nvme0n1p3"    # Root (XFS)
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

echo "[+] Format XFS di $ROOT_PART"
mkfs.xfs -L ArchLinux "$ROOT_PART"

# ====== MOUNT PARTISI ======
mount "$ROOT_PART" /mnt

# ESP di-mount ke /boot
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# Aktikan Partisi Swap
swapon "$SWAP_PART"

# ====== MIRRORLIST (host/live environment) ======
echo "[+] Atur mirror archlinux (host)"
pacman -Sy --noconfirm reflector
reflector --country Indonesia --age 24 --sort rate --save /etc/pacman.d/mirrorlist

# ====== INSTALL BASE ======
echo "[+] pacstrap base system"
pacstrap -K /mnt \
  base base-devel linux linux-firmware intel-ucode xfsprogs networkmanager \
  sudo neovim reflector firewalld git sway foot swaybg swayidle swaylock brightnessctl \
  pipewire pipewire-pulse pipewire-alsa wireplumber pipewire-jack alsa-utils rtkit sof-firmware

# Fstab gunakan UUID
genfstab -U /mnt > /mnt/etc/fstab

# Ambil UUID root untuk entri boot
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

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
echo "KEYMAP=us" > /etc/vconsole.conf
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOKB
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "us"
    Option "XkbModel" "pc105"
EndSection
EOKB

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

# ====== Bootloader: systemd-boot ======
bootctl install
cat >/boot/loader/loader.conf <<EOL
default arch
timeout 3
editor 0
console-mode 1
EOL

cat >/boot/loader/entries/arch.conf <<EOL
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw
EOL

cat >/boot/loader/entries/arch-fallback.conf <<EOL
title   Arch Linux (fallback)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux-fallback.img
options root=UUID=$ROOT_UUID rw
EOL

systemctl enable NetworkManager.service
systemctl enable firewalld.service
systemctl enable systemd-timesyncd.service

# Pastikan initramfs up-to-date
mkinitcpio -P

# (Opsional) mirrorlist di sistem terpasang
pacman -Sy --noconfirm reflector
reflector --country Indonesia --age 24 --sort rate --save /etc/pacman.d/mirrorlist || true
EOF

# ====== BERESKAN ======
echo "[+] Unmount & matikan"
umount -R /mnt
swapoff "$SWAP_PART"
trap - EXIT

# Ganti ke 'systemctl reboot' jika ingin restart
systemctl poweroff
