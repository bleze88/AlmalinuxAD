# Image de build pour personnaliser la Live ISO KDE officielle AlmaLinux
# depuis macOS/colima.
#
# Base AlmaLinux 10 (alignée sur la version cible - voir distro.conf) : pas
# besoin de systemd-nspawn/devtools ici, contrairement au projet frère
# Compass Arch (aucune compilation AUR). On part de l'ISO Live KDE déjà
# construite par le pipeline officiel AlmaLinux (sig-livemedia), et on la
# personnalise par manipulation directe du squashfs (unsquashfs/mksquashfs
# + chroot dnf --installroot), pas de VM/KVM imbriquée nécessaire - juste
# des `mount -o loop`, d'où le `--privileged` requis sur `docker run`
# (voir build/docker/run-in-container.sh) pour les périphériques loop.
FROM almalinux:10

RUN dnf install -y --setopt=install_weak_deps=False \
        rpm-build \
        rpmdevtools \
        createrepo_c \
        xorriso \
        isomd5sum \
        squashfs-tools \
        e2fsprogs \
        util-linux \
        ca-certificates \
    && dnf clean all

WORKDIR /workspace
