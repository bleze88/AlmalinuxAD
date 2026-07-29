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

# Gabarit du dossier personnel des comptes AD : /home/%D/%U (domaine complet
# / utilisateur), même convention que le projet frère Compass Arch - sans
# ce fichier, realmd retombe sur son défaut /home/%u@%d (ex:
# "mtf0001@MONTFERRINI.LOCAL"), moins lisible. Écrit APRÈS l'installation
# de `realmd` mais AVANT toute jonction (qui n'a lieu qu'au premier login,
# via l'assistant) : realmd lit ce fichier au moment de `realm join` pour
# décider du `fallback_homedir` qu'il écrit dans sssd.conf, donc ce réglage
# doit être en place dès le build, pas seulement documenté.
#
# [active-directory] os-name/os-version : sans ça, l'objet ordinateur créé
# dans l'AD a ses attributs operatingSystem/operatingSystemVersion vides
# (onglet "Operating System" d'Utilisateurs et ordinateurs Active
# Directory) - demandé pour que ces postes Linux soient identifiables au
# même titre que les postes Windows dans la console AD. `os-version` suit
# ALMALINUX_MAJOR de distro.conf plutôt qu'être codé en dur, pour rester
# correct si ce dépôt est un jour reconstruit sur une nouvelle version
# majeure d'AlmaLinux.
cat > "$ROOTFS_DIR/etc/realmd.conf" <<EOF
[users]
default-home = /home/%D/%U
default-shell = /bin/bash

[active-directory]
os-name = AlmaLinux
os-version = ${ALMALINUX_MAJOR}
EOF

echo "==> Ajout des dépôts Google Chrome et Microsoft Edge"
rpm --root "$ROOTFS_DIR" --import https://dl.google.com/linux/linux_signing_key.pub
cat > "$ROOTFS_DIR/etc/yum.repos.d/google-chrome.repo" <<'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF
rpm --root "$ROOTFS_DIR" --import https://packages.microsoft.com/keys/microsoft.asc
cat > "$ROOTFS_DIR/etc/yum.repos.d/microsoft-edge.repo" <<'EOF'
[microsoft-edge]
name=microsoft-edge
baseurl=https://packages.microsoft.com/yumrepos/edge
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
chroot "$ROOTFS_DIR" dnf install -y google-chrome-stable microsoft-edge-stable
# Dépôts laissés activés (pas de dépôt temporaire comme AlmaLinuxAD-local) :
# le système installé pourra recevoir les mises à jour de sécurité de ces
# deux navigateurs via dnf, ce qui compte plus pour un navigateur que pour
# la plupart des logiciels.

echo "==> authselect / oddjobd / journald / avahi / horloge / sudo"
chroot "$ROOTFS_DIR" authselect select sssd with-mkhomedir --force
chroot "$ROOTFS_DIR" systemctl enable oddjobd.service

# Durcissement demandé pour un environnement professionnel : sudo ne met
# JAMAIS en cache une authentification réussie (par défaut, RHEL/AlmaLinux
# redemande le mot de passe seulement toutes les timestamp_timeout=5
# minutes) - chaque `sudo` redemande donc le mot de passe à chaque fois,
# sans exception. Fragment séparé (00-) plutôt qu'ajouté au fragment AD
# (90-ad-admins, écrit plus tard au premier login par ad-join-backend.py) :
# les deux n'ont rien à voir et ne doivent pas dépendre l'un de l'autre.
cat > "$ROOTFS_DIR/etc/sudoers.d/00-no-timestamp-cache.tmp" <<'EOF'
Defaults timestamp_timeout=0
EOF
chroot "$ROOTFS_DIR" visudo -cf /etc/sudoers.d/00-no-timestamp-cache.tmp
mv "$ROOTFS_DIR/etc/sudoers.d/00-no-timestamp-cache.tmp" "$ROOTFS_DIR/etc/sudoers.d/00-no-timestamp-cache"
chmod 0440 "$ROOTFS_DIR/etc/sudoers.d/00-no-timestamp-cache"

# Marqueur machine-wide "assistant AD déjà proposé" (voir
# ad-join-wizard-autostart.sh) : groupe wheel + setgid + 0775, pour que le
# compte admin local (membre de wheel) puisse y écrire sans pkexec.
chroot "$ROOTFS_DIR" install -d -m 2775 -o root -g wheel /var/lib/almalinux-ad

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

# Relabel SELinux complet - CRITIQUE, pas optionnel. La machine de build
# (conteneur colima) n'a pas SELinux actif au niveau noyau : le plugin
# SELinux de RPM se désactive silencieusement pendant `dnf install`
# ci-dessus (`is_selinux_enabled()` regarde le noyau EN COURS
# D'EXÉCUTION, pas la politique de la cible), et nos propres écritures
# directes (journald, vmware-tools...) n'ont jamais été labellisées non
# plus. Confirmé en conditions réelles sur VMware sans ce fix : au tout
# premier boot, `dbus-broker.service` échoue à "Listen on dbus.socket",
# ce qui fait cascader `polkit`/`systemd-logind`/`upower`/`ModemManager`
# en FAILED et empêche toute session graphique (écran noir après le
# journal de boot) - signature classique d'un déni SELinux sur un fichier
# resté `unlabeled_t`/mal contextualisé plutôt qu'un vrai problème matériel
# ou de configuration système.
#
# `restorecon` NE SUFFIT PAS ICI - vérifié empiriquement (une première
# tentative avec `restorecon -Rv /` a rapporté "0 entrées relabellisées",
# silencieusement, exit 0) : `restorecon` est pensé pour un système DÉJÀ
# actif et vérifie `is_selinux_enabled()` (présence de `/sys/fs/selinux`,
# donc un noyau AVEC SELinux compilé) avant de faire quoi que ce soit - sur
# notre noyau de build (colima, sans SELinux), il se désactive
# silencieusement, y compris exécuté via `chroot` sur un rootfs cible qui a
# pourtant sa propre policy. `setfiles` (l'outil bas niveau, celui
# qu'Anaconda utilise lui-même pour labelliser un système FRAÎCHEMENT
# INSTALLÉ avant son tout premier démarrage - exactement notre cas de
# figure) n'a pas cette dépendance au noyau courant - confirmé
# empiriquement (`setfiles -F <file_contexts> /etc/passwd` relabellise
# correctement même avec `getenforce` à `Disabled` sur l'hôte de build).
# `-e proc/sys/dev` exclut les trois points de montage bind (virtuels,
# rien à labelliser dedans - les inclure ferait aussi planter setfiles sur
# des fichiers spéciaux qu'il ne sait pas gérer).
SELINUX_TYPE=$(chroot "$ROOTFS_DIR" sh -c '. /etc/selinux/config 2>/dev/null; echo "$SELINUXTYPE"')
SELINUX_TYPE="${SELINUX_TYPE:-targeted}"
echo "==> Relabel SELinux complet du rootfs live (policy '$SELINUX_TYPE', peut prendre 1-2 min)"
chroot "$ROOTFS_DIR" setfiles -v -F -e /proc -e /sys -e /dev \
    "/etc/selinux/$SELINUX_TYPE/contexts/files/file_contexts" / \
    > "$WORK_DIR/relabel.log" 2>&1 || true
echo "    $(wc -l < "$WORK_DIR/relabel.log") entrées relabellisées"

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
