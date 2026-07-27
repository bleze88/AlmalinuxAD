#!/bin/bash
# Construit le paquet almalinux-ad-firstboot-wizard (fichiers statiques,
# aucune compilation) et prépare un mini-dépôt dnf local, dans l'esprit du
# `local-repo/` du projet frère Compass Arch - mais ici sans rien compiler
# (sssd/adcli/realmd/samba/krb5-workstation/oddjob sont tous officiels,
# voir docs/ARCHITECTURE.md), juste notre propre petit paquet de fichiers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$REPO_ROOT/packaging/almalinux-ad-firstboot-wizard"
LOCAL_REPO_DIR="$REPO_ROOT/build/local-repo/AlmaLinuxAD-local"

rm -rf "$LOCAL_REPO_DIR"
mkdir -p "$LOCAL_REPO_DIR"

rpmbuild \
    --define "_topdir $PKG_DIR" \
    --define "_rpmdir $LOCAL_REPO_DIR" \
    -bb "$PKG_DIR/SPECS/almalinux-ad-firstboot-wizard.spec"

# rpmbuild range les RPM produits dans _rpmdir/<arch>/ (ici noarch/) ;
# createrepo_c doit indexer le dossier racine du mini-dépôt.
find "$LOCAL_REPO_DIR" -name '*.rpm' -exec mv {} "$LOCAL_REPO_DIR/" \;
find "$LOCAL_REPO_DIR" -mindepth 1 -type d -empty -delete

createrepo_c "$LOCAL_REPO_DIR"

echo "==> Mini-dépôt local prêt : $LOCAL_REPO_DIR"
