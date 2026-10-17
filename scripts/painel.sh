#!/bin/bash
# Sobe o painel (producao). Le /opt/modular-agentes-data/painel.env (modo 600, fora do git).
# Uso: bash scripts/painel.sh   (fica em primeiro plano; Ctrl-C encerra)
cd /opt/modular-agentes && source env.sh && set -a && source /opt/modular-agentes-data/db.env && source /opt/modular-agentes-data/painel.env && set +a
[ -f /opt/modular-agentes-data/trafego.env ] && { set -a; source /opt/modular-agentes-data/trafego.env; set +a; }
export MIX_ENV=prod PAINEL_SERVIDOR=1
exec mix run --no-halt
