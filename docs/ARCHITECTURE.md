# Architecture

## Décision : Live ISO KDE officielle AlmaLinux + Anaconda, pas de Calamares

Point tranché en premier, avant tout code (voir aussi le fil de discussion
d'origine, résumé ici pour mémoire du dépôt - **corrigé une fois en cours
de route**, voir "Correction de trajectoire" ci-dessous, qui explique
pourquoi la version ci-dessous diffère du tout premier scaffold).

**Constat de départ.** Contrairement à Arch (archiso+Calamares, très mature -
voir le projet frère [Compass Arch](../../Linux)) et à Ubuntu/Debian
(casper+Calamares, KDE Neon...), il n'existe **aucun précédent connu**
combinant live-ISO RHEL/AlmaLinux + **Calamares** : Fedora (qui maintient
`lorax`/`livemedia-creator`, le pipeline live officiel de la famille RHEL)
n'utilise pas non plus Calamares pour ses spins KDE/Kinoite (Anaconda/WebUI).
Personne, pas même AlmaLinux en amont, n'a marié ce pipeline à Calamares.

**Décision retenue : partir de la Live ISO KDE officielle et maintenue
d'AlmaLinux, garder Anaconda comme installeur (lancé depuis la session
live), et déplacer la jonction AD du temps d'installation vers un
assistant graphique de premier login** plutôt qu'un module Calamares -
voir "Assistant AD au premier login" ci-dessous.

## Correction de trajectoire (à lire avant le reste)

La toute première version de ce document recommandait un **respin du DVD
classique + Kickstart**, en écartant tout live-boot au motif qu'"aucun
précédent connu" de live-ISO RHEL/AlmaLinux n'existait. **Cette affirmation
était fausse** - découvert après coup en inspectant
`https://repo.almalinux.org/almalinux/10/live/x86_64/` : AlmaLinux publie
et maintient officiellement des Live ISO (KDE, GNOME, XFCE, MATE) via le
projet [AlmaLinux/sig-livemedia](https://github.com/AlmaLinux/sig-livemedia)
(`lorax` + `lorax-templates-almalinux` + `livemedia-creator`). Le pipeline
existe bel et bien et est bien plus mature que supposé - simplement, il
n'a jamais été marié à **Calamares** (l'installeur embarqué reste Anaconda,
comme confirmé par la documentation de `sig-livemedia`), ce qui ne change
rien à la décision Calamares-vs-Anaconda déjà actée, mais invalidait à tort
l'abandon du live-boot.

**Pourquoi ne pas reproduire le pipeline `sig-livemedia` nous-mêmes pour
autant** : `livemedia-creator` pilote une vraie VM (`virt-install`/KVM)
pour exécuter le kickstart de construction - une couche de virtualisation
imbriquée fragile dans une pile Docker-dans-colima-dans-VZ (macOS/Apple
Silicon), le risque concret que le tout premier scaffold cherchait déjà à
éviter. **Solution retenue : partir de l'ISO déjà construite** par
l'infrastructure AlmaLinux (téléchargée telle quelle,
`build/00-fetch-iso.sh`) et la personnaliser par **manipulation directe du
squashfs** (`unsquashfs`/`mksquashfs` + `chroot` + `dnf --installroot`,
voir `build/02-customize-squashfs.sh`) - aucune VM/KVM nécessaire, juste
des opérations fichier et un éventuel `mount -o loop` (simple
fonctionnalité noyau, sans rapport avec la virtualisation imbriquée).

Version AlmaLinux ciblée corrigée au passage : **10** (dernière majeure
stable), pas 9 - la version 9 avait été prise par défaut sans vérifier que
la 10 existait déjà.

## Vue d'ensemble

