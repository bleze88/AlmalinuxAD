# Construire l'ISO

## Prérequis (macOS/Apple Silicon)

```sh
brew install colima docker qemu
colima start --vm-type vz --cpu 4 --memory 8 --disk 40
```

`--privileged` est utilisé par `build/docker/run-in-container.sh` pour
`mount -o loop` (extraction/réécriture du rootfs live, voir
`build/02-customize-squashfs.sh`) - une simple fonctionnalité noyau, pas de
la virtualisation imbriquée (voir docs/ARCHITECTURE.md pour la distinction
avec `livemedia-creator`/KVM, volontairement évité). La Live ISO KDE
officielle fait ~2,6 Go - prévoir 15-20 Go d'espace disque disponible dans
la VM colima.

## Pipeline complet

```sh
./build/docker/run-in-container.sh
```

Équivaut à, dans l'ordre :

```sh
build/00-fetch-iso.sh          # télécharge + vérifie la Live ISO KDE officielle AlmaLinux
build/01-build-rpm.sh          # construit almalinux-ad-firstboot-wizard + mini-dépôt local
build/02-customize-squashfs.sh # installe les paquets AD + le RPM dans le rootfs live, réempaquette
```

L'ISO finale : `build/out/almalinux-ad-<date>-x86_64.iso`.

## État après le premier build réel (2026-07-27)

Le pipeline a été exécuté de bout en bout avec succès sur macOS/colima et
produit une ISO valide (`almalinux-ad-2026.07.27-x86_64.iso`, ~2,68 Go).
Points qui avaient été documentés comme "à vérifier" et sont maintenant
confirmés :

- **Layout du squashfs live** : confirmé simple (rootfs directement dans le
  squashfs, pas d'image imbriquée), compression `xz`.
- **Noms de paquets** (`sssd`, `sssd-krb5`, `sssd-ad`, `sssd-tools`,
  `adcli`, `realmd`, `samba-common-tools`, `krb5-workstation`,
  `bind-utils`, `oddjob`, `oddjob-mkhomedir`, `policycoreutils`) : tous
  résolus sans ambiguïté sur AlmaLinux 10.
- **`authselect select sssd with-mkhomedir --force` dans un chroot sans
  systemd/D-Bus fonctionne correctement** : confirmé via
  `chroot <rootfs> authselect current` (`Profile ID: sssd`,
  `with-mkhomedir`) et un décompte de `pam_sss` dans
  `/etc/pam.d/system-auth` (4 occurrences, auth/account/password/session).
  `nsswitch.conf`, lui, affiche `passwd: files systemd` **sans** `sss`
  explicite - normal sur cette version de systemd (257) : `nss-systemd`
  fait office de multiplexeur et interroge `sssd` via `userdb`/varlink en
  coulisses, il ne s'agit pas d'un signe que la jonction sssd est absente.
- **KDE Plasma (et `kdialog`) vient entièrement d'EPEL**, pas de
  BaseOS/AppStream/CRB - voir docs/ARCHITECTURE.md. Le rootfs live a EPEL
  déjà activé, `build/02-customize-squashfs.sh` le vérifie avant d'installer
  `kdialog`.

## Pièges de build/vérification rencontrés (à ne pas re-découvrir)

- **`unsquashfs`/`mount -o loop` échouent sur un répertoire de travail situé
  dans le volume monté** (`$REPO_ROOT`, en bind mount virtiofs depuis
  macOS via colima) : `failed to change uid and gids ... Operation not
  permitted` sur des milliers de fichiers. Cause : virtiofs ne supporte pas
  la sémantique POSIX complète (chown arbitraire) en passthrough depuis
  macOS. Fix appliqué : `WORK_DIR` de `build/02-customize-squashfs.sh` est
  volontairement un chemin **local au conteneur** (`/var/tmp/...`), pas
  sous `$REPO_ROOT` - seules la lecture de l'ISO source/du dépôt local et
  l'écriture de l'ISO finale traversent le volume monté (simples
  lectures/écritures de fichiers réguliers, sans ce problème). Un `rm -rf`
  sur un répertoire déjà partiellement extrait dans le volume monté peut
  lui aussi échouer (`Permission denied`) - `chmod -R u+rwX` d'abord avant
  `rm -rf` dans ce cas précis.
- **Piège de vérification (pas un bug du build) - lien symbolique
  absolu lu depuis le mauvais contexte** : `/etc/pam.d/system-auth` est un
  symlink vers le chemin **absolu** `/etc/authselect/system-auth`. Le lire
  depuis l'EXTÉRIEUR d'un chroot (ex: `cat $ROOTFS_DIR/etc/pam.d/system-auth`
  après un `unsquashfs` d'inspection) résout ce lien contre la racine `/`
  **de la machine/du conteneur courant**, pas contre `$ROOTFS_DIR` - lu
  ainsi, le fichier semblait ne PAS contenir `pam_sss` (fausse alerte :
  c'est le `system-auth` par défaut du conteneur d'inspection lui-même qui
  était lu, pas celui du rootfs extrait). Toujours vérifier un chroot avec
  `chroot "$ROOTFS_DIR" <commande>` (ou lire directement le fichier concret
  `$ROOTFS_DIR/etc/authselect/system-auth`, qui n'est pas un symlink),
  jamais en concaténant un chemin hôte avec un chemin qui contient un
  symlink absolu à l'intérieur.
- **`genisoimage`/`syslinux`** listés dans une première version du
  Dockerfile n'existent pas sur AlmaLinux 10 (et n'étaient de toute façon
  pas utilisés par les scripts, seul `xorriso` l'est) - retirés.
- **`curl` (paquet complet) entre en conflit avec `curl-minimal`** déjà
  présent sur l'image `almalinux:9`/`10` de base - ne pas l'ajouter
  explicitement, `curl-minimal` fournit déjà la commande `curl`.

## Tester

```sh
./test/run-qemu.sh
```

Vérifie seulement que le média boote sur la session live KDE. **Un test
d'installation complet (icône "Install to Hard Drive" puis jonction AD au
premier login) doit se faire sur VMware réel**, pas seulement QEMU : sur le
projet frère Compass Arch, la quasi-totalité des pièges liés à
l'intégration AD (horloge, DNS, SDDM, SELinux...) ne s'est révélée qu'en
conditions réelles sur VMware, jamais en QEMU seul. Secure Boot doit être
désactivé dans le firmware de la VM avant de démarrer sur l'ISO.

## Reconstruire uniquement le paquet de l'assistant AD

Après une modification de `packaging/almalinux-ad-firstboot-wizard/` :

```sh
build/01-build-rpm.sh && build/02-customize-squashfs.sh
```

(pas besoin de retélécharger la Live ISO à chaque fois -
`build/00-fetch-iso.sh` n'est nécessaire qu'une fois, ou après un
changement de version majeure dans `distro.conf`).
