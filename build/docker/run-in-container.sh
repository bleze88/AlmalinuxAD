#!/bin/bash
# Construit l'image de build puis lance tout le pipeline (fetch ISO -> RPM
# -> respin) dedans, avec le dépôt monté en volume. Pensé pour macOS/Apple
# Silicon via colima (colima start --arch aarch64 --vm-type vz, ou
# --arch x86_64 si vous préférez émuler - AlmaLinux/xorriso n'ont pas
# besoin de KVM/loop devices ici, juste de la mémoire/disque pour le DVD).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="almalinux-ad-builder"

docker build -t "$IMAGE_TAG" "$REPO_ROOT/build/docker"

docker run --rm -it \
    -v "$REPO_ROOT:/workspace" \
    -w /workspace \
    "$IMAGE_TAG" \
    bash -c "build/00-fetch-iso.sh && build/01-build-rpm.sh && build/02-respin-iso.sh"
