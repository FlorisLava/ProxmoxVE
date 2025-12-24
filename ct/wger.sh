#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/FlorisCl/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Original Author: Slaviša Arežina (tremor021)
# Revamped Script: Floris Claessens (FlorisCl)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/wger-project/wger

APP="wger"
var_tags="${var_tags:-management;fitness}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-6}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources


  WGER_HOME="/home/wger"
  WGER_SRC="${WGER_HOME}/src"
  WGER_VENV="${WGER_HOME}/venv"
  VERSION_FILE="/opt/${APP}_version.txt"

  if [[ ! -d ${WGER_HOME} ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi

  msg_info "Checking latest ${APP} release"
  RELEASE=$(curl -fsSL https://api.github.com/repos/wger-project/wger/releases/latest \
    | grep '"tag_name"' \
    | cut -d '"' -f4)

  if [[ -z "${RELEASE}" ]]; then
    msg_error "Failed to determine latest release"
    exit 1
  fi

  if [[ -f "${VERSION_FILE}" ]] && [[ "$(cat ${VERSION_FILE})" == "${RELEASE}" ]]; then
    msg_ok "${APP} is already up to date (v${RELEASE})"
    exit 0
  fi

  msg_info "Updating ${APP} to v${RELEASE}"

  msg_info "Stopping services"
  systemctl stop celery celery-beat apache2 2>/dev/null || true
  msg_ok "Services stopped"

  msg_info "Downloading release source"
  temp_dir=$(mktemp -d)

  curl -fsSL "https://github.com/wger-project/wger/archive/refs/tags/${RELEASE}.tar.gz" \
    | tar xz -C "${temp_dir}"

  rsync -a --delete "${temp_dir}/wger-${RELEASE#v}/" "${WGER_SRC}/"
  rm -rf "${temp_dir}"
  msg_ok "Source updated"

  msg_info "Updating Python dependencies"
  cd ${WGER_SRC} || EXIT

  $STD pip install -U pip setuptools wheel &>/dev/null
  $STD pip install . &>/dev/null
  msg_ok "Dependencies updated"

  msg_info "Running database migrations"
  $STD python manage.py migrate --noinput
  msg_ok "Database migrated"

  msg_info "Collecting static files"
  $STD python manage.py collectstatic --noinput
  msg_ok "Static files collected"

  echo "${RELEASE}" > "${VERSION_FILE}"

  msg_info "Starting services"
  systemctl start apache2
  systemctl start celery celery-beat
  msg_ok "Services started"

  msg_ok "${APP} updated successfully to v${RELEASE}"
  exit 0
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3000${CL}"
