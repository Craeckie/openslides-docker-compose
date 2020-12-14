#!/bin/bash

# -------------------------------------------------------------------
# Copyright (C) 2020 by Intevation GmbH
# Author(s):
# Gernot Schulz <gernot@intevation.de>
#
# This program is distributed under the MIT license, as described
# in the LICENSE file included with the distribution.
# SPDX-License-Identifier: MIT
# -------------------------------------------------------------------

DEFAULT_LABEL="Backup triggered externally on $(date +%F-%H:%M:%S)"

usage() {
  cat << EOF
Usage: ${BASH_SOURCE[0]} <start|stop> [backup label]

  start: Invokes a backup using pg_start_backup()
  stop:  Stops backups on cluster using pg_stop_backup()
EOF
}

check_recovery() {
  local RECOVERY
  RECOVERY="$(psql -tAv ON_ERROR_STOP=1 \
    <<< "SELECT pg_is_in_recovery();")"
  if [[ "$RECOVERY" = "t" ]]; then
    echo "INFO: recovery is in progress. Is this a standby node?"
    return 1
  fi
}

[[ "$(whoami)" = "postgres" ]] || {
  echo "ERROR: This script must be run as user postgres"
  exit 2
}

case $1 in
  "start")
    shift
    check_recovery || exit 0
    LABEL=${1:-$DEFAULT_LABEL}
    psql -tAv ON_ERROR_STOP=1 -v label="$LABEL" <<< \
      "SELECT pg_start_backup(:'label')" &&
      cat 11/main/backup_label
    ;;
  "stop")
    check_recovery || exit 0
    psql -tAv ON_ERROR_STOP=1 <<< "SELECT pg_stop_backup()"
    ;;
  *)
    usage
    exit 0
    ;;
esac
