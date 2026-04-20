#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

missing=()
for package in ca-certificates curl; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || missing+=("$package")
done

if [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
  dpkg-query -W -f='${Status}' qemu-guest-agent 2>/dev/null | grep -q 'install ok installed' || missing+=(qemu-guest-agent)
fi

if ((${#missing[@]} > 0)); then
  apt-get update
  apt-get install -y "${missing[@]}"
fi

if [[ -e /dev/virtio-ports/org.qemu.guest_agent.0 ]]; then
  systemctl start qemu-guest-agent
fi
