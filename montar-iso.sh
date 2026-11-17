#!/bin/bash
# Monta a ISO do Play Musica.  Uso:  bash montar-iso.sh amd64   (PCs de 64 bits)
#                                    bash montar-iso.sh i386    (PCs antigos de 32 bits)
set -e
ARCH="${1:-amd64}"
case "$ARCH" in
  amd64) FLAV="amd64"; BOOT="" ;;
  i386)  FLAV="686";   BOOT="--bootloaders syslinux" ;;
  *) echo "Arquitetura invalida: $ARCH (use amd64 ou i386)"; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$ROOT/build"; mkdir -p "$ROOT/build"; cd "$ROOT/build"
mkdir -p auto config/package-lists config/hooks/normal
mkdir -p config/includes.chroot/etc/skel
mkdir -p config/includes.chroot/etc/systemd/system/getty@tty1.service.d
mkdir -p config/includes.chroot/opt/jukebox/musicas config/includes.chroot/opt/jukebox/imagem config/includes.chroot/opt/jukebox/som

# ---------------------------------------------------------------- auto/config
cat > auto/config <<'__FIM__'
#!/bin/sh
set -e
lb config noauto \
  --distribution bookworm \
  --architectures __ARCH__ \
  --binary-images iso-hybrid \
  --linux-flavours __FLAV__ \
  __BOOT__ \
  --archive-areas "main contrib non-free non-free-firmware" \
  --apt-recommends false \
  --debian-installer none \
  --iso-volume "PLAYMUSICA" \
  --iso-application "Play Musica" \
  --iso-publisher "Play Musica" \
  --memtest none \
  --bootappend-live "boot=live components quiet loglevel=0 noeject nomodeset vga=normal nosplash locales=pt_BR.UTF-8 keyboard-layouts=br timezone=America/Maceio" \
  "${@}"
__FIM__
sed -i "s|__ARCH__|$ARCH|; s|__FLAV__|$FLAV|; s|__BOOT__|$BOOT|" auto/config

# ------------------------------------------------------------ lista de pacotes
cat > config/package-lists/jukebox.list.chroot <<'__FIM__'
xserver-xorg
xserver-xorg-video-all
xserver-xorg-input-all
xserver-xorg-legacy
xserver-xorg-video-vesa
xserver-xorg-video-fbdev
libpam-systemd
dbus
dbus-user-session
xinit
x11-xserver-utils
openbox
unclutter-xfixes
chromium
libgl1-mesa-dri
python3
curl
dbus-x11
pulseaudio
pulseaudio-utils
alsa-utils
alsa-ucm-conf
ntfs-3g
exfatprogs
dosfstools
fonts-dejavu
fonts-noto-color-emoji
locales
kbd
console-setup
keyboard-configuration
firmware-linux-free
firmware-misc-nonfree
firmware-realtek
firmware-amd-graphics
__FIM__
if [ "$ARCH" = "amd64" ]; then
  echo "firmware-sof-signed" >> config/package-lists/jukebox.list.chroot
fi

# ------------------------------------------------------------------- servico
cat > config/includes.chroot/etc/systemd/system/jukebox-server.service <<'__FIM__'
[Unit]
Description=Play Musica - servidor local
After=local-fs.target systemd-udevd.service

[Service]
Environment=PYTHONUTF8=1 LANG=C.UTF-8
ExecStart=/usr/bin/python3 /opt/jukebox/server.py
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
__FIM__

cat > config/includes.chroot/etc/systemd/system/getty@tty1.service.d/zz-jukebox.conf <<'__FIM__'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin user --noclear %I $TERM
Type=idle
__FIM__

# Permite o X rodar sem root em qualquer placa de video
mkdir -p config/includes.chroot/etc/X11
cat > config/includes.chroot/etc/X11/Xwrapper.config <<'__FIM__'
allowed_users=anybody
needs_root_rights=yes
__FIM__


# Video: NAO força mais o VESA (ele gera chuvisco/listras em boot UEFI e em varias placas).
# Em vez disso o boot tenta em ordem: automatico -> fbdev -> vesa (ver .bash_profile).
cat > config/includes.chroot/etc/X11/xorg-fbdev.conf <<'__FIM__'
Section "Device"
    Identifier "Video"
    Driver "fbdev"
EndSection
__FIM__
cat > config/includes.chroot/etc/X11/xorg-vesa.conf <<'__FIM__'
Section "Device"
    Identifier "Video"
    Driver "vesa"
EndSection
__FIM__

