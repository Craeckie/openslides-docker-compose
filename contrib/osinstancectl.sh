#!/bin/bash

# Manage dockerized OpenSlides instances

set -eu
set -o noclobber
set -o pipefail

# Defaults (override in /etc/osinstancectl)
TEMPLATE_REPO="/srv/openslides/openslides-docker-compose"
# TEMPLATE_REPO="https://github.com/OpenSlides/openslides-docker-compose"
OSDIR="/srv/openslides"
INSTANCES="${OSDIR}/docker-instances"
DEFAULT_DOCKER_IMAGE_NAME_OPENSLIDES=openslides/openslides
DEFAULT_DOCKER_IMAGE_TAG_OPENSLIDES=latest
# If set, these variables override the defaults in the
# docker-compose.yml.example template file.  They can be configured on the
# command line as well as in /etc/osinstancectl.
RELAYHOST=
MAIN_REPOSITORY_URL= # default repo used for all openslides/* images

ME=$(basename -s .sh "${BASH_SOURCE[0]}")
CONFIG="/etc/osinstancectl"
MARKER=".osinstancectl-marker"
DOCKER_IMAGE_NAME_OPENSLIDES=
DOCKER_IMAGE_TAG_OPENSLIDES=
PROJECT_NAME=
PROJECT_DIR=
PROJECT_STACK_NAME=
PORT=
DEPLOYMENT_MODE=
MODE=
OPT_LONGLIST=
OPT_METADATA=
OPT_METADATA_SEARCH=
OPT_IMAGE_INFO=
OPT_ADD_ACCOUNT=1
OPT_LOCALONLY=
OPT_FORCE=
OPT_WWW=
OPT_FAST=
FILTER=
CLONE_FROM=
ADMIN_SECRETS_FILE="adminsecret.env"
USER_SECRETS_FILE="usersecret.env"
OPENSLIDES_USER_FIRSTNAME=
OPENSLIDES_USER_LASTNAME=

# Color and formatting settings
OPT_COLOR=auto
NCOLORS=
COL_NORMAL=""
COL_RED=""
COL_YELLOW=""
COL_GREEN=""
BULLET='●'
SYM_NORMAL="OK"
SYM_ERROR="XX"
SYM_UNKNOWN="??"

# Internal options
OPT_USE_PARALLEL=

enable_color() {
  NCOLORS=$(tput colors) # no. of colors
  if [[ -n "$NCOLORS" ]] && [[ "$NCOLORS" -ge 8 ]]; then
    COL_NORMAL="$(tput sgr0)"
    COL_RED="$(tput setaf 1)"
    COL_YELLOW="$(tput setaf 3)"
    COL_GREEN="$(tput setaf 2)"
  fi
}

usage() {
cat <<EOF
Usage: $ME [options] <action> <instance>

Manage docker-compose-based OpenSlides instances.

Actions:
  ls                   List instances and their status.  <instance> is
                       a grep ERE search pattern in this case.
  add                  Add a new instance for the given domain (requires FQDN)
  rm                   Remove <instance> (requires FQDN)
  start                Start an existing instance
  stop                 Stop a running instance
  update               Update OpenSlides to a new --image
  erase                Remove an instance's volumes (stops the instance if
                       necessary)

Options:
  -d, --project-dir    Directly specify the project directory
  --force              Disable various safety checks
  --color=WHEN         Enable/disable color output.  WHEN is never, always, or
                       auto.

  for ls:
    -a, --all              Equivalent to -l -m -i
    -l, --long             Include more information in extended listing format
    -m, --metadata         Include metadata in instance list
    -i, --image-info       Show image version info (requires instance to be
                           started)
    -n, --online           Show only online instances
    -f, --offline          Show only offline instances
    -M, --search-metadata  Include metadata in instance list
    --fast                 Include less information to increase listing speed

  for add & update:
    -r, --default-repo Specifcy the default Docker repository for OpenSlides
                       images
    -I, --image        Specify the OpenSlides server Docker image
    -t, --tag          Specify the OpenSlides server Docker image
    --no-add-account   Do not add an additional, customized local admin account
    --local-only       Create an instance without setting up HAProxy and Let's
                       Encrypt certificates.  Such an instance is only
                       accessible on localhost, e.g., http://127.1:61000.
    --clone-from       Create the new instance based on the specified existing
                       instance
    --www              Add a www subdomain in addition to the specified
                       instance domain
    --mailserver       Mail server to configure as Postfix's smarthost (default
                       is the host system)

Meaning of colored status indicators in ls mode:
  green                The instance appears to be fully functional
  red                  The instance is unreachable, probably stopped
  yellow               The instance is started but a websocket connection
                       cannot be established.  This usually means that the
                       instance is starting or, if the status persists, that
                       something is wrong.  Check the docker-compose logs in
                       this case.  (If --fast is given, however, this is the
                       best possible status due to uncertainty and does not
                       necessarily indicate a problem.)
EOF
}

fatal() {
    echo 1>&2 "${COL_RED}ERROR${COL_NORMAL}: $*"
    exit 23
}

check_for_dependency () {
    [[ -n "$1" ]] || return 0
    which "$1" > /dev/null || { fatal "Dependency not found: $1"; }
}

