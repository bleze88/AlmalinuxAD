#!/bin/bash
# Lanceur autostart : propose l'assistant AD une seule fois pour toute la
# machine, au tout premier login (normalement le compte admin local créé
# pendant l'installation).
#
# Historique : une première version utilisait un marqueur PAR UTILISATEUR
# (~/.config/almalinux-ad/wizard-done), justement pour éviter tout besoin
# de pkexec/mot de passe. Confirmé en conditions réelles que c'était trop
# naïf : une fois la machine jointe au domaine, chaque compte AD se
# connectant pour la première fois obtient un $HOME flambant neuf (créé
# par pam_oddjob_mkhomedir), qui n'a évidemment jamais vu le marqueur -
# l'invite "voulez-vous rejoindre un domaine ?" réapparaissait donc à
# chaque nouveau compte du domaine qui se connectait, ce qui n'a aucun
# sens (la machine est déjà jointe). Fix à deux niveaux ci-dessous : (1) ne
# plus jamais proposer si la machine est déjà jointe à un domaine - le
# signal qui compte vraiment, indépendamment de qui se connecte - et (2) un
# marqueur MACHINE-WIDE (pas par utilisateur) pour le cas où la jonction a
# été refusée/pas encore faite, dans /var/lib/almalinux-ad (créé au build
# avec le groupe `wheel`, accessible en écriture sans pkexec par le compte
# admin local, membre de `wheel` - voir build/02-customize-squashfs.sh).
set -euo pipefail

# Ne JAMAIS se proposer pendant une session live (avant toute installation) :
# ce script vit dans le rootfs live lui-même (il doit y être pour arriver
# sur le système installé une fois copié par le paiement live d'Anaconda -
# voir docs/ARCHITECTURE.md), donc KDE le lance aussi pour le compte
# utilisateur live à son propre "premier login" - confirmé en conditions
# réelles (popup affiché par-dessus le "Welcome Center" du live). Une
# jonction AD depuis le live n'aurait de toute façon aucun sens (rootfs
# live en RAM/overlay, rien de persistant). `rd.live.image` est le
# paramètre noyau standard posé par dracut-live sur tout boot live
# (Fedora/CentOS/AlmaLinux...) - présent uniquement en live, absent une
# fois installé et démarré normalement.
grep -q 'rd\.live\.image' /proc/cmdline 2>/dev/null && exit 0

# Déjà jointe à un domaine ? Ne plus jamais proposer automatiquement, quel
# que soit le compte qui se connecte - `realm list` est une commande de
# lecture, disponible sans privilège particulier.
[ -n "$(realm list 2>/dev/null)" ] && exit 0

FLAG="/var/lib/almalinux-ad/wizard-done"

[ -f "$FLAG" ] && exit 0

# Quel que soit le résultat (jonction réussie, échouée, ou refusée), on ne
# propose plus automatiquement ensuite - toujours disponible manuellement
# depuis le menu applications (« Rejoindre un domaine Active Directory »).
/usr/bin/almalinux-ad-join-wizard || true

# Best-effort : si le compte qui a déclenché ceci n'est pas membre de
# `wheel` (donc pas de droit d'écriture sur /var/lib/almalinux-ad), on ne
# bloque pas pour autant - au pire, l'invite réapparaît au prochain login,
# dégradation acceptable plutôt qu'un crash du script d'autostart.
touch "$FLAG" 2>/dev/null || true
