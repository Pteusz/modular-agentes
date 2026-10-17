#!/bin/bash
# Envia UM e-mail de teste pelo SMTP configurado em painel.env. Uso: bash scripts/email_teste.sh destino@exemplo.com
[ -n "$1" ] || { echo "uso: bash scripts/email_teste.sh destino@exemplo.com"; exit 1; }
cd /opt/modular-agentes && source env.sh && set -a && source /opt/modular-agentes-data/db.env && source /opt/modular-agentes-data/painel.env && set +a
export MIX_ENV=prod
exec mix painel.email_teste "$1"
