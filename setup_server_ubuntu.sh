#!/bin/bash

# ==============================================================================
# Redeco IT Group - Server Provisioning Script
# Versie: 3.4.1 (Cleaned)
# Doel: Automatische configuratie van een nieuwe Ubuntu server met keuzemenu,
#       beveiliging (IP Whitelist, Fail2Ban, SSH Key) en eindrapport.
# ==============================================================================

# Stop het script onmiddellijk als een commando mislukt
set -e

# --- Globale Variabelen ---
GENERATED_PASSWORD=""
ADMIN_USER="redeco_admin"
declare -A CHOICES # Associative array om keuzes op te slaan

# --- Controleer op Root Rechten ---
if [ "$(id -u)" -ne 0 ]; then
    echo "FOUT: Dit script moet als root (of met sudo) worden uitgevoerd."
    exit 1
fi

# ==============================================================================
# --- HELPER FUNCTIE ---
# ==============================================================================

# $1: Vraag, $2: Standaard (y/n)
prompt_yes_no() {
    local prompt="$1"
    local default="$2"
    local choice

    if [ "$default" == "y" ]; then
        prompt="$prompt [J/n]: "
    else
        prompt="$prompt [j/N]: "
    fi

    read -p "$prompt" choice
    choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]') # naar lowercase

    if [ "$default" == "y" ]; then
        # Accepteer 'j', 'ja', of leeg (Enter)
        if [[ "$choice" == "j" || "$choice" == "ja" || -z "$choice" ]]; then
            echo "y"
        else
            echo "n"
        fi
    else
        # Accepteer alleen 'j' of 'ja'
        if [[ "$choice" == "j" || "$choice" == "ja" ]]; then
            echo "y"
        else
            echo "n"
        fi
    fi
}

# ==============================================================================
# --- INSTALLATIE FUNCTIES ---
# ==============================================================================

# --- 1. Essentiële Basisinstallatie ---
install_essentials() {
    echo "--- 1. Systeem updaten en essentiële pakketten installeren ---"
    apt-get update -y
    # Inclusief Python 3, pip, venv, en UFW (firewall)
    apt-get install -y htop ufw curl wget gnupg lsb-release ca-certificates apt-transport-https \
                       python3-pip python3-venv unattended-upgrades
                       
    echo "✓ Essentiële pakketten en Python 3 zijn geïnstalleerd."
}

# --- 2. Admin Gebruiker Aanmaken (MET SSH SLEUTEL) ---
create_admin_user() {
    echo "--- 2. Beheerdersaccount '$ADMIN_USER' aanmaken ---"
    
    # De publieke sleutel van Redeco IT (Bitwarden)
    local PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGSh7Q6TpLh1bhdjuSSUFYcD8dKmml1FArw6vOXPef9D"

    if id "$ADMIN_USER" &>/dev/null; then
        echo "INFO: Gebruiker '$ADMIN_USER' bestaat al. SSH-sleutel wordt (opnieuw) ingesteld."
    else
        useradd -m -s /bin/bash "$ADMIN_USER"
        usermod -aG sudo "$ADMIN_USER" # Geef sudo-rechten
        echo "INFO: Gebruiker '$ADMIN_USER' aangemaakt en aan 'sudo' groep toegevoegd."
    fi
    
    # Maak de .ssh map en authorized_keys aan
    local SSH_DIR="/home/$ADMIN_USER/.ssh"
    local AUTH_KEYS="$SSH_DIR/authorized_keys"
    
    mkdir -p "$SSH_DIR"
    echo "$PUBLIC_KEY" > "$AUTH_KEYS"
    
    # Zet de cruciale permissies
    chmod 700 "$SSH_DIR"
    chmod 600 "$AUTH_KEYS"
    chown -R "$ADMIN_USER":"$ADMIN_USER" "$SSH_DIR"
    
    echo "✓ SSH Publieke Sleutel voor '$ADMIN_USER' is geïnstalleerd."

    # Genereer een fallback wachtwoord voor 'sudo' en console-toegang
    GENERATED_PASSWORD=$(openssl rand -base64 16)
    echo "$ADMIN_USER:$GENERATED_PASSWORD" | chpasswd
    echo "✓ Fallback-wachtwoord ingesteld (voor 'sudo' en console-toegang)."
}


