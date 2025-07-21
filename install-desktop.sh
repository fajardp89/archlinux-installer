#!/bin/bash
set -e

echo "[+] Update sistem"
sudo pacman -Syu --noconfirm

echo "[+] Install XDG/Wayland Core Dependencies"
sudo pacman -S --noconfirm \
  xorg-xwayland \
  xdg-desktop-portal \
  xdg-desktop-portal-kde \
  qt5-wayland qt6-wayland \
  plasma-wayland-session \
  wayland-utils \
  wayland-protocols \
  dbus

echo "[+] Install KDE Plasma Minimal"
sudo pacman -S --noconfirm \
  plasma-desktop \
  plasma-workspace \
  plasma-nm \
  kde-cli-tools \
  dolphin \
  konsole \
  systemsettings \
  kscreen \
  sddm-kcm

echo "[✓] Instalasi selesai! Sistem akan reboot dalam 5 detik..."
sleep 5
reboot