arg_check() {
  [[ -d "$OSDIR" ]] || { fatal "$OSDIR not found!"; }
  [[ -n "$PROJECT_NAME" ]] || {
    fatal "Please specify a project name"; return 2;
  }
  case "$MODE" in
    "start" | "stop" | "remove" | "erase" | "update")
      [[ -d "$PROJECT_DIR" ]] || {
        fatal "Instance '${PROJECT_NAME}' not found."
      }
      ;;
    "clone")
      [[ -d "$CLONE_FROM_DIR" ]] || {
        fatal "$CLONE_FROM_DIR does not exist."
      }
      ;;
  esac
  echo "$DOCKER_IMAGE_NAME_OPENSLIDES" | grep -q -v ':' ||
    fatal "Image names must not contain colons.  Tags can be specified with --tag."
}

marker_check() {
  [[ -f "${PROJECT_DIR}/${MARKER}" ]] || {
    fatal "This instance was not created with $ME." \
      "Refusing to delete unless --force is given."
  }
}

_docker_compose () {
  # This basically implements the missing docker-compose -C
  local project_dir="$1"
  shift
  docker-compose --project-directory "$project_dir" \
    --file "${project_dir}/${CONFIG_FILE}" $*
}

query_user_account_name() {
  if [[ -n "$OPT_ADD_ACCOUNT" ]]; then
    echo "Create local admin account for:"
    while [[ -z "$OPENSLIDES_USER_FIRSTNAME" ]] || \
          [[ -z "$OPENSLIDES_USER_LASTNAME" ]]
    do
      read -p "First & last name: " \
        OPENSLIDES_USER_FIRSTNAME OPENSLIDES_USER_LASTNAME
    done
  fi
}

verify_domain() {
  # Verify provided domain
  local ip=$(dig +short "$PROJECT_NAME")
  [[ -n "$ip" ]] || fatal "Hostname not found"
  hostname -I | grep -q -F "$ip" || {
    fatal "$PROJECT_NAME does not point to this host.  Override with --force."
    return 3
  }
}

next_free_port() {
  # Select new port
  #
  # `docker-compose port client 80` would be a nicer way to get the port
  # mapping; however, it is only available for running services.
  local HIGHEST_PORT_IN_USE=$(
    find "${INSTANCES}" -type f -name ${CONFIG_FILE} -print0 |
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
    [[ $n -le 25 ]] || { fatal "Could not find free port"; }
    ((PORT+=1))
    [[ $PORT -le 65535 ]] || { fatal "Ran out of ports"; }
    ((n+=1))
  done
  echo "$PORT"
}

create_config_from_template() {
  local templ="$1"
  local config="$2"
  gawk -v port="${PORT}" -v image="$DOCKER_IMAGE_NAME_OPENSLIDES" \
      -v tag="$DOCKER_IMAGE_TAG_OPENSLIDES" '
    BEGIN {FS=":"; OFS=FS}
    $0 ~ /^  (prio)?server:$/ {s=1}
    image != "" && $1 ~ /image/ && s { $2 = " " image; $3 = tag; s=0 }

    $0 ~ / +ports:$/ { # enter ports section
      p = $0
      pi = length(gensub(/(^\ *).*/, "\\1", "g")) # indent level
      next
    }
    pi > 0 && /80"?$/ { # update host port for port 80 mapping
      $(NF - 1) = port
      printf("%s\n%s\n", p, $0)
      pi = 0
      next
    }
    pi > 0 { # strip all other published ports
      i = length(gensub(/(^\ *).*/, "\\1", "g")) # indent level
      if ( i > pi ) { next } else { pi = 0 }
    }
    1
    ' "$templ" |
  gawk -v proj="$PROJECT_NAME" -v relay="$RELAYHOST" '
    # Configure mail relay host
    BEGIN {FS="="; OFS=FS}
    $1 ~ /MYHOSTNAME$/ { $2 = proj }
    relay != "" && $1 ~ /RELAYHOST$/ { $2 = relay }
    1
  ' |
  gawk -v repo="$MAIN_REPOSITORY_URL" '
    # Configure all OpenSlides-specific images for custom Docker repository
    BEGIN { FS=": "; OFS=FS; }
    repo && $1 ~ / +image/ && $2 ~ /openslides\// {
      sub(/openslides\//, repo "/", $2)
    }
    1
  ' > "$config"
}

create_instance_dir() {
  # Update yaml
  git clone "${TEMPLATE_REPO}" "${PROJECT_DIR}"
  # prepare secrets files
  [[ -d "${PROJECT_DIR}/secrets" ]] ||
    mkdir -m 700 "${PROJECT_DIR}/secrets"
  touch "${PROJECT_DIR}/secrets/${ADMIN_SECRETS_FILE}"
  touch "${PROJECT_DIR}/${MARKER}"
  # Add stack name to .env file
  touch "${PROJECT_DIR}/.env"
  printf "%s=%s\n" "PROJECT_STACK_NAME" "${PROJECT_STACK_NAME}" \
    >> "${PROJECT_DIR}/.env"
}

gen_pw() {
  read -r -n 15 PW < <(LC_ALL=C tr -dc "[:alnum:]" < /dev/urandom)
  echo "$PW"
}

create_django_secrets_file() {
  echo "Generating Django secret key (for settings.py)..."
  [[ -d "${PROJECT_DIR}/secrets" ]] ||
    mkdir -m 700 "${PROJECT_DIR}/secrets"
  printf "%s\n" "$(gen_pw)" \
    >> "${PROJECT_DIR}/secrets/django"
}

create_admin_secrets_file() {
  echo "Generating admin password..."
  [[ -d "${PROJECT_DIR}/secrets" ]] ||
    mkdir -m 700 "${PROJECT_DIR}/secrets"
  printf "OPENSLIDES_ADMIN_PASSWORD=%s\n" "$(gen_pw)" \
    >> "${PROJECT_DIR}/secrets/${ADMIN_SECRETS_FILE}"
}

