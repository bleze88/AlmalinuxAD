#!/bin/bash
# Respin de l'ISO DVD AlmaLinux officiel : ajoute kickstart/ks.cfg et notre
# mini-dépôt local à la racine de l'ISO, et patche l'entrée de boot par
# défaut (grub.cfg UEFI + isolinux.cfg BIOS) pour ajouter `inst.ks=cdrom:/ks.cfg`.
#
# Technique : `xorriso -boot_image any replay` + `-map` plutôt qu'un
# extract/modify/repack complet du DVD (plusieurs Go) - xorriso rejoue les
# catalogues de boot BIOS (El Torito) et UEFI (image ESP) de l'ISO source
# tels quels, on ne fait qu'ajouter/remplacer une poignée de fichiers par
# dessus. Beaucoup plus léger que l'équivalent archiso (mkarchiso) côté
# ressources - important dans un conteneur Docker/colima.
#
# !! Premier build réel : les chemins exacts de grub.cfg/isolinux.cfg et le
# point de montage `/run/install/repo/` référencé par kickstart/ks.cfg
# doivent être reconfirmés sur le DVD effectivement téléchargé (voir
# docs/BUILD.md) - ce script les découvre dynamiquement via `xorriso -find`
# plutôt que de les coder en dur, justement parce qu'ils peuvent varier
# d'une version mineure d'AlmaLinux à l'autre.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/distro.conf"

SRC_ISO="$REPO_ROOT/build/iso-cache/almalinux-dvd.iso"
OUT_DIR="$REPO_ROOT/build/out"
OUT_ISO="$OUT_DIR/${DISTRO_ID}-${DISTRO_VERSION}-x86_64.iso"
WORK_DIR="$REPO_ROOT/build/.respin-work"
LOCAL_REPO_DIR="$REPO_ROOT/build/local-repo/AlmaLinuxAD-local"

[ -f "$SRC_ISO" ] || { echo "!! $SRC_ISO introuvable - lancez d'abord build/00-fetch-iso.sh" >&2; exit 1; }
[ -d "$LOCAL_REPO_DIR" ] || { echo "!! $LOCAL_REPO_DIR introuvable - lancez d'abord build/01-build-rpm.sh" >&2; exit 1; }

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"
rm -f "$OUT_ISO"

find_in_iso() {
    xorriso -indev "$SRC_ISO" -find / -name "$1" 2>/dev/null | awk '{print $1}' | tr -d "'" | head -1
}

GRUB_CFG_PATH=$(find_in_iso grub.cfg)
ISOLINUX_CFG_PATH=$(find_in_iso isolinux.cfg)

if [ -z "$GRUB_CFG_PATH" ]; then
    echo "!! grub.cfg introuvable sur l'ISO - layout inattendu, à investiguer manuellement (xorriso -indev $SRC_ISO -find / )." >&2
    exit 1
fi

echo "==> grub.cfg trouvé : $GRUB_CFG_PATH"
[ -n "$ISOLINUX_CFG_PATH" ] && echo "==> isolinux.cfg trouvé : $ISOLINUX_CFG_PATH" || echo "!! isolinux.cfg absent (ISO UEFI-only ?) - boot BIOS legacy non patché."

xorriso -indev "$SRC_ISO" -osirrox on \
    -extract "$GRUB_CFG_PATH" "$WORK_DIR/grub.cfg"
[ -n "$ISOLINUX_CFG_PATH" ] && xorriso -indev "$SRC_ISO" -osirrox on \
    -extract "$ISOLINUX_CFG_PATH" "$WORK_DIR/isolinux.cfg"

# Ajoute inst.ks=cdrom:/ks.cfg à la fin de chaque ligne de commande noyau
# (linux/linuxefi) du menu de boot - fonctionne aussi bien pour l'entrée
# "Install AlmaLinux" par défaut que pour "Test this media & install".
patch_boot_cfg() {
    local file="$1"
    [ -f "$file" ] || return 0
    sed -i.bak -E 's/^([[:space:]]*(linux|linuxefi)[[:space:]].*)$/\1 inst.ks=cdrom:\/ks.cfg/' "$file"
}
patch_boot_cfg "$WORK_DIR/grub.cfg"
patch_boot_cfg "$WORK_DIR/isolinux.cfg"

cp "$REPO_ROOT/kickstart/ks.cfg" "$WORK_DIR/ks.cfg"

XORRISO_ARGS=(
    -indev "$SRC_ISO"
    -outdev "$OUT_ISO"
    -boot_image any replay
    -map "$WORK_DIR/ks.cfg" /ks.cfg
    -map "$WORK_DIR/grub.cfg" "$GRUB_CFG_PATH"
    -map "$LOCAL_REPO_DIR" /AlmaLinuxAD-local
)
[ -f "$WORK_DIR/isolinux.cfg" ] && XORRISO_ARGS+=(-map "$WORK_DIR/isolinux.cfg" "$ISOLINUX_CFG_PATH")
XORRISO_ARGS+=(-commit -eject all)

echo "==> Respin de l'ISO -> $OUT_ISO"
xorriso "${XORRISO_ARGS[@]}"

if command -v implantisomd5 >/dev/null 2>&1; then
    implantisomd5 "$OUT_ISO"
    echo "==> Somme de contrôle média (checkisomd5) implantée."
fi

echo "==> Terminé : $OUT_ISO"
