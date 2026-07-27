# Architecture

## Décision : Kickstart+Anaconda, pas de live-ISO Calamares

Point tranché en premier, avant tout code (voir aussi le fil de discussion
d'origine, résumé ici pour mémoire du dépôt).

**Constat de départ.** Contrairement à Arch (archiso+Calamares, très mature -
voir le projet frère [Compass Arch](../../Linux)) et à Ubuntu/Debian
(casper+Calamares, KDE Neon...), il n'existe **aucun précédent connu** côté
famille RHEL combinant live-ISO + Calamares :
- `lorax`/`livemedia-creator` (le pipeline live officiel, utilisé par Fedora
  pour ses spins KDE/Kinoite) est bien disponible dans les dépôts AlmaLinux,
  mais personne ne l'a marié à Calamares pour cette famille de distributions.
  Fedora lui-même n'utilise pas Calamares (Anaconda/WebUI).
- L'ancien CentOS Live SIG (livecd-tools) est mort depuis CentOS 7 - pas de
  fork viable.
- `livemedia-creator` pilote généralement une installation Anaconda imbriquée
  (QEMU + loop devices, souvent KVM) - une couche de virtualisation
  supplémentaire fragile dans un conteneur Docker lui-même dans la VM colima
  (macOS/Apple Silicon), par rapport au `mksquashfs` relativement simple
  d'archiso.

**Décision retenue : Kickstart + Anaconda natif**, avec l'étape de jonction
AD déplacée du temps d'installation (module Calamares) vers un **assistant
graphique de premier login** (voir "Assistant AD au premier login"
ci-dessous), plutôt qu'un `%post` kickstart aveugle et non-interactif.

Compromis assumé : pas de mode "essayer avant d'installer" (live boot).
Jugé mineur en contexte poste de travail professionnel/entreprise (à
l'inverse d'une distribution grand public/hobbyiste), où ce mode sert
surtout à la découverte avant achat/déploiement.

Bénéfice collatéral important : toute la classe de pièges "artefacts du
live copiés tel quel sur la cible" (compte `liveuser`, sudo sans mot de
passe, `unpackfs` qui vide `/boot`...), qui a occupé une bonne partie du
travail sur le projet Arch (voir son `docs/ARCHITECTURE.md`), **disparaît
structurellement** ici : Anaconda installe proprement depuis les paquets,
il n'y a pas de session live à nettoyer après coup.

## Vue d'ensemble

```
                    packaging/almalinux-ad-firstboot-wizard/
                    (spec RPM : wizard kdialog + backend Python + .desktop)
                                  │ rpmbuild
                                  ▼
                    build/01-build-rpm.sh → RPM dans un mini-dépôt dnf local
                                  │
kickstart/ks.cfg  ────────────┐  │
(%packages: @kde-desktop-      │  │
 environment + sssd/adcli/     │  │
 samba/realmd/krb5-workstation/│  │
 oddjob-mkhomedir/bind-utils + │  │
 notre RPM wizard, %post:      │  │
 authselect, oddjobd, journald,│  │
 avahi, vmware-tools)          │  │
                                ▼  ▼
                    build/02-respin-iso.sh
                    (extrait le DVD AlmaLinux officiel, injecte ks.cfg +
                     mini-dépôt local, patch grub.cfg/isolinux.cfg pour
                     'inst.ks=cdrom:/ks.cfg' par défaut, réempaquette avec
                     xorriso + isohybrid)
                                  │
                                  ▼
                         build/out/*.iso
                                  │  boot + install Anaconda GUI normal
                                  │  (partitionnement, compte utilisateur,
                                  │  réseau... toutes les étapes STANDARD
                                  │  restent interactives - seul le choix
                                  │  de logiciels est pré-rempli)
                                  ▼
                    premier redémarrage, premier login Plasma
                                  │
                                  ▼
        /etc/xdg/autostart/almalinux-ad-join-wizard.desktop
        (une seule fois - voir "Assistant AD au premier login")
```

## Pourquoi respin du DVD (pas du boot.iso netinstall)

Le DVD ISO officiel AlmaLinux contient déjà tous les paquets nécessaires
(BaseOS + AppStream, dont le groupe `@kde-desktop-environment` et
`sssd`/`adcli`/`samba`/`realmd`/`krb5-workstation`/`oddjob-mkhomedir` - tous
dans les dépôts **officiels**, contrairement au projet Arch où
`yay`/`realmd`/`calamares` étaient AUR-only et avaient nécessité un dépôt
pacman local compilé maison). Respin du DVD = **aucun accès réseau requis
pendant l'installation**, même philosophie que le projet Arch mais sans
avoir besoin de compiler quoi que ce soit - seul notre propre petit RPM
(assistant AD) est ajouté à un mini-dépôt local sur l'ISO.

## Pourquoi Kickstart ne bloque pas l'expérience "pas-à-pas"

Un fichier Kickstart n'a pas besoin d'être exhaustif : les commandes
omises (partitionnement, réseau, fuseau horaire, création du compte
utilisateur/mot de passe...) laissent Anaconda afficher son **assistant
graphique normal**, interactif, comme une installation manuelle. Seule la
**sélection de logiciels** (`%packages`) et quelques réglages `%post` sont
pré-remplis par notre `kickstart/ks.cfg`. C'est le même principe que
n'importe quel "respin" DVD personnalisé d'entreprise (préchargement de
logiciels), sans toucher au caractère pas-à-pas de l'installeur natif RHEL.

## Assistant AD au premier login (remplace le module Calamares "adjoinview/adjoinjob")