create_user_secrets_file() {
  if [[ -n "$OPT_ADD_ACCOUNT" ]]; then
    echo "Generating user credentials..."
    [[ -d "${PROJECT_DIR}/secrets" ]] ||
      mkdir -m 700 "${PROJECT_DIR}/secrets"
    local first_name="$1"
    local last_name="$2"
    local PW="$(gen_pw)"
    cat << EOF > "${PROJECT_DIR}/secrets/${USER_SECRETS_FILE}"
OPENSLIDES_USER_FIRSTNAME=$first_name
OPENSLIDES_USER_LASTNAME=$last_name
OPENSLIDES_USER_PASSWORD=$PW
EOF
  fi
}

gen_tls_cert() {
  # Generate Let's Encrypt certificate
  [[ -z "$OPT_LOCALONLY" ]] || return 0

  # add optional www subdomain
  local www=
  [[ -z "$OPT_WWW" ]] || www="www.${PROJECT_NAME}"

  # Generate Let's Encrypt certificate
  echo "Generating certificate..."
  if [[ -z "$OPT_WWW" ]]; then
    acmetool want "${PROJECT_NAME}"
  else
    acmetool want "${PROJECT_NAME}" "${www}"
  fi
}

add_to_haproxy_cfg() {
  [[ -z "$OPT_LOCALONLY" ]] || return 0
  cp -f /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.osbak &&
  gawk -v target="${PROJECT_NAME}" -v port="${PORT}" '
    BEGIN {
      begin_block = "-----BEGIN AUTOMATIC OPENSLIDES CONFIG-----"
      end_block   = "-----END AUTOMATIC OPENSLIDES CONFIG-----"
      use_server_tmpl = "\tuse-server %s if { ssl_fc_sni_end -i %s }"
      server_tmpl     = "\tserver     %s 127.1:%d  weight 0 check"
    }
    $0 ~ begin_block { b = 1 }
    $0 ~ end_block   { e = 1 }
    !e
    b && e {
      printf(use_server_tmpl "\n", target, target)
      printf(server_tmpl "\n", target, port)
      print
      e = 0
    }
  ' /etc/haproxy/haproxy.cfg.osbak >| /etc/haproxy/haproxy.cfg &&
    systemctl reload haproxy
}

rm_from_haproxy_cfg() {
  cp -f /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.osbak &&
  gawk -v target="${PROJECT_NAME}" -v port="${PORT}" '
    BEGIN {
      begin_block = "-----BEGIN AUTOMATIC OPENSLIDES CONFIG-----"
      end_block   = "-----END AUTOMATIC OPENSLIDES CONFIG-----"
    }
    $0 ~ begin_block { b = 1 }
    $0 ~ end_block   { e = 1 }
    b && !e && $0 ~ target { next }
    1
  ' /etc/haproxy/haproxy.cfg.osbak >| /etc/haproxy/haproxy.cfg &&
    systemctl reload haproxy
}

remove() {
  local PROJECT_NAME="$1"
  [[ -d "$PROJECT_DIR" ]] || {
    fatal "$PROJECT_DIR does not exist."
  }
  echo "Stopping and removing containers..."
  instance_erase
  echo "Removing instance repo dir..."
  rm -rf "${PROJECT_DIR}"
  echo "acmetool unwant..."
  acmetool unwant "$PROJECT_NAME"
  echo "remove HAProxy config..."
  rm_from_haproxy_cfg
  echo "Done."
}

