#!/bin/bash
set -e

install_safe() {
  for pkg in "$@"; do
    echo "[+] Memasang paket: $pkg"
    sudo pacman -S --noconfirm "$pkg" || echo "[!] Gagal memasang $pkg, dilewati."
  done
}

install_safe_needed() {
  for pkg in "$@"; do
    echo "[+] Memasang paket (cek sudah ada dulu): $pkg"
    sudo pacman -S --noconfirm --needed "$pkg" || echo "[!] Gagal memasang $pkg, dilewati."
  done
}

echo "[+] Update sistem"
sudo pacman -Syu --noconfirm

echo "[+] Install Sway dan komponen pendukungnya"
install_safe \
  sway \
  foot \
  waybar \
  wofi \
  mako \
  grim \
  slurp \
  swaybg \
  xorg-xwayland \
  xdg-desktop-portal \
  xdg-desktop-portal-wlr \
  thunar \
  thunar-archive-plugin \
  file-roller \
  gvfs \
  tumbler \
  mpv \
  imv \
  firefox \
  pipewire \
  wireplumber \
  pipewire-audio \
  pavucontrol \
  ttf-dejavu \
  ttf-liberation \
  noto-fonts \
  noto-fonts-emoji \
  network-manager-applet \
  upower \
  brightnessctl

# Optional: autologin setup bisa ditambahkan di luar script ini jika perlu

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

echo "[+] Install dan aktifkan FirewallD"
install_safe firewalld

echo "[+] Enable dan start firewalld.service"
sudo systemctl enable firewalld.service

echo "[✓] Instalasi selesai! Sistem akan reboot dalam 5 detik..."
sleep 5
reboot
