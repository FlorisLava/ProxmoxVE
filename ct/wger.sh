#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: Slaviša Arežina (tremor021)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/wger-project/wger

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# --------------------------------------------------
# Constants
# --------------------------------------------------
WGER_USER="wger"
WGER_HOME="/home/wger"
WGER_SRC="${WGER_HOME}/src"
WGER_VENV="${WGER_HOME}/venv"
WGER_DB="${WGER_HOME}/db"
WGER_PORT="${WGER_PORT:-3000}"

# --------------------------------------------------
# Helpers
# --------------------------------------------------
section() {
  echo -e "\n\e[1;34m▶ $1\e[0m"
}

# --------------------------------------------------
# System setup
# --------------------------------------------------
install_dependencies() {
  msg_info "Installing system dependencies"
  $STD apt install -y \
    git \
    apache2 \
    libapache2-mod-wsgi-py3 \
    python3-venv \
    python3-pip \
    redis-server
  msg_ok "System dependencies installed"
}

setup_redis() {
  msg_info "Starting Redis"
  systemctl enable --now redis-server
  redis-cli ping | grep -q '^PONG$' \
    && msg_ok "Redis is running" \
    || msg_error "Redis failed to start"
}

setup_node() {
  msg_info "Setting up Node.js toolchain"
  NODE_VERSION="22" NODE_MODULE="sass" setup_nodejs
  corepack enable
  corepack prepare npm@10.5.0 --activate
  corepack disable yarn pnpm
  msg_ok "Node.js toolchain ready"
}

# --------------------------------------------------
# Apache
# --------------------------------------------------
setup_apache_port() {
  msg_info "Configuring Apache port (${WGER_PORT})"

  sed -i "s/^Listen .*/Listen ${WGER_PORT}/" /etc/apache2/ports.conf || true
  grep -q "^Listen ${WGER_PORT}$" /etc/apache2/ports.conf \
    || echo "Listen ${WGER_PORT}" >> /etc/apache2/ports.conf

  msg_ok "Apache listening on port ${WGER_PORT}"
}

setup_apache_permissions() {
  msg_info "Adjusting Apache systemd permissions"

  mkdir -p /etc/systemd/system/apache2.service.d
  cat <<EOF >/etc/systemd/system/apache2.service.d/override.conf
[Service]
ProtectHome=false
EOF

  systemctl daemon-reexec
  msg_ok "Apache permissions adjusted"
}

setup_apache_vhost() {
  msg_info "Creating Apache virtual host"

  cat <<EOF >/etc/apache2/sites-available/wger.conf
<Directory ${WGER_SRC}>
  <Files wsgi.py>
    Require all granted
  </Files>
</Directory>

<VirtualHost *:${WGER_PORT}>
  WSGIApplicationGroup %{GLOBAL}
  WSGIDaemonProcess wger python-path=${WGER_SRC} python-home=${WGER_VENV}
  WSGIProcessGroup wger
  WSGIScriptAlias / ${WGER_SRC}/wger/wsgi.py
  WSGIPassAuthorization On

  Alias /static/ ${WGER_HOME}/static/
  <Directory ${WGER_HOME}/static>
    Require all granted
  </Directory>

  Alias /media/ ${WGER_HOME}/media/
  <Directory ${WGER_HOME}/media>
    Require all granted
  </Directory>

  ErrorLog /var/log/apache2/wger-error.log
  CustomLog /var/log/apache2/wger-access.log combined
</VirtualHost>
EOF

  $STD a2dissite 000-default.conf
  $STD a2ensite wger
  systemctl restart apache2

  msg_ok "Apache virtual host enabled"
}

# --------------------------------------------------
# wger application
# --------------------------------------------------
create_wger_user() {
  msg_info "Creating wger user and directories"

  id ${WGER_USER} &>/dev/null \
    || $STD adduser ${WGER_USER} --disabled-password --gecos ""

  mkdir -p ${WGER_DB} ${WGER_HOME}/{static,media}
  touch ${WGER_DB}/database.sqlite

  chown :www-data -R ${WGER_DB}
  chmod g+w ${WGER_DB} ${WGER_DB}/database.sqlite
  chmod o+w ${WGER_HOME}/media

  msg_ok "User and directories ready"
}

fetch_wger_source() {
  msg_info "Downloading wger source"

  local tmp
  tmp=$(mktemp -d)
  cd "${tmp}" || exit

  curl -fsSL https://github.com/wger-project/wger/archive/refs/heads/master.tar.gz -o wger.tar.gz
  tar xzf wger.tar.gz
  mv wger-master ${WGER_SRC}

  rm -rf "${tmp}"
  msg_ok "Source downloaded"
}

