#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Запустите скрипт от root." >&2
  exit 1
fi

SITE_DIR=/opt/list-box
SITE_ROOT=/var/www/list-box
CRM_DIR=/opt/light-box-crm
CRM_REPOSITORY=https://github.com/treglazovdm-cyber/light-box-CRM-new.git
NGINX_SITE=/etc/nginx/sites-available/list-box
NGINX_SNIPPET=/etc/nginx/snippets/list-box-site-order.conf
SERVICE_FILE=/etc/systemd/system/light-box-crm.service

if [[ ! -d "$SITE_DIR/.git" ]]; then
  echo "Репозиторий сайта не найден: $SITE_DIR" >&2
  exit 1
fi

install -d "$SITE_ROOT"
cp -a "$SITE_DIR/dist/." "$SITE_ROOT/"

if [[ -d "$CRM_DIR/.git" ]]; then
  git -C "$CRM_DIR" pull --ff-only origin main
else
  git clone --depth 1 "$CRM_REPOSITORY" "$CRM_DIR"
fi

install -d -o www-data -g www-data "$CRM_DIR/data"
chown -R www-data:www-data "$CRM_DIR/data"

cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Light Box CRM
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=$CRM_DIR
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=/usr/bin/python3 $CRM_DIR/server.py --port 8080
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$CRM_DIR/data

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now light-box-crm

if [[ ! -f "$NGINX_SITE" ]]; then
  echo "Конфигурация Nginx не найдена: $NGINX_SITE" >&2
  exit 1
fi

cat >"$NGINX_SNIPPET" <<'EOF'
location = /api/site-order {
    client_max_body_size 16k;
    proxy_pass http://127.0.0.1:8080/api/site-order;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
}
EOF

python3 - "$NGINX_SITE" "$NGINX_SNIPPET" <<'PY'
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

site = Path(sys.argv[1])
snippet = Path(sys.argv[2])
text = site.read_text()
include = f"include {snippet};"
if include not in text:
    pattern = re.compile(r"(^\s*server_name\s+[^;]*\btreglazovdm\.fvds\.ru\b[^;]*;)", re.M)
    updated, count = pattern.subn(lambda match: match.group(1) + "\n    " + include, text)
    if not count:
        raise SystemExit("В конфигурации Nginx не найден server_name treglazovdm.fvds.ru")
    backup = site.with_name(site.name + ".bak-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(site, backup)
    site.write_text(updated)
PY

nginx -t
systemctl reload nginx

response=$(curl --fail --silent --show-error \
  --request POST http://127.0.0.1:8080/api/site-order \
  --header 'Content-Type: application/json' \
  --data '{"website":"healthcheck","request_type":"consultation","name":"Проверка","phone":"+70000000000"}')

echo "CRM отвечает: $response"
echo "Готово. Форма заказа подключена к CRM."
