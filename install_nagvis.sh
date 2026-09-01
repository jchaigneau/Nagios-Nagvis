#!/bin/bash

# ==============================================================================
# Installation automatique NagVis + MK Livestatus
#
# Plateforme validée :
#   Debian 13
#   Nagios Core 4.5.14 déjà installé dans /usr/local/nagios
#
# Installe :
#   - MK Livestatus 1.5.0p25
#   - NagVis
#   - Apache / PHP
#
# Correctifs intégrés :
#   - Headers Nagios Core 4.5.14 injectés dans MK Livestatus
#   - shared.h : lib/libnagios.h -> libnagios.h
#   - compilation --with-nagios4
#   - CFLAGS/CXXFLAGS -fcommon
#   - dépendances Boost / RRDtool
#   - socket /usr/local/nagios/var/rw/live
#   - permissions www-data
#   - configuration NagVis validée :
#
#       [defaults]
#       backend="live_1"
#
#       [backend_live_1]
#       backendtype="mklivestatus"
#       socket="unix:/usr/local/nagios/var/rw/live"
#
# ==============================================================================

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ==============================================================================
# VARIABLES
# ==============================================================================

NAGIOS_VERSION="4.5.14"
LIVESTATUS_VERSION="1.5.0p25"
NAGVIS_VERSION="1.10.6"

NAGIOS_DIR="/usr/local/nagios"
NAGIOS_BIN="${NAGIOS_DIR}/bin/nagios"
NAGIOS_CFG="${NAGIOS_DIR}/etc/nagios.cfg"
NAGIOS_VAR="${NAGIOS_DIR}/var"

LIVESTATUS_DIR="/usr/local/lib/mk-livestatus"
MODULE="${LIVESTATUS_DIR}/livestatus.o"
UNIXCAT="${LIVESTATUS_DIR}/unixcat"
SOCKET="${NAGIOS_VAR}/rw/live"

NAGVIS_DIR="/usr/local/nagvis"
NAGVIS_CFG="${NAGVIS_DIR}/etc/nagvis.ini.php"

APACHE_USER="www-data"
APACHE_GROUP="www-data"
APACHE_CONF="/etc/apache2/conf-available/nagvis.conf"

WORKDIR="/tmp/nagvis-install"
DATE="$(date +%Y%m%d-%H%M%S)"

NAGIOS_URL="https://github.com/NagiosEnterprises/nagioscore/archive/refs/tags/nagios-${NAGIOS_VERSION}.tar.gz"

LIVESTATUS_URL="https://download.checkmk.com/checkmk/${LIVESTATUS_VERSION}/mk-livestatus-${LIVESTATUS_VERSION}.tar.gz"

NAGVIS_GIT="https://github.com/NagVis/nagvis.git"


# ==============================================================================
# FONCTIONS
# ==============================================================================

info() {
    echo
    echo "======================================================================"
    echo "[+] $1"
    echo "======================================================================"
}

ok() {
    echo "[OK] $1"
}

warn() {
    echo "[ATTENTION] $1"
}

die() {
    echo
    echo "[ERREUR] $1" >&2
    exit 1
}


# ==============================================================================
# ROOT
# ==============================================================================

[[ "${EUID}" -eq 0 ]] ||
    die "Ce script doit être exécuté en root."


# ==============================================================================
# VÉRIFICATION NAGIOS
# ==============================================================================

info "Vérification de Nagios Core"

[[ -x "${NAGIOS_BIN}" ]] ||
    die "Nagios introuvable : ${NAGIOS_BIN}"

[[ -f "${NAGIOS_CFG}" ]] ||
    die "nagios.cfg introuvable : ${NAGIOS_CFG}"

id nagios >/dev/null 2>&1 ||
    die "Utilisateur nagios introuvable."


INSTALLED_VERSION="$(
    "${NAGIOS_BIN}" --version 2>/dev/null |
    sed -n 's/^Nagios Core \([^ ]*\).*/\1/p' |
    head -1
)"


echo
echo "Nagios détecté : ${INSTALLED_VERSION:-inconnu}"
echo


if [[ -n "${INSTALLED_VERSION}" ]] &&
   [[ "${INSTALLED_VERSION}" != "${NAGIOS_VERSION}" ]]