# --- 3. Firewall Configuratie (met hardcoded IPs) ---
configure_firewall() {
    echo "--- 3. Firewall (UFW) configureren ---"
    
    # De WAN IP's van Redeco IT Group zijn nu hardcoded
    local TRUSTED_IPS=("81.172.248.3" "31.149.54.249")
    echo "INFO: Beveiligde WAN IP's van Redeco IT Group worden ingesteld voor SSH..."

    for ip in "${TRUSTED_IPS[@]}"; do
        ufw allow from "$ip" to any port 22 proto tcp
        echo "INFO: Toegang verleend aan $ip voor poort 22 (SSH)."
    done
    echo "✓ SSH-toegang beperkt tot: ${TRUSTED_IPS[*]}"

    # Voeg andere regels toe op basis van keuzes
    if [ "${CHOICES[PORTAINER]}" == "y" ]; then ufw allow 9443/tcp; ufw allow 8000/tcp; fi
    if [ "${CHOICES[NPM]}" == "y" ]; then ufw allow 80/tcp; ufw allow 443/tcp; ufw allow 81/tcp; fi
    if [ "${CHOICES[JELLYFIN]}" == "y" ]; then ufw allow 8096/tcp; fi
    if [ "${CHOICES[OPENVPN]}" == "y" ]; then ufw allow 1194/udp; fi # Standaard poort OpenVPN

    ufw --force enable
    echo "✓ Firewall (UFW) is geactiveerd."
}


# --- 4. Docker & Docker Compose Installatie ---
install_docker() {
    echo "--- Installeren: Docker & Docker Compose ---"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    usermod -aG docker "$ADMIN_USER"
    
    echo "INFO: Docker 'hello-world' test uitvoeren..."
    if ! docker run --rm hello-world | grep -q "Hello from Docker!"; then
         echo "WAARSCHUWING: Docker 'hello-world' test mislukt."
    else
         echo "✓ Docker en Docker Compose succesvol geïnstalleerd en geverifieerd."
    fi
}

# --- 5. Portainer Installatie (IDEMPOTENT via Compose) ---
install_portainer() {
    echo "--- Installeren: Portainer CE (via Docker Compose) ---"
    
    local PORTAINER_DIR="/opt/portainer"
    mkdir -p "$PORTAINER_DIR"
    cd "$PORTAINER_DIR"

    # Maak het data-volume aan (dit is idempotent, doet niets als het al bestaat)
    docker volume create portainer_data
    
    echo "INFO: docker-compose.yml aanmaken in $PORTAINER_DIR..."
    tee "$PORTAINER_DIR/docker-compose.yml" > /dev/null <<EOF
version: '3.8'
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
      - portainer_data:/data
EOF

    echo "INFO: Portainer stack starten met docker compose..."
    docker compose up -d
        
    echo "✓ Portainer is gestart en bereikbaar op: https://<server-ip>:9443"
}

# --- 6. OpenVPN Server Installatie ---
install_openvpn() {
    echo "--- Installeren: OpenVPN Server ---"
    apt-get install -y openvpn easy-rsa
    echo "✓ OpenVPN software is geïnstalleerd. (Poort 1194/udp geopend in firewall)"
    echo "WAARSCHUWING: Vereist handmatige configuratie van sleutels in /etc/openvpn/."
}