local_port() {
  # Retrieve the reverse proxy's published port from config file
  [[ -f "${1}/${CONFIG_FILE}" ]] &&
  gawk 'BEGIN { FS=":" }
    $0 ~ / +client:$/ { c = 1 }
    c && $0 ~ / +ports:$/ { s = 1; next; }
    # print second to last element in ports definition, i.e., the local port
    s && ( NF == 2 || NF == 3 ) {
      gsub(/[\ "-]/, "")
      print $(NF - 1)
      exit
    }' "${instance}/${CONFIG_FILE}"
  # better but slower:
  # docker inspect --format '{{ (index (index .NetworkSettings.Ports "80/tcp") 0).HostPort }}' \
  #   $(docker-compose ps -q client))
}


ping_instance_simple() {
  # Check if the instance's reverse proxy is listening
  #
  # This is used as an indicator as to whether the instance is supposed to be
  # running or not.  The reason for this check is that it is fast and that the
  # reverse proxy container rarely fails itself, so it is always running when
  # an instance has been started.  Errors usually happen in the server
  # container which is checked with ping_instance_websocket.
  nc -z localhost "$1" || return 1
}

ping_instance_websocket() {
  # Connect to OpenSlides and parse its version string
  #
  # This is a way to test the availability of the app.  Most grave errors in
  # OpenSlides lead to this function failing.
  LC_ALL=C curl --silent --max-time 0.1 \
    "http://127.0.0.1:${1}/apps/core/version/" |
  gawk 'BEGIN { FPAT = "\"[^\"]*\"" } { gsub(/"/, "", $2); print $2}'
}

value_from_yaml() {
  instance="$1"
  awk -v m="^ *${2}:$" \
    '$1 ~ m { print $2; exit; }' \
    "${instance}/${CONFIG_FILE}"
}

image_from_yaml() {
  instance="$1"
  gawk '
    BEGIN {FS=":"}
    $0 ~ /^  (prio)?server:$/ {s=1}
    $1 ~ /image/ && s { printf("%s\n%s\n", $2, $3); exit; }
    ' "${instance}/${CONFIG_FILE}"
}

highlight_match() {
  # Highlight search term match in string
  if [[ -n "$NCOLORS" ]] && [[ -n "$PROJECT_NAME" ]]; then
    sed -e "s/${PROJECT_NAME}/$(tput smso)&$(tput rmso)/g" <<< "$1"
  else
    echo "$1"
  fi
}

ls_instance() {
  local instance="$1"
  local shortname=$(basename "$instance")
  local normalized_shortname=

  [[ -f "${instance}/${CONFIG_FILE}" ]] ||
    fatal "$shortname is not a $DEPLOYMENT_MODE instance."

  #  For stacks, get the normalized shortname
  if [[ -f "${instance}/.env" ]]; then
    PROJECT_STACK_NAME=
    source "${instance}/.env"
    [[ -z "${PROJECT_STACK_NAME}" ]] ||
      local normalized_shortname="${PROJECT_STACK_NAME}"
  fi

  # Determine instance state
  local port=$(local_port "$instance")
  local sym="$SYM_UNKNOWN"
  local version=
  if [[ -n "$OPT_FAST" ]]; then
    version="[skipped]"
    ping_instance_simple "$port" || {
      version="DOWN"
      sym="$SYM_ERROR"
    }
  else
    # If we can fetch the version string from the app this is an indicator of
    # a fully functional instance.  If we cannot this could either mean that
    # the instance has been stopped or that it is only partially working.
    version=$(ping_instance_websocket "$port")
    sym="$SYM_NORMAL"
    if [[ -z "$version" ]]; then
      sym="$SYM_UNKNOWN"
      version="DOWN"
      # The following function simply checks if the reverse proxy port is open.
      # If it is the instance is *supposed* to be running but is not fully
      # functional; otherwise, it is assumed to be turned off on purpose.
      ping_instance_simple "$port" || sym="$SYM_ERROR"
    fi
  fi

  # Filter online/offline instances
  case "$FILTER" in
    online)
      [[ "$version" != "DOWN" ]] || return 1 ;;
    offline)
      [[ "$version" = "DOWN" ]] || return 1 ;;
    *) ;;
  esac

  # Parse metadata for first line (used in overview)
  local first_metadatum=
  if [[ -z "$OPT_FAST" ]] && [[ -r "${instance}/metadata.txt" ]]; then
    first_metadatum=$(head -1 "${instance}/metadata.txt")
    # Shorten if necessary.  This string will be printed as a column of the
    # general output, so it should not cause linebreaks.  Since the same
    # information will additionally be displayed in the extended output,
    # we can just cut if off here.
    # Ideally, we'd dynamically adjust to how much space is available.
    [[ "${#first_metadatum}" -le 40 ]] || {
      first_metadatum="${first_metadatum:0:30}"
      # append ellipsis and reset formatting.  The latter may be necessary
      # because we might be cutting this off above.
      first_metadatum+="…[0m"
    }
  fi

  # Basic output
  printf "%s %-40s\t%s\n" "$sym" "$shortname" "$first_metadatum"

  # --long
  if [[ -n "$OPT_LONGLIST" ]]; then

    # Parse docker-compose.yml
    local git_repo=$(value_from_yaml "$instance" "REPOSITORY_URL")
    local git_commit=$(value_from_yaml "$instance" "GIT_CHECKOUT")

    if [[ -z "$git_commit" ]]; then
      local image=$(value_from_yaml "$instance" "image")
    fi

    # Parse admin credentials file
    local OPENSLIDES_ADMIN_PASSWORD="—"
    if [[ -f "${instance}/secrets/${ADMIN_SECRETS_FILE}" ]]; then
      source "${instance}/secrets/${ADMIN_SECRETS_FILE}"
    fi

    printf "   ├ %-12s %s\n" "Directory:" "$instance"
    if [[ -n "$normalized_shortname" ]]; then
      printf "   ├ %-12s %s\n" "Stack name:" "$normalized_shortname"
    fi
    printf "   ├ %-12s %s\n" "Version:" "$version"
    if [[ -n "$git_commit" ]]; then
      printf "   ├ %-12s %s\n" "Git rev:" "$git_commit"
      printf "   ├ %-12s %s\n" "Git repo:" "$git_repo"
    elif [[ -n "$image" ]]; then
      printf "   ├ %-12s %s\n" "Image:" "$image"
    fi
    printf "   ├ %-12s %s\n" "Local port:" "$port"
    printf "   ├ %-12s %s : %s\n" "Login:" "admin" "$OPENSLIDES_ADMIN_PASSWORD"

    # Include secondary account credentials if available
    local OPENSLIDES_USER_FIRSTNAME=
    local OPENSLIDES_USER_LASTNAME=
    local OPENSLIDES_USER_PASSWORD=
    local user_name=
    if [[ -f "${instance}/secrets/${USER_SECRETS_FILE}" ]]; then
      source "${instance}/secrets/${USER_SECRETS_FILE}"
      local user_name="${OPENSLIDES_USER_FIRSTNAME} ${OPENSLIDES_USER_LASTNAME}"
      [[ -n "$user_name" ]] &&
        printf "   ├ %-12s \"%s\" : %s\n" \
          "Login:" "$user_name" "$OPENSLIDES_USER_PASSWORD"
    fi
  fi

  # --metadata
  if [[ -n "$OPT_METADATA" ]] && [[ -r "${instance}/metadata.txt" ]]; then
    local metadata=()
    # Parse metadata file for use in long output
    readarray -t metadata < <(grep -v '^\s*#' "${instance}/metadata.txt")

    if [[ ${#metadata[@]} -ge 1 ]]; then
      printf "   └ %s\n" "Metadata:"
      for m in "${metadata[@]}"; do
        m=$(highlight_match "$m") # Colorize match in metadata
        printf "     ┆ %s\n" "$m"
      done
    fi
  fi

  # --image-info
  if [[ -n "$OPT_IMAGE_INFO" ]] && [[ "$version" != DOWN ]]; then
    local image_info="$(curl -s http://localhost:${port}/image-version.txt)"
    if [[ "$image_info" =~ ^Built ]]; then
      printf "   └ %s\n" "Image info:"
      echo "${image_info}" | sed 's/^/     ┆ /'
    fi
  fi
}

colorize_ls() {
  # Colorize the status indicators
  if [[ -n "$NCOLORS" ]]; then
    gawk \
      -v m="$PROJECT_NAME" \
      -v hlstart="$(tput smso)" \
      -v hlstop="$(tput rmso)" \
      -v bullet="${BULLET}" \
      -v normal="${COL_NORMAL}" \
      -v green="${COL_GREEN}" \
      -v yellow="${COL_YELLOW}" \
      -v red="${COL_RED}" \
    'BEGIN {
      FPAT = "([[:space:]]*[^[:space:]]+)"
      OFS = ""
    }
    # highlight matches in instance name
    /^[^ ]/ { gsub(m, hlstart "&" hlstop, $2) }
    # bullets
    /^OK/   { $1 = " " green  bullet normal }
    /^\?\?/ { $1 = " " yellow bullet normal }
    /^XX/   { $1 = " " red    bullet normal }
    1'
  else
    cat -
  fi
}

list_instances() {
  # Find instances and filter based on search term.
  # PROJECT_NAME is used as a grep -E search pattern here.
  local i=()
  local j=()
  readarray -d '' i < <(
    find "${INSTANCES}" -mindepth 1 -maxdepth 1 -type d -print0 |
    sort -z
  )
  for instance in "${i[@]}"; do
    # skip directories that aren't instances
    [[ -f "${instance}/${CONFIG_FILE}" ]] || continue

    # Filter instances
    # 1. instance name/project dir matches
    if grep -E -q "$PROJECT_NAME" <<< "$(basename $instance)"; then :
    # 2. metadata matches
    elif [[ -n "$OPT_METADATA_SEARCH" ]] && [[ -f "${instance}/metadata.txt" ]] &&
      grep -E -q "$PROJECT_NAME" "${instance}/metadata.txt"; then :
    else
      continue
    fi

    j+=("$instance")
  done

  # return here if no matches
  [[ "${#j[@]}" -ge 1 ]] || return

  # list instances, either one by one or in parallel
  if [[ $OPT_USE_PARALLEL ]]; then
    env_parallel --no-notice --keep-order ls_instance ::: ${j[@]}
  else
    for instance in "${j[@]}"; do
      ls_instance "$instance" || continue
    done
  fi | colorize_ls
}

clone_secrets() {
  if [[ -d "${CLONE_FROM_DIR}/secrets/" ]]; then
    rsync -axv "${CLONE_FROM_DIR}/secrets/" "${PROJECT_DIR}/secrets/"
  fi
}

containerid_from_service_name() {
  local id
  local containerid
  id="$(docker service ps -q "$1")"
  cid="$(docker inspect -f '{{.Status.ContainerStatus.ContainerID}}' ${id})"
  echo "$cid"
}

get_clone_from_id() (
  source "${1}/.env"
  containerid_from_service_name "${PROJECT_STACK_NAME}_pgnode1"
)

clone_db() {
  local clone_from_id
  local clone_to_id
  local available_dbs
  case "$DEPLOYMENT_MODE" in
    "compose")
      _docker_compose "$PROJECT_DIR" up -d --no-deps pgnode1
      local clone_from_id="$(_docker_compose "$CLONE_FROM_DIR" ps -q pgnode1)"
      local clone_to_id=$(_docker_compose "$PROJECT_DIR" ps -q pgnode1)
      sleep 20 # XXX
      ;;
    "stack")
      clone_from_id="$(get_clone_from_id "$CLONE_FROM_DIR")"
      source "${PROJECT_DIR}/.env"
      instance_start
      echo "Waiting 20 seconds for database to become available..."
      sleep 20 # XXX
      clone_to_id="$(containerid_from_service_name "${PROJECT_STACK_NAME}_pgnode1")"
      ;;
  esac
  echo "DEBUG: from: $clone_from_id to: $clone_to_id"

  # Clone instance databases individually using pg_dump
  #
  # pg_dump's advantage is that it requires no special access (unlike
  # pg_dumpall) and does not require the cluster to be reinitialized (unlike
  # pg_basebackup).
  #
  # In the future, the origin cluster will hopefully be accessed through the
  # pgbouncer service, so it will be possible to clone even from secondary
  # Postgres nodes if a failover occured.  It is assumed, however, that both
  # the origin's pgbouncer instance as well as the cloned instance's pgnode1
  # are running on localhost because both get accessed using `docker exec`.
  #
  # The pg_dump/psql method may very well run into issues with large mediafile
  # databases, however.  pg_dump/pg_restore using the custom format could be
  # worth a try.
  available_dbs=("$(docker exec "$clone_from_id" \
    psql -U openslides -h db -d openslides -c '\l' -AtF '	' | cut -f1)")
  for db in openslides instancecfg mediafiledata; do
    echo "${available_dbs[@]}" | grep -wq "$db" || {
      echo "DB $db not found; skipping..."
      sleep 10
      continue
    }
    echo "Recreating db for new instance: ${db}..."
    docker exec -u postgres "$clone_to_id" psql -q -c "SELECT pg_terminate_backend(pid)
        FROM pg_stat_activity WHERE datname='${db}';"
    docker exec -u postgres "$clone_to_id" dropdb --if-exists "$db"
    docker exec -u postgres "$clone_to_id" createdb -O openslides "$db"

    echo "Cloning ${db}..."
    docker exec -u postgres "$clone_from_id" \
      pg_dump -h db -U openslides -c --if-exists "$db" |
    docker exec -u postgres -i "$clone_to_id" psql -h pgnode1 -U openslides "$db"
  done
}

