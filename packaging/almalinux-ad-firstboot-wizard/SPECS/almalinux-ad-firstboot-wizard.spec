# Paquet "files-only" (rien à compiler) : l'assistant de jonction Active
# Directory de premier login (wizard kdialog + backend privilégié) et ses
# entrées de menu/autostart. Voir docs/AD-JOIN-WIZARD.md à la racine du
# dépôt pour la logique métier détaillée.

Name:           almalinux-ad-firstboot-wizard
Version:        1.0.0
Release:        1%{?dist}
Summary:        Assistant de jonction Active Directory au premier login (AlmaLinux AD)

License:        Unspecified
URL:            https://github.com/bleze88/AlmalinuxAD
BuildArch:      noarch

Source0:        ad-join-backend.py
Source1:        ad-join-wizard.sh
Source2:        ad-join-wizard-autostart.sh
Source3:        almalinux-ad-join-wizard.desktop
Source4:        almalinux-ad-join-wizard-autostart.desktop

Requires:       sssd
Requires:       sssd-krb5
Requires:       sssd-ad
Requires:       adcli
Requires:       realmd
Requires:       samba-common-tools
Requires:       krb5-workstation
Requires:       oddjob
Requires:       oddjob-mkhomedir
Requires:       bind-utils
Requires:       policycoreutils
Requires:       polkit
Requires:       python3
Requires:       kdialog
Requires:       zenity

%description
Installe un assistant graphique (kdialog) proposé une fois au premier
login Plasma pour rejoindre un domaine Windows Active Directory, ainsi
que le backend privilégié (realm/sssd/krb5/sudoers, invoqué via pkexec)
qui effectue la jonction. Reste disponible ensuite comme entrée du menu
applications pour une jonction/reconfiguration manuelle ultérieure.

%prep
# Rien à préparer : paquet de fichiers statiques, pas de sources à compiler.

%build
# Rien à compiler.

%install
install -Dm0755 %{SOURCE0} %{buildroot}%{_libexecdir}/almalinux-ad/ad-join-backend.py
install -Dm0755 %{SOURCE1} %{buildroot}%{_bindir}/almalinux-ad-join-wizard
install -Dm0755 %{SOURCE2} %{buildroot}%{_libexecdir}/almalinux-ad/ad-join-wizard-autostart.sh
install -Dm0644 %{SOURCE3} %{buildroot}%{_datadir}/applications/almalinux-ad-join-wizard.desktop
install -Dm0644 %{SOURCE4} %{buildroot}%{_sysconfdir}/xdg/autostart/almalinux-ad-join-wizard-autostart.desktop

%files
%{_libexecdir}/almalinux-ad/ad-join-backend.py
%{_bindir}/almalinux-ad-join-wizard
%{_libexecdir}/almalinux-ad/ad-join-wizard-autostart.sh
%{_datadir}/applications/almalinux-ad-join-wizard.desktop
%{_sysconfdir}/xdg/autostart/almalinux-ad-join-wizard-autostart.desktop

%changelog
* Mon Jul 27 2026 AlmaLinux AD Project <https://example.invalid> - 1.0.0-1
- Version initiale.
