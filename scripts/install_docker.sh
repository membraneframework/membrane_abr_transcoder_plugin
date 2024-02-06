#!/bin/bash

set -euo pipefail

apt-get update &&  apt-get -y install --no-install-recommends ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg |  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
"$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" |
 tee /etc/apt/sources.list.d/docker.list >/dev/null
apt-get update

apt-get -y install --no-install-recommends docker-ce docker-ce-cli 