append_metadata() {
  local m="${1}/metadata.txt"
  touch "$m"
  shift
  printf "%s\n" "$*" >> "$m"
}

ask_start() {
  local start=
  read -p "Start containers? [Y/n] " start
  case "$start" in
    Y|y|Yes|yes|YES|"")
      instance_start ;;
    *)
      echo "Not starting containers." ;;
  esac
}

instance_start() {
  case "$DEPLOYMENT_MODE" in
    "compose")
      _docker_compose "$PROJECT_DIR" build
      _docker_compose "$PROJECT_DIR" up -d
      ;;
    "stack")
      source "${PROJECT_DIR}/.env"
      docker stack deploy -c "${PROJECT_DIR}/docker-stack.yml" \
        "$PROJECT_STACK_NAME"
      ;;
  esac
}

instance_stop() {
  case "$DEPLOYMENT_MODE" in
    "compose")
      _docker_compose "$PROJECT_DIR" down
      ;;
    "stack")
      source "${PROJECT_DIR}/.env"
      docker stack rm "$PROJECT_STACK_NAME"
    ;;
esac
}

instance_erase() {
  case "$DEPLOYMENT_MODE" in
    "compose")
      _docker_compose "$PROJECT_DIR" down --volumes
      ;;
    "stack")
      local vol=()
      instance_stop || true
      readarray -t vol < <(
        docker volume ls --format '{{ .Name }}' |
        grep "^${PROJECT_STACK_NAME}_"
      )
      if [[ "${#vol[@]}" -gt 0 ]]; then
        echo "Please manually verify and remove the instance's volumes:"
        for i in "${vol[@]}"; do
          echo "  docker volume rm $i"
        done
      fi
      echo "WARN: Please note that $ME does not take volumes" \
        "on other nodes into account."
      ;;
  esac
}

