#!/bin/bash
set -euo pipefail

# --- Konfigurasi ---
DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
SWAP_PART="${DISK}p2"
ROOT_PART="${DISK}p3"
HOSTNAME="fajardp-archlinux-pc"
USERNAME="fajar"
SWAPFILE_SIZE="4G"

# --- Fungsi utilitas ---
confirm() {
  local msg="$1"
  local expected="${2:-yes}"
  echo "${msg}"
  read -rp "Ketik '${expected}' untuk konfirmasi: " reply
  if [ "$reply" != "$expected" ]; then
    echo "[!] Konfirmasi gagal. Batal."
    exit 1
  fi
}

cleanup_mounts() {
  set +e
  umount -R /mnt || true
  swapoff "$SWAP_PART" || true
  set -e
}
trap cleanup_mounts EXIT

# --- Pengecekan awal ---
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "[!] Sistem tidak berjalan dalam mode UEFI. Instalasi dibatalkan."
    exit 1
fi

for part in "$EFI_PART" "$ROOT_PART" "$SWAP_PART"; do
    if [ ! -b "$part" ]; then
        echo "[!] Partisi $part tidak ditemukan. Instalasi dibatalkan."
        exit 1
    fi
done

confirm "PERINGATAN: Script akan memformat $ROOT_PART (semua data akan hilang).\nUntuk melanjutkan, ketik nama disk target: $DISK" "$DISK"

timedatectl set-ntp true

echo -n "Masukkan password root: "
read -s ROOT_PASS
echo
echo -n "Masukkan password user $USERNAME: "
read -s USER_PASS
echo

printf "%s\n" "root:${ROOT_PASS}" > /mnt_rootpw.tmp
printf "%s\n" "${USERNAME}:${USER_PASS}" > /mnt_userpw.tmp
chmod 600 /mnt_rootpw.tmp /mnt_userpw.tmp

echo "[+] Format BTRFS on $ROOT_PART"
mkfs.btrfs -f -L archlinux "$ROOT_PART"

echo "[+] Membuat dan mengaktifkan swap pada $SWAP_PART"
mkswap "$SWAP_PART"
swapon "$SWAP_PART"

mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@swap
umount /mnt

mount -o noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvol=@ "$ROOT_PART" /mnt
mkdir -p /mnt/home /mnt/tmp /mnt/srv /mnt/swap /mnt/var/log /mnt/var/cache /mnt/boot/efi
mount -o noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvol=@home  "$ROOT_PART" /mnt/home
mount -o noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvol=@tmp   "$ROOT_PART" /mnt/tmp
mount -o noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvol=@srv   "$ROOT_PART" /mnt/srv
mount -o noatime,nodatacow,compress=no,subvol=@swap "$ROOT_PART" /mnt/swap
mount -o noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvol=@log   "$ROOT_PART" /mnt/var/log
mount -o noatime,compress=zstd:1,ssd,discard=async,space_cache=v2,subvol=@cache "$ROOT_PART" /mnt/var/cache

# Pastikan nodatacow aktif di level file
chattr +C /mnt/swap

# Buat swapfile 4GB di subvolume @swap
echo "[+] Membuat swapfile ${SWAPFILE_SIZE} di /mnt/swap"
truncate -s ${SWAPFILE_SIZE} /mnt/swap/swapfile
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile
swapon /mnt/swap/swapfile

mount "$EFI_PART" /mnt/boot/efi

pacstrap -K --needed /mnt base base-devel linux-zen linux-lts linux linux-firmware intel-ucode vim sudo btrfs-progs git bash tzdata lz4 zstd iwd reflector firewalld apparmor

genfstab -U /mnt > /mnt/etc/fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")
if ! grep -q "$SWAP_UUID" /mnt/etc/fstab 2>/dev/null; then
  echo "UUID=${SWAP_UUID} none swap sw,pri=10 0 0" >> /mnt/etc/fstab
fi
if ! grep -q "/swap/swapfile" /mnt/etc/fstab 2>/dev/null; then
  echo "/swap/swapfile none swap sw,pri=100 0 0" >> /mnt/etc/fstab
fi

mkdir -p /mnt/boot/loader/entries
cat > /mnt/boot/loader/loader.conf <<-LOADER
default  arch-zen.conf
timeout  3
console-mode max
editor   no
LOADER

cat > /mnt/boot/loader/entries/arch-zen.conf <<-ZENCONF
title   Arch Linux (Zen)
linux   /vmlinuz-linux-zen
initrd  /intel-ucode.img
initrd  /initramfs-linux-zen.img
initrd  /initramfs-linux-zen-fallback.img
options root=UUID=${ROOT_UUID} rw rootflags=subvol=@ quiet splash loglevel=3 lsm=landlock,lockdown,yama,integrity,apparmor,bpf
ZENCONF

cat > /mnt/boot/loader/entries/arch.conf <<-ARCHCONF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
initrd  /initramfs-linux-fallback.img
options root=UUID=${ROOT_UUID} rw rootflags=subvol=@ quiet splash loglevel=3 lsm=landlock,lockdown,yama,integrity,apparmor,bpf
ARCHCONF

cat > /mnt/boot/loader/entries/arch-lts.conf <<-LTSCONF
title   Arch Linux (LTS)
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts.img
initrd  /initramfs-linux-lts-fallback.img
options root=UUID=${ROOT_UUID} rw rootflags=subvol=@ quiet splash loglevel=3 lsm=landlock,lockdown,yama,integrity,apparmor,bpf
LTSCONF

cat > /mnt/boot/loader/entries/arch-recovery.conf <<-RECOV
title   Arch Linux (recovery)
linux   /vmlinuz-linux
initrd  /initramfs-linux-fallback.img
options root=UUID=${ROOT_UUID} rw rootflags=subvol=@ single lsm=landlock,lockdown,yama,integrity,apparmor,bpf
RECOV

arch-chroot /mnt /bin/bash <<'CHROOT'
set -euo pipefail

ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "${HOSTNAME}" > /etc/hostname
cat <<EOL > /etc/hosts
127.0.0.1       localhost
::1             localhost
127.0.1.1       ${HOSTNAME}.localdomain ${HOSTNAME}
EOL

if [ -f /mnt_rootpw.tmp ]; then
  cat /mnt_rootpw.tmp | chpasswd
  rm -f /mnt_rootpw.tmp
fi

useradd -m -G wheel,audio,video,network,storage,optical,power,lp,scanner -s /bin/bash ${USERNAME}
if [ -f /mnt_userpw.tmp ]; then
  cat /mnt_userpw.tmp | chpasswd
  rm -f /mnt_userpw.tmp
fi

echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

reflector --country Indonesia --latest 10 --sort rate --save /etc/pacman.d/mirrorlist || echo "[!] reflector gagal"

bootctl install || true
bootctl update || true

systemctl enable iwd || true
systemctl enable firewalld || true
systemctl enable apparmor || true
if pacman -Qi networkmanager >/dev/null 2>&1; then
  systemctl disable --now NetworkManager || true
  pacman --noconfirm -Rns networkmanager || true
fi
CHROOT

if [ ! -f /mnt/boot/vmlinuz-linux-zen ] || [ ! -f /mnt/boot/initramfs-linux-zen.img ]; then
    echo "[!] Kernel Zen atau initramfs tidak ditemukan! Instalasi dibatalkan."
    exit 1
fi

rm -f /mnt_rootpw.tmp /mnt_userpw.tmp || true

trap - EXIT
cleanup_mounts

echo "[✓] Instalasi selesai! Sistem akan dimatikan sekarang."
shutdown now