then
    warn "Nagios installé : ${INSTALLED_VERSION}"
    warn "Headers utilisés : ${NAGIOS_VERSION}"
fi


"${NAGIOS_BIN}" -v "${NAGIOS_CFG}" >/dev/null ||
    die "Configuration Nagios invalide."


ok "Nagios Core opérationnel."


# ==============================================================================
# DÉPENDANCES
# ==============================================================================

info "Installation des dépendances"

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    build-essential \
    gcc \
    g++ \
    make \
    autoconf \
    automake \
    libtool \
    pkg-config \
    libc6-dev \
    librrd-dev \
    rrdtool \
    libboost-all-dev \
    wget \
    curl \
    git \
    rsync \
    tar \
    gzip \
    ca-certificates \
    file \
    binutils \
    python3 \
    iproute2 \
    apache2 \
    apache2-utils \
    php \
    php-cli \
    php-common \
    php-gd \
    php-mbstring \
    php-xml \
    php-curl \
    php-sqlite3 \
    libapache2-mod-php


a2enmod rewrite >/dev/null || true

systemctl enable apache2
systemctl restart apache2

ok "Dépendances installées."


# ==============================================================================
# BOOST
# ==============================================================================

info "Vérification de Boost"

[[ -f /usr/include/boost/version.hpp ]] ||
    die "Boost introuvable."

grep BOOST_LIB_VERSION \
    /usr/include/boost/version.hpp |
    head -1 || true

ok "Boost disponible."


# ==============================================================================
# RRD
# ==============================================================================

info "Vérification de RRDtool"

dpkg-query \
    -W \
    -f='${Status}\n' \
    librrd-dev 2>/dev/null |
    grep -q "install ok installed" ||
    die "librrd-dev absent."

rrdtool --version || true

ok "RRDtool disponible."


# ==============================================================================
# SAUVEGARDES
# ==============================================================================

info "Sauvegardes"

NAGIOS_CFG_BACKUP="${NAGIOS_CFG}.before-nagvis-${DATE}"

cp \
    "${NAGIOS_CFG}" \
    "${NAGIOS_CFG_BACKUP}"

echo
echo "nagios.cfg sauvegardé :"
echo "    ${NAGIOS_CFG_BACKUP}"


mkdir -p "${LIVESTATUS_DIR}"


if [[ -f "${MODULE}" ]]; then

    cp \
        "${MODULE}" \
        "${MODULE}.backup-${DATE}"

fi


if [[ -f "${UNIXCAT}" ]]; then

    cp \
        "${UNIXCAT}" \
        "${UNIXCAT}.backup-${DATE}"

fi


if [[ -d "${NAGVIS_DIR}" ]]; then

    echo
    echo "Installation NagVis existante détectée."

    mv \
        "${NAGVIS_DIR}" \
        "${NAGVIS_DIR}.backup-${DATE}"

    echo
    echo "Sauvegarde :"
    echo "    ${NAGVIS_DIR}.backup-${DATE}"

fi


# ==============================================================================
# DÉSACTIVATION TEMPORAIRE LIVESTATUS
# ==============================================================================

info "Désactivation temporaire de Livestatus"

sed -i \
    '\|^[[:space:]]*broker_module=.*livestatus\.o|d' \
    "${NAGIOS_CFG}"

rm -f "${SOCKET}"


"${NAGIOS_BIN}" \
    -v \
    "${NAGIOS_CFG}" >/dev/null ||
    die "Configuration Nagios invalide."


systemctl restart nagios

sleep 2


systemctl is-active --quiet nagios ||
    die "Nagios ne démarre pas sans Livestatus."


ok "Nagios fonctionne sans Livestatus."


# ==============================================================================
# WORKDIR
# ==============================================================================

info "Préparation du répertoire de travail"

rm -rf "${WORKDIR}"

mkdir -p \
    "${WORKDIR}/nagios-src" \
    "${WORKDIR}/livestatus-src"

cd "${WORKDIR}"


# ==============================================================================
# SOURCES NAGIOS
# ==============================================================================

info "Téléchargement des sources Nagios ${NAGIOS_VERSION}"

