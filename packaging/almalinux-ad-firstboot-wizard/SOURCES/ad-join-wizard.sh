#!/bin/bash
# Assistant graphique (non privilégié) de jonction Active Directory.
#
# Contrepartie de la page Calamares "adjoinview" du projet frère Compass
# Arch, mais tourne ici après l'installation, au premier login Plasma (ou
# manuellement depuis le menu applications - voir
# etc/xdg/autostart/almalinux-ad-join-wizard-autostart.desktop vs.
# usr/share/applications/almalinux-ad-join-wizard.desktop).
#
# Un seul écran (`zenity --forms`), pas une série de boîtes de dialogue
# séquentielles : retour direct d'un test en conditions réelles sur poste
# physique - avec plusieurs popups à la suite, il est facile de se tromper
# de champ (répondre à la mauvaise question, ou valider un champ vide en
# pensant être ailleurs). `zenity --forms` regroupe tous les champs dans
# une seule fenêtre, review complète avant validation.
#
# `zenity`, pas `kdialog --forms` : la première version de ce script
# utilisait `kdialog --forms`, qui s'est révélé **ne pas exister du tout**
# sur cette version de kdialog (25.12.3, ère KDE Frameworks 6) - confirmé
# en conditions réelles sur poste physique ("kdialog: Option inconnue
# 'forms'.") et par `kdialog --help` (aucune trace de `--forms` dans la
# sortie). `--forms` était un mode de l'ancien kdialog (KDE4/Plasma5), visiblement
# jamais reporté sur le kdialog fourni par EPEL pour AlmaLinux 10. `zenity`
# (déjà présent dans l'image, confirmé par `zenity --help-forms`) a un mode
# forms mature et stable, avec champ mot de passe masqué natif
# (`--add-password`) - léger écart visuel (boîte GTK plutôt que native KDE)
# pour ce seul écran, acceptable vu la fiabilité. Le reste de l'assistant
# (confirmation, succès, erreur) reste en `kdialog`, qui fonctionne
# normalement pour ces modes plus simples.
set -euo pipefail

TITLE="AlmaLinux AD - Jonction Active Directory"

# Annuler ce formulaire (bouton Annuler) = ne pas rejoindre maintenant,
# exactement comme répondre "Non" dans l'ancienne version à plusieurs
# écrans - toujours possible plus tard depuis le menu applications.
# --width/--height fixés : sans ça, zenity dimensionne la fenêtre sur la
# largeur du label le plus long au lieu de faire des retours à la ligne -
# confirmé en conditions réelles (fenêtre débordant de l'écran, champs
# tronqués comme "Unité d'organisation" affichant la fin de la valeur
# saisie plutôt que le début). Labels aussi raccourcis pour limiter le
# besoin de largeur en premier lieu.
form_output=$(zenity --forms --title="$TITLE" --separator="|" --width=800 --height=480 \
    --text="Rejoindre un domaine Windows Active Directory\n(Annuler = ne pas rejoindre maintenant - toujours possible plus tard depuis le menu applications)" \
    --add-entry="Domaine AD (ex: example.corp)" \
    --add-entry="Nom de l'ordinateur (AD + hostname - actuel : $(hostname -s))" \
    --add-entry="Compte administrateur du domaine" \
    --add-password="Mot de passe administrateur" \
    --add-entry="Unité d'organisation - OU (optionnel)" \
    --add-entry="Groupe(s) autorisés à se connecter (virgules, optionnel)" \
    --add-entry="Groupe(s) avec sudo (virgules, optionnel)") || exit 1

# Une seule ligne, valeurs séparées par "|" dans l'ordre des champs déclarés
# ci-dessus (voir --separator ci-dessus).
IFS='|' read -r -a fields <<< "$form_output"
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
