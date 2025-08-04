#!/bin/bash
set -e

# Cek apakah dijalankan sebagai root
if [ "$EUID" -eq 0 ]; then
  echo "[!] Jangan jalankan script ini sebagai root langsung. Gunakan user sudoer."
  exit 1
fi

# Cek koneksi internet
echo "[+] Mengecek koneksi internet..."
ping -q -c 1 archlinux.org > /dev/null || { echo "[!] Tidak ada koneksi internet. Keluar."; exit 1; }

FAILED_PACKAGES=()

install_safe() {
  for pkg in "$@"; do
    echo "[+] Memasang paket: $pkg"
    if ! sudo pacman -S --noconfirm "$pkg"; then
      echo "[!] Gagal memasang $pkg, dilewati."
      FAILED_PACKAGES+=("$pkg")
    fi
  done
}

install_safe_needed() {
  for pkg in "$@"; do
    echo "[+] Memasang paket (cek sudah ada dulu): $pkg"
    if ! sudo pacman -S --noconfirm --needed "$pkg"; then
      echo "[!] Gagal memasang $pkg, dilewati."
      FAILED_PACKAGES+=("$pkg")
    fi
  done
}

echo "[+] Update sistem"
sudo pacman -Syu --noconfirm

echo "[+] Install Sway dan komponen pendukungnya"
install_safe \
  sway \
  

echo "[+] Install base-devel dan git (dibutuhkan untuk build AUR)"
install_safe_needed base-devel git

echo "[+] Install yay (AUR helper)"
cd /tmp
rm -rf yay
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd /
rm -rf /tmp/yay

# Install neofetch dari AUR
yay -S --noconfirm neofetch

echo "[+] Install dan aktifkan FirewallD"
install_safe firewalld

echo "[+] Enable dan start firewalld.service"
sudo systemctl enable firewalld.service
sudo systemctl start firewalld.service

if [ ${#FAILED_PACKAGES[@]} -ne 0 ]; then
  echo "[!] Paket berikut gagal dipasang:"
  printf ' - %s\n' "${FAILED_PACKAGES[@]}"
fi

echo "[✓] Instalasi selesai."
read -rp "[?] Reboot sekarang? (y/N): " jawab
if [[ "$jawab" =~ ^[Yy]$ ]]; then
  echo "[↻] Rebooting..."
  sleep 3
  reboot
else
  echo "[✓] Silakan reboot manual jika perlu."
fi
