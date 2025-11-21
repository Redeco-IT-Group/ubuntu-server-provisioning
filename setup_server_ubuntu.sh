#!/usr/bin/env bash
# Ubuntu installatie script met keuze-menu
# Ondersteunt:
#  - apt update
#  - apt upgrade
#  - Docker (laatste versie via get.docker.com)
#  - Portainer (via docker compose, in /home/<user>/docker/Portainer)

########################################
# Basis instellingen en variabelen
########################################

# Zorg dat script stopt bij ctrl+c maar niet bij elke fout
set -u

SELECT_UPDATE=false
SELECT_UPGRADE=false
SELECT_DOCKER=false
SELECT_PORTAINER=false

ERRORS=0
REPORT=()

# Bepaal de "echte" gebruiker (niet root)
BASE_USER="${SUDO_USER:-$USER}"
HOME_DIR="$(eval echo "~$BASE_USER")"
DOCKER_BASE_DIR="$HOME_DIR/docker"
PORTAINER_DIR="$DOCKER_BASE_DIR/Portainer"
START_DIR="$(pwd)"

########################################
# Helper functies
########################################

log() {
  local line="$1"
  echo "$line"
  REPORT+=("$line")
}

run_cmd() {
  local desc="$1"
  shift
  if "$@"; then
    log "OK: $desc"
  else
    log "FOUT: $desc (commando: $*)"
    ERRORS=$((ERRORS + 1))
  fi
}

ask_yes_no() {
  local prompt="$1"
  local answer
  while true; do
    read -rp "$prompt (y/n): " answer
    case "$answer" in
      [Yy]) echo "yes"; return 0 ;;
      [Nn]) echo "no"; return 0 ;;
      *) echo "Kies y of n." ;;
    esac
  done
}

########################################
# Acties
########################################

do_update() {
  log "=== APT update gestart ==="
  run_cmd "apt-get update" sudo apt-get update
}

do_upgrade() {
  log "=== APT upgrade gestart ==="
  run_cmd "apt-get upgrade -y" sudo apt-get upgrade -y
}

install_docker() {
  log "=== Docker installatie gestart ==="

  # Curl installeren indien nodig
  if ! command -v curl >/dev/null 2>&1; then
    log "curl niet gevonden, installeren..."
    run_cmd "curl installeren" sudo apt-get install -y curl
  fi

  # Laatste Docker via get.docker.com
  if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
    if sudo sh /tmp/get-docker.sh; then
      log "Docker installatie script succesvol uitgevoerd."
    else
      log "FOUT: get.docker.com script gaf een fout."
      ERRORS=$((ERRORS + 1))
      return
    fi
  else
    log "FOUT: kon https://get.docker.com niet downloaden."
    ERRORS=$((ERRORS + 1))
    return
  fi

  # Gebruiker aan docker groep toevoegen (zodat je later zonder sudo kunt werken)
  if sudo usermod -aG docker "$BASE_USER"; then
    log "Gebruiker $BASE_USER toegevoegd aan de 'docker' groep."
  else
    log "LET OP: kon gebruiker $BASE_USER niet aan 'docker' groep toevoegen."
    ERRORS=$((ERRORS + 1))
  fi

  # Docker directory aanmaken
  if mkdir -p "$DOCKER_BASE_DIR"; then
    log "Docker basisdirectory: $DOCKER_BASE_DIR"
  else
    log "FOUT: kon directory $DOCKER_BASE_DIR niet aanmaken."
    ERRORS=$((ERRORS + 1))
  fi

  # Versie info
  local docker_ver
  docker_ver="$(docker --version 2>/dev/null || echo 'Docker versie onbekend (mogelijk shell nog niet opnieuw ingelogd)')"
  log "Docker versie: $docker_ver"
}

install_portainer() {
  log "=== Portainer installatie gestart ==="

  if ! command -v docker >/dev/null 2>&1; then
    log "FOUT: Docker is niet beschikbaar, Portainer installatie overgeslagen."
    ERRORS=$((ERRORS + 1))
    return
  fi

  # Portainer directory
  if mkdir -p "$PORTAINER_DIR/data"; then
    log "Portainer directory: $PORTAINER_DIR"
  else
    log "FOUT: kon Portainer directory $PORTAINER_DIR niet aanmaken."
    ERRORS=$((ERRORS + 1))
    return
  fi

  # docker-compose.yml aanmaken
  cat > "$PORTAINER_DIR/docker-compose.yml" <<'EOF'
version: "3.8"

services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    ports:
      - "8000:8000"
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
EOF

  log "docker-compose.yml aangemaakt in $PORTAINER_DIR"

  # Portainer starten via docker compose / docker-compose
  (
    cd "$PORTAINER_DIR" || exit 1
    if command -v docker compose >/dev/null 2>&1; then
      sudo docker compose pull && sudo docker compose up -d
    elif command -v docker-compose >/dev/null 2>&1; then
      sudo docker-compose pull && sudo docker-compose up -d
    else
      echo "NO_COMPOSE"
      exit 1
    fi
  )
  rc=$?

  if [ $rc -ne 0 ]; then
    log "FOUT: kon Portainer niet starten (geen 'docker compose' of 'docker-compose'? of andere fout)."
    ERRORS=$((ERRORS + 1))
    return
  fi

  # Informatie over de draaiende Portainer container
  local portainer_image
  portainer_image="$(sudo docker ps --filter "name=portainer" --format '{{.Image}}' | head -n1)"
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  log "Portainer container image: ${portainer_image:-onbekend}"
  if [ -n "$host_ip" ]; then
    log "Portainer URL (HTTPS): https://$host_ip:9443"
    log "Portainer URL (HTTP):  http://$host_ip:8000"
  else
    log "Kon geen host IP bepalen, controleer zelf het IP voor Portainer."
  fi

  log "Portainer data directory: $PORTAINER_DIR/data"
}

