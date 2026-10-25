#!/usr/bin/env bash
#
# BrainFrame dev-environment setup / validation (Debian/Ubuntu).
#
#   scripts/install.sh           set up the environment (install packages and
#                                tooling, wire git hooks, extend PATH)
#   scripts/install.sh --check   validate only; change nothing; exit non-zero
#                                if anything is missing
#
# A thin wrapper: the work is done by ansible/dev-environment.yml, and this runs
# the command written at the top of that playbook. Any other arguments pass
# straight through to ansible-playbook (e.g. --diff, --skip-tags packages).
#
# Windows is covered by the PowerShell port, scripts/install.ps1, which mirrors
# the playbook's checks — keep the two in step when either changes.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "ansible-playbook not found. Install Ansible, then re-run:" >&2
  echo "  sudo apt install ansible" >&2
  exit 1
fi

exec ansible-playbook -K -i localhost, ansible/dev-environment.yml "$@"