instance_update() {
  if grep -q 'context: ./server' "${DCCONFIG}"; then
    fatal 'This appears to be a legacy configuration file.' \
      'Please update it by specifying an "image" node for the server services,' \
      'and remove the "build" nodes, c.f. the provided example file.'
  fi
  gawk -v image="$DOCKER_IMAGE_NAME_OPENSLIDES" \
      -v tag="$DOCKER_IMAGE_TAG_OPENSLIDES" '
    BEGIN {FS=":"; OFS=FS}
    $0 ~ /^  (prio)?server:$/ {i=1; t=1}
    image != "" && $1 ~ /image/ && i { $2 = " " image; i=0 }
    tag != "" && $1 ~ /image/ && t { $3 = tag; t=0 }
    1
    ' "${DCCONFIG}" > "${DCCONFIG}.tmp" &&
  mv -f "${DCCONFIG}.tmp" "${DCCONFIG}"
  case "$DEPLOYMENT_MODE" in
    "compose")
      echo "Creating services"
      _docker_compose "$PROJECT_DIR" up --no-start
      local prioserver="$(_docker_compose "$PROJECT_DIR" ps -q prioserver)"
      # Delete staticfiles volume
      local vol=$(docker inspect --format \
          '{{ range .Mounts }}{{ if eq .Destination "/app/openslides/static" }}{{ .Name }}{{ end }}{{ end }}' \
          "$prioserver"
      )
      echo "Scaling down"
      _docker_compose "$PROJECT_DIR" up -d \
        --scale server=0 --scale prioserver=0 --scale client=0
      echo "Deleting staticfiles volume"
      docker volume rm "$vol"
      echo "OK.  Bringing up all services"
      _docker_compose "$PROJECT_DIR" up -d
      ;;
    "stack")
      local force_opt=
      [[ -z "$OPT_FORCE" ]] || local force_opt="--force"
      source "${PROJECT_DIR}/.env"
      # docker stack deploy -c "${PROJECT_DIR}/docker-stack.yml" "$STACK_NAME"
      for i in prioserver server; do
        if docker service ls --format '{{.Name}}' | grep -q "${PROJECT_STACK_NAME}_${i}"
        then
          docker service update $force_opt "${PROJECT_STACK_NAME}_${i}"
        else
          echo "WARN: ${PROJECT_STACK_NAME}_${i} is not running."
        fi
      done
      ;;
  esac
  append_metadata "$PROJECT_DIR" "$(date +"%F %H:%M"): Updated to" \
    "${DOCKER_IMAGE_NAME_OPENSLIDES}:${DOCKER_IMAGE_TAG_OPENSLIDES}"
}

# Use GNU parallel if found
if [[ -f /usr/bin/env_parallel.bash ]]; then
  source /usr/bin/env_parallel.bash
  OPT_USE_PARALLEL=1
fi

# Decide mode from invocation
case "$(basename "${BASH_SOURCE[0]}")" in
  "osinstancectl" | "osinstancectl.sh")
    DEPLOYMENT_MODE=compose
    ;;
  "osstackctl" | "osstackctl.sh")
    DEPLOYMENT_MODE=stack
    ;;
  *)
    echo "WARNING: could not determine desired deployment mode;" \
      " assuming 'compose'"
    DEPLOYMENT_MODE=compose
    ;;
