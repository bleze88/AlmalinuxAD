#!/bin/bash
# Construit l'image de build puis lance tout le pipeline (fetch Live ISO ->
# RPM -> personnalisation squashfs -> respin) dedans, avec le dépôt monté
# en volume. Pensé pour macOS/Apple Silicon via colima (colima start
# --vm-type vz).
#
# --privileged : nécessaire pour `mount -o loop` (extraction/réécriture du
# rootfs ext4 embarqué dans le squashfs live, voir
# build/02-customize-squashfs.sh) - un simple `mount -o loop` a besoin de
# CAP_SYS_ADMIN + accès aux périphériques /dev/loop*, ce que Docker
# n'accorde pas par défaut. Contrairement à `livemedia-creator`
# (KVM/virt-install, voir docs/ARCHITECTURE.md), ceci reste une simple
# fonctionnalité du noyau Linux - colima l'expose nativement à ses
# conteneurs, aucune virtualisation imbriquée n'est en jeu ici.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="almalinux-ad-builder"

docker build -t "$IMAGE_TAG" "$REPO_ROOT/build/docker"

docker run --rm \
    --privileged \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace \
    "$IMAGE_TAG" \
    bash -c "build/00-fetch-iso.sh && build/01-build-rpm.sh && build/02-customize-squashfs.sh"
