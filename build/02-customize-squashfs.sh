#!/bin/bash
# Personnalise la Live ISO KDE officielle AlmaLinux : ajoute les paquets
# d'intégration Active Directory + notre RPM assistant DIRECTEMENT dans le
# rootfs live (squashfs), puis réempaquette l'ISO.
#
# Différence structurelle avec l'ancienne approche "respin DVD + kickstart"
# (abandonnée - voir docs/ARCHITECTURE.md) : l'installeur Anaconda lancé
# depuis une session live AlmaLinux ("Install to Hard Drive") COPIE le
# rootfs live sur le disque cible (paiement de type "image", comme le
# `unpackfs` d'archiso) - il ne réinstalle PAS de paquets depuis un dépôt à
# l'installation. Tout ce qu'on veut voir sur le système installé
# (paquets AD, notre assistant, authselect, oddjobd...) doit donc être
# préparé ICI, dans le rootfs live lui-même, PAS dans un kickstart %post
# qui ne serait jamais exécuté par ce mode d'installation. D'où la
# suppression de kickstart/ks.cfg.
#
# Nécessite un conteneur privilégié (`--privileged`, voir
# build/docker/run-in-container.sh) : le rootfs live d'AlmaLinux est
# généralement un squashfs contenant une image ext4 (`mount -o loop`),
# pas directement l'arborescence - ce script détecte dynamiquement lequel
# des deux cas s'applique plutôt que de le supposer.
#
# WORK_DIR est DÉLIBÉRÉMENT en dehors du volume monté ($REPO_ROOT, passé en
# bind mount virtiofs depuis macOS via colima) : `unsquashfs` doit pouvoir
# recréer des uid/gid/permissions arbitraires (dont root:root sur des
# milliers de fichiers système) - confirmé en échec réel
# ("failed to change uid and gids ... Operation not permitted") sur un
# répertoire situé dans ce volume monté, virtiofs ne supportant pas cette
# sémantique POSIX complète en passthrough depuis macOS. Un répertoire
# purement local à la couche writable du conteneur (vrai filesystem Linux)
# n'a pas cette limite - seuls la lecture de l'ISO source/du dépôt local et
# l'écriture de l'ISO finale traversent le volume monté (simples
# lectures/écritures de fichiers réguliers, sans ce problème).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/distro.conf"

SRC_ISO="$REPO_ROOT/build/iso-cache/almalinux-live-kde.iso"
OUT_DIR="$REPO_ROOT/build/out"
OUT_ISO="$OUT_DIR/${DISTRO_ID}-${DISTRO_VERSION}-x86_64.iso"
WORK_DIR="/var/tmp/almalinux-ad-customize-work"
LOCAL_REPO_DIR="$REPO_ROOT/build/local-repo/AlmaLinuxAD-local"
ROOTFS_MOUNT="$WORK_DIR/rootfs-mount"

[ -f "$SRC_ISO" ] || { echo "!! $SRC_ISO introuvable - lancez d'abord build/00-fetch-iso.sh" >&2; exit 1; }
[ -d "$LOCAL_REPO_DIR" ] || { echo "!! $LOCAL_REPO_DIR introuvable - lancez d'abord build/01-build-rpm.sh" >&2; exit 1; }
[ "$(id -u)" = "0" ] || { echo "!! Ce script a besoin de root (mount -o loop) - lancez-le via build/docker/run-in-container.sh (--privileged)." >&2; exit 1; }

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR" "$ROOTFS_MOUNT"

find_in_iso() {
    xorriso -indev "$SRC_ISO" -find / -name "$1" 2>/dev/null | awk '{print $1}' | tr -d "'" | head -1
}

SQUASHFS_PATH=$(find_in_iso squashfs.img)
[ -n "$SQUASHFS_PATH" ] || { echo "!! squashfs.img introuvable sur l'ISO - layout inattendu (xorriso -indev $SRC_ISO -find / )." >&2; exit 1; }
echo "==> squashfs live trouvé : $SQUASHFS_PATH"

xorriso -indev "$SRC_ISO" -osirrox on -extract "$SQUASHFS_PATH" "$WORK_DIR/squashfs.img"

# Compression d'origine à reproduire au réempaquetage (le layout
# dracut-live utilise habituellement xz, mais on le lit plutôt que de le
# supposer - voir `unsquashfs -s`).
ORIG_COMP=$(unsquashfs -s "$WORK_DIR/squashfs.img" 2>/dev/null | awk -F': ' '/Compression/ {print $2; exit}')
ORIG_COMP="${ORIG_COMP:-xz}"
echo "==> Compression détectée : $ORIG_COMP"

mkdir -p "$WORK_DIR/squashfs-extracted"
unsquashfs -f -d "$WORK_DIR/squashfs-extracted" "$WORK_DIR/squashfs.img"

# Deux layouts possibles selon la version de dracut-live/lorax utilisée
# pour construire l'ISO officielle : soit le squashfs contient DIRECTEMENT
# l'arborescence du système (etc/, usr/...), soit il contient une image de
# système de fichiers unique (ext4, souvent nommée *.img) à monter en loop.
# Détecté dynamiquement plutôt que supposé - à documenter/ajuster ici si le
# layout réel diffère des deux cas prévus (voir docs/BUILD.md).
NESTED_IMAGE=""
if [ -d "$WORK_DIR/squashfs-extracted/etc" ] && [ -d "$WORK_DIR/squashfs-extracted/usr" ]; then
    echo "==> Layout : rootfs directement dans le squashfs (pas d'image imbriquée)."
    ROOTFS_DIR="$WORK_DIR/squashfs-extracted"