# --- 7. Datto RMM Agent Installatie (Vraagt om URL) ---
install_datto_rmm() {
    echo "--- Installeren: Datto RMM Agent ---"
    local datto_url=""
    
    # Vraag om de URL, deze wordt niet opgeslagen in het script
    echo "Plak de volledige Datto RMM download-URL (deze wordt niet in het script opgeslagen):"
    read -p "Datto URL: " datto_url

    # Controleer of er iets is ingevoerd
    if [ -z "$datto_url" ]; then
        echo "INFO: Geen URL ingevoerd. Installatie van Datto RMM wordt overgeslagen."
        return 0 # Keer succesvol terug om 'set -e' niet te triggeren
    fi

    # Trim 'wget ' als de gebruiker dat meegkopieerd heeft
    datto_url=$(echo "$datto_url" | sed -e 's/^[ \t]*wget[ \t]*//')

    echo "INFO: Downloaden en uitvoeren van Datto RMM agent setup..."
    
    # Gebruik de variabele in het wget commando
    if ! wget -O /tmp/setup_datto.sh "$datto_url"; then
        echo "FOUT: Downloaden van Datto RMM Agent mislukt. Controleer de URL."
        echo "INFO: Script gaat door, maar Datto is NIET geïnstalleerd."
        return 0 # Keer succesvol terug, 'set -e' stopt het script niet
    fi
    
    # Voer het gedownloade script uit en ruim op
    sh /tmp/setup_datto.sh
    rm /tmp/setup_datto.sh
    
    echo "✓ Installatie Datto RMM voltooid."
    return 0
}

# --- 8. Jellyfin Server (Docker) Installatie (IDEMPOTENT via Compose) ---
install_jellyfin_docker() {
    echo "--- Installeren: Jellyfin Server (via Docker Compose) ---"
    
    local JELLYFIN_DIR="/opt/jellyfin"
    mkdir -p "$JELLYFIN_DIR"
    cd "$JELLYFIN_DIR"

    # Maak de volumes aan
    docker volume create jellyfin_config
    docker volume create jellyfin_cache
    
    echo "INFO: docker-compose.yml aanmaken in $JELLYFIN_DIR..."
    tee "$JELLYFIN_DIR/docker-compose.yml" > /dev/null <<EOF
version: '3.8'
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - "8096:8096"
    volumes:
      - jellyfin_config:/config
      - jellyfin_cache:/cache
      # --- VOEG HIER HANDMATIG MEDIA MAPPEN TOE ---
      # Voorbeeld:
      # - /pad/op/server/naar/films:/media/films
      # - /pad/op/server/naar/series:/media/series
EOF

    echo "INFO: Jellyfin stack starten met docker compose..."
    docker compose up -d
      
    echo "✓ Jellyfin is gestart en bereikbaar op: http://<server-ip>:8096"
    echo "======================================================================="
    echo "LET OP: Je moet handmatig media-mappen toevoegen aan Jellyfin!"
    echo "Bewerk het bestand: $JELLYFIN_DIR/docker-compose.yml"
    echo "En voer daarna uit: cd $JELLYFIN_DIR && docker compose up -d"
    echo "======================================================================="
}


# --- 9. Nginx Proxy Manager (Docker) Installatie ---
install_npm_docker() {
    echo "--- Installeren: Nginx Proxy Manager (via Docker Compose) ---"
    local NPM_DIR="/opt/npm"
    mkdir -p "$NPM_DIR"
    cd "$NPM_DIR"

    echo "INFO: docker-compose.yml aanmaken in $NPM_DIR..."
    
    # Schrijf de officiële docker-compose file
    tee "$NPM_DIR/docker-compose.yml" > /dev/null <<EOF
version: '3.8'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '81:81'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
  db:
    image: 'jc21/mariadb-aria:latest'
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: 'npm'
      MYSQL_DATABASE: 'npm'
      MYSQL_USER: 'npm'
      MYSQL_PASSWORD: 'npm'
    volumes:
      - ./data/mysql:/var/lib/mysql
EOF

    echo "INFO: Nginx Proxy Manager stack starten met docker compose..."
    docker compose up -d
    
    echo "✓ Nginx Proxy Manager is gestart. (Poorten 80, 443, 81 geopend in firewall)"
}

