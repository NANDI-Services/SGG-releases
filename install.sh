#!/usr/bin/env bash
# ============================================================================
# SGG — install.sh
#
# Instala una instancia SGG en una máquina Ubuntu 22.04+ o Debian 12+ limpia.
# Uso desde una VM/CT limpia:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/NANDI-Services/SGG-releases/main/install.sh)"
#
# Overridable:
#   SGG_VERSION=0.1.2 bash -c "$(curl -fsSL ...)"     — pinnear otra versión
#   SGG_HOME=/srv/sgg bash -c "$(curl -fsSL ...)"     — otro directorio
#   SGG_DRY_RUN=1 bash install.sh                     — no toca nada
#   SGG_ALLOW_LXC=1 bash install.sh                   — permitir CT/LXC (avanzado)
#
# El script pide UNA sola cosa interactiva: el PAT classic de GitHub con
# scope read:packages (para bajar imágenes del registry privado de la org
# NANDI-Services). Generar en: https://github.com/settings/tokens/new
# (fine-grained NO sirve para org packages — limitación de GitHub).
# ============================================================================

set -euo pipefail

# --- Config bumpeada por publish-release.yml ---
SGG_VERSION="0.2.5"
SGG_HOME="${SGG_HOME:-/opt/sgg}"
SGG_DRY_RUN="${SGG_DRY_RUN:-0}"
SGG_ALLOW_LXC="${SGG_ALLOW_LXC:-0}"

RELEASES_RAW="https://raw.githubusercontent.com/NANDI-Services/SGG-releases/main"
GHCR_ORG="nandi-services"

LOG_FILE="${SGG_HOME}/install.log"

# Root check ANTES de crear el directorio (log() lo requiere).
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Correr como root (sudo bash install.sh)." >&2
  exit 1
fi

# Log file debe existir antes del primer log() (tee -a falla si no).
mkdir -p "$SGG_HOME"
touch "$LOG_FILE"

log()  { echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE" >&2; }
die()  { log "ERROR: $*"; exit 1; }
step() { echo ""; log "==> $*"; }

# --- 0. Precondiciones de OS y entorno ---
step "0/9 Verificando OS y entorno"
[[ -f /etc/os-release ]] || die "No es un sistema Linux estándar (falta /etc/os-release)."
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
  *ubuntu*|*debian*) log "OS: $PRETTY_NAME";;
  *) die "OS no soportado: $PRETTY_NAME. Requiere Ubuntu 22.04+ o Debian 12+.";;
esac

# Devuelve el tipo de container (lxc, docker, …) o string vacío si es bare
# metal / VM. systemd-detect-virt es el camino canónico, pero no existe en
# imágenes sin systemd — de ahí los dos fallbacks.
detect_container() {
  local v=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    v="$(systemd-detect-virt --container 2>/dev/null || true)"
    [[ "$v" == "none" ]] && v=""
  fi
  [[ -z "$v" ]] && grep -qa 'container=lxc' /proc/1/environ 2>/dev/null && v="lxc"
  [[ -z "$v" && -f /run/systemd/container ]] && v="$(cat /run/systemd/container)"
  # Docker sin systemd (ej. debian:12 pelado) no cae en ninguno de los de
  # arriba, pero siempre deja este marcador en la raíz.
  [[ -z "$v" && -f /.dockerenv ]] && v="docker"
  printf '%s' "$v"
}

# Chequeo de POLICY: "¿es una configuración que soportamos?". Bypasseable a
# propósito con SGG_ALLOW_LXC=1 — el probe funcional del paso 1 es el que
# verifica si el entorno REALMENTE puede correr la stack, y ese no se bypassea.
CONTAINER_TYPE="$(detect_container)"
if [[ -n "$CONTAINER_TYPE" ]]; then
  if [[ "$SGG_ALLOW_LXC" == "1" ]]; then
    log "ADVERTENCIA: container detectado ($CONTAINER_TYPE). SGG_ALLOW_LXC=1 — sigo."
  else
    log "Container detectado: $CONTAINER_TYPE — esto no es una VM."
    log "SGG se soporta sobre VM. Docker adentro de LXC no está soportado upstream:"
    log "  la stack falla al montar el volumen de Postgres (operation not permitted)."
    log "Si es un CT Proxmox privilegiado con nesting=1,keyctl=1, forzalo con:"
    log "  SGG_ALLOW_LXC=1 bash install.sh"
    die "Entorno no soportado. No se instaló Docker ni se pidió el PAT."
  fi
