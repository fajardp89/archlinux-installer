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
  swaylock \
  swayidle \
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
  xdg-desktop-portal-gtk \
  thunar \
  thunar-archive-plugin \
  file-roller \
  gvfs \
  gvfs-mtp \
  gvfs-gphoto2 \
  gvfs-afc \
  gvfs-smb \
  tumbler \
  mpv \
  imv \
  firefox \
  pipewire \
  wireplumber \
  pipewire-audio \
  pipewire-pulse \
  pavucontrol \
  sof-firmware \
  ttf-dejavu \
  ttf-liberation \
  noto-fonts \
  noto-fonts-emoji \
  ttf-font-awesome \
  noto-fonts-cjk \
  qt5-wayland \
  qt6-wayland \
  glib2 \
  libva \
  libvdpau \
  gnome-themes-extra \
  lxappearance \
  qt5ct \
  kvantum-qt5 \
  kvantum-theme-materia \
  papirus-icon-theme \
  network-manager-applet \
  upower \
  brightnessctl \
  polkit \
  polkit-kde-agent \
  zsh \
  zsh-completions \
  starship \
  bat \
  fzf \
  tlp \
  tlp-rdw \
  acpi \
  acpid

# Salin konfigurasi awal Sway
echo "[+] Menyalin konfigurasi default sway"
mkdir -p ~/.config/sway
cp /etc/sway/config ~/.config/sway/

# Hapus blok bar bawaan (bar { ... }) dari config sway
sed -i '/^bar {/,/^}/d' ~/.config/sway/config

# Tambahkan autostart polkit agent di sway config jika belum ada
if ! grep -q polkit-kde-authentication-agent ~/.config/sway/config; then
  echo 'exec /usr/lib/polkit-kde-authentication-agent-1' >> ~/.config/sway/config
fi

# Tambahkan konfigurasi kursor jika belum ada
if ! grep -q 'seat seat0 xcursor_theme' ~/.config/sway/config; then
  echo 'seat seat0 xcursor_theme Adwaita 24' >> ~/.config/sway/config
fi

# Tambahkan konfigurasi swayidle dan swaylock jika belum ada
if ! grep -q swayidle ~/.config/sway/config; then
  cat <<EOC >> ~/.config/sway/config

exec swayidle -w \
  timeout 300 'swaylock -f' \
  timeout 600 'swaymsg "output * dpms off"' \
  resume 'swaymsg "output * dpms on"' \
  before-sleep 'swaylock -f'
EOC
fi

# Tambahkan autostart waybar jika belum ada
if ! grep -q '^exec waybar' ~/.config/sway/config; then
  echo 'exec waybar' >> ~/.config/sway/config
fi

# Konfigurasi tema Materia Dark
mkdir -p ~/.config/gtk-3.0
cat <<EOF > ~/.config/gtk-3.0/settings.ini
[Settings]
gtk-theme-name=Materia-dark
gtk-icon-theme-name=Papirus-Dark
gtk-font-name=Sans 10
EOF

mkdir -p ~/.config/Kvantum
cat <<EOF > ~/.config/Kvantum/kvantum.kvconfig
[General]
theme=MateriaDark
EOF

if ! grep -q 'QT_QPA_PLATFORMTHEME=qt5ct' ~/.profile; then
  echo 'export QT_QPA_PLATFORMTHEME=qt5ct' >> ~/.profile
fi

if ! grep -q 'QT_STYLE_OVERRIDE=kvantum' ~/.profile; then
  echo 'export QT_STYLE_OVERRIDE=kvantum' >> ~/.profile
fi

# Tambahkan autostart Sway saat login di TTY1
echo "[+] Menambahkan autostart sway di tty1"
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOF | sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $USER --noclear %I \$TERM
EOF

echo '[ -z $DISPLAY ] && [ "$(tty)" = "/dev/tty1" ] && exec sway' >> ~/.bash_profile

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

# Aktifkan power management
sudo systemctl enable tlp.service
sudo systemctl enable acpid.service

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