# --- 10. Fail2Ban Installatie ---
install_fail2ban() {
    echo "--- Installeren: Fail2Ban (Brute-force bescherming) ---"
    apt-get install -y fail2ban
    
    tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
bantime  = 1d
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF

    systemctl restart fail2ban
    echo "✓ Fail2Ban geïnstalleerd en geconfigureerd voor SSH."
}

# --- 11. SSH Hardening ---
harden_ssh() {
    echo "--- Beveiligen: SSH-server (Harding) ---"
    # Verbod op directe root login
    sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    
    systemctl restart sshd
    echo "✓ SSH-server beveiligd (Directe Root login verboden)."
}


# ==============================================================================
# --- HOOFD SCRIPT UITVOERING ---
# ==============================================================================

clear
echo "================================================="
echo "  Redeco IT Group - Server Configuratie Script v3.4"
echo "================================================="
echo "Dit script zal de server configureren."
echo ""
echo "De volgende onderdelen worden *altijd* uitgevoerd:"
echo " 1. Systeem update & essentiële tools (Python 3, htop...)"
echo " 2. Aanmaken admin-account '$ADMIN_USER' met Redeco SSH-sleutel"
echo ""
echo "--- Selecteer Optionele Componenten ---"

# Applicaties
CHOICES[DOCKER]=$(prompt_yes_no "Docker & Docker Compose installeren?" "y")
CHOICES[PORTAINER]=$(prompt_yes_no "Portainer CE installeren?" "y")
CHOICES[NPM]=$(prompt_yes_no "Nginx Proxy Manager (Docker) installeren?" "y")
CHOICES[JELLYFIN]=$(prompt_yes_no "Jellyfin Server (Docker) installeren?" "n")
CHOICES[OPENVPN]=$(prompt_yes_no "OpenVPN Server (software) installeren?" "n")
CHOICES[DATTO]=$(prompt_yes_no "Datto RMM Agent installeren?" "y")

# Beveiliging
echo ""
echo "--- Selecteer Beveiligingsopties (Aanbevolen) ---"
CHOICES[FAIL2BAN]=$(prompt_yes_no "Fail2Ban (brute-force protectie) installeren?" "y")
CHOICES[HARDEN_SSH]=$(prompt_yes_no "SSH Hardening (root login verbieden) toepassen?" "y")


echo ""
echo "--- START CONFIGURATIE ---"

# --- 1. Verplichte stappen ---
install_essentials
create_admin_user

# --- 2. Afhankelijkheden controleren ---
if [[ "${CHOICES[PORTAINER]}" == "y" || "${CHOICES[NPM]}" == "y" || "${CHOICES[JELLYFIN]}" == "y" ]] && \
   [[ "${CHOICES[DOCKER]}" == "n" ]]; then
    echo "INFO: Docker is vereist voor Portainer, NPM, of Jellyfin. Docker wordt automatisch mee-geïnstalleerd."
    CHOICES[DOCKER]="y"
fi

# --- 3. Firewall configureren ---
configure_firewall

# --- 4. Optionele componenten installeren ---
if [ "${CHOICES[DOCKER]}" == "y" ]; then install_docker; fi
if [ "${CHOICES[PORTAINER]}" == "y" ]; then install_portainer; fi
if [ "${CHOICES[NPM]}" == "y" ]; then install_npm_docker; fi
if [ "${CHOICES[JELLYFIN]}" == "y" ]; then install_jellyfin_docker; fi
if [ "${CHOICES[OPENVPN]}" == "y" ]; then install_openvpn; fi
if [ "${CHOICES[DATTO]}" == "y" ]; then install_datto_rmm; fi

