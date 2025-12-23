#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/FlorisLava/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts ORG
# Original Author: Slaviša Arežina (tremor021)
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

  if [[ ! -d /home/wger ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi

  WGER_HOME="/home/wger"
  WGER_SRC="${WGER_HOME}/src"
  WGER_VENV="${WGER_HOME}/venv"

  msg_info "Stopping services"
  systemctl stop wger-celery wger-celery-beat apache2 2>/dev/null || true
  msg_ok "Services stopped"

  msg_info "Updating ${APP} source"
  temp_dir=$(mktemp -d)
  # TEMP CHANGE FROM $RELEASE TO MASTER
  curl -fsSL https://github.com/wger-project/wger/archive/refs/heads/master.tar.gz \
    | tar xz -C "${temp_dir}"
  rsync -a --delete "${temp_dir}/wger-master/" "${WGER_SRC}/"
  rm -rf "${temp_dir}"
  msg_ok "Source updated"

  msg_info "Updating Python dependencies"
  "${WGER_VENV}/bin/pip" install -U pip setuptools wheel &>/dev/null
  "${WGER_VENV}/bin/pip" install . &>/dev/null
  msg_ok "Dependencies updated"

  msg_info "Running database migrations"
  cd "${WGER_SRC}" || exit 1
  "${WGER_VENV}/bin/python" manage.py migrate --noinput
  msg_ok "Database migrated"

  msg_info "Collecting static files"
  "${WGER_VENV}/bin/python" manage.py collectstatic --noinput
  msg_ok "Static files collected"

  msg_info "Starting services"
  systemctl start apache2
  systemctl start wger-celery wger-celery-beat
  msg_ok "Services started"

  msg_ok "${APP} updated successfully!"
  exit 0
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3000${CL}"