else
    NESTED_IMAGE=$(find "$WORK_DIR/squashfs-extracted" -maxdepth 2 -type f \( -name '*.img' -o -name 'rootfs*' \) | head -1)
    [ -n "$NESTED_IMAGE" ] || { echo "!! Layout squashfs non reconnu (ni etc/usr direct, ni image imbriquée) - inspecter $WORK_DIR/squashfs-extracted à la main." >&2; exit 1; }
    echo "==> Layout : image imbriquée détectée ($NESTED_IMAGE) - montage en loop."
    mount -o loop "$NESTED_IMAGE" "$ROOTFS_MOUNT"
    ROOTFS_DIR="$ROOTFS_MOUNT"
fi

cleanup() {
    for m in dev/pts dev proc sys; do
        mountpoint -q "$ROOTFS_DIR/$m" && umount -R "$ROOTFS_DIR/$m" 2>/dev/null || true
    done
    mountpoint -q "$ROOTFS_DIR/mnt/local-repo" && umount "$ROOTFS_DIR/mnt/local-repo" 2>/dev/null || true
    if [ -n "$NESTED_IMAGE" ]; then
        mountpoint -q "$ROOTFS_MOUNT" && umount "$ROOTFS_MOUNT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

for m in proc sys dev dev/pts; do
    mkdir -p "$ROOTFS_DIR/$m"
    mount --bind "/$m" "$ROOTFS_DIR/$m" 2>/dev/null || mount -t "$m" "$m" "$ROOTFS_DIR/$m"
done
cp -L /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

mkdir -p "$ROOTFS_DIR/mnt/local-repo"
mount --bind "$LOCAL_REPO_DIR" "$ROOTFS_DIR/mnt/local-repo"

# KDE Plasma (donc kdialog, requis par notre RPM) n'est PAS dans
# BaseOS/AppStream/CRB sur la famille RHEL10 - RHEL ne "supporte"
# officiellement que GNOME comme bureau, KDE est entièrement fourni par
# EPEL (confirmé : `dnf repoquery plasma-desktop` -> repoid `epel`). Le
# rootfs live a donc forcément déjà EPEL activé (c'est de là que vient KDE
# lui-même) - vérifié plutôt que supposé, avec un filet de sécurité si ce
# n'était pas le cas.
if ! chroot "$ROOTFS_DIR" rpm -q epel-release >/dev/null 2>&1; then
    echo "!! epel-release absent du rootfs live (inattendu, KDE en dépend) - installation de secours."
    chroot "$ROOTFS_DIR" dnf install -y epel-release
fi

cat > "$ROOTFS_DIR/etc/yum.repos.d/almalinuxad-local.repo" <<'EOF'
[AlmaLinuxAD-local]
name=AlmaLinux AD - paquet local (assistant de jonction)
baseurl=file:///mnt/local-repo
enabled=1
gpgcheck=0
EOF

echo "==> Installation des paquets AD + de l'assistant dans le rootfs live"
chroot "$ROOTFS_DIR" dnf install -y --setopt=install_weak_deps=False \
    sssd sssd-krb5 sssd-ad sssd-tools \
    adcli realmd samba-common-tools krb5-workstation bind-utils \
    oddjob oddjob-mkhomedir \
    policycoreutils \
    almalinux-ad-firstboot-wizard

echo "==> authselect / oddjobd / journald / avahi / horloge"
chroot "$ROOTFS_DIR" authselect select sssd with-mkhomedir --force
chroot "$ROOTFS_DIR" systemctl enable oddjobd.service

mkdir -p "$ROOTFS_DIR/var/log/journal" "$ROOTFS_DIR/etc/systemd/journald.conf.d"
cat > "$ROOTFS_DIR/etc/systemd/journald.conf.d/persistent-storage.conf" <<'EOF'
[Journal]
Storage=persistent
EOF

chroot "$ROOTFS_DIR" systemctl mask avahi-daemon.service avahi-daemon.socket 2>/dev/null || true

mkdir -p "$ROOTFS_DIR/etc/vmware-tools"
cat > "$ROOTFS_DIR/etc/vmware-tools/tools.conf" <<'EOF'
[timesync]
disable = TRUE
EOF

echo "==> Nettoyage post-install (cache dnf, dépôt local temporaire)"
chroot "$ROOTFS_DIR" dnf clean all
rm -f "$ROOTFS_DIR/etc/yum.repos.d/almalinuxad-local.repo"
umount "$ROOTFS_DIR/mnt/local-repo"
rmdir "$ROOTFS_DIR/mnt/local-repo" 2>/dev/null || true

for m in dev/pts dev proc sys; do
    umount -R "$ROOTFS_DIR/$m" 2>/dev/null || true
done

if [ -n "$NESTED_IMAGE" ]; then
    umount "$ROOTFS_MOUNT"
fi
trap - EXIT

echo "==> Réempaquetage du squashfs ($ORIG_COMP)"
NEW_SQUASHFS="$WORK_DIR/squashfs-new.img"
rm -f "$NEW_SQUASHFS"
mksquashfs "$WORK_DIR/squashfs-extracted" "$NEW_SQUASHFS" -comp "$ORIG_COMP" -noappend

echo "==> Respin de l'ISO -> $OUT_ISO"
rm -f "$OUT_ISO"
xorriso -indev "$SRC_ISO" \
    -outdev "$OUT_ISO" \
    -boot_image any replay \
    -map "$NEW_SQUASHFS" "$SQUASHFS_PATH" \
    -commit -eject all

if command -v implantisomd5 >/dev/null 2>&1; then
    implantisomd5 "$OUT_ISO"
    echo "==> Somme de contrôle média (checkisomd5) implantée."
fi

echo "==> Terminé : $OUT_ISO"
