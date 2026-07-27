#!/bin/bash
# Boot rapide de l'ISO produite dans QEMU (UEFI, OVMF) - juste pour vérifier
# que le menu de boot patché (inst.ks=cdrom:/ks.cfg) apparaît et
# qu'Anaconda démarre. Ne remplace PAS un test d'installation complet sur
# VMware réel (voir docs/BUILD.md et l'expérience du projet frère
# Compass Arch : la plupart des pièges AD ne se sont révélés qu'en
# conditions réelles sur VMware, pas sous QEMU).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="${1:-$(ls -t "$REPO_ROOT"/build/out/*.iso 2>/dev/null | head -1)}"

[ -n "$ISO" ] && [ -f "$ISO" ] || { echo "!! Aucune ISO trouvée dans build/out/ - précisez le chemin en argument." >&2; exit 1; }

OVMF_CODE="${OVMF_CODE:-/opt/homebrew/share/qemu/edk2-x86_64-code.fd}"
[ -f "$OVMF_CODE" ] || echo "!! OVMF introuvable à $OVMF_CODE - ajustez OVMF_CODE= (brew install qemu fournit edk2-x86_64-code.fd)." >&2

echo "==> Boot de $ISO dans QEMU (fermez la fenêtre QEMU pour arrêter)"
qemu-system-x86_64 \
    -m 4096 \
    -smp 2 \
    -bios "$OVMF_CODE" \
    -cdrom "$ISO" \
    -boot d \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -display default,show-cursor=on
