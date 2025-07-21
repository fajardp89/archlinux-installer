#!/bin/bash
set -e

install_safe() {
  for pkg in "$@"; do
    echo "[+] Memasang paket: $pkg"
    sudo pacman -S --noconfirm "$pkg" || echo "[!] Gagal memasang $pkg, dilewati."
  done
}

echo "[+] Update sistem"
sudo pacman -Syu --noconfirm

echo "[+] Install XDG/Wayland Core Dependencies"
install_safe \
  xorg-xwayland \
  xdg-desktop-portal \
  xdg-desktop-portal-kde \
  qt5-wayland qt6-wayland \
  plasma-wayland-session \
  wayland-utils \
  wayland-protocols \
  dbus

echo "[+] Install KDE Plasma Minimal"
install_safe \
  plasma-desktop \
  plasma-workspace \
  plasma-nm \
  kde-cli-tools \
  dolphin \
  konsole \
  systemsettings \
  kscreen \
  sddm \
  sddm-kcm

echo "[+] Install Audio, Network, and Power Support"
install_safe \
  pipewire \
  wireplumber \
  pipewire-audio \
  pipewire-alsa \
  pipewire-pulse \
  networkmanager \
  powerdevil \
  upower \
  plasma-pa \
  sof-firmware

echo "[+] Install GPG & KWallet Support"
install_safe \
  gnupg \
  pinentry-qt \
  kwalletmanager \
  kwallet-pam \
  gpgme

echo "[✓] Instalasi selesai! Sistem akan reboot dalam 5 detik..."
sleep 5
reboot