Contrairement au module Calamares du projet Arch, l'assistant tourne **sur
le système réellement installé et démarré** (vrai `systemd` PID 1, vrai bus
D-Bus système, NetworkManager actif), jamais dans un `chroot()` pendant
l'installation. Conséquence directe : plusieurs pièges du projet Arch
**ne s'appliquent structurellement pas ici** (voir
[AD-JOIN-WIZARD.md](AD-JOIN-WIZARD.md) pour le détail complet paragraphe
par paragraphe) :
- pas besoin de `realm join --install=/` (mode conçu pour un chroot
  hors-ligne sans D-Bus) - `realmd` tourne normalement sur un système
  démarré, `realm join` "nu" suffit et passe par le chemin normal/testé
  de `realmd` (dont ses propres hooks NetworkManager) ;
- pas besoin de `socket.sethostname()` (le noyau a déjà le bon hostname au
  premier boot, pas de `chroot()` sans namespace UTS séparé) ;
- pas besoin de réparer `/etc/resolv.conf` (NetworkManager gère déjà un
  vrai `resolv.conf` fonctionnel sur un système démarré, pas de stub
  `systemd-resolved` sur AlmaLinux par défaut).

Ce qui **reste** applicable tel quel (comportements indépendants de la
distribution ou de l'environnement chroot/live) : synchro horloge
`chronyd -q` avant jonction, figer le KDC via `dig SRV` dans
`krb5.conf`, forcer `use_fully_qualified_names=False`/`case_sensitive=False`
dans `sssd.conf` (bug `pam_systemd`/`ConflictingRecordFound`), restriction
`realm permit --groups`, fragment sudoers validé par `visudo -cf`, et
`HideUsers`/`RememberLastUser` dans une seule section `[Users]` de
`/etc/sddm.conf.d/`.

Architecture en deux couches (calque du split Calamares
`adjoinview`/`adjoinjob`) :
- **`/usr/bin/almalinux-ad-join-wizard`** (non privilégié, lancé au premier
  login Plasma via l'autostart `almalinux-ad-join-wizard-autostart.desktop`,
  et disponible ensuite comme entrée de menu applications pour une jonction
  manuelle ultérieure) : dialogues `kdialog` (déjà présent, fourni par KDE,
  pas de dépendance Python/Qt supplémentaire à faire vérifier sur les dépôts
  EL9). Ne se propose automatiquement qu'une seule fois par compte
  utilisateur local (marqueur `~/.config/almalinux-ad/wizard-done`, voir
  AD-JOIN-WIZARD.md pour pourquoi ce marqueur est par utilisateur et non
  machine-wide).
- **`/usr/libexec/almalinux-ad/ad-join-backend.py`** (privilégié, invoqué
  via `pkexec` depuis le wizard - mot de passe transmis par stdin, jamais
  en argv) : toute la logique realm/sssd/krb5/sudoers/SELinux, idempotente,
  appelable aussi en ligne de commande directe pour un dépannage manuel
  après coup.

## Différences RHEL/AlmaLinux vs le projet Arch de référence

Voir [AD-JOIN-WIZARD.md](AD-JOIN-WIZARD.md) pour le détail complet. Résumé :

| Sujet | Projet Arch (référence) | Ce projet (AlmaLinux) |
|---|---|---|
| PAM/NSS → sssd | édition manuelle (`system-auth`, bug `su` cassé) | `authselect select sssd with-mkhomedir --force` (officiel, couvre `su` correctement) |
| Home dir au premier login | `pam_mkhomedir.so` (AUR `oddjob` évité) | `oddjob-mkhomedir` officiel + `oddjobd.service` (c'est le mécanisme *documenté* RHEL pour `with-mkhomedir`) |
| Paquets AD | AUR-only (`realmd`/`adcli`), dépôt pacman local compilé | tous officiels BaseOS/AppStream, `dnf install` direct |
| SELinux | absent (Arch n'en a pas) | **enforcing par défaut** - `restorecon -Rv` après chaque écriture de fichier par le backend (voir AD-JOIN-WIZARD.md) |
| Contexte d'exécution de la jonction | `chroot()` Calamares (D-Bus absent, DNS cassé, hostname noyau du live) | système réellement démarré (aucun de ces trois problèmes) |
| GRUB | généré par un module Calamares (`grubcfg`/`bootloader`), piège BLS potentiel | généré nativement par Anaconda (`bootloader` kickstart), zéro custom |
| Journal systemd persistant | forcé explicitement (Arch, volatile par défaut) | forcé explicitement quand même par robustesse (ne pas supposer que RHEL le fait déjà) |
| mDNS/`.local` | `systemd-resolved` (`MulticastDNS=yes` par défaut du profil live) | pas de `systemd-resolved` actif par défaut ; source possible : `avahi-daemon` si présent - masqué par défaut en `%post` |
| Horloge concurrente | `systemd-timesyncd` + VMware Tools | `systemd-timesyncd` absent par défaut (chrony seul) ; VMware Tools (`open-vm-tools`) reste à surveiller si test VMware - synchro désactivée par défaut en `%post`, sans effet si absent |

## Ce qu'on ne personnalise pas (délibérément)

Plymouth, thème/branding GRUB2 (BLS géré nativement par Anaconda), SDDM par
défaut, branding KDE : tout reste strictement la valeur par défaut de la
distribution. Objectif : environnement professionnel sobre, pas un produit
de marque. Seule exception fonctionnelle (pas esthétique) : le fragment
`/etc/sddm.conf.d/` qui bascule SDDM en saisie libre du nom d'utilisateur
une fois une jonction AD faite (voir AD-JOIN-WIZARD.md) - un réglage de
comportement, pas de thème.