esac

shortopt="halmiMnfd:r:I:t:"
longopt=(
  help
  color:
  long
  project-dir:
  force

  # filtering
  all
  online
  offline
  metadata
  image-info
  fast
  search-metadata

  # adding instances
  default-repo:
  clone-from:
  local-only
  no-add-account
  mailserver:
  www

  # adding & upgrading instances
  image:
  tag:
)
# format options array to comma-separated string for getopt
longopt=$(IFS=,; echo "${longopt[*]}")

ARGS=$(getopt -o "$shortopt" -l "$longopt" -n "$ME" -- "$@")
if [ $? -ne 0 ]; then usage; exit 1; fi
eval set -- "$ARGS";
unset ARGS

# Config file
if [[ -f "$CONFIG" ]]; then
  source "$CONFIG"
  # For legacy settings, make sure defaults are stored in DEFAULT_* vars and
  # that the CLI variables remain unset at this point
  [[ -z "$DOCKER_IMAGE_NAME_OPENSLIDES" ]] ||
    DEFAULT_DOCKER_IMAGE_NAME_OPENSLIDES="$DOCKER_IMAGE_NAME_OPENSLIDES"
  [[ -z "$DOCKER_IMAGE_TAG_OPENSLIDES" ]] ||
    DEFAULT_DOCKER_IMAGE_TAG_OPENSLIDES="$DOCKER_IMAGE_TAG_OPENSLIDES"
  DOCKER_IMAGE_NAME_OPENSLIDES=
  DOCKER_IMAGE_TAG_OPENSLIDES=
fi

# Parse options
while true; do
  case "$1" in
    -d|--project-dir)
      PROJECT_DIR="$2"
      shift 2
      ;;
    -r|--default-repo)
      MAIN_REPOSITORY_URL="$2"
      shift 2
      ;;
    -I|--image)
      DOCKER_IMAGE_NAME_OPENSLIDES="$2"
      shift 2
      ;;
    -t|--tag)
      DOCKER_IMAGE_TAG_OPENSLIDES="$2"
      shift 2
      ;;
    --mailserver)
      RELAYHOST="$2"
      shift 2
      ;;
    --no-add-account)
      OPT_ADD_ACCOUNT=
      shift 1
      ;;
    -a|--all)
      OPT_LONGLIST=1
      OPT_METADATA=1
      OPT_IMAGE_INFO=1
      shift 1
      ;;
    -l|--long)
      OPT_LONGLIST=1
      shift 1
      ;;
    -m|--metadata)
      OPT_METADATA=1
      shift 1
      ;;
    -M|--search-metadata)
      OPT_METADATA_SEARCH=1
      shift 1
      ;;
    -i|--image-info)
      OPT_IMAGE_INFO=1
      shift 1
      ;;
    -n|--online)
      FILTER="online"
      shift 1
      ;;
    -f|--offline)
      FILTER="offline"
      shift 1
      ;;
    --clone-from)
      CLONE_FROM="$2"
      shift 2
      ;;
    --local-only)
      OPT_LOCALONLY=1
      shift 1
      ;;
    --www)
      OPT_WWW=1
      shift 1
      ;;
    --color)
      OPT_COLOR="$2"
      shift 2
      ;;
    --force)
      OPT_FORCE=1
      shift 1
      ;;
    --fast)
      OPT_FAST=1
      shift 1
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift ; break ;;
    *) usage; exit 1 ;;
  esac
done

# Parse commands
for arg; do
  case $arg in
    ls|list)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=list
      shift 1
      ;;
    add|create)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=create
      [[ -z "$CLONE_FROM" ]] || MODE=clone
      shift 1
      ;;
    rm|remove)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=remove
      shift 1
      ;;
    start|up)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=start
      shift 1
      ;;
    stop|down)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=stop
      shift 1
      ;;
    erase)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=erase
      shift 1
      ;;
    update)
      [[ -z "$MODE" ]] || { usage; exit 2; }
      MODE=update
      [[ -n "$DOCKER_IMAGE_NAME_OPENSLIDES" ]] ||
      [[ -n "$DOCKER_IMAGE_TAG_OPENSLIDES" ]] || {
        fatal "Need image or tag for update"
      }
      shift 1
      ;;
    *)
      # The final argument should be the project name/search pattern
      PROJECT_NAME="$arg"
      break
      ;;
  esac
done

case "$OPT_COLOR" in
  auto)
    if [[ -t 1 ]]; then enable_color; fi ;;
  always)
    enable_color ;;
  never) true ;;
  *)
    fatal "Unknown option to --color" ;;
esac


DEPS=(
  docker
  docker-compose
  gawk
  acmetool
  nc
  dig
)
# Check dependencies
for i in "${DEPS[@]}"; do
    check_for_dependency "$i"
done

# Prevent --project-dir to be used together with a project name
if [[ -n "$PROJECT_DIR" ]] && [[ -n "$PROJECT_NAME" ]]; then
  fatal "Mutually exclusive options"
fi
# Deduce project name from path
if [[ -n "$PROJECT_DIR" ]]; then
  PROJECT_NAME=$(basename $(readlink -f "$PROJECT_DIR"))
  OPT_METADATA_SEARCH=
# Treat the project name "." as --project-dir=.
elif [[ "$PROJECT_NAME" = "." ]]; then
  PROJECT_NAME=$(basename $(readlink -f "$PROJECT_NAME"))
  PROJECT_DIR="${INSTANCES}/${PROJECT_NAME}"
  OPT_METADATA_SEARCH=
