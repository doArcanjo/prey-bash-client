#!/bin/sh
############################################################
# Prey Unattended Installer
# Written by Tomas Pollak (tomas@forkhq.com)
# (c) 2013 Fork, Ltd.
############################################################

set -e
abort() { echo $1 && exit 1; }

VERSION=$1
API_KEY=$2
DEV_KEY=$3

cwd="$(dirname $0)"
zip="${cwd}/package.zip"

[ -z "$API_KEY" ] && abort 'Usage: install [version] [api_key] [device_key].'

if [ "$(uname)" = 'windowsnt' ]; then

  WIN=1
  BASE_PATH="${WINDIR}\Prey"
  CONFIG_DIR="$BASE_PATH"
  LOG_FILE="$BASE_PATH\prey.log"
  OLD_CLIENT="C:\Prey"

else

  [ "$(whoami)" != 'root' ] && abort 'Must run as root.'
  PREY_USER="prey"
  BASE_PATH="/usr/lib/prey"
  CONFIG_DIR="/etc/prey"
  LOG_FILE="/var/log/prey.log"
  OLD_CLIENT="/usr/share/prey"

fi

RELEASES_URL="https://s3.amazonaws.com/prey-releases/node-client"
VERSIONS_PATH="${BASE_PATH}/versions"
INSTALL_PATH="${BASE_PATH}/versions/${VERSION}"
PREY_BIN="bin/prey"

############################################################
# helpers

log() {
  echo "$1"
}

lowercase() {
  echo "$1" | sed "y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/"
}

contains() {
  local string="$1"
  local substring="$2"
  if test "${string#*$substring}" != "$string"; then
    return 0
  else
    return 1
  fi
}

cleanup() {
  local code="$?"
  [ "$code" -eq 0 ] && return 0

  log "Cleaning up! Exit code is ${code}."

  if [ ! -d "$INSTALL_PATH" ]; then
    remove_all
  else
    cd "$INSTALL_PATH"

    # if a previous installation exited, this will remove the daemon scripts
    # so we should later run post_install on the previous version's path
    log "Running uninstallation hooks..."
    $PREY_BIN config hooks pre_uninstall 2> /dev/null

    cd "$cwd"

    if [ -n "$existing_base_path" ]; then
      log "Removing version path: ${INSTALL_PATH}"
      rm -Rf "$INSTALL_PATH"

      if [ -n "$installation_activated" ]; then
        if [ -d "$previous_active_version" ]; then
          log "Reverting to previous active version..."

          # symlink and put daemon scripts back in place
          post_install "$previous_active_version"
        else
          remove_all
        fi
      fi
    fi
  fi
}

remove_all() {
  if [ -n "$user_created" ]; then
    log "Deleting user ${PREY_USER}..."
    userdel "$PREY_USER"
  fi

  log "Removing path: ${BASE_PATH}"
  rm -Rf "$BASE_PATH"
}

############################################################
# existing versions

check_installed() {
  if [ -d "$BASE_PATH" ]; then
    log "Previous installation detected."
    existing_base_path=1

    if [ -d "$INSTALL_PATH" ]; then
      log "Matching version found! Exiting."
      exit 1
    else
      if [ -e "${BASE_PATH}/current" ]; then
        previous_active_version="$(readlink "${BASE_PATH}/current")"
        log "Previous active version found: ${previous_active_version}"
      fi
      log "Installing new version."
    fi
  fi
}

remove_previous() {

  log "Checking for previous installed versions..."

  if [ -n "$WIN" ]; then

    if [ -d "$OLD_CLIENT" ]; then
      log "Old Prey client found! Removing..."

      taskkill /im cronsvc.exe /f

      if [ -f "${OLD_CLIENT}\\Uninstall.exe" ]; then
        "${OLD_CLIENT}\\Uninstall.exe" /S _?="$OLD_CLIENT"
      elif [ -f "${OLD_CLIENT}\\platform\\windows\\Uninstall.exe" ]; then
        "${OLD_CLIENT}\\platform\\windows\\Uninstall.exe" /S _?="$OLD_CLIENT"
      fi

      rm -Rf "$OLD_CLIENT"
    fi

  else

    if [ -d "$OLD_CLIENT" ]; then
      log "Previous installation found. Removing..."
      rm -Rf "$OLD_CLIENT"
      (sudo crontab -l | grep -v prey) | sudo crontab -
    fi

  fi

}

############################################################
# download, unpack

get_latest_version() {
  local ver=$(curl "${RELEASES_URL}/latest.txt" 2> /dev/null)
  [ $? -ne 0 ] && return 1

  # rewrite variables
  VERSION="$ver"
  INSTALL_PATH="${BASE_PATH}/versions/${VERSION}"
}

determine_file() {
  local ver="$1"
  local os=$(lowercase $(uname))
  local cpu=$(uname -p)

  if [ "$cpu" = "x86_64" ]; then
    local arch="x64"
  else
    local arch="x86"
  fi

  echo "prey-${os}-${ver}-${arch}.zip"
}

download_zip() {
  local ver="$1"
  local out="$2"

  local file=$(determine_file $ver)
  local url="${RELEASES_URL}/${ver}/${file}"

  log "Downloading ${url}"
  curl -s "$url" -o "$out"
  return $?
}

unpack_file() {
  local file="$1"

  log "Unpacking ${file} into ${VERSIONS_PATH}..."
  mkdir -p "$VERSIONS_PATH"
  unzip "$file" -d "$VERSIONS_PATH" 1> /dev/null
  [ $? -ne 0 ] && return 1

  rm -f "$file"

  cd "$VERSIONS_PATH"
  mv prey-${VERSION} $VERSION
}

############################################################
# when files are in place

create_user() {
  [ -z "$PREY_USER" ] && return 1

  local script="$INSTALL_PATH/scripts/create_user.sh"

  if [ -f "$script" ]; then
    user_created=1 # for checking on cleanup
    log "Creating local '${PREY_USER}' user..."
    "$script" $PREY_USER || true
  fi
}

set_permissions() {
  log "Setting up permissions..."
  mkdir -p "$CONFIG_DIR"
  touch "$LOG_FILE"

  if [ -z "$WIN" ]; then # set up permissions
    chown -R $PREY_USER: "$CONFIG_DIR" "$BASE_PATH" "$LOG_FILE"
  fi
}

post_install() {
  local path="$1"
  cd "$path"
  installation_activated=1 # for cleanup

  if [ -z "$WIN" ]; then
    # as user, symlinks and generates prey.conf
    su $PREY_USER -c "$PREY_BIN config activate"
  else
    $PREY_BIN config activate
  fi

  # as root, admin, sets up launch/init/service
  $PREY_BIN config hooks post_install
}

setup() {
  cd "$INSTALL_PATH"
  if [ contains "$API_KEY" '@' ]; then # email/pass
    $PREY_BIN config account authorize -e $API_KEY -p $DEV_KEY
  else # api_key/device_key
    $PREY_BIN config account verify -a $API_KEY -d $DEV_KEY -u
  fi
}

############################################################
# the main course

trap cleanup EXIT

[ "$VERSION" = 'latest' ] && get_latest_version

check_installed

log "Installing version ${VERSION} to ${BASE_PATH}"

download_zip "$VERSION" "$zip"
[ $? -ne 0 ] && abort 'Unable to download file.'

unpack_file "$zip"

[ -z "$WIN" ] && create_user

set_permissions
post_install "$INSTALL_PATH"

[ -n "$API_KEY" ] && setup

remove_previous

cd "$cwd"
log "All done."
exit 0
