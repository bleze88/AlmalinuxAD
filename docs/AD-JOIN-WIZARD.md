# Assistant de jonction Active Directory (premier login)

Contrepartie fonctionnelle du module Calamares `adjoinview`/`adjoinjob` du
projet frère [Compass Arch](https://github.com/bleze88/compassarch/blob/main/docs/AD-JOIN-MODULE.md), mais
repensée autour d'une différence structurelle : ici, tout tourne **sur le
système réellement installé et démarré** (vrai `systemd` PID 1, vrai bus
D-Bus système, NetworkManager actif), jamais dans un `chroot()`
d'installeur. Ce document explique ce qui change, ce qui reste identique,
et pourquoi - en particulier pour éviter de re-découvrir un par un des
pièges déjà rencontrés (et corrigés) sur le projet Arch.

## Deux fichiers, deux niveaux de privilège

- **`/usr/bin/almalinux-ad-join-wizard`**
  ([`packaging/.../SOURCES/ad-join-wizard.sh`](../packaging/almalinux-ad-firstboot-wizard/SOURCES/ad-join-wizard.sh)) :
  non privilégié, **un seul écran** (`zenity --forms` : domaine, nom de
  machine, compte admin, mot de passe, OU, groupe autorisé, groupe sudo),
  puis écran de confirmation récapitulatif (`kdialog --yesno`, qui
  fonctionne normalement). Remplace une première version à boîtes de
  dialogue séquentielles (une par champ) - retour direct d'un test en
  conditions réelles sur poste physique : avec une série de popups, il est
  facile de répondre au mauvais champ ou de valider par erreur, le
  formulaire groupé élimine ce risque.

  **`zenity`, pas `kdialog --forms`** : une toute première tentative de
  formulaire groupé utilisait `kdialog --forms` - confirmé **inexistant**
  sur cette version de kdialog (`kdialog-25.12.3`, ère KDE Frameworks 6) en
  conditions réelles sur poste physique (*"kdialog: Option inconnue
  'forms'."*), `--forms` étant un mode de l'ancien kdialog (KDE4/Plasma5)
  visiblement jamais reporté sur le paquet EPEL pour AlmaLinux 10. `zenity`
  (déjà présent dans l'image de façon transitive, `Requires: zenity` ajouté
  explicitement par sécurité) a un mode `--forms` mature et stable, avec
  champ mot de passe masqué natif (`--add-password`) - confirmé disponible
  via `zenity --help-forms` avant de l'adopter. Léger écart visuel (boîte
  GTK plutôt que native KDE) pour ce seul écran, acceptable vu la fiabilité
  - le reste de l'assistant reste en `kdialog`. Le mot de passe ne vit que
  dans une variable shell, jamais écrit sur disque ni passé en argument de
  commande
  (visible dans `/proc/*/cmdline`) - transmis au backend par **stdin**, à
  travers `pkexec` (qui préserve l'entrée standard de l'appelant).
- **`/usr/libexec/almalinux-ad/ad-join-backend.py`**
  ([`packaging/.../SOURCES/ad-join-backend.py`](../packaging/almalinux-ad-firstboot-wizard/SOURCES/ad-join-backend.py)) :
  privilégié (invoqué via `pkexec`, donc sous l'identité `root` après
  authentification standard de l'utilisateur - aucune règle polkit
  personnalisée nécessaire, le compte admin local créé pendant
  l'installation Anaconda appartient déjà au groupe `wheel`). Toute la
  logique realm/sssd/krb5/sudoers/SELinux. Idempotent et appelable
  directement en ligne de commande pour un dépannage manuel après coup
  (voir l'en-tête du script pour l'invocation exacte).

## Déclenchement au premier login (pas au premier boot)

- `etc/xdg/autostart/almalinux-ad-join-wizard-autostart.desktop` : lancé
  par KDE Plasma au premier login, appelle `ad-join-wizard-autostart.sh`.
- **Jamais pendant une session live** : ce lanceur vit dans le rootfs live
  lui-même (il doit y être pour arriver sur le système installé, copié tel
  quel par le paiement live d'Anaconda), donc KDE le déclenche aussi pour
  le compte utilisateur de la session live à son propre "premier login" -
  confirmé en conditions réelles (popup affiché par-dessus le "Welcome
  Center" du live, avant même toute installation). Corrigé en détectant
  `rd.live.image` dans `/proc/cmdline` (paramètre noyau standard posé par
  dracut-live sur tout boot live, absent une fois installé) : le script
  sort immédiatement si présent.
- **Ne se propose plus si la machine est déjà jointe à un domaine**
  (`realm list` non vide) - le signal qui compte vraiment, indépendamment
  du compte qui se connecte. Corrigé après un bug confirmé en conditions
  réelles : avec un marqueur par utilisateur (première version), chaque
  nouveau compte **AD** se connectant pour la première fois obtenait un
  `$HOME` flambant neuf (créé par `pam_oddjob_mkhomedir`) qui n'avait
  jamais vu le marqueur - l'invite "voulez-vous rejoindre un domaine ?"
  réapparaissait donc à chaque nouveau compte du domaine, ce qui n'a aucun
  sens une fois la machine déjà jointe.
- Marqueur **machine-wide** (`/var/lib/almalinux-ad/wizard-done`), pas par
  utilisateur : ce répertoire est créé au build avec le groupe `wheel` et
  le bit setgid (`install -d -m 2775 -o root -g wheel`, voir
  `build/02-customize-squashfs.sh`), pour que le compte admin local
  (membre de `wheel`) puisse y écrire sans `pkexec` - la même contrainte
  qui avait motivé un marqueur par utilisateur au départ (éviter un mot de
  passe demandé juste pour cliquer « Non ») reste respectée, avec cette
  fois une portée machine-wide correcte. Si le compte qui déclenche
  l'autostart n'est pas membre de `wheel`, l'écriture du marqueur échoue
  silencieusement (`|| true`) plutôt que de faire planter la session -
  dégradation acceptable (l'invite réapparaîtrait au login suivant) plutôt
  qu'un crash.
- Quel que soit le résultat (jonction réussie, échouée, ou refusée), le
  marqueur est posé et l'invite automatique ne revient plus - la jonction
  reste possible manuellement ensuite via l'entrée de menu applications
  « Rejoindre un domaine Active Directory »
  (`usr/share/applications/almalinux-ad-join-wizard.desktop`), qui appelle
  le même wizard sans condition de marqueur ni de vérification `realm list`.

## Ce qui disparaît par rapport au projet Arch (contexte chroot vs système réel)

Le module Calamares de référence tournait dans un `chroot()` pendant
l'installation (`libcalamares.utils.target_env_call`), un environnement
très différent d'un système réellement démarré. Trois pièges majeurs de ce
projet **ne s'appliquent structurellement plus ici** :

1. **`realm join --install=/` devient inutile.** Ce mode existe précisément
   pour opérer sans `realmd`/D-Bus (absents d'un `chroot()` sans vrai
   `systemd` PID 1). Sur un système démarré, `realmd` tourne normalement -
   `realm join` "nu" suffit et passe par son chemin normal/testé (dont ses
   propres hooks NetworkManager), plutôt que de le contourner sans raison.
2. **Pas de bricolage de hostname.** Le piège Arch venait de `chroot()` qui
   ne crée pas de namespace UTS séparé : le hostname NOYAU restait celui du
   média live tant qu'on ne le changeait pas explicitement via
   `socket.sethostname()`, indépendamment de `/etc/hostname` de la cible.
   Ici, le système a déjà démarré avec le bon hostname noyau (celui défini
   pendant l'installation Anaconda) avant même que l'utilisateur n'ouvre une
   session - `realm join`/`adcli` (qui utilisent `gethostname()`) voient
   donc directement la bonne valeur. `ad-join-backend.py` accepte quand
   même un `--computer-name` explicite (par défaut `$(hostname -s)` côté
   wizard) plutôt que de se fier implicitement au hostname noyau, par
   robustesse et pour permettre un nom d'ordinateur AD différent du
   hostname Linux si souhaité.
3. **Pas de réparation de `/etc/resolv.conf`.** Le piège Arch venait du
   `/etc/resolv.conf` du chroot cible pointant vers un stub
   `systemd-resolved` (`127.0.0.53`) jamais peuplé (aucun service démarré
   dans un simple `chroot()`). AlmaLinux n'active pas `systemd-resolved` par
   défaut (NetworkManager écrit `/etc/resolv.conf` directement), et de
   toute façon le système tourne réellement ici (NetworkManager actif,
   résolution DNS fonctionnelle comme sur n'importe quel poste allumé).

**Point de vigilance retenu malgré tout** : le principe général derrière
ces trois pièges - "tout ce qui dépend d'un service non démarré peut se
comporter différemment" - n'a plus de prise ici puisqu'il n'y a plus de
chroot. Mais si `realm discover <domaine>` échoue alors qu'un ping/`dig`
manuel réussit, vérifier d'abord l'état de `NetworkManager` et du profil de
connexion actif avant de chercher plus loin.

## Ce qui reste identique (comportements indépendants de l'environnement chroot/live)

Ces pièges viennent de `sssd`/`krb5`/`systemd`/`sudo`/`SDDM` eux-mêmes, pas
de la façon dont l'installeur s'exécute - ils s'appliquent donc tels quels
ici, implémentés dans `ad-join-backend.py` :

- **Renommage réel de la machine avant jonction** (`set_hostname()`,
  `hostnamectl set-hostname`) : `realm join --computer-name` ne fait que
  déclarer un nom à l'annuaire AD, ça n'a **aucun effet** sur le hostname
  Linux réel. Piège confirmé en conditions réelles : une installation dont
  le hostname n'avait pas été changé explicitement à l'étape réseau
  d'Anaconda héritait du hostname du média live (`localhost-live`, nom par
  défaut de dracut-live) - la machine se retrouvait joignable dans l'AD
  sous un nom ("ALMA") complètement différent de son hostname système réel
  (visible dans toute invite de terminal), source de confusion. Contexte
  d'exécution réel (D-Bus/`systemd-hostnamed` disponibles) : pas besoin du
  contournement `socket.sethostname()` du projet Arch (voir plus haut) -
  `hostnamectl` fonctionne ici normalement.
- **Synchro horloge avant jonction** (`sync_clock()`) : Kerberos est
  sensible au décalage d'horloge. `chrony` est déjà l'unique client NTP
  actif par défaut sur AlmaLinux (voir "Horloge" ci-dessous pour le détail
  du risque résiduel).
- **`[realms]`/`[domain_realm]` peuplés avec le nom de domaine, pas un
  contrôleur précis** (`ensure_dns_realm_discovery()` +
  `populate_krb5_realms()`) - **trois itérations successives après des
  tests en conditions réelles sur un AD d'entreprise à 8 contrôleurs de
  domaine** :
  1. Version initiale : figeait explicitement UN SEUL KDC (le premier
     trouvé via `dig SRV`) - point de panne unique confirmé dangereux (si
     ce contrôleur précis tombe, plus d'authentification).
  2. Corrigé en supprimant tout contenu de `[realms]`/`[domain_realm]`,
     ne gardant que `dns_lookup_realm=true`/`dns_lookup_kdc=true` dans
     `[libdefaults]` (découverte DNS SRV dynamique pure) - fonctionnellement
     correct, mais rejeté : l'administrateur veut des sections visibles et
     peuplées, pas vides.
  3. **Version actuelle** : `[realms]`/`[domain_realm]` peuplés avec le
     **nom de domaine lui-même** comme `kdc`/`admin_server`
     (`kdc = MonEntreprise.CH`), pas une liste de contrôleurs individuels.
     Confirmé par l'administrateur : ses 8 contrôleurs répondent tous sous
     ce même nom (répartition/DNS round-robin déjà géré côté AD - un ping
     répété sur ce nom répond depuis un contrôleur différent à chaque
     fois). Pas de résolution DNS SRV nécessaire : le nom de domaine tel
     que saisi/joint suffit, la redondance entre les 8 DC est déjà
     transparente à ce niveau. `dns_lookup_realm`/`dns_lookup_kdc=true`
     restent en place dans `[libdefaults]` en filet de sécurité
     complémentaire.

  **Piège annexe corrigé dans la foulée - le royaume Kerberos n'est pas
  toujours `domaine.upper()`** : la valeur utilisée comme clé dans
  `[realms]`/valeur dans `[domain_realm]` supposait au départ que le
  royaume Kerberos s'obtient en majusculant simplement le domaine saisi
  (points conservés, ex: "montferrini.local" -> "MONTFERRINI.LOCAL") -
  faux dans certaines entreprises, où le royaume réel ne suit pas le nom
  DNS à l'identique (ex: underscore plutôt que point,
  "DOMAINE_EXTENSION" au lieu de "DOMAINE.EXTENSION"). `realm join` a
  déjà écrit le vrai royaume dans l'en-tête `[domain/<royaume>]` de
  `sssd.conf` au moment où `populate_krb5_realms()` s'exécute - extrait
  via `find_actual_realm()` (fonction partagée, aussi utilisée par
  `fix_sssd_conf()` ci-dessous pour le même genre de piège) plutôt que
  recalculé en devinant.
- **`use_fully_qualified_names=False` / `case_sensitive=False`**
  (`fix_sssd_conf()`) : **le piège le plus retors du projet Arch**, détaillé
  ci-dessous, reproduit intégralement ici car il vient de
  `systemd`/`pam_systemd`, pas de la distribution.
- **`ldap_user_gecos = displayName`** (`fix_sssd_conf()`, nouveau par
  rapport au projet Arch) : `realm join` ne mappe **pas par défaut**
  l'attribut AD `displayName` ("Prénom Nom") vers le GECOS Unix - confirmé
  en conditions réelles, `getent passwd <compte>` renvoyait le CN brut de
  l'objet AD (souvent identique au `sAMAccountName`, ex: "MTF0001") au menu
  applications KDE au lieu du nom complet, y compris avec le Display Name
  correctement renseigné côté AD. Sans ce réglage explicite, sssd retombe
  sur le CN de l'objet plutôt que sur `displayName`.
  **Piège corrigé dans `fix_sssd_conf()` lui-même** : la fonction
  cherchait la section `[domain/{}]".format(domain.upper())` en supposant
  que `realm join` écrit toujours ce nom en MAJUSCULES strictes - faux
  avec un domaine à casse mixte (ex: `MonEntreprise.CH`), confirmé en
  conditions réelles sur poste physique (aucun des trois réglages
  ci-dessus n'était appliqué, la section n'étant jamais reconnue). Fix :
  recherche insensible à la casse contre le domaine effectivement joint,
  avec repli sur la première section `[domain/...]` rencontrée si même ça
  ne correspond pas.
- **Restriction de connexion, plusieurs groupes possibles**
  (`restrict_login()`) : `realm deny --all` + `realm permit --groups
  <court1> <court2> ...` (`realm permit --groups` accepte nativement
  plusieurs noms de groupes) - sans ça, tout compte du domaine peut se
  connecter une fois la jonction faite. Le champ du wizard accepte
  plusieurs groupes séparés par des virgules et/ou des espaces
  (`split_groups()`), demandé après un test réel où un seul groupe ne
  couvrait pas les besoins d'accès de l'entreprise.
- **Sudo par groupe(s) AD** (`grant_sudo()`) : fragment
  `/etc/sudoers.d/90-ad-admins`, **une ligne par groupe** (plutôt qu'une
  liste sur une seule ligne - plus simple à relire, évite tout piège de
  virgule dans la syntaxe `User_List` de sudoers), validé par `visudo -cf`
  sur le fichier **entier** **avant** activation - un seul nom de groupe
  invalide fait échouer tout le fragment plutôt que d'activer partiellement
  des droits.
- **SDDM en saisie libre** (`switch_sddm_to_free_text()`) : `HideUsers` +
  `RememberLastUser=false` dans une **seule** section `[Users]` de
  `/etc/sddm.conf.d/90-hide-local-user.conf` - comportement du composant
  SDDM lui-même, identique quelle que soit la distribution.

### Écran noir après connexion AD réussie (`use_fully_qualified_names`)

Reconstitué en conditions réelles sur le projet Arch, cause racine
confirmée dans le code source de `pam_systemd` : `userdbctl`/`pam_systemd`
comparent, **casse comprise**, le nom saisi au login au nom canonique
retourné par NSS/sssd, et refusent l'enregistrement au moindre écart
(`io.systemd.UserDatabase.ConflictingRecordFound`). `pam_systemd` traite
alors l'échec comme `PAM_USER_UNKNOWN` et ne crée **pas**
`/run/user/<uid>` - d'où un écran noir juste après une authentification
SDDM pourtant réussie (`kwin_wayland`: *"Could not create wayland
socket"*). `case_sensitive=False` seul ne suffit pas (la vérification de
casse vient de `systemd`, pas de `sssd`) ; le vrai fix est
`use_fully_qualified_names=False`, qui élimine l'ambiguïté source du
conflit en ne laissant qu'une seule forme de nom possible. Ce comportement
appartient à `systemd`/`pam_systemd`, indépendant de la distribution - **à
reconfirmer avec la version de `systemd` livrée par AlmaLinux 10** au premier
test réel, mais très probablement identique.

**Piège d'application, reproduit dans `fix_sssd_conf()`** : `realm join`
génère `use_fully_qualified_names=True` par défaut ; une clé ini dupliquée
garde sa **dernière** occurrence, donc un simple ajout en tête de section
serait écrasé par le `True` d'origine plus bas dans le fichier. Le code
retire donc toute occurrence existante des deux clés avant de réinjecter
la sienne une seule fois, juste après l'en-tête de section.

**Conséquence sur le nom de groupe sudo** : avec
`use_fully_qualified_names=False`, c'est le nom **court** du groupe qui
résout via `getent group` (résolution NSS, utilisée par `sudo`/`visudo`
via `getgrnam()`) - pas la forme qualifiée `groupe@domaine`. `grant_sudo()`
retire explicitement tout suffixe `@domaine` saisi par erreur.

### Horloge : chrony seul, mais VMware Tools reste à surveiller

Contrairement à Arch, AlmaLinux n'active pas `systemd-timesyncd` par
défaut (`chrony` est l'unique client NTP dès l'installation) - la classe de
bug "deux services de synchro d'horloge se marchent dessus, `sssd_be`
plante en boucle tué par son propre watchdog" perd donc une de ses deux
causes connues. La seconde (**VMware Tools**, `open-vm-tools`) reste
d'actualité si le test se fait sur VMware : `build/02-customize-squashfs.sh` écrit
préventivement `/etc/vmware-tools/tools.conf` (`[timesync] disable =
TRUE`), sans effet tant que le paquet n'est pas installé. Si ce symptôme
réapparaît (`chronyc tracking` ou les logs de `chronyd` signalant *"System
clock interference detected"*, `journalctl -u sssd` montrant `sssd_be`
tué par son propre watchdog toutes les ~30s), chercher une source de
synchronisation d'horloge concurrente avant toute autre piste.

### mDNS et domaines `.local`

De nombreux domaines AD historiques utilisent le suffixe `.local`
(convention héritée de Windows Server 2000/2003), réservé au mDNS par la
RFC 6762. Le piège Arch venait spécifiquement de `systemd-resolved`
(`MulticastDNS=yes` par défaut du profil live), absent d'AlmaLinux par
défaut - mais **`avahi-daemon`** (souvent présent pour la découverte
réseau/imprimantes) fait aussi du mDNS et peut causer le même
ralentissement. `build/02-customize-squashfs.sh` le masque par défaut en contexte
professionnel (`systemctl mask avahi-daemon.service avahi-daemon.socket`,
best-effort, sans erreur si le paquet est absent). Si un domaine cible en
`.local` semble anormalement lent à joindre malgré ça, vérifier
`systemctl status avahi-daemon` en premier.

## SELinux : nouveau par rapport au projet Arch

AlmaLinux tourne avec SELinux **enforcing** par défaut (absent d'Arch).
`sssd`/`realmd`/`adcli`/`samba` sont couverts par les policies SELinux
upstream de Red Hat (cas d'usage RHEL officiel et documenté) - le
comportement à l'exécution de `realm join` lui-même ne devrait poser aucun
problème. Le vrai risque est ailleurs : tout fichier réécrit par
`ad-join-backend.py` en dehors du mécanisme RPM normal (`krb5.conf`,
`sssd.conf`, le fragment `sudoers.d`, le fragment `sddm.conf.d`) peut se
retrouver avec un contexte SELinux incorrect. `restorecon()`
(voir en tête de `ad-join-backend.py`) est appelé après **chaque** écriture
de ce type, sans exception - un réflexe systématique plutôt que de deviner
au cas par cas quel contexte serait correct.

**À vérifier en conditions réelles avant mise en production** (voir aussi
[BUILD.md](BUILD.md)) : tester d'abord en mode `Permissive`
(`setenforce 0`) pour confirmer qu'aucun `avc: denied` n'apparaît
(`ausearch -m avc -ts recent`) pendant un cycle complet (jonction,
connexion SDDM avec un compte AD, `sudo` avec le groupe AD configuré), puis
repasser en `Enforcing` (`setenforce 1`, qui est déjà l'état par défaut
d'AlmaLinux) avant de considérer le sujet réglé.

## PAM/NSS : `authselect`, pas d'édition manuelle

Sur Arch (pas d'`authselect`), le câblage de `sssd` dans NSS/PAM s'était
fait à la main (édition de `nsswitch.conf`, `pam.d/system-login`), avec un
bug découvert tardivement : `/etc/pam.d/su` (hérité de `pambase`) ne
routait que la pile "password" vers `system-auth`, pas
`auth`/`account`/`session` - `su` échouait silencieusement vers un compte
AD, sans aucune trace dans les logs `sssd`, alors que `sudo` fonctionnait.

`authselect select sssd with-mkhomedir --force` (dans `build/02-customize-squashfs.sh`,
`%post`, appliqué une fois pour toutes à l'installation - indépendant de
la jonction AD elle-même, qui peut être refaite/reconfigurée sans jamais
retoucher ce câblage) reconfigure d'un coup NSS et **tous** les fichiers
PAM concernés, dont `su` correctement. Ce choix élimine par construction
la classe de bug "`su` ne consulte pas `sssd`" - à vérifier tout de même
après un premier test réel avec `authselect current` et un `su -
<compte_ad>` explicite.

**Home directory au premier login : `oddjob-mkhomedir`, pas
`pam_mkhomedir.so`.** Sur Arch, `oddjob`/`oddjob-mkhomedir` étaient
AUR-only, d'où le choix du module PAM générique `pam_mkhomedir.so` (fourni
par le paquet `pam` de base) plutôt que de compiler un paquet AUR de plus
pour un gain nul. Sur AlmaLinux, `oddjob-mkhomedir` est **officiel**
(BaseOS/AppStream) et c'est justement le mécanisme que documente
`authselect --with-mkhomedir` (il insère `pam_oddjob_mkhomedir.so`, qui
nécessite le démon `oddjobd` actif - `build/02-customize-squashfs.sh` l'active via
`systemctl enable oddjobd.service`). Suivre le mécanisme officiel plutôt
que de reproduire le contournement Arch, qui n'a plus lieu d'être ici.

**Chemin du home directory : `/home/%D/%U`, comme sur Arch.** Sans
configuration explicite, `realmd` utilise son propre défaut
(`/home/%u@%d`, ex: `/home/mtf0001@MONTFERRINI.LOCAL`) - moins lisible que
la convention du projet Arch (`/home/%D/%U`, ex:
`/home/MONTFERRINI.LOCAL/mtf0001`, `%D` = domaine complet). Différence
constatée en conditions réelles entre les deux projets, pas une
particularité d'AlmaLinux : le projet Arch avait ce réglage dans un
`/etc/realmd.conf` statique fourni dès le live (overlay `airootfs/`, avant
`pacstrap`) ; ici, `realmd` n'étant installé qu'au moment du build du
squashfs (pas un paquet de base du live officiel AlmaLinux), le fichier
`/etc/realmd.conf` (`[users]` `default-home = /home/%D/%U` /
`default-shell = /bin/bash`) est écrit par `build/02-customize-squashfs.sh`
juste après l'installation de `realmd` - `realmd` lit ce fichier au moment
de `realm join` (donc au premier login, via l'assistant) pour décider du
`fallback_homedir` qu'il écrit dans `sssd.conf` ; le réglage doit donc être
en place dès le build, pas seulement documenté ou appliqué après coup.

**Identification du poste dans la console AD : `os-name`/`os-version`.**
Sans ce réglage, l'objet ordinateur créé par `realm join` a ses attributs
`operatingSystem`/`operatingSystemVersion` vides (onglet "Operating
System" d'Utilisateurs et ordinateurs Active Directory - vide alors qu'un
poste Windows y affiche normalement "Windows 11 Entreprise"/"10.0
(26200)"). `/etc/realmd.conf` (`[active-directory]` `os-name = AlmaLinux`
/ `os-version = ${ALMALINUX_MAJOR}` - suit `distro.conf`, pas codé en dur)
comble ça, `adcli`/`realmd` transmettent ces valeurs à l'AD au moment de la
jonction.

## Diagnostiquer un échec

`ad-join-backend.py` journalise sur **stderr** (visible dans la sortie
capturée par `pkexec` puis affichée par le wizard en cas d'échec, et dans
`journalctl` si invoqué comme partie d'un service systemd). Contrairement
au module Calamares de référence (dont le log vivait sur le live, en RAM,
perdu au redémarrage), ici le journal systemd est **persistant** par
défaut (voir `build/02-customize-squashfs.sh`) : après un échec, `journalctl` reste
consultable après un redémarrage. Une fois la jonction faite, l'état réel
se vérifie directement : `realm list` (domaines rejoints), `journalctl -u
sssd`, et `/var/log/sssd/*.log` (le plus détaillé pour les problèmes
Kerberos/LDAP spécifiquement).

## Étendre / adapter

- **Rendre la jonction bloquante** : le wizard affiche déjà l'échec en
  détail (sortie complète de `pkexec`/`ad-join-backend.py`) plutôt que de
  l'avaler silencieusement - pas de changement de code nécessaire pour ça,
  contrairement au module Calamares de référence où c'était un choix `job`
  explicite (`return None` vs échec bloquant).
- **Ajouter un champ** : ajouter l'argument `argparse` correspondant dans
  `ad-join-backend.py`, le champ `kdialog --inputbox` correspondant dans
  `ad-join-wizard.sh`, et le passer dans le tableau `args=(...)`.
- **Jonction en ligne de commande, sans le wizard** : voir l'en-tête de
  `ad-join-backend.py` pour l'invocation directe (utile pour un déploiement
  scripté/MDM plutôt qu'une saisie manuelle au premier login).