wget \
    --https-only \
    --timeout=30 \
    --tries=3 \
    -O nagios.tar.gz \
    "${NAGIOS_URL}" ||
    die "Téléchargement Nagios impossible."


[[ -s nagios.tar.gz ]] ||
    die "Archive Nagios vide."


tar tzf nagios.tar.gz >/dev/null ||
    die "Archive Nagios invalide."


tar xzf \
    nagios.tar.gz \
    -C "${WORKDIR}/nagios-src" \
    --strip-components=1


[[ -d "${WORKDIR}/nagios-src/include" ]] ||
    die "Headers include Nagios absents."

[[ -d "${WORKDIR}/nagios-src/lib" ]] ||
    die "Headers lib Nagios absents."

[[ -f "${WORKDIR}/nagios-src/lib/libnagios.h" ]] ||
    die "libnagios.h absent."


ok "Sources Nagios récupérées."


# ==============================================================================
# LIVESTATUS
# ==============================================================================

info "Téléchargement de MK Livestatus ${LIVESTATUS_VERSION}"

cd "${WORKDIR}"

wget \
    --https-only \
    --timeout=30 \
    --tries=3 \
    -O livestatus.tar.gz \
    "${LIVESTATUS_URL}" ||
    die "Téléchargement Livestatus impossible."


[[ -s livestatus.tar.gz ]] ||
    die "Archive Livestatus vide."


tar tzf livestatus.tar.gz >/dev/null ||
    die "Archive Livestatus invalide."


tar xzf \
    livestatus.tar.gz \
    -C "${WORKDIR}/livestatus-src" \
    --strip-components=1


cd "${WORKDIR}/livestatus-src"


[[ -d nagios4 ]] ||
    die "Répertoire nagios4 absent."

[[ -f nagios4/shared.h ]] ||
    die "nagios4/shared.h absent."


# ==============================================================================
# HEADERS NAGIOS
# ==============================================================================

info "Injection des headers Nagios ${NAGIOS_VERSION}"


cp -a \
    nagios4 \
    nagios4.original


cp -vf \
    "${WORKDIR}/nagios-src/lib/"*.h \
    nagios4/


cp -vf \
    "${WORKDIR}/nagios-src/include/"*.h \
    nagios4/


if [[ -d "${WORKDIR}/nagios-src/base" ]]; then

    find \
        "${WORKDIR}/nagios-src/base" \
        -maxdepth 1 \
        -type f \
        -name '*.h' \
        -exec cp -vf {} nagios4/ \;

fi


[[ -f nagios4/libnagios.h ]] ||
    die "nagios4/libnagios.h absent."


# ==============================================================================
# CORRECTIF SHARED.H
# ==============================================================================

info "Correction shared.h pour Nagios 4.5.x"

SHARED_H="nagios4/shared.h"


sed -i \
    -E \
    's|^[[:space:]]*#include[[:space:]]*"lib/libnagios\.h"[[:space:]]*$|#include "libnagios.h"|' \
    "${SHARED_H}"


if ! grep -qE \
    '^[[:space:]]*#include[[:space:]]*"libnagios\.h"' \
    "${SHARED_H}"
then

    sed -i \
        '5i #include "libnagios.h"' \
        "${SHARED_H}"

fi


# Suppression des doublons éventuels.

python3 - <<'PY'
from pathlib import Path

path = Path("nagios4/shared.h")

lines = path.read_text().splitlines()

result = []
seen = False

for line in lines:

    if line.strip() == '#include "libnagios.h"':

        if seen:
            continue

        seen = True

        result.append('#include "libnagios.h"')

    else:

        result.append(line)

path.write_text("\n".join(result) + "\n")
PY


if grep -q \
    'lib/libnagios.h' \
    "${SHARED_H}"
then

    die "shared.h référence toujours lib/libnagios.h."

fi


grep -q \
    '#include "libnagios.h"' \
    "${SHARED_H}" ||
    die "libnagios.h non inclus."


echo
grep -n libnagios "${SHARED_H}"
echo


ok "Correctif appliqué."


# ==============================================================================
# COMPILATION LIVESTATUS
# ==============================================================================

info "Compilation de MK Livestatus"


