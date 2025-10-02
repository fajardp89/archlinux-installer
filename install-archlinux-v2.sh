#!/usr/bin/env bash
set -Eeuo pipefail

###############################################
# Arch Linux Auto Install (f2fs + systemd-boot)
###############################################

# ====== KONFIGURASI YANG WAJIB DICEK ======
EFI_PART="/dev/nvme0n1p1"     # ESP (FAT32)
SWAP_PART="/dev/nvme0n1p2"    # Swap Partisi
ROOT_PART="/dev/nvme0n1p3"    # Root (f2fs)
HOME_PART="/dev/nvme0n1p4"    # Home (f2fs)
HOSTNAME="fajardp-archlinux-pc"
USERNAME="fajar"
ROOT_PASS="r!N4@O50689#25"
USER_PASS="050689"

# ====== BUAT PARTISI ======
mkfs.fat -F32 -n ESP "$EFI_PART"
mkswap -L Swap "$SWAP_PART"
mkfs.f2fs -l ArchLinux -O extra_attr,inode_checksum,sb_checksum,compression "$ROOT_PART"
mkfs.f2fs -l Home -O extra_attr,inode_checksum,sb_checksum,compression "$HOME_PART"

# ====== MOUNT PARTISI ======
mount -o compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime /dev/nvme0n1p3 /mnt
mkdir -p /mnt/{home,boot}
mount -o compress_algorithm=zstd:6,compress_chksum,atgc,gc_merge,lazytime /dev/nvme0n1p4 /mnt/home

# ESP di-mount ke /boot
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
  base base-devel linux linux-firmware intel-ucode f2fs-tools networkmanager \
  sudo neovim git reflector apparmor firewalld plasma-desktop konsole sddm plasma-nm plasma-pa \
  fastfetch gnupg kwalletmanager pipewire pipewire-pulse pipewire-alsa wireplumber pipewire-jack \
  alsa-utils rtkit sof-firmware

# Fstab gunakan UUID
genfstab -U /mnt >> /mnt/etc/fstab

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

echo "apparmor" > /etc/modules-load.d/apparmor.conf

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
options root=UUID=$ROOT_UUID rw rootflags=atgc lsm=landlock,lockdown,yama,integrity,apparmor,bpf
EOL

cat >/boot/loader/entries/arch-fallback.conf <<EOL
title   Arch Linux (fallback)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux-fallback.img
options root=UUID=$ROOT_UUID rw rootflags=atgc lsm=landlock,lockdown,yama,integrity,apparmor,bpf
EOL

systemctl enable NetworkManager.service
systemctl enable systemd-timesyncd.service
systemctl enable firewalld.service
systemctl enable apparmor.service
systemctl enable sddm.service

# Pastikan initramfs up-to-date
mkinitcpio -P
EOF

# ====== BERESKAN ======
echo "[+] Unmount & matikan"
umount -R /mnt
swapoff "$SWAP_PART"
trap - EXIT

# Ganti ke 'systemctl reboot' jika ingin restart
systemctl poweroff
