# Image de build pour respinner l'ISO AlmaLinux AD depuis macOS/colima.
#
# Base AlmaLinux (pas besoin de systemd-nspawn/devtools ici, contrairement
# au projet frère Compass Arch : aucune compilation AUR, seulement
# rpmbuild pour notre propre paquet "files-only" et xorriso pour patcher
# l'ISO officiel - les deux tournent très bien dans un conteneur Docker
# classique, sans privilèges particuliers).
FROM almalinux:9

RUN dnf install -y --setopt=install_weak_deps=False \
        rpm-build \
        rpmdevtools \
        createrepo_c \
        xorriso \
        genisoimage \
        syslinux \
        isomd5sum \
        curl \
        ca-certificates \
    && dnf clean all

WORKDIR /workspace
