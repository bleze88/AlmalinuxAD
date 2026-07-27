#!/bin/bash
# Télécharge la Live ISO KDE officielle AlmaLinux (dépôt miroir officiel
# repo.almalinux.org, arborescence /live/ - construite et maintenue par
# AlmaLinux via le pipeline officiel lorax/livemedia-creator, voir
# https://github.com/AlmaLinux/sig-livemedia) et vérifie son empreinte
# SHA256 avant de la réutiliser pour la personnalisation - jamais de
# réutilisation silencieuse d'un fichier corrompu ou incomplet.
#
# Pourquoi partir de cette ISO déjà construite plutôt que de reproduire le
# pipeline sig-livemedia nous-mêmes : `livemedia-creator` pilote une vraie
# VM (`virt-install`/KVM) pour exécuter le kickstart - fragile dans une
# pile Docker-dans-colima-dans-VZ (voir docs/ARCHITECTURE.md). On part donc
# du résultat déjà construit par l'infrastructure AlmaLinux, et on le
# personnalise par manipulation du squashfs (build/02-customize-squashfs.sh),
# qui ne nécessite aucune VM/KVM.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/distro.conf"

CACHE_DIR="$REPO_ROOT/build/iso-cache"
mkdir -p "$CACHE_DIR"

ARCH="x86_64"
BASE_URL="https://repo.almalinux.org/almalinux/${ALMALINUX_MAJOR}/live/${ARCH}"
ISO_NAME="AlmaLinux-${ALMALINUX_MAJOR}-latest-${ARCH}-Live-KDE.iso"

echo "==> Téléchargement de ${ISO_NAME} depuis ${BASE_URL}"
echo "    (URL 'latest' officielle - vérifiez sur ${BASE_URL}/"
echo "    si le nom de fichier a changé pour votre version majeure)"

curl -fL --progress-bar -o "$CACHE_DIR/$ISO_NAME.tmp" "$BASE_URL/$ISO_NAME"
curl -fL --progress-bar -o "$CACHE_DIR/CHECKSUM" "$BASE_URL/CHECKSUM"

# Format simple `sha256sum` (hash  fichier), différent du format BSD
# "SHA256 (fichier) = hash" utilisé par le CHECKSUM du DVD classique - deux
# outils/générateurs différents côté AlmaLinux selon l'arborescence.
expected=$(awk -v f="$ISO_NAME" '$2 == f {print $1}' "$CACHE_DIR/CHECKSUM")
if [ -z "$expected" ]; then
    echo "!! Impossible de trouver l'empreinte SHA256 de ${ISO_NAME} dans CHECKSUM - abandon." >&2
    exit 1
fi

actual=$(sha256sum "$CACHE_DIR/$ISO_NAME.tmp" | awk '{print $1}')
if [ "$expected" != "$actual" ]; then
    echo "!! Empreinte SHA256 invalide pour ${ISO_NAME} (attendu $expected, obtenu $actual) - abandon." >&2
    rm -f "$CACHE_DIR/$ISO_NAME.tmp"
    exit 1
fi

mv "$CACHE_DIR/$ISO_NAME.tmp" "$CACHE_DIR/$ISO_NAME"
ln -sf "$ISO_NAME" "$CACHE_DIR/almalinux-live-kde.iso"
echo "==> OK : $CACHE_DIR/$ISO_NAME (empreinte vérifiée)"
