#!/bin/bash
# Assistant graphique (non privilégié) de jonction Active Directory.
#
# Contrepartie de la page Calamares "adjoinview" du projet frère Compass
# Arch, mais tourne ici après l'installation, au premier login Plasma (ou
# manuellement depuis le menu applications - voir
# etc/xdg/autostart/almalinux-ad-join-wizard.desktop vs.
# usr/share/applications/almalinux-ad-join-wizard.desktop).
#
# kdialog est utilisé plutôt qu'une page Calamares/Qt dédiée : déjà fourni
# par KDE (aucune dépendance Python/Qt supplémentaire à faire vérifier sur
# les dépôts EL10), et suffisant pour un formulaire séquentiel simple. Toute
# la logique privilégiée (realm/sssd/krb5/sudoers/SELinux) vit dans
# ad-join-backend.py, invoqué ici via `pkexec` - ce script-ci ne fait que
# collecter les réponses et afficher le résultat.
set -euo pipefail

TITLE="AlmaLinux AD - Jonction Active Directory"

ask_required() {
    local prompt="$1" default="${2:-}"
    kdialog --title "$TITLE" --inputbox "$prompt" "$default"
}

ask_optional() {
    local prompt="$1"
    kdialog --title "$TITLE" --inputbox "$prompt" "" || true
}

if ! kdialog --title "$TITLE" --yesno \
    "Voulez-vous rejoindre un domaine Windows Active Directory maintenant ?\n\nVous pourrez toujours le faire plus tard depuis le menu applications (« Rejoindre un domaine Active Directory »)."; then
    exit 1
fi

domain=$(ask_required "Nom du domaine AD (ex: example.corp) :") || exit 1
[ -n "$domain" ] || exit 1

ou=$(ask_optional "Unité d'organisation (OU) - optionnel, laissez vide pour la valeur par défaut :\n(ex: OU=Postes,DC=example,DC=corp)")

admin_user=$(ask_required "Compte administrateur du domaine (autorisé à joindre un poste) :") || exit 1
[ -n "$admin_user" ] || exit 1

computer_name=$(ask_required "Nom de cet ordinateur (utilisé à la fois pour l'annuaire AD et comme nom d'hôte système - un redémarrage sera nécessaire pour que le changement soit visible partout) :" "$(hostname -s)") || exit 1
[ -n "$computer_name" ] || exit 1

allowed_group=$(ask_optional "Groupe AD autorisé à se connecter sur ce poste - optionnel, nom court.\nLaissez vide pour autoriser tout le domaine :")

sudo_group=$(ask_optional "Groupe AD avec droits sudo sur ce poste - optionnel, nom court :")

# Le mot de passe ne vit que dans cette variable shell, jamais écrit sur
# disque ni passé en argument de commande (visible dans /proc/*/cmdline) -
# transmis à ad-join-backend.py par stdin, à travers pkexec, qui préserve
# l'entrée standard de l'appelant.
password=$(kdialog --title "$TITLE" --password "Mot de passe du compte administrateur :") || exit 1
if [ -z "$password" ]; then
    kdialog --title "$TITLE" --error "Mot de passe vide, jonction annulée."
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