export CFLAGS="-O2 -fcommon"
export CXXFLAGS="-O2 -fcommon"


if [[ ! -x ./configure ]]; then

    autoreconf -fi

fi


if ! ./configure \
    --with-nagios4 \
    CFLAGS="${CFLAGS}" \
    CXXFLAGS="${CXXFLAGS}"
then

    echo
    echo "config.log :"
    echo

    tail -100 config.log || true

    die "configure Livestatus a échoué."

fi


make clean >/dev/null 2>&1 || true


make -j"$(nproc)" ||
    die "Compilation Livestatus impossible."


ok "Livestatus compilé."


# ==============================================================================
# RECHERCHE DES BINAIRES
# ==============================================================================

info "Recherche des binaires Livestatus"


COMPILED_MODULE="$(
    find "${WORKDIR}/livestatus-src" \
        -type f \
        -name 'livestatus.o' \
        -print \
        -quit
)"


[[ -n "${COMPILED_MODULE}" ]] ||
    die "livestatus.o introuvable."

[[ -s "${COMPILED_MODULE}" ]] ||
    die "livestatus.o vide."


COMPILED_UNIXCAT="$(
    find "${WORKDIR}/livestatus-src" \
        -type f \
        -name unixcat \
        -perm -u+x \
        -print \
        -quit || true
)"


file "${COMPILED_MODULE}"


if ldd "${COMPILED_MODULE}" |
    grep -q "not found"
then

    ldd "${COMPILED_MODULE}"

    die "Dépendance Livestatus manquante."

fi


# ==============================================================================
# INSTALLATION LIVESTATUS
# ==============================================================================

info "Installation de MK Livestatus"


mkdir -p "${LIVESTATUS_DIR}"


install \
    -m 755 \
    "${COMPILED_MODULE}" \
    "${MODULE}"


if [[ -n "${COMPILED_UNIXCAT}" ]]; then

    install \
        -m 755 \
        "${COMPILED_UNIXCAT}" \
        "${UNIXCAT}"

fi


ok "Livestatus installé."


# ==============================================================================
# SOCKET
# ==============================================================================

info "Préparation du socket Livestatus"


mkdir -p "${NAGIOS_VAR}/rw"

chown \
    nagios:nagios \
    "${NAGIOS_VAR}/rw"

chmod \
    2775 \
    "${NAGIOS_VAR}/rw"


usermod \
    -aG nagios \
    "${APACHE_USER}"


rm -f "${SOCKET}"


# ==============================================================================
# CONFIGURATION NAGIOS
# ==============================================================================

info "Configuration du broker Nagios"


if grep -qE \
    '^[[:space:]]*event_broker_options=' \
    "${NAGIOS_CFG}"
then

    sed -i \
        's/^[[:space:]]*event_broker_options=.*/event_broker_options=-1/' \
        "${NAGIOS_CFG}"

else

    echo >> "${NAGIOS_CFG}"

    echo \
        "event_broker_options=-1" \
        >> "${NAGIOS_CFG}"

fi


sed -i \
    '\|^[[:space:]]*broker_module=.*livestatus\.o|d' \
    "${NAGIOS_CFG}"


cat >> "${NAGIOS_CFG}" <<EOF

# ==============================================================================
# MK Livestatus ${LIVESTATUS_VERSION}
# ==============================================================================

broker_module=${MODULE} ${SOCKET}

EOF


# ==============================================================================
# VALIDATION
# ==============================================================================

info "Validation de la configuration Nagios"


"${NAGIOS_BIN}" \
    -v \
    "${NAGIOS_CFG}" ||
    die "Configuration Nagios invalide."


# ==============================================================================
# DÉMARRAGE NAGIOS + LIVESTATUS
# ==============================================================================

info "Démarrage Nagios + Livestatus"


rm -f "${SOCKET}"


systemctl restart nagios


sleep 5


if ! systemctl is-active --quiet nagios
then

    journalctl \
        -u nagios \
        -n 100 \
        --no-pager

    die "Nagios a crashé avec Livestatus."

fi


# ==============================================================================
# ATTENTE DU SOCKET
# ==============================================================================

for i in {1..15}; do

    if [[ -S "${SOCKET}" ]]; then
        break
    fi

    echo "Attente du socket ${i}/15..."

    sleep 1

