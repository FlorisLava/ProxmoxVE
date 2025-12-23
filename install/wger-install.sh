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

WGER_USER="wger"
WGER_HOME="/home/wger"
WGER_SRC="${WGER_HOME}/src"
WGER_VENV="${WGER_HOME}/venv"
WGER_DB="${WGER_HOME}/db"
WGER_PORT="${WGER_PORT:-3000}"

setup_python_env() {
  msg_info "Creating Python virtual environment"

  [ -d ${WGER_VENV} ] || python3 -m venv ${WGER_VENV} &>/dev/null
  source ${WGER_VENV}/bin/activate
  $STD pip install -U pip setuptools wheel

  msg_ok "Virtual environment ready"
}

setup_apache_port() {
    msg_info "Configuring Apache port"
    sed -i "s/^Listen .*/Listen ${WGER_PORT}/" /etc/apache2/ports.conf || true
    grep -q "^Listen ${WGER_PORT}$" /etc/apache2/ports.conf || echo "Listen ${WGER_PORT}" >> /etc/apache2/ports.conf
    msg_ok "Apache configured to listen on port ${WGER_PORT}"
}


msg_info "Installing General Dependencies"
$STD apt install -y \
  git \
  apache2 \
  libapache2-mod-wsgi-py3
msg_ok "Installed Dependencies"

msg_info "Installing Python"
$STD apt install -y python3-venv python3-pip
msg_ok "Installed Python"

msg_info "Installing Redis"
$STD apt install -y redis-server
msg_ok "Installed Redis"
systemctl enable --now redis-server

redis-cli ping | grep -qP '^PONG$' && msg_ok "Redis is running" || msg_error "Redis is not running"

NODE_VERSION="22" NODE_MODULE="sass" setup_nodejs

msg_info "Enabling Corepack"
corepack enable
msg_ok "Corepack enabled"
corepack prepare npm@10.5.0 --activate
corepack disable yarn
corepack disable pnpm

setup_apache_port

msg_info "Setting up wger"
id wger &>/dev/null || $STD adduser wger --disabled-password --gecos ""
mkdir ${WGER_DB}
touch ${WGER_DB}/database.sqlite
chown :www-data -R ${WGER_DB}
chmod g+w ${WGER_DB} ${WGER_DB}/database.sqlite
mkdir ${WGER_HOME}/{static,media}
chmod o+w ${WGER_HOME}/media
temp_dir=$(mktemp -d)
cd "$temp_dir" || exit
# RELEASE=$(curl -fsSL https://api.github.com/repos/wger-project/wger/releases/latest | grep "tag_name" | awk '{print substr($2, 2, length($2)-3)}')
# TEMP CHANGE FROM $RELEASE TO MASTER
curl -fsSL "https://github.com/wger-project/wger/archive/refs/heads/master.tar.gz" -o "master.tar.gz"
tar xzf "master.tar.gz"
mv wger-master ${WGER_SRC}
cd ${WGER_SRC} || exit

setup_python_env

msg_info "Installing Python dependencies"
$STD pip install .
$STD pip install psycopg2-binary
msg_ok "Installed Python dependencies"


export DJANGO_SETTINGS_MODULE=settings
export PYTHONPATH=${WGER_SRC}
$STD wger create-settings --database-path ${WGER_DB}/database.sqlite

if ! grep -q "CELERY_BROKER_URL" ${WGER_SRC}/settings.py; then
cat <<'EOF' >> ${WGER_SRC}/settings.py

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
rm -rf "$temp_dir"
# echo "${RELEASE}" >/opt/wger_version.txt
# echo "TEST" >/opt/wger_version.txt
msg_ok "Finished setting up wger"

msg_info "Creating Service"
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
chown -R ${WGER_USER}:wger ${WGER_SRC}
chown -R ${WGER_USER}:www-data ${WGER_HOME}/static ${WGER_HOME}/media ${WGER_DB}
chmod -R 775 ${WGER_HOME}/static ${WGER_HOME}/media ${WGER_DB}

chmod 755 /home
chmod 755 ${WGER_HOME}
chmod 755 ${WGER_SRC}


systemctl enable -q --now wger
msg_ok "Created Service"

msg_info "Configuring Apache systemd permissions"
mkdir -p /etc/systemd/system/apache2.service.d
cat <<EOF >/etc/systemd/system/apache2.service.d/override.conf
[Service]
ProtectHome=false
EOF
systemctl daemon-reexec
msg_ok "Apache systemd override applied"


msg_info "Creating Celery Worker Service"
cat <<EOF >/etc/systemd/system/wger-celery.service
[Unit]
Description=wger Celery Worker
After=network.target redis-server.service
Requires=redis-server.service

[Service]
Type=simple
User=wger
Group=wger
WorkingDirectory=${WGER_SRC}
Environment=DJANGO_SETTINGS_MODULE=settings
Environment=PYTHONPATH=${WGER_SRC}
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal
ExecStart=${WGER_VENV}/bin/celery -A wger worker -l info
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${WGER_HOME}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wger-celery
msg_ok "Created Celery Worker Service"

msg_info "Creating Celery Beat Service"
cat <<EOF >/etc/systemd/system/wger-celery-beat.service
[Unit]
Description=wger Celery Beat
After=network.target redis-server.service
Requires=redis-server.service

[Service]
Type=simple
User=wger
Group=wger
WorkingDirectory=${WGER_SRC}
Environment=DJANGO_SETTINGS_MODULE=settings
Environment=PYTHONPATH=${WGER_SRC}
Environment=PYTHONUNBUFFERED=1
StandardOutput=journal
StandardError=journal
ExecStart=${WGER_VENV}/bin/celery -A wger beat -l info
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${WGER_HOME}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now wger-celery-beat
msg_ok "Created Celery Beat Service"


motd_ssh
customize
cleanup_lxc
