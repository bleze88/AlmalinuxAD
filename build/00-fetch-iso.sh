#!/bin/bash
# Télécharge le DVD ISO officiel AlmaLinux (dépôt miroir officiel
# repo.almalinux.org) et vérifie son empreinte SHA256 avant de le réutiliser
# pour le respin - jamais de réutilisation silencieuse d'un fichier corrompu
# ou incomplet.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/distro.conf"

CACHE_DIR="$REPO_ROOT/build/iso-cache"
mkdir -p "$CACHE_DIR"

ARCH="x86_64"
BASE_URL="https://repo.almalinux.org/almalinux/${ALMALINUX_MAJOR}/isos/${ARCH}"
ISO_NAME="AlmaLinux-${ALMALINUX_MAJOR}-latest-${ARCH}-dvd1.iso"

echo "==> Téléchargement de ${ISO_NAME} depuis ${BASE_URL}"
echo "    (URL 'latest' officielle - vérifiez sur https://almalinux.org/get-almalinux/"
echo "    si le nom de fichier a changé pour votre version majeure)"

curl -fL --progress-bar -o "$CACHE_DIR/$ISO_NAME.tmp" "$BASE_URL/$ISO_NAME"
curl -fL --progress-bar -o "$CACHE_DIR/CHECKSUM" "$BASE_URL/CHECKSUM"

expected=$(grep -i "SHA256.*(${ISO_NAME})" "$CACHE_DIR/CHECKSUM" | awk -F'= ' '{print $2}')
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
ln -sf "$ISO_NAME" "$CACHE_DIR/almalinux-dvd.iso"
echo "==> OK : $CACHE_DIR/$ISO_NAME (empreinte vérifiée)"