fi

# --- 1. Docker + openssl + curl ---
step "1/9 Instalando dependencias y verificando Docker"
apt-get update -qq
# iproute2 es no-op en cualquier VM real (priority important, viene en todas
# las cloud images), pero el paso 7/9 depende de `ip` para resolver la IP de
# LAN: declararlo evita que degrade en silencio a un placeholder.
apt-get install -y -qq ca-certificates curl gnupg openssl iproute2

if ! command -v docker >/dev/null 2>&1; then
  log "Docker no encontrado. Instalando desde repo oficial…"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/${ID}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  log "Docker ya instalado: $(docker --version)"
fi

docker compose version >/dev/null 2>&1 || die "docker compose plugin no disponible."

# Chequeo de FÍSICA: "¿este kernel puede correr la stack?". Verifica el
# mecanismo (levantar un container + montar un volumen), no la identidad del
# entorno — que es justo lo que rompe en un CT sin nesting=1/keyctl=1, y
# también caza VMs con el daemon roto o storage driver degradado.
# NO es bypasseable: si esto falla, `docker compose up` tampoco va a andar.
# Corre acá, antes del prompt del PAT y de generar secrets, para que un
# entorno incapaz falle barato en vez de dejar media instalación.
if [[ "$SGG_DRY_RUN" == "1" ]]; then
  log "DRY_RUN: salteando probe de Docker."
elif docker pull -q alpine:3 >/dev/null 2>&1; then
  docker volume create sgg_probe >/dev/null
  probe_rc=0
  docker run --rm -v sgg_probe:/probe alpine:3 sh -c 'touch /probe/ok' >/dev/null 2>&1 || probe_rc=$?
  # Limpiar ANTES del die: si no, el volumen queda huérfano en el host.
  docker volume rm sgg_probe >/dev/null 2>&1 || true
  if [[ $probe_rc -ne 0 ]]; then
    log "Docker no puede correr un container con volumen montado en este host."
    log "Es exactamente lo que rompe la stack de SGG (volumen de Postgres)."
    log "En un CT Proxmox: falta --features nesting=1,keyctl=1 y/o el CT es unprivileged."
    die "Docker no es funcional acá. No se pidió el PAT ni se generaron secrets."
  fi
  log "Probe OK: Docker puede correr containers y montar volúmenes."
else
  # Fallar el pull es red, no permisos. Perdemos la verificación pero no
  # bloqueamos una instalación por un corte de Docker Hub.
  log "ADVERTENCIA: no pude bajar alpine:3 para el probe (¿sin red?). Sigo sin verificar."
fi

# --- 2. Pedir PAT ---
step "2/9 Autenticación GitHub Container Registry"
if [[ "$SGG_DRY_RUN" == "1" ]]; then
  log "DRY_RUN: saltando prompt de PAT."
  PAT="dryrun"
elif [[ -n "${GHCR_PAT:-}" ]]; then
  log "Usando GHCR_PAT del entorno (unattended)."
  PAT="$GHCR_PAT"
else
  echo ""
  echo "Necesito un Personal Access Token CLASSIC con scope: read:packages"
  echo "Generar en: https://github.com/settings/tokens/new"
  echo "  Note: sgg-$(hostname)-pull"
  echo "  Expiration: 90 days (recomendado)"
  echo "  Scopes: SOLO 'read:packages'"
  echo ""
  read -r -s -p "Pegá el PAT (no se muestra): " PAT
  echo ""
  [[ -n "$PAT" ]] || die "PAT vacío."
fi