setup_python_env() {
  msg_info "Setting up Python virtual environment"

  if [ ! -d "${WGER_VENV}" ]; then
    python3 -m venv "${WGER_VENV}" &>/dev/null
  fi

  source "${WGER_VENV}/bin/activate"
  $STD pip install -U pip setuptools wheel

  msg_ok "Python environment ready"
}

install_python_deps() {
  msg_info "Installing Python dependencies"

  cd "${WGER_SRC}" || exit
  $STD pip install .
  $STD pip install psycopg2-binary

  msg_ok "Python dependencies installed"
}

configure_wger() {
  msg_info "Configuring wger application"

  export DJANGO_SETTINGS_MODULE=settings
  export PYTHONPATH=${WGER_SRC}

  $STD wger create-settings --database-path ${WGER_DB}/database.sqlite

  if ! grep -q "CELERY_BROKER_URL" ${WGER_SRC}/settings.py; then
    cat <<'EOF' >>${WGER_SRC}/settings.py

#
# Celery configuration
#
CELERY_BROKER_URL = "redis://localhost:6379/0"
CELERY_RESULT_BACKEND = "redis://localhost:6379/0"
CELERY_ACCEPT_CONTENT = ["json"]
CELERY_TASK_SERIALIZER = "json"
CELERY_RESULT_SERIALIZER = "json"
CELERY_TIMEZONE = "Europe/Berlin"
EOF
  fi

  sed -i "s#home/wger/src/media#home/wger/media#g" ${WGER_SRC}/settings.py
  sed -i "/MEDIA_ROOT = '\/home\/wger\/media'/a STATIC_ROOT = '${WGER_HOME}/static'" ${WGER_SRC}/settings.py

  $STD wger bootstrap
  $STD python3 manage.py collectstatic

  msg_ok "wger configured"
}

# --------------------------------------------------
# Services
# --------------------------------------------------
setup_dummy_service() {
  msg_info "Registering wger system service"

  cat <<EOF >/etc/systemd/system/wger.service
[Unit]
Description=wger Service
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable -q --now wger
  msg_ok "wger service registered"
}

setup_celery_worker() {
  msg_info "Creating Celery worker service"

  cat <<EOF >/etc/systemd/system/wger-celery.service
[Unit]
Description=wger Celery Worker
After=network.target redis-server.service
Requires=redis-server.service

[Service]
Type=simple
User=${WGER_USER}
Group=${WGER_USER}
WorkingDirectory=${WGER_SRC}
Environment=DJANGO_SETTINGS_MODULE=settings
Environment=PYTHONPATH=${WGER_SRC}
Environment=PYTHONUNBUFFERED=1
ExecStart=${WGER_VENV}/bin/celery -A wger worker -l info
Restart=always
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${WGER_HOME}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now wger-celery
  msg_ok "Celery worker running"
}

setup_celery_beat() {
  msg_info "Creating Celery beat service"

  cat <<EOF >/etc/systemd/system/wger-celery-beat.service
[Unit]
Description=wger Celery Beat
After=network.target redis-server.service
Requires=redis-server.service

[Service]
Type=simple
User=${WGER_USER}
Group=${WGER_USER}
WorkingDirectory=${WGER_SRC}
Environment=DJANGO_SETTINGS_MODULE=settings
Environment=PYTHONPATH=${WGER_SRC}
Environment=PYTHONUNBUFFERED=1
ExecStart=${WGER_VENV}/bin/celery -A wger beat -l info
Restart=always
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${WGER_HOME}

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable --now wger-celery-beat
  msg_ok "Celery beat running"
}

# --------------------------------------------------
# Permissions & cleanup
# --------------------------------------------------
finalize_permissions() {
  msg_info "Applying filesystem permissions"

  chown -R ${WGER_USER}:wger ${WGER_SRC}
  chown -R ${WGER_USER}:www-data ${WGER_HOME}/{static,media} ${WGER_DB}
  chmod -R 775 ${WGER_HOME}/{static,media} ${WGER_DB}

  # Required for Apache traversal
  chmod 755 /home ${WGER_HOME} ${WGER_SRC}

  msg_ok "Permissions applied"
}

# --------------------------------------------------
# Execution
# --------------------------------------------------
section "System Preparation"
install_dependencies
setup_redis
setup_node

section "Apache Configuration"
setup_apache_port
setup_apache_permissions
setup_apache_vhost

section "wger Application Setup"
create_wger_user
fetch_wger_source
setup_python_env
install_python_deps
configure_wger

section "Services"
setup_dummy_service
setup_celery_worker
setup_celery_beat

section "Finalization"
finalize_permissions
motd_ssh
customize
cleanup_lxc

section "Installation Complete"
msg_ok "wger available at http://$(hostname -I | awk '{print $1}'):${WGER_PORT}"
