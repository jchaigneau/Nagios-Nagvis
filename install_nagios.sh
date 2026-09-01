#!/bin/bash

# ============================================================
# Installation automatique de Nagios Core sur Debian 13
# ============================================================

set -euo pipefail

# IMPORTANT sous Debian :
# groupadd, useradd, usermod, etc. sont dans /usr/sbin.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

NAGIOS_VERSION="4.5.14"
PLUGINS_VERSION="2.5"

NAGIOS_USER="nagiosadmin"
NAGIOS_PASSWORD="ChangeMe123!"

WORKDIR="/tmp/nagios-install"

NAGIOS_URL="https://github.com/NagiosEnterprises/nagioscore/releases/download/nagios-${NAGIOS_VERSION}/nagios-${NAGIOS_VERSION}.tar.gz"
PLUGINS_URL="https://github.com/nagios-plugins/nagios-plugins/releases/download/release-${PLUGINS_VERSION}/nagios-plugins-${PLUGINS_VERSION}.tar.gz"

# ============================================================
# Fonctions
# ============================================================

info() {
    echo
    echo "============================================================"
    echo "[+] $1"
    echo "============================================================"
}

error() {
    echo
    echo "[ERREUR] $1" >&2
    exit 1
}

# ============================================================
# Vérification ROOT
# ============================================================

if [[ "${EUID}" -ne 0 ]]; then
    error "Ce script doit être exécuté en root."
fi

# ============================================================
# Vérification Debian
# ============================================================

info "Vérification du système"

if [[ ! -f /etc/os-release ]]; then
    error "/etc/os-release introuvable."
fi

source /etc/os-release

if [[ "${ID}" != "debian" ]]; then
    error "Ce script est prévu pour Debian."
fi

echo "Système : ${PRETTY_NAME}"

if [[ "${VERSION_ID:-}" != "13" ]]; then
    echo "[ATTENTION] Script prévu pour Debian 13."
    echo "Version détectée : ${VERSION_ID:-inconnue}"
fi

# ============================================================
# Dépendances
# ============================================================

info "Installation des dépendances"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    passwd \
    unzip \
    ca-certificates \
    wget \
    curl \
    tar \
    gzip \
    autoconf \
    automake \
    gcc \
    g++ \
    make \
    libc6-dev \
    pkg-config \
    gettext \
    libtool \
    apache2 \
    apache2-utils \
    php \
    libapache2-mod-php \
    libgd-dev \
    libssl-dev \
    openssl \
    libperl-dev \
    libnet-snmp-perl \
    snmp \
    dnsutils \
    iputils-ping

# ============================================================
# Vérification commandes système
# ============================================================

info "Vérification des commandes système"

REQUIRED_COMMANDS=(
    groupadd
    useradd
    usermod
    make
    gcc
    wget
    htpasswd
)

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        error "Commande '${cmd}' introuvable. PATH=${PATH}"
    fi

    echo "[OK] ${cmd} -> $(command -v "${cmd}")"
done

# ============================================================
# Préparation du répertoire
# ============================================================

info "Préparation du répertoire de travail"

rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"

cd "${WORKDIR}"

# ============================================================
# Nagios Core
# ============================================================

info "Téléchargement Nagios Core ${NAGIOS_VERSION}"

wget \
    --https-only \
    -O nagios-core.tar.gz \
    "${NAGIOS_URL}"

info "Extraction de Nagios Core"

tar xzf nagios-core.tar.gz

cd "${WORKDIR}/nagios-${NAGIOS_VERSION}"

# ============================================================
# Configuration
# ============================================================

info "Configuration de Nagios Core"

./configure \
    --with-httpd-conf=/etc/apache2/sites-enabled \
    --with-command-group=nagios

# ============================================================
# Compilation
# ============================================================

info "Compilation de Nagios Core"

make -j"$(nproc)" all

# ============================================================
# Utilisateur Nagios
# ============================================================

info "Création de l'utilisateur et du groupe Nagios"

# Cette commande utilise groupadd/useradd.
# Le PATH défini au début du script corrige le problème rencontré.
make install-groups-users

# Vérification
if ! getent group nagios >/dev/null; then
    error "Le groupe nagios n'a pas été créé."
fi

if ! id nagios >/dev/null 2>&1; then
    error "L'utilisateur nagios n'a pas été créé."
fi

echo "[OK] Utilisateur nagios présent."
echo "[OK] Groupe nagios présent."

# Apache doit pouvoir envoyer des commandes à Nagios.
usermod -aG nagios www-data

# ============================================================
# Installation Nagios
# ============================================================

info "Installation des binaires"

make install

info "Installation du service Nagios"

make install-daemoninit

info "Installation du mode commandes"

make install-commandmode

info "Installation des fichiers de configuration"

make install-config

info "Installation de la configuration Apache"

make install-webconf

# ============================================================
# Apache
# ============================================================

info "Configuration Apache"

a2enmod rewrite

# Debian utilise généralement cgid avec Apache MPM event.
a2enmod cgid

