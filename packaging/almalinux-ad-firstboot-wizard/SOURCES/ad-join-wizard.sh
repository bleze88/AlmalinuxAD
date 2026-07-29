#!/bin/bash
# Assistant graphique (non privilégié) de jonction Active Directory.
#
# Contrepartie de la page Calamares "adjoinview" du projet frère Compass
# Arch, mais tourne ici après l'installation, au premier login Plasma (ou
# manuellement depuis le menu applications - voir
# etc/xdg/autostart/almalinux-ad-join-wizard-autostart.desktop vs.
# usr/share/applications/almalinux-ad-join-wizard.desktop).
#
# Un seul écran (`kdialog --forms`), pas une série de boîtes de dialogue
# séquentielles : retour direct d'un test en conditions réelles sur poste
# physique - avec plusieurs popups à la suite, il est facile de se tromper
# de champ (répondre à la mauvaise question, ou valider un champ vide en
# pensant être ailleurs). `kdialog --forms` regroupe tous les champs dans
# une seule fenêtre, review complète avant validation.
#
# !! Syntaxe `--forms` moins courante que les boîtes `--inputbox`/`--yesno`
# habituelles de kdialog - comportement à reconfirmer au premier test réel
# après ce changement (voir docs/AD-JOIN-WIZARD.md) : un label préfixé par
# `*` doit produire un champ mot de passe masqué, et la sortie doit donner
# une valeur par ligne dans l'ordre des champs déclarés.
#
# kdialog est utilisé plutôt qu'une page Calamares/Qt dédiée : déjà fourni
# par KDE (aucune dépendance Python/Qt supplémentaire à faire vérifier sur
# les dépôts EL10). Toute la logique privilégiée
# (realm/sssd/krb5/sudoers/SELinux) vit dans ad-join-backend.py, invoqué
# ici via `pkexec` - ce script-ci ne fait que collecter les réponses et
# afficher le résultat.
set -euo pipefail

TITLE="AlmaLinux AD - Jonction Active Directory"

# Annuler ce formulaire (bouton Annuler) = ne pas rejoindre maintenant,
# exactement comme répondre "Non" dans l'ancienne version à plusieurs
# écrans - toujours possible plus tard depuis le menu applications.
form_output=$(kdialog --title "$TITLE" --forms \
    "Rejoindre un domaine Windows Active Directory (Annuler = ne pas rejoindre maintenant - toujours possible plus tard depuis le menu applications « Rejoindre un domaine Active Directory ») :" \
    "Domaine AD (ex: example.corp) :" "" \
    "Nom de cet ordinateur (annuaire AD + hostname système) :" "$(hostname -s)" \
    "Compte administrateur du domaine :" "" \
    "*Mot de passe administrateur :" "" \
    "Unité d'organisation - OU (optionnel) :" "" \
    "Groupe(s) autorisé(s) à se connecter (optionnel, noms courts séparés par des virgules) :" "" \
    "Groupe(s) avec sudo (optionnel, noms courts séparés par des virgules) :" "") || exit 1

# Une valeur par ligne, dans l'ordre des champs déclarés ci-dessus.
mapfile -t fields <<< "$form_output"
domain="${fields[0]:-}"
computer_name="${fields[1]:-}"
admin_user="${fields[2]:-}"
# Le mot de passe ne vit que dans cette variable shell, jamais écrit sur
# disque ni passé en argument de commande (visible dans /proc/*/cmdline) -
# transmis à ad-join-backend.py par stdin, à travers pkexec, qui préserve
# l'entrée standard de l'appelant.
password="${fields[3]:-}"
ou="${fields[4]:-}"
allowed_group="${fields[5]:-}"
sudo_group="${fields[6]:-}"

if [ -z "$domain" ] || [ -z "$computer_name" ] || [ -z "$admin_user" ] || [ -z "$password" ]; then
    password=""
    kdialog --title "$TITLE" --error "Domaine, nom de l'ordinateur, compte admin et mot de passe sont obligatoires - jonction annulée.\n\nRelancez depuis le menu applications si besoin."
    exit 1
fi

summary="Domaine : $domain
Nom de l'ordinateur : $computer_name
Compte admin AD : $admin_user"
[ -n "$ou" ] && summary+="
OU : $ou"
[ -n "$allowed_group" ] && summary+="
Groupe autorisé à se connecter : $allowed_group"
[ -n "$sudo_group" ] && summary+="
Groupe avec sudo : $sudo_group"

if ! kdialog --title "$TITLE" --yesno "Confirmer la jonction avec ces paramètres ?

$summary"; then
    password=""
    exit 1
fi

args=(--domain "$domain" --admin-user "$admin_user" --computer-name "$computer_name" --local-admin-user "$(id -un)")
[ -n "$ou" ] && args+=(--ou "$ou")
[ -n "$allowed_group" ] && args+=(--allowed-group "$allowed_group")
[ -n "$sudo_group" ] && args+=(--sudo-group "$sudo_group")

if output=$(printf '%s\n' "$password" | pkexec /usr/libexec/almalinux-ad/ad-join-backend.py "${args[@]}" 2>&1); then
    password=""
    kdialog --title "$TITLE" --msgbox "Jonction au domaine $domain réussie.

Vous pouvez maintenant vous connecter avec un compte du domaine depuis l'écran de connexion SDDM (saisie libre du nom d'utilisateur)."
    exit 0
else
    password=""
    kdialog --title "$TITLE" --textbox <(printf '%s\n' "La jonction au domaine $domain a échoué. Détails :" "" "$output") 700 400
    exit 1
fi
