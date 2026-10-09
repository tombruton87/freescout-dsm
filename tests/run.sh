#!/usr/bin/env bash
# Every test that runs without a Synology.
set -u
cd "$(dirname "$0")"
rc=0
bash test-api.sh || rc=1
echo
bash test-read-settings.sh || rc=1
echo
bash test-wizard.sh || rc=1
exit $rc
