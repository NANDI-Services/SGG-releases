#!/usr/bin/env bash
# ============================================================================
# migrate-to-autoupdate.sh — puente ÚNICO por SSH para instalaciones previas
# al auto-update (docs/plans/autoupdate-plan.md §18).
#
# Las residencias instaladas antes de la Fase 0 tienen `sgg` y compose
# congelados en la versión de instalación: la Fase 0 no les puede llegar por
# el mecanismo que la Fase 0 instala. Este script rompe el huevo-gallina:
# baja el `sgg` nuevo, instala el agente + timer de systemd, genera el token
# si falta y mergea el .env. Idempotente: correrlo dos veces no duplica nada.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/NANDI-Services/SGG-releases/main/migrate-to-autoupdate.sh | sudo bash
# ============================================================================
set -euo pipefail

SGG_HOME="${SGG_HOME:-/opt/sgg}"
RELEASES_RAW="${RELEASES_RAW:-https://raw.githubusercontent.com/NANDI-Services/SGG-releases/main}"

[[ $EUID -eq 0 ]] || { echo "Correr con sudo/root." >&2; exit 1; }
[[ -f "${SGG_HOME}/.env" ]] || {
  echo "No encuentro ${SGG_HOME}/.env — ¿SGG está instalado acá? (setear SGG_HOME)" >&2
  exit 1
}

cd "$SGG_HOME"

echo "==> 1/4 Bajando sgg, sgg-agent y units de systemd (main del repo público)…"
curl -fsSL "${RELEASES_RAW}/sgg"       -o /usr/local/bin/sgg
curl -fsSL "${RELEASES_RAW}/sgg-agent" -o /usr/local/bin/sgg-agent
chmod +x /usr/local/bin/sgg /usr/local/bin/sgg-agent
curl -fsSL "${RELEASES_RAW}/sgg-agent.service" -o /etc/systemd/system/sgg-agent.service
curl -fsSL "${RELEASES_RAW}/sgg-agent.timer"   -o /etc/systemd/system/sgg-agent.timer

echo "==> 2/4 Mergeando variables nuevas al .env (nunca pisa valores)…"
curl -fsSL "${RELEASES_RAW}/.env.example" -o /tmp/sgg-env-example
while IFS= read -r line; do
  [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]] || continue
  key="${BASH_REMATCH[1]}"
  grep -q "^${key}=" .env || printf '%s\n' "$line" >> .env
done < /tmp/sgg-env-example
rm -f /tmp/sgg-env-example

echo "==> 3/4 Token del agente…"
current_token=$(grep '^SGG_AGENT_TOKEN=' .env | cut -d= -f2- | tr -d '"') || true
if [[ -z "${current_token:-}" ]]; then
  # hex: viaja por shell y headers HTTP.
  new_token=$(openssl rand -hex 32)
  sed -i "s|^SGG_AGENT_TOKEN=.*|SGG_AGENT_TOKEN=\"${new_token}\"|" .env
  echo "    Token generado."
  echo "    OJO: el container api lee el token en el arranque. Correr después:"
  echo "      sgg update   (o: docker compose up -d)"
else
  echo "    Ya había token; no se toca."
fi

echo "==> 4/4 Habilitando timer de systemd…"
systemctl daemon-reload
systemctl enable --now sgg-agent.timer

echo ""
echo "Listo. El agente corre cada 5 min (journalctl -u sgg-agent)."
echo "Es la última vez que hizo falta SSH para actualizar el mecanismo de update."
