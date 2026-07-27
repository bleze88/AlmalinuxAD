#!/bin/bash
# Lanceur autostart : propose l'assistant AD une seule fois par compte
# utilisateur local, à son tout premier login Plasma.
#
# Marqueur PAR UTILISATEUR (~/.config/almalinux-ad/wizard-done), pas
# machine-wide : écrire un marqueur global depuis un script non privilégié
# demanderait un `pkexec` (donc un mot de passe) même quand l'utilisateur
# clique juste « Non » - une gêne inutile pour ce cas très fréquent. En
# pratique, l'installation interactive Anaconda ne crée qu'un seul compte
# local (l'admin) : si d'autres comptes locaux sont créés plus tard, chacun
# verra l'invite une seule fois à son propre premier login - limitation
# assumée, documentée dans docs/AD-JOIN-WIZARD.md, plutôt qu'un mécanisme
# de marqueur privilégié pour un cas marginal.
set -euo pipefail

FLAG="$HOME/.config/almalinux-ad/wizard-done"

[ -f "$FLAG" ] && exit 0

mkdir -p "$(dirname "$FLAG")"

# Quel que soit le résultat (jonction réussie, échouée, ou refusée), on ne
# propose plus automatiquement ensuite - toujours disponible manuellement
# depuis le menu applications (« Rejoindre un domaine Active Directory »).
/usr/bin/almalinux-ad-join-wizard || true

touch "$FLAG"