if [[ "$SGG_DRY_RUN" != "1" ]]; then
  # GHCR usa el GitHub username del OWNER del PAT como identidad para el pull,
  # no la org. Aunque el docker login acepte cualquier -u con un PAT válido,
  # el pull va a fallar con 403 si el username no corresponde al owner del PAT.
  GHCR_USER=$(curl -sSf -H "Authorization: token $PAT" https://api.github.com/user \
              | sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' | head -1)
  [[ -n "$GHCR_USER" ]] || die "No pude leer el username del PAT desde api.github.com/user. ¿PAT inválido?"
  log "PAT válido, dueño: $GHCR_USER"
  echo "$PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin \
    || die "docker login ghcr.io falló. Verificá el PAT y su scope."
fi

# --- 3. Bajar compose + .env.example ---
step "3/9 Descargando docker-compose.yaml y .env.example"
cd "$SGG_HOME"
curl -fsSL "${RELEASES_RAW}/docker-compose.yaml" -o docker-compose.yaml
curl -fsSL "${RELEASES_RAW}/.env.example"       -o .env.example

# --- 4. Generar .env con secrets ---
step "4/9 Generando secrets (openssl)"
if [[ -f .env ]]; then
  log ".env ya existe. NO se sobrescribe. Si querés reinstalar, borralo primero."
else
  # hex (no base64): el password entra en la connection URL de Prisma; base64
  # trae `+/=` que rompen el parser (visto: P1013 invalid port number).
  POSTGRES_PASSWORD_VAL=$(openssl rand -hex 32)
  JWT_SECRET_VAL=$(openssl rand -hex 64)
  REFRESH_TOKEN_SECRET_VAL=$(openssl rand -hex 64)
  PGBACKREST_REPO_CIPHER_PASS_VAL=$(openssl rand -base64 32)
  SEED_ADMIN_PASSWORD_VAL=$(openssl rand -base64 24)
  # hex: viaja por shell y headers HTTP (X-SGG-Agent-Token).
  SGG_AGENT_TOKEN_VAL=$(openssl rand -hex 32)

  cp .env.example .env
  # Substituciones (sed con delimitador | porque los base64 traen /)
  sed -i "s|^SGG_VERSION=.*|SGG_VERSION=\"${SGG_VERSION}\"|"                                             .env
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=\"${POSTGRES_PASSWORD_VAL}\"|"                        .env
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=\"${JWT_SECRET_VAL}\"|"                                             .env
  sed -i "s|^REFRESH_TOKEN_SECRET=.*|REFRESH_TOKEN_SECRET=\"${REFRESH_TOKEN_SECRET_VAL}\"|"               .env
  sed -i "s|^PGBACKREST_REPO_CIPHER_PASS=.*|PGBACKREST_REPO_CIPHER_PASS=\"${PGBACKREST_REPO_CIPHER_PASS_VAL}\"|" .env
  sed -i "s|^SEED_ADMIN_PASSWORD=.*|SEED_ADMIN_PASSWORD=\"${SEED_ADMIN_PASSWORD_VAL}\"|"                  .env
  sed -i "s|^SGG_AGENT_TOKEN=.*|SGG_AGENT_TOKEN=\"${SGG_AGENT_TOKEN_VAL}\"|"                              .env

  chmod 600 .env
  log ".env generado con permisos 600."
fi

# --- 5. Levantar stack ---
step "5/9 Docker compose pull + up"
if [[ "$SGG_DRY_RUN" == "1" ]]; then
  log "DRY_RUN: saltando docker compose."
else
  docker compose pull
  docker compose up -d --wait
fi

# --- 6. Instalar CLI + agente de auto-update ---
step "6/9 Instalando /usr/local/bin/sgg y sgg-agent"
curl -fsSL "${RELEASES_RAW}/sgg" -o /usr/local/bin/sgg
chmod +x /usr/local/bin/sgg
# Agente de auto-update (docs/plans/autoupdate-plan.md): systemd timer cada
# 5 min. El agente sale en silencio si SGG_AGENT_TOKEN no está en el .env.
curl -fsSL "${RELEASES_RAW}/sgg-agent" -o /usr/local/bin/sgg-agent
chmod +x /usr/local/bin/sgg-agent
curl -fsSL "${RELEASES_RAW}/sgg-agent.service" -o /etc/systemd/system/sgg-agent.service
curl -fsSL "${RELEASES_RAW}/sgg-agent.timer"   -o /etc/systemd/system/sgg-agent.timer
if [[ "$SGG_DRY_RUN" == "1" ]]; then
  log "DRY_RUN: saltando systemctl enable sgg-agent.timer."
else
  systemctl daemon-reload
  systemctl enable --now sgg-agent.timer
fi

# --- 7. Firewall hint (no toca) ---

# Devuelve la IP con la que se llega al server desde la LAN, o string vacío.
#
# `hostname -I` NO sirve acá: lista TODAS las IPs no-loopback y para este
# punto el paso 5 ya levantó la stack, así que docker0 (172.17.0.1) y el
# bridge del proyecto (172.18.0.1) ya existen. Tomar "la primera" acierta o
# no según el orden de los índices de interfaz, que no es contrato.
#
# El `|| true` no es decorativo: con `set -euo pipefail` una asignación cuyo
# comando falla aborta el script, y pipefail hace fallar el pipe entero si
# `ip` no existe (127) o no hay ruta por default. Sin el guard, una VM sin
# default route moriría acá — después de que la stack ya levantó.
detect_server_ip() {
  local ip=""
  # `ip route get` no manda paquetes: consulta la tabla de ruteo. Buscamos el
  # campo `src` recorriendo, no por posición: el formato varía según haya
  # `via`, `uid`, `table`, etc.
  ip="$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i+1); exit }}' || true)"
  # Sin ruta por default (red aislada): primera IP global que no sea de una
  # interfaz de Docker. Filtra por NOMBRE de interfaz, no por rango: 172.16/12
  # es RFC1918 legítimo y puede ser perfectamente la LAN del cliente.
  if [[ -z "$ip" ]]; then
    ip="$(ip -o -4 addr show scope global 2>/dev/null \
          | awk '$2 !~ /^(docker|br-|veth)/ { split($4, a, "/"); print a[1]; exit }' || true)"
  fi
  printf '%s' "$ip"
}

step "7/9 Puertos"
SERVER_IP="$(detect_server_ip)"
if [[ -n "$SERVER_IP" ]]; then
  log "Web:  http://${SERVER_IP}:3000"
  log "API:  http://${SERVER_IP}:3001/health"
else
  log "No pude determinar la IP del servidor. Corré 'hostname -I' y entrá a:"
  log "Web:  http://<IP>:3000"
  log "API:  http://<IP>:3001/health"
fi
log "Si usás UFW: sudo ufw allow 3000/tcp && sudo ufw allow 3001/tcp"

# --- 8. Info de credenciales admin (única vez) ---
step "8/9 Credenciales admin"
if [[ "$SGG_DRY_RUN" == "1" ]]; then
  log "DRY_RUN: no hay credenciales."
elif [[ -n "${SEED_ADMIN_PASSWORD_VAL:-}" ]]; then
  ADMIN_EMAIL=$(grep '^SEED_ADMIN_EMAIL=' .env | cut -d= -f2- | tr -d '"')
  echo ""
  echo "===================================================================="
  echo " ADMIN INICIAL — GUARDÁ ESTO AHORA, NO SE MUESTRA DE NUEVO"
  echo "===================================================================="
  echo " Email:    $ADMIN_EMAIL"
  echo " Password: $SEED_ADMIN_PASSWORD_VAL"
  echo "===================================================================="
  echo " Cambiala desde la UI después del primer login."
  echo "===================================================================="
  echo ""
else
  log ".env pre-existente — no regeneré password. Credenciales admin viven en .env."
fi

# --- 9. Fin ---
step "9/9 Listo"
log "Directorio: $SGG_HOME"
log "Log:        $LOG_FILE"
log "Comandos:   sgg update | sgg logs | sgg doctor | sgg backup-now"
log "Versión:    $SGG_VERSION"