done


[[ -S "${SOCKET}" ]] ||
    die "Socket Livestatus absent."


ls -lah "${SOCKET}"


ok "Socket Livestatus disponible."


# ==============================================================================
# TEST LIVESTATUS
# ==============================================================================

info "Test de Livestatus"


if [[ -x "${UNIXCAT}" ]]; then

    RESPONSE="$(
        printf 'GET status\nColumns: program_version\n\n' |
        "${UNIXCAT}" \
            "${SOCKET}" \
            2>/dev/null || true
    )"


    [[ -n "${RESPONSE}" ]] ||
        die "Livestatus ne répond pas."


    echo
    echo "Réponse Livestatus :"
    echo
    echo "    ${RESPONSE}"
    echo

fi


# ==============================================================================
# STABILITÉ LIVESTATUS
# ==============================================================================

info "Vérification de la stabilité de Livestatus"


echo
echo "Attente de 15 secondes..."
echo


sleep 15


if ! systemctl is-active --quiet nagios
then

    journalctl \
        -u nagios \
        -n 100 \
        --no-pager

    die "Nagios a crashé."

fi


if journalctl \
    -u nagios \
    --since "-1 minute" \
    --no-pager |
    grep -q 'SIGSEGV'
then

    die "SIGSEGV détecté."

fi


ok "Nagios + Livestatus stables."


# ==============================================================================
#
#                                NAGVIS
#
# ==============================================================================


# ==============================================================================
# TÉLÉCHARGEMENT NAGVIS
# ==============================================================================

info "Téléchargement de NagVis"


cd "${WORKDIR}"

rm -rf nagvis-src


NAGVIS_CLONED=0


for TAG in \
    "${NAGVIS_VERSION}" \
    "nagvis-${NAGVIS_VERSION}" \
    "v${NAGVIS_VERSION}"
do

    echo
    echo "Tentative avec le tag : ${TAG}"
    echo

    rm -rf nagvis-src


    if git clone \
        --depth 1 \
        --branch "${TAG}" \
        "${NAGVIS_GIT}" \
        nagvis-src
    then

        NAGVIS_CLONED=1

        echo
        echo "Tag NagVis utilisé : ${TAG}"
        echo

        break

    fi

done


# ------------------------------------------------------------------------------
# Si le dépôt n'utilise pas ces noms de tags, branche principale.
# ------------------------------------------------------------------------------

if [[ "${NAGVIS_CLONED}" -eq 0 ]]; then

    warn "Tag ${NAGVIS_VERSION} non trouvé."

    echo
    echo "Récupération de la branche principale."
    echo

    rm -rf nagvis-src


    git clone \
        --depth 1 \
        "${NAGVIS_GIT}" \
        nagvis-src ||
        die "Téléchargement NagVis impossible."

fi


[[ -d "${WORKDIR}/nagvis-src" ]] ||
    die "Sources NagVis absentes."


# ==============================================================================
# INSTALLATION NAGVIS
# ==============================================================================

info "Installation de NagVis"


rm -rf "${NAGVIS_DIR}"

mkdir -p "${NAGVIS_DIR}"


rsync \
    -a \
    --exclude='.git' \
    "${WORKDIR}/nagvis-src/" \
    "${NAGVIS_DIR}/"


[[ -d "${NAGVIS_DIR}/share" ]] ||
    die "Répertoire share NagVis absent."


ok "Sources NagVis installées."


# ==============================================================================
# ARBORESCENCE NAGVIS
# ==============================================================================

info "Création de l'arborescence NagVis"


mkdir -p \
    "${NAGVIS_DIR}/etc" \
    "${NAGVIS_DIR}/etc/maps" \
    "${NAGVIS_DIR}/var" \
    "${NAGVIS_DIR}/var/tmpl" \
    "${NAGVIS_DIR}/var/tmpl/cache" \
    "${NAGVIS_DIR}/var/tmpl/compile" \
    "${NAGVIS_DIR}/share/userfiles" \
    "${NAGVIS_DIR}/share/userfiles/images" \
    "${NAGVIS_DIR}/share/userfiles/images/maps" \
    "${NAGVIS_DIR}/share/userfiles/images/shapes" \
    "${NAGVIS_DIR}/share/userfiles/images/iconsets"


