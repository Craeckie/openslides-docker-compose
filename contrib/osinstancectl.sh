#!/bin/bash

# Set up a new OpenSlides docker-compose instance
#
# This script makes some assumptions and would need more options to become more
# flexible

set -eu

TEMPLATE_REPO="/srv/openslides/openslides-docker-compose"
# TEMPLATE_REPO="https://github.com/OpenSlides/openslides-docker-compose"
OSDIR="/srv/openslides"
INSTANCES="${OSDIR}/docker-instances"

NGINX_TEMPLATE=
PROJECT_NAME=
PROJECT_DIR=
PORT=
MODE=
START=

usage() {
cat <<EOF
Usage: ${BASH_SOURCE[0]} [-r|--remove] <instance_domain>

Set up a new docker-compose-based OpenSlides instance (unless --remove is
used).  Expects a FQDN.

Options:
  -r, --remove    Remove the instance instance_domain
EOF
}

check_for_dependency () {
    [[ -n "$1" ]] || return 0
    which "$1" > /dev/null || { echo "ERROR: Dependency not found: $1"; return 1; }
}


arg_check() {
  [[ -d "$OSDIR" ]] || { echo "ERROR: $OSDIR not found!"; return 2; }
  [[ -n "$PROJECT_NAME" ]] || {
    echo "ERROR: Please specify a project name"; return 2;
  }
}

verify_domain() {
  # Verify provided domain
  HOSTNAME=$(hostname -f)
  IP=$(host "$HOSTNAME" | awk '/has address/ { print $4; exit; } /has IPv6 address/ { print $5}')
  host "$PROJECT_NAME" | grep -q "$IP" || {
    echo "ERROR: $PROJECT_NAME does not point to this host?"
    return 3
  }
}


next_free_port() {
  # Select new port
  local HIGHEST_PORT_IN_USE=$(
    find "${INSTANCES}" -type f -name docker-compose.yml -print0 |
    xargs -0 grep -h -o "127.0.0.1:61[0-9]\{3\}:80"|
    cut -d: -f2 | sort -rn | head -1
  )
  [[ -n "$HIGHEST_PORT_IN_USE" ]] || HIGHEST_PORT_IN_USE=61000
  local PORT=$((HIGHEST_PORT_IN_USE + 1))

  # Check if port is actually free
  #  try to find the next free port (this situation can occur if there are test
  #  instances outside of the regular instances directory)
  n=0
  while ! ss -tnHl | awk -v port="$PORT" '$4 ~ port { exit 2 }'; do
    [[ $n -lt 5 ]] || { echo "ERROR: Could not find free port"; exit 3; }
    ((PORT+=1))
    ((n+=1))
  done
  echo "$PORT"
}

create_instance_dir() {
  # Update yaml
  git clone "${TEMPLATE_REPO}" "${PROJECT_DIR}"
  cp -v "${DCCONFIG}"{.example,}
  ex -s +"%s/127.0.0.1:\zs61000\ze:80/${PORT}/" +x "$DCCONFIG"
}

update_nginx_config() {
# Create Nginx configs
  # First, without TLS
  sed -e "s/<INSTANCE>/${PROJECT_NAME}/" "$NGINX_TEMPLATE" \
    -e "/proxy_pass/s/61000/${PORT}/" \
    > /etc/nginx/sites-available/"${PROJECT_NAME}".conf
  ln -s ../sites-available/"${PROJECT_NAME}".conf /etc/nginx/sites-enabled/ || true
  systemctl reload nginx

  # Generate Let's Encrypt certificate
  acmetool want "${PROJECT_NAME}"
  echo "Got certificate."

  # Update Nginx to use TLS certs
  ex -s +"g/ssl-cert-snakeoil/d" +"g/ssl_certificate/s/#\ //" +x \
    /etc/nginx/sites-available/"${PROJECT_NAME}".conf
  systemctl reload nginx
}

remove() {
  local PROJECT_NAME="$1"
  # Ask for confirmation
  local ANS=
  echo "Delete the following instance including all its data and configuration?"
  echo "  $PROJECT_DIR"
  read -p "Really delete? (uppercase YES to confirm) " ANS
  [[ "$ANS" = "YES" ]] || return 0

  echo "Stopping and removing containers..."
  cd "${PROJECT_DIR}" &&
    ./handle-instance.sh -f rm
  cd
  echo "Removing instance repo dir..."
  rm -rf "${PROJECT_DIR}"
  echo "Remove config from Nginx..."
  rm -f /etc/nginx/sites-available/"${PROJECT_NAME}".conf \
     /etc/nginx/sites-enabled/"${PROJECT_NAME}".conf
  systemctl reload nginx
  echo "acmetool unwant..."
  acmetool unwant "$PROJECT_NAME"
  echo "Done."
}

shortopt="hars"
longopt="help,add,remove,start"

ARGS=$(getopt -o "$shortopt" -l "$longopt" -- "$@")
if [ $? -ne 0 ]; then usage; exit 1; fi
eval set -- "$ARGS";

[[ $# -gt 1 ]] || { usage; exit 2; }

while true; do
    case "$1" in
        -a|--add)
          MODE=create
          shift 1
          ;;
        -r|--remove)
          MODE=remove
          shift 1
          ;;
        -s|--start)
          START=1
          shift 1
          ;;
        -h|--help) usage; exit 0 ;;
        --) shift ; break ;;
        *) usage; exit 1 ;;
    esac
done

[[ -n "$MODE" ]] || { usage; exit 2; }

DEPS=(
  gawk
  acmetool
)
# Check dependencies
for i in "${DEPS[@]}"; do
    check_for_dependency "$i"
done

PROJECT_NAME="$1"
PROJECT_DIR="${INSTANCES}/${PROJECT_NAME}"
DCCONFIG="${PROJECT_DIR}/docker-compose.yml"
NGINX_TEMPLATE="${PROJECT_DIR}/contrib/nginx.conf.in"

case "$MODE" in
  remove)
    arg_check || { usage; exit 2; }
    remove "$PROJECT_NAME"
    exit 0
    ;;
  create)
    arg_check || { usage; exit 2; }
    echo "Creating new instance: $PROJECT_NAME"
    verify_domain
    PORT=$(next_free_port)
    create_instance_dir
    update_nginx_config
    ;;
esac

# Start containers
if [[ -n "$START" ]]; then
  cd "${PROJECT_DIR}"
  ./handle-instance.sh -f run
else
  echo "INFO: Not automatically starting containers."
fi