```
                    packaging/almalinux-ad-firstboot-wizard/
                    (spec RPM : wizard kdialog + backend Python + .desktop)
                                  │ rpmbuild
                                  ▼
                    build/01-build-rpm.sh → RPM dans un mini-dépôt dnf local
                                  │
build/00-fetch-iso.sh             │
(télécharge la Live ISO KDE       │
 officielle AlmaLinux, vérifie    │
 son empreinte SHA256)            │
                  │                │
                  ▼                ▼
              build/02-customize-squashfs.sh
              (extrait le squashfs live, dnf install --installroot les
               paquets AD + notre RPM DIRECTEMENT dans le rootfs live,
               authselect/oddjobd/journald/avahi/horloge, réempaquette
               squashfs + xorriso replay)
                                  │
                                  ▼
                         build/out/*.iso
                                  │  boot live KDE (session d'essai) ->
                                  │  icône "Install to Hard Drive" -> Anaconda
                                  │  GUI normal (partitionnement, compte
                                  │  utilisateur, réseau... interactif,
                                  │  paiement de type "copie du rootfs live",
                                  │  pas de %packages/%post à ce stade)
                                  ▼
                    premier redémarrage, premier login Plasma
                                  │
                                  ▼
        /etc/xdg/autostart/almalinux-ad-join-wizard-autostart.desktop
        (une seule fois - voir "Assistant AD au premier login")
```

## KDE Plasma vient entièrement d'EPEL (pas de BaseOS/AppStream/CRB)

