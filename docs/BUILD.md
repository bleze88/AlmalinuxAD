# Construire l'ISO

## Prérequis (macOS/Apple Silicon)

```sh
brew install colima docker qemu
colima start --arch aarch64 --vm-type vz --cpu 4 --memory 8 --disk 60
```

Le DVD AlmaLinux fait ~10 Go et le respin en duplique une partie
temporairement (`build/.respin-work/`, `build/local-repo/`) - prévoir au
moins 30 à 40 Go d'espace disque disponible dans la VM colima (`--disk 60`
ci-dessus).

## Pipeline complet

```sh
./build/docker/run-in-container.sh
```

Équivaut à, dans l'ordre :

```sh
build/00-fetch-iso.sh    # télécharge + vérifie le DVD AlmaLinux officiel
build/01-build-rpm.sh    # construit almalinux-ad-firstboot-wizard + mini-dépôt local
build/02-respin-iso.sh   # patch le boot + ajoute ks.cfg/le dépôt local, réempaquette
```

L'ISO finale : `build/out/almalinux-ad-<date>-x86_64.iso`.

## Points à vérifier lors du tout premier build réel

Ce dépôt a été scaffoldé sans accès à un DVD AlmaLinux réel ni à un
environnement de build - plusieurs détails, documentés au fil du code
plutôt que supposés corrects à l'aveugle, sont à confirmer empiriquement
dès le premier essai :

1. **Id du groupe d'environnement KDE** (`kickstart/ks.cfg`,
   `@^kde-desktop-environment`) : vérifier avec
   `dnf --repofrompath=dvd,file:///chemin/vers/dvd/monté group list -v`
   (ou en montant l'ISO avec `xorriso -osirrox` et en pointant `dnf` dessus)
   que cet id existe bien tel quel sur la version d'AlmaLinux téléchargée.
2. **Chemin de montage du dépôt local pendant l'installation**
   (`repo --baseurl=file:///run/install/repo/AlmaLinuxAD-local` dans
   `ks.cfg`) : `/run/install/repo/` est l'emplacement habituel où Anaconda
   monte le média source pendant l'installation, mais à confirmer avec les
   logs Anaconda (`/tmp/anaconda.log` accessible via une console texte,
   Ctrl+Alt+F2, pendant l'installation) si `%packages` échoue à trouver
   `almalinux-ad-firstboot-wizard`.
3. **Chemins de `grub.cfg`/`isolinux.cfg` sur l'ISO** : `build/02-respin-iso.sh`
   les découvre dynamiquement (`xorriso -find`) plutôt que de les coder en
   dur, justement parce qu'ils peuvent varier - mais la substitution
   `sed` qui ajoute `inst.ks=cdrom:/ks.cfg` suppose un format de fichier
   standard (`linux .../vmlinuz ...` / `linuxefi ...`). Si le menu de boot
   ne montre pas l'option kickstart après respin, inspecter
   `build/.respin-work/grub.cfg` à la main.
4. **SELinux** : tester d'abord une installation complète avec
   `setenforce 0` (mode `Permissive`) pour isoler d'éventuels `avc: denied`
   liés à l'assistant AD (`ausearch -m avc -ts recent`) de tout autre
   problème, puis repasser en `Enforcing` (déjà la valeur par défaut
   d'AlmaLinux) avant de considérer le sujet réglé - voir
   [AD-JOIN-WIZARD.md](AD-JOIN-WIZARD.md).
5. **Nom exact des paquets sssd** (`sssd`, `sssd-krb5`, `sssd-ad`,
   `sssd-tools` dans `ks.cfg`) : à reconfirmer avec `dnf search sssd` sur
   le DVD monté - certaines de ces sous-paquetages peuvent avoir fusionné
   ou changé de nom entre versions mineures d'AlmaLinux 9.

## Tester

```sh
./test/run-qemu.sh
```

Vérifie seulement que le menu de boot patché apparaît et qu'Anaconda
démarre. **Un test d'installation complet doit se faire sur VMware réel**,
pas seulement QEMU : sur le projet frère Compass Arch, la quasi-totalité
des pièges liés à l'intégration AD (horloge, DNS, SDDM, SELinux...) ne
s'est révélée qu'en conditions réelles sur VMware, jamais en QEMU seul.
Secure Boot doit être désactivé dans le firmware de la VM avant de démarrer
sur l'ISO (GRUB généré par Anaconda n'est pas signé Secure Boot par défaut
sur un DVD AlmaLinux standard).

## Reconstruire uniquement le paquet de l'assistant AD

Après une modification de `packaging/almalinux-ad-firstboot-wizard/` :

```sh
build/01-build-rpm.sh && build/02-respin-iso.sh
```

(pas besoin de retélécharger le DVD à chaque fois - `build/00-fetch-iso.sh`
n'est nécessaire qu'une fois, ou après un changement de version majeure
dans `distro.conf`).