else
  PROJECT_DIR="${INSTANCES}/${PROJECT_NAME}"
fi

case "$DEPLOYMENT_MODE" in
  "compose")
    CONFIG_FILE="docker-compose.yml"
    ;;
  "stack")
    CONFIG_FILE="docker-stack.yml"
    # The project name is a valid domain which is not suitable as a Docker
    # stack name.  Here, we remove all dots from the domain which turns the
    # domain into a compatible name.  This also appears to be the method
    # docker-compose uses to name its containers.
    PROJECT_STACK_NAME="$(echo "$PROJECT_NAME" | tr -d '.')"
    ;;
esac
DCCONFIG="${PROJECT_DIR}/${CONFIG_FILE}"

case "$MODE" in
  remove)
    arg_check || { usage; exit 2; }
    [[ -n "$OPT_FORCE" ]] || marker_check
    # Ask for confirmation
    ANS=
    echo "Delete the following instance including all of its data and configuration?"
    # Show instance listing
    OPT_LONGLIST=1 OPT_METADATA=1 OPT_METADATA_SEARCH= \
      ls_instance "$PROJECT_DIR" | colorize_ls
    echo
    read -p "Really delete? (uppercase YES to confirm) " ANS
    [[ "$ANS" = "YES" ]] || exit 0
    remove "$PROJECT_NAME"
    ;;
  create)
    [[ -f "$CONFIG" ]] && echo "Found ${CONFIG} file." || true
    arg_check || { usage; exit 2; }
    [[ -n "$OPT_FORCE" ]] || verify_domain
    # Use defaults in the absence of options
    [[ -n "$DOCKER_IMAGE_NAME_OPENSLIDES" ]] ||
      DOCKER_IMAGE_NAME_OPENSLIDES="$DEFAULT_DOCKER_IMAGE_NAME_OPENSLIDES"
    [[ -n "$DOCKER_IMAGE_TAG_OPENSLIDES" ]] ||
      DOCKER_IMAGE_TAG_OPENSLIDES="$DEFAULT_DOCKER_IMAGE_TAG_OPENSLIDES"
    query_user_account_name
    echo "Creating new instance: $PROJECT_NAME"
    PORT=$(next_free_port)
    create_instance_dir
    create_config_from_template "${PROJECT_DIR}/${CONFIG_FILE}.example" \
      "${PROJECT_DIR}/${CONFIG_FILE}"
    create_django_secrets_file
    create_admin_secrets_file
    create_user_secrets_file "${OPENSLIDES_USER_FIRSTNAME}" "${OPENSLIDES_USER_LASTNAME}"
    gen_tls_cert
    add_to_haproxy_cfg
    append_metadata "$PROJECT_DIR" \
      "$(date +"%F %H:%M"): Instance created (${DEPLOYMENT_MODE})"
    [[ -z "$OPT_LOCALONLY" ]] ||
      append_metadata "$PROJECT_DIR" "No HAProxy config added (--local-only)"
    ask_start
    ;;
  clone)
    CLONE_FROM_DIR="${INSTANCES}/${CLONE_FROM}"
    arg_check || { usage; exit 2; }
    [[ -n "$OPT_FORCE" ]] || verify_domain
    echo "Creating new instance: $PROJECT_NAME (based on $CLONE_FROM)"
    PORT=$(next_free_port)
    # Parse image and/or tag from original config if necessary
    ia=()
    readarray -n 2 -t ia < <(image_from_yaml "$CLONE_FROM_DIR")
    for i in ${ia[@]}; do echo $i ; done
    [[ -n "$DOCKER_IMAGE_NAME_OPENSLIDES" ]] ||
      DOCKER_IMAGE_NAME_OPENSLIDES="${ia[0]}"
    [[ -n "$DOCKER_IMAGE_TAG_OPENSLIDES" ]] ||
      DOCKER_IMAGE_TAG_OPENSLIDES="${ia[1]}"
    create_instance_dir
    create_config_from_template "${CLONE_FROM_DIR}/${CONFIG_FILE}.example" \
      "${PROJECT_DIR}/${CONFIG_FILE}"
    clone_secrets
    clone_db
    gen_tls_cert
    add_to_haproxy_cfg
    append_metadata "$PROJECT_DIR" "Cloned from $CLONE_FROM on $(date)"
    [[ -z "$OPT_LOCALONLY" ]] ||
      append_metadata "$PROJECT_DIR" "No HAProxy config added (--local-only)"
    ask_start
    ;;
  list)
    list_instances
    ;;
  start)
    arg_check || { usage; exit 2; }
    instance_start ;;
  stop)
    arg_check || { usage; exit 2; }
    instance_stop ;;
  erase)
    arg_check || { usage; exit 2; }
    # Ask for confirmation
    ANS=
    echo "Stop the following instance, and remove its containers and volumes?"
    # Show instance listing
    OPT_LONGLIST=1 OPT_METADATA=1 OPT_METADATA_SEARCH= \
      ls_instance "$PROJECT_DIR" | colorize_ls
    echo
    read -p "Really delete? (uppercase YES to confirm) " ANS
    [[ "$ANS" = "YES" ]] || exit 0
    instance_erase
    ;;
  update)
    [[ -f "$CONFIG" ]] && echo "Found ${CONFIG} file." || true
    arg_check || { usage; exit 2; }
    instance_update
    ;;
  *)
    fatal "Missing command.  Please consult $ME --help."
    ;;
esac