Découvert en vérifiant la disponibilité de `kdialog` (requis par notre
assistant AD) avant de lancer le tout premier build réel : RHEL ne
"supporte" officiellement que GNOME comme environnement de bureau - **KDE
Plasma dans son intégralité (`plasma-desktop`, `plasma-workspace`, `sddm`,
`kdialog`...) est fourni par EPEL**, pas par BaseOS/AppStream/CRB (vérifié
par `dnf repoquery --qf '%{repoid}' plasma-desktop` -> `epel`, sur une image
`almalinux:10` vierge). La Live ISO KDE officielle a donc forcément EPEL
déjà activé dans son rootfs (c'est de là que vient KDE lui-même) -
`build/02-customize-squashfs.sh` le vérifie avant d'installer `kdialog` via
notre RPM, avec un filet de sécurité (installation d'`epel-release`) si ce
n'était pas le cas. Conséquence pratique à garder en tête pour toute
personnalisation future : **ne jamais désactiver EPEL** sur ce système, ce
n'est pas un dépôt optionnel ici, KDE en dépend structurellement.

## Pourquoi personnaliser le squashfs plutôt qu'un kickstart %post

**Différence structurelle importante avec l'ancienne approche DVD+Kickstart**
(abandonnée) : l'installeur Anaconda lancé depuis une session live AlmaLinux
("Install to Hard Drive") **copie le rootfs live sur le disque cible**
(paiement de type "image", conceptuellement proche de l'`unpackfs`
d'archiso) - il ne réinstalle **pas** de paquets depuis un dépôt au moment
de l'installation, et n'exécute donc **aucun** `%packages`/`%post` de
kickstart pour ce mode. Tout ce qu'on veut voir sur le système installé
(paquets AD, notre assistant RPM, câblage `authselect`, `oddjobd` actif,
journal persistant, `avahi`/VMware Tools désactivés) doit donc être préparé
**dans le rootfs live lui-même**, avant de reconstruire l'ISO - d'où
`build/02-customize-squashfs.sh` plutôt qu'un `kickstart/ks.cfg` (retiré du
dépôt, il n'aurait plus aucun effet avec ce mode d'installation).

**Point de vigilance retenu** (même famille de piège que le projet Arch,
"artefacts du live copiés tel quel sur la cible") : puisque le rootfs live
est copié tel quel à l'installation, tout réglage propre à la session live
elle-même (compte `liveuser` avec autologin, sudo sans mot de passe pour la
démo) se retrouverait aussi sur le système installé s'il n'était pas géré.
**Ce cas précis est cependant déjà résolu par Anaconda lui-même** : le
paiement "live" d'Anaconda est le mécanisme qu'utilise Fedora Workstation
Live à grande échelle depuis des années, et son assistant graphique
redemande explicitement un compte utilisateur/mot de passe à l'installation
(le compte live n'est pas conservé tel quel) - un point à **confirmer tout
de même lors du premier test réel** (voir docs/BUILD.md) plutôt qu'à
supposer aveuglément, mais qui ne nécessite a priori aucun script de
nettoyage custom de notre part, contrairement au projet Arch (où c'est
`mkarchiso`/`unpackfs`, un mécanisme différent et moins abouti sur ce
point précis, qui avait exigé un nettoyage manuel).

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
distribution ou de l'environnement chroot/live) : synchro horloge avant
jonction, figer le KDC via `dig SRV` dans `krb5.conf`, forcer
`use_fully_qualified_names=False`/`case_sensitive=False` dans `sssd.conf`
(bug `pam_systemd`/`ConflictingRecordFound`), restriction
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
  EL10). Ne se propose automatiquement qu'une seule fois par compte
  utilisateur local (marqueur `~/.config/almalinux-ad/wizard-done`, voir
  AD-JOIN-WIZARD.md pour pourquoi ce marqueur est par utilisateur et non
  machine-wide).
- **`/usr/libexec/almalinux-ad/ad-join-backend.py`** (privilégié, invoqué
  via `pkexec` depuis le wizard - mot de passe transmis par stdin, jamais
  en argv) : toute la logique realm/sssd/krb5/sudoers/SELinux, idempotente,
  appelable aussi en ligne de commande directe pour un dépannage manuel
  après coup.

Ces deux fichiers, ainsi que le câblage `authselect`/`oddjobd`/journald/
avahi/horloge, sont désormais installés **dans le rootfs live** par
`build/02-customize-squashfs.sh` (via notre RPM
`almalinux-ad-firstboot-wizard`) plutôt que par un `%post` de kickstart -
voir la section précédente pour pourquoi ce déplacement était nécessaire.

## Différences RHEL/AlmaLinux vs le projet Arch de référence

Voir [AD-JOIN-WIZARD.md](AD-JOIN-WIZARD.md) pour le détail complet. Résumé :

| Sujet | Projet Arch (référence) | Ce projet (AlmaLinux) |
|---|---|---|
| PAM/NSS → sssd | édition manuelle (`system-auth`, bug `su` cassé) | `authselect select sssd with-mkhomedir --force` (officiel, couvre `su` correctement) |
| Home dir au premier login | `pam_mkhomedir.so` (AUR `oddjob` évité) | `oddjob-mkhomedir` officiel + `oddjobd.service` (c'est le mécanisme *documenté* RHEL pour `with-mkhomedir`) |
| Paquets AD | AUR-only (`realmd`/`adcli`), dépôt pacman local compilé | tous officiels BaseOS/AppStream, `dnf install` direct |
| SELinux | absent (Arch n'en a pas) | **enforcing par défaut** - `restorecon -Rv` après chaque écriture de fichier par le backend (voir AD-JOIN-WIZARD.md) |
| Contexte d'exécution de la jonction | `chroot()` Calamares (D-Bus absent, DNS cassé, hostname noyau du live) | système réellement démarré (aucun de ces trois problèmes) |
| Où les paquets/réglages custom sont préparés | overlay `airootfs/` + `pacstrap`, copié par `unpackfs` | rootfs du squashfs live personnalisé directement (`chroot` + `dnf --installroot`), copié par le paiement live d'Anaconda - même principe, outillage différent |
| GRUB | généré par un module Calamares (`grubcfg`/`bootloader`), piège BLS potentiel | généré nativement par Anaconda, zéro custom |
| Journal systemd persistant | forcé explicitement (Arch, volatile par défaut) | forcé explicitement quand même par robustesse (ne pas supposer que RHEL le fait déjà) |
| mDNS/`.local` | `systemd-resolved` (`MulticastDNS=yes` par défaut du profil live) | pas de `systemd-resolved` actif par défaut ; source possible : `avahi-daemon` si présent - masqué par défaut |
| Horloge concurrente | `systemd-timesyncd` + VMware Tools | `systemd-timesyncd` absent par défaut (chrony seul) ; VMware Tools (`open-vm-tools`) reste à surveiller si test VMware - synchro désactivée par défaut, sans effet si absent |

## Ce qu'on ne personnalise pas (délibérément)

Plymouth, thème/branding GRUB2 (BLS géré nativement par Anaconda), SDDM par
défaut, branding KDE : tout reste strictement la valeur par défaut de la
distribution (celle de la Live ISO KDE officielle AlmaLinux, elle-même déjà
sobre). Objectif : environnement professionnel sobre, pas un produit de
marque. Seule exception fonctionnelle (pas esthétique) : le fragment
`/etc/sddm.conf.d/` qui bascule SDDM en saisie libre du nom d'utilisateur
une fois une jonction AD faite (voir AD-JOIN-WIZARD.md) - un réglage de
comportement, pas de thème.
