#!/bin/bash
set -e

echo "[+] Update sistem"
sudo pacman -Syu --noconfirm

echo "[+] Install plasma-desktop minimal (tanpa Xorg & SDDM)"
sudo pacman -S --noconfirm plasma-desktop

echo "[+] Install Qt5 Wayland support"
sudo pacman -S --noconfirm qt5-wayland

echo "[+] Install Konsole (terminal KDE)"
sudo pacman -S --noconfirm konsole

echo "[✓] Instalasi selesai! Sistem akan reboot dalam 5 detik..."
sleep 5
reboot
