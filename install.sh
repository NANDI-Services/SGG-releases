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
#
# El script pide UNA sola cosa interactiva: el PAT classic de GitHub con
# scope read:packages (para bajar imágenes del registry privado de la org
# NANDI-Services). Generar en: https://github.com/settings/tokens/new
# (fine-grained NO sirve para org packages — limitación de GitHub).
# ============================================================================

set -euo pipefail

# --- Config bumpeada por publish-release.yml ---
SGG_VERSION="0.1.0-test"
SGG_HOME="${SGG_HOME:-/opt/sgg}"
SGG_DRY_RUN="${SGG_DRY_RUN:-0}"

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

# --- 0. Precondiciones de OS ---
step "0/9 Verificando OS"
[[ -f /etc/os-release ]] || die "No es un sistema Linux estándar (falta /etc/os-release)."
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
  *ubuntu*|*debian*) log "OS: $PRETTY_NAME";;
  *) die "OS no soportado: $PRETTY_NAME. Requiere Ubuntu 22.04+ o Debian 12+.";;
esac

# --- 1. Docker + openssl + curl ---
step "1/9 Instalando dependencias (docker, openssl, curl)"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg openssl

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
  echo "$PAT" | docker login ghcr.io -u "$GHCR_ORG" --password-stdin \
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
  POSTGRES_PASSWORD_VAL=$(openssl rand -base64 32)
  JWT_SECRET_VAL=$(openssl rand -hex 64)
  REFRESH_TOKEN_SECRET_VAL=$(openssl rand -hex 64)
  PGBACKREST_REPO_CIPHER_PASS_VAL=$(openssl rand -base64 32)
  SEED_ADMIN_PASSWORD_VAL=$(openssl rand -base64 24)

  cp .env.example .env
  # Substituciones (sed con delimitador | porque los base64 traen /)
  sed -i "s|^SGG_VERSION=.*|SGG_VERSION=\"${SGG_VERSION}\"|"                                             .env
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=\"${POSTGRES_PASSWORD_VAL}\"|"                        .env
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=\"${JWT_SECRET_VAL}\"|"                                             .env
  sed -i "s|^REFRESH_TOKEN_SECRET=.*|REFRESH_TOKEN_SECRET=\"${REFRESH_TOKEN_SECRET_VAL}\"|"               .env
  sed -i "s|^PGBACKREST_REPO_CIPHER_PASS=.*|PGBACKREST_REPO_CIPHER_PASS=\"${PGBACKREST_REPO_CIPHER_PASS_VAL}\"|" .env
  sed -i "s|^SEED_ADMIN_PASSWORD=.*|SEED_ADMIN_PASSWORD=\"${SEED_ADMIN_PASSWORD_VAL}\"|"                  .env

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

# --- 6. Instalar CLI ---
step "6/9 Instalando /usr/local/bin/sgg"
curl -fsSL "${RELEASES_RAW}/sgg" -o /usr/local/bin/sgg
chmod +x /usr/local/bin/sgg

# --- 7. Firewall hint (no toca) ---
step "7/9 Puertos"
log "Web:  http://\$(hostname -I | awk '{print \$1}'):3000"
log "API:  http://\$(hostname -I | awk '{print \$1}'):3001/health"
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
