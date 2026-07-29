#!/usr/bin/env python3
"""Rejoint un domaine Active Directory sur un système AlmaLinux déjà installé et démarré.

Contrepartie du job Calamares "adjoinjob" du projet frère Compass Arch (Arch
Linux), mais tourne ici sur le système RÉEL (vrai systemd PID 1, vrai bus
D-Bus, NetworkManager actif) plutôt que dans un chroot() d'installeur - voir
docs/AD-JOIN-WIZARD.md du dépôt pour le détail de ce qui change et pourquoi.

Appelé par ad-join-wizard.sh via `pkexec` (mot de passe admin transmis par
stdin, jamais en argv, jamais écrit sur disque). Idempotent et utilisable
aussi en ligne de commande directe pour un dépannage manuel :

    printf '%s' 'MotDePasse' | sudo ad-join-backend.py \\
        --domain example.corp --admin-user Administrator \\
        --computer-name $(hostname -s) \\
        [--ou 'OU=Postes,DC=example,DC=corp'] \\
        [--allowed-group g_linux] [--sudo-group g_admins_linux]

Best-effort par conception : un échec de jonction n'est pas masqué (code de
sortie non-nul, message clair), mais chaque étape *après* la jonction
elle-même (krb5.conf, sssd.conf, restriction de groupe, sudo, SDDM) est
individuellement best-effort - un échec sur l'une n'empêche pas les
suivantes, il est seulement journalisé sur stderr.
"""

import argparse
import subprocess
import sys


def log(msg):
    print("[ad-join-backend] {}".format(msg), file=sys.stderr, flush=True)


def run(cmd, input_text=None, timeout=60, check=True):
    result = subprocess.run(
        cmd,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, cmd, output=result.stdout, stderr=result.stderr
        )
    return result


def restorecon(path):
    """Corrige le contexte SELinux d'un fichier/dossier fraîchement écrit par ce script.

    SELinux est enforcing par défaut sur AlmaLinux (absent du projet Arch de
    référence). Un fichier réécrit par un script tiers plutôt que par un
    paquet RPM peut se retrouver avec un contexte hérité du répertoire
    parent (ou `unlabeled_t`) au lieu du contexte attendu par la policy
    (ex: `sssd_conf_t` pour sssd.conf) - appeler `restorecon -Rv` juste
    après écriture élimine cette classe de bug par construction, sans avoir
    à deviner le contexte correct à la main. Best-effort : `restorecon` est
    fourni par `policycoreutils`, présent par défaut sur AlmaLinux ; si
    SELinux est désactivé (`disabled`), la commande existe toujours mais ne
    fait rien d'utile - sans danger dans les deux cas.
    """
    try:
        result = run(["restorecon", "-Rv", path], check=False)
        if result.stdout.strip():
            log("restorecon: {}".format(result.stdout.strip()))
    except (OSError, subprocess.TimeoutExpired) as exc:
        log("restorecon a échoué sur {} ({}) - continue quand même.".format(path, exc))