# On active explicitement la configuration Nagios si nécessaire.
if [[ -f /etc/apache2/conf-available/nagios.conf ]]; then
    a2enconf nagios || true
fi

apache2ctl configtest

# ============================================================
# Authentification Web
# ============================================================

info "Création du compte Web ${NAGIOS_USER}"

HTPASSWD_FILE="/usr/local/nagios/etc/htpasswd.users"

if [[ -f "${HTPASSWD_FILE}" ]]; then

    htpasswd -b \
        "${HTPASSWD_FILE}" \
        "${NAGIOS_USER}" \
        "${NAGIOS_PASSWORD}"

else

    htpasswd -b -c \
        "${HTPASSWD_FILE}" \
        "${NAGIOS_USER}" \
        "${NAGIOS_PASSWORD}"

fi

chown root:www-data "${HTPASSWD_FILE}"
chmod 640 "${HTPASSWD_FILE}"

# ============================================================
# Nagios Plugins
# ============================================================

info "Téléchargement Nagios Plugins ${PLUGINS_VERSION}"

cd "${WORKDIR}"

wget \
    --https-only \
    -O nagios-plugins.tar.gz \
    "${PLUGINS_URL}"

info "Extraction des plugins"

tar xzf nagios-plugins.tar.gz

cd "${WORKDIR}/nagios-plugins-${PLUGINS_VERSION}"

# ============================================================
# Configuration Plugins
# ============================================================

info "Configuration des plugins Nagios"

./configure \
    --with-nagios-user=nagios \
    --with-nagios-group=nagios

# ============================================================
# Compilation Plugins
# ============================================================

info "Compilation des plugins"

make -j"$(nproc)"

# ============================================================
# Installation Plugins
# ============================================================

info "Installation des plugins"

make install

# ============================================================
# Vérification plugins
# ============================================================

info "Vérification des plugins"

if [[ ! -d /usr/local/nagios/libexec ]]; then
    error "Le répertoire des plugins n'existe pas."
fi

ls -la /usr/local/nagios/libexec/ | head -20

# ============================================================
# Vérification configuration Nagios
# ============================================================

info "Validation de la configuration Nagios"

/usr/local/nagios/bin/nagios \
    -v \
    /usr/local/nagios/etc/nagios.cfg

# ============================================================
# Activation Apache
# ============================================================

info "Activation Apache"

systemctl enable apache2
systemctl restart apache2

if ! systemctl is-active --quiet apache2; then
    systemctl --no-pager status apache2 || true
    error "Apache n'a pas démarré."
fi

echo "[OK] Apache fonctionne."

# ============================================================
# Activation Nagios
# ============================================================

info "Activation Nagios"

systemctl daemon-reload
systemctl enable nagios
systemctl restart nagios

if ! systemctl is-active --quiet nagios; then
    systemctl --no-pager status nagios || true
    journalctl -u nagios -n 50 --no-pager || true
    error "Nagios n'a pas démarré."
fi

echo "[OK] Nagios fonctionne."

# ============================================================
# Informations réseau
# ============================================================

SERVER_IP="$(hostname -I | awk '{print $1}')"

if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP="IP_DU_SERVEUR"
fi

# ============================================================
# Résultat
# ============================================================

echo
echo "============================================================"
echo "        INSTALLATION NAGIOS TERMINÉE"
echo "============================================================"
echo
echo "Nagios Core :"
echo "    ${NAGIOS_VERSION}"
echo
echo "Nagios Plugins :"
echo "    ${PLUGINS_VERSION}"
echo
echo "Interface Web :"
echo
echo "    http://${SERVER_IP}/nagios/"
echo
echo "Identifiant :"
echo "    ${NAGIOS_USER}"
echo
echo "Mot de passe :"
echo "    ${NAGIOS_PASSWORD}"
echo
echo "Configuration principale :"
echo "    /usr/local/nagios/etc/nagios.cfg"
echo
echo "Objets :"
echo "    /usr/local/nagios/etc/objects/"
echo
echo "Plugins :"
echo "    /usr/local/nagios/libexec/"
echo
echo "Logs :"
echo "    /usr/local/nagios/var/nagios.log"
echo
echo "------------------------------------------------------------"
echo "Commandes utiles"
echo "------------------------------------------------------------"
echo
echo "État Nagios :"
echo "    systemctl status nagios"
echo
echo "Redémarrer Nagios :"
echo "    systemctl restart nagios"
echo
echo "État Apache :"
echo "    systemctl status apache2"
echo
echo "Tester la configuration Nagios :"
echo "    /usr/local/nagios/bin/nagios -v /usr/local/nagios/etc/nagios.cfg"
echo
echo "Logs systemd :"
echo "    journalctl -u nagios -f"
echo
echo "============================================================"
echo
echo "IMPORTANT : change le mot de passe nagiosadmin."
echo
echo "Commande :"
echo
echo "    htpasswd /usr/local/nagios/etc/htpasswd.users nagiosadmin"
echo
echo "============================================================"
