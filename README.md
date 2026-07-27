# AlmaLinux AD

Distribution Linux basée sur **AlmaLinux** (dernière version majeure
stable, compatible RHEL), pour un environnement professionnel/entreprise,
avec :

- **KDE Plasma** comme environnement de bureau (valeurs par défaut de la
  distribution - Plymouth, GRUB2, SDDM, branding KDE non personnalisés)
- **Anaconda**, l'installeur graphique natif AlmaLinux/RHEL, pas-à-pas
  (respin du DVD officiel avec une sélection de logiciels pré-remplie -
  voir [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) pour pourquoi ce choix
  plutôt qu'un live-ISO + Calamares)
- **sssd + adcli + samba + realmd + krb5-workstation** préinstallés, avec
  un **assistant graphique proposé au premier login** pour rejoindre un
  domaine Windows **Active Directory** (optionnel, "skip" possible)

Projet frère de [Compass Arch](../Linux) (même intégration AD sur base Arch
Linux) - l'essentiel de la logique métier realm/sssd/krb5/sudoers a été
porté depuis ce projet ; voir
[docs/AD-JOIN-WIZARD.md](docs/AD-JOIN-WIZARD.md) pour le détail de ce qui
change (et ce qui ne change pas) sur AlmaLinux.

## Décision d'architecture

**Pas de live-ISO Calamares** : contrairement à Arch (archiso) ou
Ubuntu/Debian (casper), il n'existe aucun précédent connu combinant
live-ISO + Calamares côté RHEL/AlmaLinux. Ce projet utilise **Kickstart +
Anaconda natif** (100% outillage RHEL balisé), avec l'étape de jonction AD
déplacée du temps d'installation vers un **assistant graphique de premier
login** plutôt qu'un `%post` kickstart aveugle et non-interactif. Détail
complet et alternatives évaluées : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Structure du dépôt

```
distro.conf                              Identité de la distro (nom, version AlmaLinux ciblée)
kickstart/ks.cfg                         Kickstart partiel (logiciels + %post uniquement, reste interactif)
packaging/almalinux-ad-firstboot-wizard/ RPM "files-only" : wizard kdialog + backend Python + autostart/menu
build/                                   Scripts de build (fetch ISO -> RPM -> respin xorriso)
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
points à **vérifier empiriquement lors du tout premier build réel** (id du
groupe KDE, chemin de montage du dépôt local pendant l'install, noms exacts
des paquets sssd...) - ce dépôt a été scaffoldé sans accès à un DVD
AlmaLinux réel, ces détails sont documentés plutôt que supposés corrects
à l'aveugle.

## Secure Boot

Désactivez Secure Boot dans le firmware avant de démarrer sur l'ISO -
GRUB (généré nativement par Anaconda) n'est pas signé Secure Boot par
défaut sur un DVD AlmaLinux standard.

## Intégration Active Directory

Voir [docs/AD-JOIN-WIZARD.md](docs/AD-JOIN-WIZARD.md) pour le détail de
l'assistant de premier login (kdialog + backend Python privilégié via
`pkexec`), et notamment le tableau des différences avec le projet Arch de
référence (SELinux, `authselect`, `oddjob-mkhomedir` officiel, absence de
chroot pendant la jonction).

## Licence

À définir par le mainteneur du projet (aucune licence n'est présumée ici).