def sync_clock():
    # Kerberos est sensible au décalage d'horloge (voir docs/AD-JOIN-WIZARD.md
    # pour l'historique des plantages sssd_be liés à une horloge instable).
    # chrony est déjà le seul client NTP actif par défaut sur AlmaLinux
    # (pas de systemd-timesyncd concurrent, contrairement à Arch) ; on
    # déclenche juste une synchro ponctuelle avant la jonction.
    try:
        run(["chronyc", "-a", "makestep"], timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        log("synchro horloge best-effort échouée ({}) - on continue quand même.".format(exc))


def set_hostname(computer_name):
    """Renomme réellement la machine (pas seulement l'objet AD créé par realm join).

    `realm join --computer-name` ne fait que déclarer un nom à l'annuaire -
    ça n'a aucun effet sur le hostname Linux réel. Confirmé en conditions
    réelles : une installation dont le hostname n'a pas été changé
    explicitement à l'étape réseau d'Anaconda hérite du hostname du média
    live ("localhost-live", nom par défaut de dracut-live) - la machine se
    retrouvait donc joignable dans l'AD sous un nom ("ALMA") complètement
    différent de son hostname système réel, source de confusion (et
    potentiellement de SPN Kerberos incohérents avec le hostname réel).
    `hostnamectl set-hostname` fonctionne normalement ici (contrairement au
    piège équivalent du projet Arch : ce script tourne sur un système
    réellement démarré, D-Bus/systemd-hostnamed sont disponibles - pas le
    `chroot()` d'installeur qui avait forcé l'usage de
    `socket.sethostname()` là-bas). Fait AVANT la jonction elle-même,
    inconditionnellement : même si `realm join` échoue ensuite, un hostname
    cohérent reste un gain en soi. Persisté (/etc/hostname), un
    redémarrage ou une nouvelle session reste nécessaire pour que
    l'affichage KDE (invite de terminal déjà ouverte, etc.) se mette à jour
    partout.
    """
    try:
        run(["hostnamectl", "set-hostname", computer_name])
        log("hostname système renommé en '{}'.".format(computer_name))
    except subprocess.CalledProcessError as exc:
        log("échec du renommage du hostname système ({}) - on continue quand même.".format(exc.stderr))


def join_domain(domain, admin_user, computer_name, ou, password):
    cmd = ["realm", "join", "--user", admin_user, "--computer-name", computer_name, "--verbose"]
    if ou:
        cmd += ["--computer-ou", ou]
    cmd.append(domain)
    log("exécution : {}".format(" ".join(cmd)))
    try:
        result = run(cmd, input_text=password + "\n", timeout=180)
    except subprocess.CalledProcessError as exc:
        log("échec de 'realm join' :\n{}".format(exc.stderr or exc.output))
        raise
    log("sortie de realm join --verbose :\n{}".format(result.stdout))
    run(["systemctl", "enable", "--now", "sssd.service"], check=False)


def ensure_dns_realm_discovery():
    """Force dns_lookup_realm=true / dns_lookup_kdc=true dans [libdefaults], sans jamais figer un KDC précis.

    Version précédente de cette fonction : figeait explicitement UN SEUL
    KDC (celui répondu en premier par `dig SRV`) dans `[realms]`/
    `[domain_realm]` de krb5.conf. Erreur de conception signalée après un
    test en conditions réelles sur un AD d'entreprise avec **8 contrôleurs
    de domaine** : figer un seul hostname en dur crée un point de panne
    unique - si CE contrôleur précis tombe (maintenance, panne...), plus
    aucune authentification Kerberos n'est possible, alors que Kerberos
    sait nativement basculer entre tous les contrôleurs disponibles via
    découverte DNS SRV (`_kerberos._tcp.<royaume>`), c'est justement fait
    pour ça. Le raisonnement d'origine ("réduire la dépendance à une
    découverte DNS répétée") avait du sens dans un labo à un seul
    contrôleur de test, pas dans un environnement d'entreprise avec
    plusieurs DC - la robustesse attendue est exactement l'inverse : ne
    JAMAIS coder en dur un contrôleur précis, laisser Kerberos interroger
    DNS à chaque fois pour profiter automatiquement de tous les DC
    disponibles (et de leur éventuelle redondance géographique/site AD).

    `realm join` positionne normalement déjà `dns_lookup_realm`/
    `dns_lookup_kdc` à `true` par défaut, mais on le vérifie et le force
    explicitement plutôt que de le supposer - même logique que les autres
    réglages de ce fichier (ne jamais deviner un défaut, le garantir).
    """
    try:
        with open("/etc/krb5.conf") as f:
            conf = f.read()
    except OSError as exc:
        log("impossible de lire /etc/krb5.conf ({}), réglages non appliqués.".format(exc))
        return

    header = "[libdefaults]"
    in_section = False
    filtered_lines = []
    for line in conf.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            in_section = stripped == header
            filtered_lines.append(line)
            continue
        if in_section and stripped.split("=", 1)[0].strip() in ("dns_lookup_realm", "dns_lookup_kdc"):
            continue
        filtered_lines.append(line)

    if header not in [l.strip() for l in filtered_lines]:
        # Pas de section [libdefaults] du tout (template inhabituel) - en
        # ajouter une en tête plutôt que de renoncer.
        filtered_lines = [header] + filtered_lines

    final_lines = []
    for line in filtered_lines:
        final_lines.append(line)
        if line.strip() == header:
            final_lines.append("    dns_lookup_realm = true")
            final_lines.append("    dns_lookup_kdc = true")
    new_conf = "\n".join(final_lines) + "\n"

    with open("/etc/krb5.conf", "w") as f:
        f.write(new_conf)
    restorecon("/etc/krb5.conf")
    log("dns_lookup_realm=true / dns_lookup_kdc=true garantis dans krb5.conf (aucun KDC figé en dur).")


def fix_sssd_conf(domain):
    """Force use_fully_qualified_names=False, case_sensitive=False, ldap_user_gecos=displayName.

    `realm join` génère par défaut use_fully_qualified_names=True dans la
    section [domain/<REALM>]. Comportement de systemd/pam_systemd (donc
    indépendant de la distribution - confirmé en conditions réelles sur le
    projet Arch de référence, très probablement identique sur la version de
    systemd livrée par AlmaLinux 10) : userdbctl/pam_systemd comparent, casse
    comprise, le nom saisi au login au nom canonique NSS/sssd, et
    refusent l'enregistrement au moindre écart
    (io.systemd.UserDatabase.ConflictingRecordFound) - pam_systemd traite
    ça comme PAM_USER_UNKNOWN et ne crée PAS /run/user/<uid>, d'où un écran
    noir juste après une authentification SDDM pourtant réussie
    (kwin_wayland: "Could not create wayland socket"). case_sensitive=False
    seul ne suffit pas, la vérification de casse vient de systemd, pas de
    sssd. Voir docs/AD-JOIN-WIZARD.md pour la reconstitution complète.

    Troisième réglage dans le même lot, sans rapport avec le piège
    ci-dessus mais touchant la même section : `realm join` ne mappe PAR
    DÉFAUT PAS l'attribut AD `displayName` ("Christophe Montferrini") vers
    le GECOS Unix - confirmé en conditions réelles, `getent passwd
    <compte>` renvoyait le CN brut de l'objet AD (souvent identique au
    sAMAccountName, ex: "MTF0001") au lieu du nom complet, y compris avec
    le Display Name correctement renseigné côté AD. `ldap_user_gecos =
    displayName` force explicitement ce mapping - sans lui, le menu
    applications KDE (et tout autre endroit lisant le GECOS) affiche
    l'identifiant du compte plutôt que "Prénom Nom".

    Toute occurrence existante des trois clés dans la section du domaine
    est retirée avant réinjection unique juste après l'en-tête de section :
    un fichier ini avec une clé dupliquée garde sa DERNIÈRE occurrence,
    donc un simple ajout en tête serait écrasé par une valeur générée par
    realm join plus bas dans le fichier.
    """
    try:
        with open("/etc/sssd/sssd.conf") as f:
            conf = f.read()
    except OSError as exc:
        log("impossible de lire /etc/sssd/sssd.conf ({}), réglages non appliqués.".format(exc))
        return

    # Bug corrigé après un test en conditions réelles (domaine "MonEntreprise.CH") :
    # supposer que realm join écrit toujours la section en MAJUSCULES
    # strictes ("[domain/{}]".format(domain.upper())) était faux - la casse
    # réellement utilisée dans le fichier généré peut différer de celle du
    # domaine tel que saisi. Avec l'ancienne comparaison stricte, la section
    # n'était JAMAIS reconnue, donc TOUTE la fonction ne faisait rien - ni le
    # fix use_fully_qualified_names/case_sensitive (bug écran noir), ni
    # ldap_user_gecos (nom complet KDE). Recherche insensible à la casse
    # contre le domaine effectivement joint, avec repli sur la première
    # section [domain/...] rencontrée (une installation fraîchement jointe
    # n'en a normalement qu'une seule) si même ça ne correspond pas.
    domain_header = None
    fallback_header = None
    expected = "[domain/{}]".format(domain).lower()
    for line in conf.splitlines():
        stripped = line.strip()
        if stripped.startswith("[domain/") and stripped.endswith("]"):
            if fallback_header is None:
                fallback_header = stripped
            if stripped.lower() == expected:
                domain_header = stripped
                break
    if domain_header is None:
        domain_header = fallback_header
    if domain_header is None:
        log("aucune section [domain/...] trouvée dans sssd.conf, réglages non appliqués.")
        return

    in_domain_section = False
    filtered_lines = []
    for line in conf.splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            in_domain_section = stripped == domain_header
            filtered_lines.append(line)
            continue
        if in_domain_section and stripped.split("=", 1)[0].strip() in (
            "use_fully_qualified_names",
            "case_sensitive",
            "ldap_user_gecos",
        ):
            continue
        filtered_lines.append(line)

    final_lines = []
    for line in filtered_lines:
        final_lines.append(line)
        if line.strip() == domain_header:
            final_lines.append("use_fully_qualified_names = False")
            final_lines.append("case_sensitive = False")
            final_lines.append("ldap_user_gecos = displayName")
    new_conf = "\n".join(final_lines) + "\n"

    with open("/etc/sssd/sssd.conf", "w") as f:
        f.write(new_conf)
    import os

    os.chmod("/etc/sssd/sssd.conf", 0o600)
    restorecon("/etc/sssd/sssd.conf")
    run(["systemctl", "restart", "sssd.service"], check=False)
    log("use_fully_qualified_names=False / case_sensitive=False / ldap_user_gecos=displayName appliqués à sssd.conf.")


def split_groups(raw):
    """Découpe une liste de groupes saisie en un seul champ (virgules et/ou espaces)."""
    return [g.strip() for g in raw.replace(",", " ").split() if g.strip()]


def restrict_login(allowed_groups_raw):
    """`realm deny --all` puis `realm permit --groups <groupe1> <groupe2> ...` (noms courts).

    Sans ça, n'importe quel compte du domaine peut se connecter une fois la
    jonction faite. `realm permit --groups` accepte nativement PLUSIEURS
    noms de groupes en arguments (pas besoin de répéter `--groups`) -
    demandé après un test en conditions réelles où un seul groupe ne
    suffisait pas à couvrir les besoins d'accès réels de l'entreprise. Noms
    COURTS (pas de "@domaine") : avec use_fully_qualified_names=False
    (forcé ci-dessus), c'est le nom court du groupe qui résout via getent
    group - vérifié avec la commande plutôt que supposé, comportement
    inverse de celui documenté avant ce changement de réglage.
    """
    groups = split_groups(allowed_groups_raw)
    if not groups:
        return
    try:
        run(["realm", "deny", "--all"], timeout=30)
        run(["realm", "permit", "--groups"] + groups, timeout=30)
        log("connexion restreinte au(x) groupe(s) AD : {}.".format(", ".join(groups)))
    except subprocess.CalledProcessError as exc:
        log("échec de la restriction de connexion aux groupes {} : {}".format(groups, exc.stderr))


def grant_sudo(sudo_groups_raw, domain):
    """Fragment /etc/sudoers.d/, une ligne par groupe, validé par visudo -cf avant activation.

    Plusieurs groupes possibles (même raison que restrict_login) : une
    ligne sudoers séparée par groupe dans le même fragment plutôt qu'une
    liste sur une seule ligne - plus simple à relire/déboguer, et évite
    tout piège de virgule dans la syntaxe `User_List` de sudoers. Le
    fichier ENTIER (toutes les lignes) est validé par `visudo -cf` avant
    activation - un seul nom de groupe invalide fait échouer tout le
    fragment plutôt que d'activer partiellement des droits.

    Noms COURTS du groupe (voir fix_sssd_conf) : sudo/visudo résolvent un
    groupe via getgrnam() (NSS), qui suit use_fully_qualified_names - forcé
    à False juste au-dessus.
    """
    groups = split_groups(sudo_groups_raw)
    if not groups:
        return
    groups_short = [g.split("@", 1)[0] for g in groups]
    tmp_path = "/etc/sudoers.d/90-ad-admins.tmp"
    final_path = "/etc/sudoers.d/90-ad-admins"
    sudoers_content = "".join("%{} ALL=(ALL:ALL) ALL\n".format(g) for g in groups_short)

    with open(tmp_path, "w") as f:
        f.write(sudoers_content)

    check = run(["visudo", "-cf", tmp_path], check=False)
    if check.returncode == 0:
        import os

        os.chmod(tmp_path, 0o440)
        os.rename(tmp_path, final_path)
        restorecon(final_path)
        log("droits sudo accordés au(x) groupe(s) AD : {}.".format(", ".join(groups_short)))
    else:
        import os

        os.remove(tmp_path)
        log("un ou plusieurs noms de groupe sudo {} invalides pour sudoers, ignorés : {}".format(groups_short, check.stderr))


def switch_sddm_to_free_text(local_admin_user):
    """Bascule SDDM en saisie libre du nom d'utilisateur (comptes AD non listés).

    sssd ne supporte volontairement pas l'énumération complète d'un
    annuaire - un compte AD n'apparaît donc jamais dans la liste cliquable
    de SDDM. HideUsers=<compte local admin> + RememberLastUser=false, dans
    une SEULE section [Users] (une deuxième section [Users] séparée dans le
    même fichier ne fusionne pas, elle semble écraser la première - piège
    confirmé sur le projet Arch de référence, ce comportement appartient au
    composant SDDM lui-même, donc identique ici). Le thème Breeze bascule
    alors automatiquement en champ de texte libre (comme sur Windows)
    quand la liste de comptes affichables est vide.
    """
    if not local_admin_user:
        log("nom du compte local admin non fourni, écran SDDM laissé en mode liste.")
        return

    import os

    os.makedirs("/etc/sddm.conf.d", exist_ok=True)
    sddm_conf = "[Users]\nHideUsers={}\nRememberLastUser=false\n".format(local_admin_user)
    path = "/etc/sddm.conf.d/90-hide-local-user.conf"
    with open(path, "w") as f:
        f.write(sddm_conf)
    restorecon(path)
    log("écran SDDM basculé en saisie libre (compte local '{}' masqué de la liste).".format(local_admin_user))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--admin-user", required=True)
    parser.add_argument("--computer-name", required=True)
    parser.add_argument("--ou", default="")
    parser.add_argument("--allowed-group", default="")
    parser.add_argument("--sudo-group", default="")
    parser.add_argument("--local-admin-user", default="", help="Compte local à masquer de la liste SDDM")
    args = parser.parse_args()

    password = sys.stdin.readline().rstrip("\n")
    if not password:
        log("mot de passe vide lu sur stdin, abandon.")
        return 1

    set_hostname(args.computer_name)
    sync_clock()

    try:
        join_domain(args.domain, args.admin_user, args.computer_name, args.ou, password)
    except subprocess.CalledProcessError:
        log("jonction AD échouée, aucune autre étape exécutée. Jonction manuelle possible : 'realm join'.")
        return 1

    ensure_dns_realm_discovery()
    fix_sssd_conf(args.domain)

    if args.allowed_group:
        restrict_login(args.allowed_group)
    if args.sudo_group:
        grant_sudo(args.sudo_group, args.domain)
    switch_sddm_to_free_text(args.local_admin_user)

    log("jonction au domaine {} terminée.".format(args.domain))
    return 0


if __name__ == "__main__":
    sys.exit(main())
