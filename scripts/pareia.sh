#!/bin/bash
# Roda o demo da etapa 1 com o QR na tela (10 min). Uso: ssh -t vps2 bash /opt/modular-agentes/scripts/pareia.sh
cd /opt/modular-agentes && source env.sh && set -a && source /opt/modular-agentes-data/db.env && set +a
exec mix run scripts/real.exs 600
