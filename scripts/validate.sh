#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f collections/requirements.yml ]]; then
  ansible-galaxy collection install -r collections/requirements.yml -p .ansible/collections
fi

ansible-playbook --syntax-check provision.yml
