#!/bin/bash

#
# Script options (exit script on command fail).
#
set -e

#
# Define default Variables.
#

USER="bind"
GROUP="bind"
COMMAND_OPTIONS_DEFAULT="-f $@"
COMMAND_OPTIONS="${COMMAND_OPTIONS:-${COMMAND_OPTIONS_DEFAULT}}"
dirs=( /var/bind /etc/bind /run/named /var/log/named /var/cache/bind )

read -r -a command_options <<< "${COMMAND_OPTIONS}"
COMMAND=( /usr/sbin/named -u "${USER}" -c /etc/bind/named.conf "${command_options[@]}" )

mkdir -p /run "${dirs[@]}"

#
# Display Version
#
echo "versions"
echo "=============="
echo "  image:           ${IMAGE_VERSION:-${VERSION:-}}"
echo

#
# Display settings on standard out.
#
echo "named settings"
echo "=============="
echo
echo "  Username:        ${USER}"
echo "  Groupname:       ${GROUP}"
echo "  Command:         ${COMMAND[*]}"
echo

#
# Set owner and permissions.
#
echo "Set owner and permissions... "
chown -R "${USER}:${GROUP}" "${dirs[@]}"
chmod -R o-rwx "${dirs[@]}"
echo "[DONE]"

#
# Start named.
#
echo "Start named... "
exec "${COMMAND[@]}"
