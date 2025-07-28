# 🐧 ArchLinux Automated Installer by Fajar

Script ini digunakan untuk mengotomatisasi proses instalasi Arch Linux dengan partisi BTRFS, bootloader GRUB UEFI, dan desktop environment KDE.

---

## 📁 Struktur Script

| File                 | Deskripsi                                                                 |
|----------------------|---------------------------------------------------------------------------|
| `install.sh`         | Script utama untuk instalasi Arch Linux, setup BTRFS, user, GRUB, dsb.    |
| `install-desktop.sh` | Script tambahan yang dijalankan setelah reboot untuk install KDE minimal. |

---

## 🧰 Fitur

- ✅ Format dan setup partisi BTRFS dengan subvolume standar (`@`, `@home`, dll)
- ✅ Mount partisi `/data` secara permanen tanpa format ulang
- ✅ Instalasi sistem dasar (`base`, `linux`, `networkmanager`, `grub`, dll)
- ✅ Setup user, hostname, locale, zona waktu otomatis
- ✅ Install KDE Minimal Desktop Environment
- ✅ SDDM Display Manager

---

## 📦 Persyaratan Sebelum Menjalankan

- Mode boot: **UEFI**
- Koneksi internet aktif
- Partisi sudah disiapkan manual (gunakan `fdisk`, `gdisk`, atau `parted`):

| Partisi         | Tipe     | Fungsi        |
|------------------|----------|---------------|
| `/dev/nvme0n1p1` | FAT32    | EFI Boot      |
| `/dev/nvme0n1p2` | swap     | SWAP          |
| `/dev/nvme0n1p3` | kosong   | Untuk root    |
| `/dev/nvme0n1p4` | ada data | Untuk `/data` |

**⚠️ Peringatan:** Partisi `p3` akan diformat otomatis menjadi BTRFS!

---

## 🚀 Cara Menggunakan

### 1. Boot ke Arch ISO (Live)
Pastikan kamu sudah terkoneksi internet (misalnya via WiFi atau ethernet).

### 2. Unduh dan Jalankan Script Utama

```bash
cd /root
git clone https://github.com/fajardp89/archlinux-installer.git
cd archlinux-installer
chmod +x install.sh
./install.sh

git clone https://github.com/fajardp89/archlinux-installer.git
cd archlinux-installer
chmod +x install-desktop.sh
./install-desktop.sh