# ==============================================================================
# DOCS
# ==============================================================================

info "Configuration de share/docs"


rm -rf "${NAGVIS_DIR}/share/docs"


if [[ -d "${NAGVIS_DIR}/docs" ]]; then

    ln -s \
        "${NAGVIS_DIR}/docs" \
        "${NAGVIS_DIR}/share/docs"

    ok "share/docs configuré."

else

    mkdir -p \
        "${NAGVIS_DIR}/share/docs"

    warn "docs absent : share/docs vide créé."

fi


# ==============================================================================
# CONFIGURATION NAGVIS
# ==============================================================================
#
# IMPORTANT :
#
# Cette configuration a été validée sur notre installation.
#
# Elle évite notamment :
#
#   Invalid JSON response
#   Trying to access array offset on null
#   ViewManageBackends.php
#
# ==============================================================================

info "Création de la configuration NagVis"


# ------------------------------------------------------------------------------
# Sauvegarde si un fichier existe déjà.
# ------------------------------------------------------------------------------

if [[ -f "${NAGVIS_CFG}" ]]; then

    cp \
        "${NAGVIS_CFG}" \
        "${NAGVIS_CFG}.backup-${DATE}"

fi


cat > "${NAGVIS_CFG}" <<EOF
; ==============================================================================
; NagVis configuration
; ==============================================================================

[global]
dateformat="Y-m-d H:i:s"
language="en_US"
refreshtime=60

[defaults]
backend="live_1"

[backend_live_1]
backendtype="mklivestatus"
socket="unix:${SOCKET}"
EOF


# ==============================================================================
# PERMISSIONS NAGVIS
# ==============================================================================

info "Configuration des permissions NagVis"


chown -R \
    root:root \
    "${NAGVIS_DIR}"


chown -R \
    "${APACHE_USER}:${APACHE_GROUP}" \
    "${NAGVIS_DIR}/etc" \
    "${NAGVIS_DIR}/var" \
    "${NAGVIS_DIR}/share/userfiles"


chmod \
    664 \
    "${NAGVIS_CFG}"


find "${NAGVIS_DIR}/etc" \
    -type d \
    -exec chmod 775 {} \;


find "${NAGVIS_DIR}/var" \
    -type d \
    -exec chmod 775 {} \;


find "${NAGVIS_DIR}/share/userfiles" \
    -type d \
    -exec chmod 775 {} \;


ok "Permissions NagVis configurées."


# ==============================================================================
# AFFICHAGE CONFIGURATION
# ==============================================================================

info "Configuration NagVis active"


cat "${NAGVIS_CFG}"


# ==============================================================================
# APACHE
# ==============================================================================

info "Configuration Apache pour NagVis"


cat > "${APACHE_CONF}" <<EOF
# ==============================================================================
# NagVis
# ==============================================================================

Alias /nagvis "${NAGVIS_DIR}/share"

<Directory "${NAGVIS_DIR}/share">

    Options FollowSymLinks

    AllowOverride None

    Require all granted

    DirectoryIndex index.php

</Directory>


<Directory "${NAGVIS_DIR}/share/userfiles">

    Require all granted

</Directory>
EOF


a2enmod rewrite >/dev/null || true

a2enconf nagvis >/dev/null


apache2ctl configtest ||
    die "Configuration Apache invalide."


systemctl restart apache2


ok "Apache redémarré."


# ==============================================================================
# TEST WWW-DATA -> LIVESTATUS
# ==============================================================================

info "Test Livestatus depuis www-data"


if [[ -x "${UNIXCAT}" ]]; then

    WWW_RESPONSE="$(
        runuser \
            -u "${APACHE_USER}" \
            -- \
            "${UNIXCAT}" \
            "${SOCKET}" <<'EOF' 2>/dev/null || true
GET status
Columns: program_version

