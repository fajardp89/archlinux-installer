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

systemctl enable sddm.service

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

echo "[+] Install Apps & Utility Tools"
install_safe \
  gparted \
  dosfstools \
  kate \
  firefox \
  libreoffice-fresh \
  timeshift \
  geoclue \
  geoip \
  iw \
  modemmanager \
  avahi

sudo systemctl enable --now avahi-daemon.service
sudo systemctl enable --now ModemManager.service

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
sudo systemctl start firewalld.service

echo "[✓] Instalasi selesai! Sistem akan reboot dalam 5 detik..."
sleep 5
reboot
