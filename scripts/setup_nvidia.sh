#!/bin/bash

set -euo pipefail

NVIDIA_DRIVERS_VERSION=535
export DEBIAN_FRONTEND=noninteractive

function install_nvidia_drivers() {
	 apt-get update 
	 apt-get -y install --no-install-recommends \
   nvidia-driver-${NVIDIA_DRIVERS_VERSION} \
	 nvidia-dkms-${NVIDIA_DRIVERS_VERSION} 

	 apt-get install -y --fix-broken --no-install-recommends nvidia-cuda-toolkit

   apt-get autoremove --purge -y \
		&&  apt-get clean \
		&&  apt-get autoclean
}

function install_nvidia_container_toolkit() {
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |  gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
     tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
   apt-get update

   apt-get install -y --no-install-recommends nvidia-container-toolkit
   apt-get autoremove --purge -y \
		&&  apt-get clean \
		&&  apt-get autoclean
}

function install_nvidia_docker() {
  curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -

  distribution=$(
    . /etc/os-release
    echo $ID$VERSION_ID
  )

  curl -s -L https://nvidia.github.io/nvidia-docker/${distribution}/nvidia-docker.list |
     tee /etc/apt/sources.list.d/nvidia-docker.list &&
     apt update

   apt-get install -y --no-install-recommends nvidia-docker2
   pkill -SIGHUP dockerd
}

function setup_nvidia_docker() {
	nvidia-ctk runtime configure
	systemctl restart docker
}

trap 'echo $ERROR at line $LINENO' ERR

install_nvidia_drivers
install_nvidia_container_toolkit
install_nvidia_docker
setup_nvidia_docker