EOF
    )"


    if [[ -n "${WWW_RESPONSE}" ]]; then

        echo
        echo "Réponse Livestatus depuis www-data :"
        echo
        echo "    ${WWW_RESPONSE}"
        echo

        ok "Apache/www-data communique avec Livestatus."

    else

        echo
        echo "Socket :"
        ls -lah "${SOCKET}" || true

        echo
        echo "Utilisateur Apache :"
        id "${APACHE_USER}" || true

        die "www-data ne peut pas communiquer avec Livestatus."

    fi

fi


# ==============================================================================
# TEST PHP
# ==============================================================================

info "Vérification PHP"


php -v | head -2


echo
echo "Modules principaux :"
echo


php -m |
    grep -Ei \
    'gd|mbstring|xml|curl|sqlite' || true


# ==============================================================================
# TEST HTTP
# ==============================================================================

info "Test HTTP NagVis"


HTTP_TEST="/tmp/nagvis-http-test.html"


HTTP_CODE="$(
    curl \
        -L \
        -s \
        -o "${HTTP_TEST}" \
        -w '%{http_code}' \
        http://127.0.0.1/nagvis/ || true
)"


echo
echo "Code HTTP : ${HTTP_CODE}"
echo


case "${HTTP_CODE}" in

    200|301|302)

        ok "NagVis répond via Apache."

        ;;

    *)

        warn "NagVis retourne HTTP ${HTTP_CODE}."

        echo
        echo "Réponse :"
        echo

        head -50 "${HTTP_TEST}" || true

        echo
        echo "Logs Apache :"
        echo

        journalctl \
            -u apache2 \
            -n 50 \
            --no-pager || true

        ;;

esac


# ==============================================================================
# TEST FINAL
# ==============================================================================

info "Test final de stabilité"


echo
echo "Attente de 20 secondes..."
echo


sleep 20


if ! systemctl is-active --quiet nagios
then

    echo
    echo "Nagios a crashé :"
    echo

    journalctl \
        -u nagios \
        -n 100 \
        --no-pager

    die "Nagios n'est plus actif."

fi


if journalctl \
    -u nagios \
    --since "-2 minutes" \
    --no-pager |
    grep -q 'SIGSEGV'
then

    echo
    echo "SIGSEGV détecté :"
    echo

    journalctl \
        -u nagios \
        --since "-2 minutes" \
        --no-pager

    die "SIGSEGV détecté."

fi


systemctl is-active --quiet apache2 ||
    die "Apache n'est pas actif."


ok "Nagios est stable."
ok "Apache est actif."


# ==============================================================================
# TEST FINAL LIVESTATUS
# ==============================================================================

info "Test final Livestatus"


if [[ -x "${UNIXCAT}" ]]; then

    printf \
        'GET status\nColumns: program_version\n\n' |
        "${UNIXCAT}" \
        "${SOCKET}"

fi


# ==============================================================================
# RÉSULTAT
# ==============================================================================

echo
echo
echo "======================================================================"
echo "                    INSTALLATION TERMINÉE"
echo "======================================================================"
echo
echo "Nagios Core"
echo "    ${INSTALLED_VERSION:-inconnu}"
echo
echo "MK Livestatus"
echo "    ${LIVESTATUS_VERSION}"
echo
echo "Module"
echo "    ${MODULE}"
echo
echo "Socket"
echo "    ${SOCKET}"
echo
echo "Unixcat"
echo "    ${UNIXCAT}"
echo
echo "----------------------------------------------------------------------"
echo
echo "NagVis"
echo "    ${NAGVIS_DIR}"
echo
echo "Configuration"
echo "    ${NAGVIS_CFG}"
echo
echo "Backend par défaut"
echo "    live_1"
echo
echo "URL"
echo
echo "    http://ADRESSE_IP_DU_SERVEUR/nagvis/"
echo
echo "----------------------------------------------------------------------"
echo
echo "Test Livestatus"
echo
echo "    printf 'GET status\\nColumns: program_version\\n\\n' \\"
echo "    | ${UNIXCAT} ${SOCKET}"
echo
echo "----------------------------------------------------------------------"
echo
echo "Diagnostic"
echo
echo "    systemctl status nagios --no-pager -l"
echo "    systemctl status apache2 --no-pager -l"
echo
echo "    journalctl -u nagios -n 100 --no-pager"
echo "    journalctl -u apache2 -n 100 --no-pager"
echo
echo "======================================================================"
