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
elle-même (figer le KDC, sssd.conf, restriction de groupe, sudo, SDDM) est
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


def pin_kdc_in_krb5_conf(domain):
    """Fige le KDC découvert par SRV DNS dans /etc/krb5.conf (best-effort).

    `realm join` fait fonctionner Kerberos via découverte DNS SRV
    automatique - suffisant, mais laisser le fichier au template par défaut
    du paquet `krb5-workstation` (exemples MIT.EDU/CMU.EDU) est perturbant
    pour un admin qui l'inspecterait. On fige donc explicitement le KDC
    trouvé, ce qui rend Kerberos indépendant de cette découverte répétée
    pour les opérations suivantes. Sans effet si `dig` échoue ou ne renvoie
    rien (pas de RFC 2782 SRV pour ce domaine, pas de résolveur DNS
    fonctionnel...) : on retombe alors sur la découverte automatique, déjà
    le comportement par défaut sans ce bloc.
    """
    try:
        srv = run(
            ["sh", "-c", "dig +short SRV _kerberos._tcp.{} | sort -n | head -1".format(domain)],
            timeout=15,
            check=False,
        ).stdout.strip()
        kdc_host = srv.split()[-1].rstrip(".") if srv else ""
    except (OSError, subprocess.TimeoutExpired):
        kdc_host = ""

    if not kdc_host:
        log("pas de KDC trouvé via SRV, /etc/krb5.conf laissé tel quel (découverte DNS automatique).")
        return

    try:
        with open("/etc/krb5.conf") as f:
            krb5_conf = f.read()
    except OSError as exc:
        log("impossible de lire /etc/krb5.conf ({}), KDC non figé.".format(exc))
        return

    realm_upper = domain.upper()
    realm_block = "    {} = {{\n        kdc = {}\n        admin_server = {}\n    }}\n".format(
        realm_upper, kdc_host, kdc_host
    )
    domain_realm_block = "    .{0} = {1}\n    {0} = {1}\n".format(domain, realm_upper)

    new_lines = []
    for line in krb5_conf.splitlines(keepends=True):
        new_lines.append(line)
        stripped = line.strip()
        if stripped == "[realms]":
            new_lines.append(realm_block)
        elif stripped == "[domain_realm]":
            new_lines.append(domain_realm_block)

    with open("/etc/krb5.conf", "w") as f:
        f.write("".join(new_lines))
    restorecon("/etc/krb5.conf")
    log("KDC '{}' figé dans /etc/krb5.conf pour le royaume {}.".format(kdc_host, realm_upper))


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

    domain_header = "[domain/{}]".format(domain.upper())
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


def restrict_login(allowed_group):
    """`realm deny --all` puis `realm permit --groups <groupe>` (nom court).

    Sans ça, n'importe quel compte du domaine peut se connecter une fois la
    jonction faite. Nom COURT (pas de "@domaine") : avec
    use_fully_qualified_names=False (forcé ci-dessus), c'est le nom court du
    groupe qui résout via getent group - vérifié avec la commande plutôt que
    supposé, comportement inverse de celui documenté avant ce changement de
    réglage.
    """
    try:
        run(["realm", "deny", "--all"], timeout=30)
        run(["realm", "permit", "--groups", allowed_group], timeout=30)
        log("connexion restreinte au groupe AD '{}'.".format(allowed_group))
    except subprocess.CalledProcessError as exc:
        log("échec de la restriction de connexion au groupe '{}' : {}".format(allowed_group, exc.stderr))


def grant_sudo(sudo_group, domain):
    """Fragment /etc/sudoers.d/, validé par visudo -cf avant activation.

    Nom COURT du groupe (voir fix_sssd_conf) : sudo/visudo résolvent un
    groupe via getgrnam() (NSS), qui suit use_fully_qualified_names - forcé
    à False juste au-dessus.
    """
    sudo_group_short = sudo_group.split("@", 1)[0]
    tmp_path = "/etc/sudoers.d/90-ad-admins.tmp"
    final_path = "/etc/sudoers.d/90-ad-admins"
    sudoers_line = "%{} ALL=(ALL:ALL) ALL\n".format(sudo_group_short)

    with open(tmp_path, "w") as f:
        f.write(sudoers_line)

    check = run(["visudo", "-cf", tmp_path], check=False)
    if check.returncode == 0:
        import os

        os.chmod(tmp_path, 0o440)
        os.rename(tmp_path, final_path)
        restorecon(final_path)
        log("droits sudo accordés au groupe AD '{}'.".format(sudo_group_short))
    else:
        import os

        os.remove(tmp_path)
        log("nom de groupe sudo '{}' invalide pour sudoers, ignoré : {}".format(sudo_group_short, check.stderr))


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

    pin_kdc_in_krb5_conf(args.domain)
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