# --- 5. Beveiligingscomponenten installeren ---
if [ "${CHOICES[FAIL2BAN]}" == "y" ]; then install_fail2ban; fi
if [ "${CHOICES[HARDEN_SSH]}" == "y" ]; then harden_ssh; fi

# --- 6. Eindbericht ---
echo ""
echo "================================================="
echo "  CONFIGURATIE VOLTOOID"
echo "================================================="
echo "De server is succesvol geconfigureerd."
echo ""
echo "BELANGRIJK: Inloggegevens voor Wachtwoordbeheer:"
echo "-------------------------------------------------"
echo "  Gebruiker: $ADMIN_USER"
echo "  Login: Via SSH-sleutel (geïnstalleerd)"
echo "  Fallback Wachtwoord: $GENERATED_PASSWORD"
echo "  (Dit wachtwoord is voor 'sudo' commando's of console-toegang)"
echo ""
echo ""
echo "Overzicht Geïnstalleerde Componenten & Paden:"
echo "-------------------------------------------------"
echo ""
echo "✓ Beheerdersaccount:"
echo "  Pad: /home/$ADMIN_USER/"
echo ""
echo "✓ Essentiële Tools (Python3, UFW, etc.):"
echo "  Pad: Standaard Systeempaden (bijv. /usr/bin/python3, /etc/ufw/)"
echo ""
echo "✓ Firewall (UFW):"
echo "  Status: Actief. SSH-toegang beperkt tot: 81.172.248.3, 31.149.54.249"
echo ""

if [ "${CHOICES[DOCKER]}" == "y" ]; then
    echo "✓ Docker & Docker Compose:"
    echo "  Pad (Docker Root): /var/lib/docker/"
    echo "  Pad (Volumes): /var/lib/docker/volumes/"
    echo ""
fi

if [ "${CHOICES[PORTAINER]}" == "y" ]; then
    echo "✓ Portainer CE (Docker Container):"
    echo "  Toegang: https://<server-ip>:9443 (Firewall poort 9443/tcp geopend)"
    echo "  Pad (Configuratie): /opt/portainer/docker-compose.yml"
    echo "  Pad (Data Volume): 'portainer_data'"
    echo ""
fi

if [ "${CHOICES[NPM]}" == "y" ]; then
    echo "✓ Nginx Proxy Manager (Docker Container):"
    echo "  Toegang: http://<server-ip>:81 (Firewall poorten 80, 443, 81/tcp geopend)"
    echo "  Pad (Configuratie): /opt/npm/"
    echo ""
fi

if [ "${CHOICES[JELLYFIN]}" == "y" ]; then
    echo "✓ Jellyfin Server (Docker Container):"
    echo "  Toegang: http://<server-ip>:8096 (Firewall poort 8096/tcp geopend)"
    echo "  Pad (Configuratie): /opt/jellyfin/docker-compose.yml"
    echo "  Pad (Data Volumes): 'jellyfin_config', 'jellyfin_cache'"
    echo ""
fi

if [ "${CHOICES[OPENVPN]}" == "y" ]; then
    echo "✓ OpenVPN Server (Software):"
    echo "  Info: Vereist handmatige sleutelconfiguratie. (Firewall poort 1194/udp geopend)"
    echo "  Pad (Configuratie): /etc/openvpn/"
    echo ""
fi

if [ "${CHOICES[DATTO]}" == "y" ]; then
    echo "✓ Datto RMM Agent:"
    echo "  Info: Agent is geïnstalleerd en rapporteert."
    echo ""
fi

if [ "${CHOICES[FAIL2BAN]}" == "y" ]; then
    echo "✓ Fail2Ban (Beveiliging):"
    echo "  Info: Actief en beveiligt SSH tegen brute-force aanvallen."
    echo ""
fi

if [ "${CHOICES[HARDEN_SSH]}" == "y" ]; then
    echo "✓ SSH Hardening (Beveiliging):"
    echo "  Info: Directe 'root' login via SSH is nu verboden."
    echo ""
fi

echo "================================================="