########################################
# Menu keuzes
########################################

echo "=============================="
echo " Ubuntu installatie script"
echo " Gebruiker: $BASE_USER"
echo " Home dir: $HOME_DIR"
echo " Start dir: $START_DIR"
echo "=============================="
echo

if [ ! -d "$HOME_DIR" ]; then
  echo "FOUT: Home directory $HOME_DIR bestaat niet. Stop."
  exit 1
fi

# Keuzes maken
if [ "$(ask_yes_no 'apt update uitvoeren?')" = "yes" ]; then
  SELECT_UPDATE=true
fi

if [ "$(ask_yes_no 'apt upgrade uitvoeren?')" = "yes" ]; then
  SELECT_UPGRADE=true
fi

if [ "$(ask_yes_no 'Docker installeren / updaten naar laatste versie?')" = "yes" ]; then
  SELECT_DOCKER=true
fi

if [ "$(ask_yes_no 'Portainer installeren / updaten naar laatste versie?')" = "yes" ]; then
  SELECT_PORTAINER=true
fi

########################################
# Overzicht & Bevestiging
########################################

echo
echo "Je hebt het volgende geselecteerd:"
$SELECT_UPDATE     && echo " - apt update"
$SELECT_UPGRADE    && echo " - apt upgrade"
$SELECT_DOCKER     && echo " - Docker (laatste versie, directory: $DOCKER_BASE_DIR)"
$SELECT_PORTAINER  && echo " - Portainer (laatste versie, directory: $PORTAINER_DIR)"
echo

if [ "$SELECT_UPDATE" = false ] && \
   [ "$SELECT_UPGRADE" = false ] && \
   [ "$SELECT_DOCKER" = false ] && \
   [ "$SELECT_PORTAINER" = false ]; then
  echo "Geen acties geselecteerd. Script stopt."
  exit 0
fi

if [ "$(ask_yes_no 'Weet je zeker dat je dit wilt uitvoeren?')" != "yes" ]; then
  echo "Bevestiging geweigerd. Script stopt."
  exit 0
fi

########################################
# Uitvoeren van geselecteerde acties
########################################

log "=== SYSTEEMINFO ==="
log "Distributie: $(lsb_release -ds 2>/dev/null || echo 'onbekend')"
log "Kernel: $(uname -r)"
log "Huidige werkdirectory bij start script: $START_DIR"
log "Home directory voor installaties: $HOME_DIR"
log ""

if [ "$SELECT_UPDATE" = true ]; then
  do_update
  log ""
fi

if [ "$SELECT_UPGRADE" = true ]; then
  do_upgrade
  log ""
fi

if [ "$SELECT_DOCKER" = true ]; then
  install_docker
  log ""
fi

if [ "$SELECT_PORTAINER" = true ]; then
  install_portainer
  log ""
fi

########################################
# Eindverslag
########################################

echo
echo "========================================"
echo "             EINDE VERSLAG"
echo "========================================"

for line in "${REPORT[@]}"; do
  echo "$line"
done

echo
if [ "$SELECT_DOCKER" = true ]; then
  echo "Docker binaries staan normaal in /usr/bin/docker"
  echo "Docker directory (zoals gevraagd): $DOCKER_BASE_DIR"
fi

if [ "$SELECT_PORTAINER" = true ]; then
  echo "Portainer files staan in: $PORTAINER_DIR"
  echo "Portainer data directory: $PORTAINER_DIR/data"
  echo "Config bestand: $PORTAINER_DIR/docker-compose.yml"
fi

if [ $ERRORS -gt 0 ]; then
  echo
  echo "Script klaar, maar er zijn $ERRORS fout(en) opgetreden. Check de meldingen hierboven."
else
  echo
  echo "Script succesvol afgerond zonder fouten."
fi

echo
echo "Let op: als je net aan de docker groep bent toegevoegd, log even opnieuw in voordat je 'docker' zonder sudo gebruikt."