# Som: evita estalos/mudez por economia de energia da placa HDA Intel
mkdir -p config/includes.chroot/etc/modprobe.d
cat > config/includes.chroot/etc/modprobe.d/jukebox-audio.conf <<'__FIM__'
options snd_hda_intel power_save=0 power_save_controller=N
__FIM__

cat > config/includes.chroot/etc/skel/.bash_profile <<'__FIM__'
# Abre o jukebox direto na tela cheia (sem desktop) ao logar no tty1.
# Tenta o video automatico; se o X cair em menos de 20s, tenta fbdev e depois vesa.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  for modo in "" "-config xorg-fbdev.conf" "-config xorg-vesa.conf"; do
    t0=$(date +%s)
    startx -- $modo
    [ $(( $(date +%s) - t0 )) -ge 20 ] && break
  done
  sleep 2
  exit
fi
__FIM__

cat > config/includes.chroot/etc/skel/.xinitrc <<'__FIM__'
#!/bin/sh
export LANG=C.UTF-8
xset s off; xset s noblank; xset -dpms
unclutter -idle 1 -root &
openbox &

# Som: inicia o PulseAudio e deixa tudo no maximo e sem mudo
pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1
(
  sleep 5
  for c in 0 1 2 3 4 5 6 7; do
    amixer -q -c "$c" sset "Auto-Mute Mode" Disabled 2>/dev/null
    for ctl in Master Speaker Headphone PCM Front Surround Center LFE "Line Out" Line Digital "Master Mono"; do
      amixer -q -c "$c" sset "$ctl" 100% unmute 2>/dev/null
    done
  done
  S="$(pactl list short sinks 2>/dev/null | cut -f2 | grep -i analog | head -n1)"
  [ -n "$S" ] && pactl set-default-sink "$S"
  for s in $(pactl list short sinks 2>/dev/null | cut -f2); do
    pactl set-sink-mute "$s" 0
    pactl set-sink-volume "$s" 100%
  done
) &

# espera o servidor local subir
for i in $(seq 1 40); do
  curl -s -o /dev/null http://127.0.0.1:8765/api/fontes && break
  sleep 0.5
done

# abre em tela cheia e reabre sozinho se fechar/travar
while true; do
  chromium --kiosk --start-fullscreen --no-first-run --noerrdialogs --disable-infobars \
    --disable-session-crashed-bubble --disable-features=Translate --password-store=basic \
    --overscroll-history-navigation=0 --disable-pinch \
    --autoplay-policy=no-user-gesture-required \
    --disable-gpu --disable-dev-shm-usage \
    --user-data-dir=/tmp/chromium-jukebox \
    http://127.0.0.1:8765/index.html
  sleep 1
done
__FIM__

# --------------------------------------------------------------------- hooks
cat > config/hooks/normal/0100-jukebox.hook.chroot <<'__FIM__'
#!/bin/sh
set -e
systemctl enable jukebox-server.service
mkdir -p /mnt/jukebox
chmod +x /opt/jukebox/server.py
__FIM__

cat > config/hooks/normal/0200-boot-rapido.hook.binary <<'__FIM__'
#!/bin/sh
# Entra direto no sistema, sem mostrar o menu de boot
if [ -f binary/isolinux/live.cfg ] && [ -f binary/isolinux/isolinux.cfg ]; then
  L="$(grep -m1 "^label " binary/isolinux/live.cfg | awk "{print \$2}")"
  [ -n "$L" ] && sed -i -E "s/^default .*/default $L/" binary/isolinux/isolinux.cfg
  grep -q "^timeout" binary/isolinux/isolinux.cfg || echo "timeout 1" >> binary/isolinux/isolinux.cfg
  sed -i -E "s/^timeout .*/timeout 1/" binary/isolinux/isolinux.cfg
  grep -q "^prompt" binary/isolinux/isolinux.cfg || echo "prompt 0" >> binary/isolinux/isolinux.cfg
fi
for f in binary/boot/grub/*.cfg; do
  [ -f "$f" ] && sed -i -E "s/^set timeout=.*/set timeout=0/" "$f"
done
exit 0
__FIM__

chmod +x auto/config config/hooks/normal/* config/includes.chroot/etc/skel/.xinitrc
cp "$ROOT/index.html" "$ROOT/server.py" config/includes.chroot/opt/jukebox/

if [ -n "$SO_GERAR" ]; then echo "Arvore gerada ($ARCH)."; exit 0; fi

lb config
lb build
ls -lh ./*.iso
mv ./*.iso "$ROOT/PlayMusica-$ARCH.iso"
