# AlmaLinux AD

Distribution Linux basée sur **AlmaLinux 10** (dernière version majeure
stable, compatible RHEL), pour un environnement professionnel/entreprise,
avec :

- **KDE Plasma** comme environnement de bureau, live-boot inclus ("essayer
  avant d'installer" - valeurs par défaut de la distribution : Plymouth,
  GRUB2, SDDM, branding KDE non personnalisés)
- **Anaconda**, l'installeur graphique natif AlmaLinux/RHEL, pas-à-pas
  (lancé depuis la session live via "Install to Hard Drive" - voir
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) pour pourquoi Anaconda
  plutôt que Calamares)
- **sssd + adcli + samba + realmd + krb5-workstation** préinstallés, avec
  un **assistant graphique proposé au premier login** pour rejoindre un
  domaine Windows **Active Directory** (optionnel, "skip" possible)
- **Google Chrome + Microsoft Edge** préinstallés (dépôts officiels
  ajoutés au build, laissés activés pour les mises à jour de sécurité)
- **Evolution + evolution-ews** préinstallés (client mail avec support
  Exchange/EWS, dépôt EPEL)
- **LibreOffice** préinstallé via Flatpak/Flathub - absent de tout dépôt
  dnf sur AlmaLinux 10 (RHEL10 a abandonné le système de modules qui le
  portait sur RHEL8/9), seul logiciel de cette image géré hors dnf
- **sudo sans mise en cache** (`timestamp_timeout=0`) : mot de passe
  redemandé à chaque `sudo`, durcissement pour environnement professionnel

Projet frère de [Compass Arch](https://github.com/bleze88/compassarch) (même intégration AD sur base Arch
Linux) - l'essentiel de la logique métier realm/sssd/krb5/sudoers a été
porté depuis ce projet ; voir
[docs/AD-JOIN-WIZARD.md](docs/AD-JOIN-WIZARD.md) pour le détail de ce qui
change (et ce qui ne change pas) sur AlmaLinux.

## Décision d'architecture

**Pas de Calamares** : contrairement à Arch (archiso) ou Ubuntu/Debian
(casper), personne - pas même AlmaLinux en amont - n'a marié le pipeline
live RHEL (`lorax`/`livemedia-creator`) à Calamares ; l'installeur reste
partout Anaconda. Ce projet part donc de la **Live ISO KDE officielle et
maintenue par AlmaLinux**, la personnalise par manipulation directe du
squashfs (paquets AD + assistant ajoutés dans le rootfs live, pas de
kickstart au moment de l'installation), et déplace la jonction AD vers un
**assistant graphique de premier login**. Détail complet, alternatives
évaluées, et une correction de trajectoire en cours de route (le tout
premier scaffold avait écarté à tort tout live-boot) :
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Structure du dépôt

```
distro.conf                              Identité de la distro (nom, version AlmaLinux ciblée)
packaging/almalinux-ad-firstboot-wizard/ RPM "files-only" : wizard kdialog + backend Python + autostart/menu
build/                                   Scripts de build (fetch Live ISO -> RPM -> personnalisation squashfs)
test/run-qemu.sh                         Boot rapide de l'ISO produite (test complet : VMware réel)
docs/                                    Documentation détaillée
```

## Démarrage rapide

```sh
# Depuis macOS (Apple Silicon) via colima :
./build/docker/run-in-container.sh

# Tester le boot de l'ISO produite dans QEMU :
./test/run-qemu.sh
```

L'ISO finale se trouve dans `build/out/`. Voir
[docs/BUILD.md](docs/BUILD.md) pour les prérequis et surtout la liste des
points à **vérifier empiriquement lors du tout premier build réel** (layout
interne du squashfs live, noms exacts des paquets sssd, nettoyage des
artefacts live par Anaconda...) - ce dépôt a été en grande partie scaffoldé
avant d'avoir inspecté la Live ISO réelle, ces détails sont documentés
plutôt que supposés corrects à l'aveugle.

## Secure Boot

Désactivez Secure Boot dans le firmware avant de démarrer sur l'ISO -
GRUB (généré nativement par Anaconda) n'est pas signé Secure Boot par
défaut sur une Live ISO AlmaLinux standard.

## Intégration Active Directory

Voir [docs/AD-JOIN-WIZARD.md](docs/AD-JOIN-WIZARD.md) pour le détail de
l'assistant de premier login (kdialog + backend Python privilégié via
`pkexec`), et notamment le tableau des différences avec le projet Arch de
référence (SELinux, `authselect`, `oddjob-mkhomedir` officiel, absence de
chroot pendant la jonction).

## Licence

À définir par le mainteneur du projet (aucune licence n'est présumée ici).
