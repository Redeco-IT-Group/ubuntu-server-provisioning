# Redeco IT Group - Ubuntu Server Provisioning

Dit is het officiële en gestandaardiseerde provisioning script van Redeco IT Group voor het installeren en beveiligen van nieuwe Ubuntu 22.04+ servers voor klanten.

Het doel van dit script is **standaardisatie**, **veiligheid** en **efficiëntie**. Het zorgt ervoor dat elke server die we opleveren exact dezelfde basisconfiguratie, beveiliging en mappenstructuur heeft.

-----

## Configuratie (Voor Hergebruik)

Dit script is ontworpen om makkelijk herbruikbaar te zijn. Alle organisatiespecifieke instellingen staan bovenaan het script (`setup_server_ubuntu.sh`) in een duidelijk **configuratieblok**.

Als je dit script voor een andere organisatie wilt gebruiken, hoef je alleen de waarden in dit blok aan te passen:

```bash
# ==============================================================================
# --- CONFIGURATIE VARIABELEN ---
# ==============================================================================

# De Sudo-gebruiker die wordt aangemaakt
ADMIN_USER="redeco_admin"

# De *volledige* publieke SSH-sleutel voor de admin-gebruiker
ADMIN_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..."

# De WAN IP-adressen die SSH-toegang krijgen (spatie-gescheiden)
FIREWALL_TRUSTED_IPS=("81.172.248.3" "31.149.54.249")

# ...
# ==============================================================================
```

-----

## Gebruik

Dit script is bedoeld om te draaien op een **nieuwe, schone Ubuntu server**.

1.  Log in op de nieuwe server via SSH (meestal als `root`):
    ```bash
    ssh root@<ip-adres-van-server>
    ```
2.  Voer het onderstaande commando uit. Het script downloadt de laatste versie van `main` en voert deze uit met `sudo`.

<!-- end list -->

```bash
curl -sSL https://raw.githubusercontent.com/Redeco-IT-Group/ubuntu-server-provisioning/main/setup_server_ubuntu.sh | sudo bash
```

Het script zal je vervolgens een aantal (J/n) vragen stellen over welke optionele componenten je wilt installeren.

-----

## Wat doet dit script?

Het script is **idempotent**: je kunt het veilig meerdere keren draaien. Componenten die al correct zijn geïnstalleerd, worden overgeslagen.

### 1\. Basis Systeemconfiguratie (Altijd)

Deze stappen worden *altijd* uitgevoerd:

  * **Systeem Update:** Voert `apt-get update` uit.
  * **Essentiële Tools:** Installeert `htop`, `ufw` (firewall), `curl`, `wget`, `python3-pip` en `python3-venv`.
  * **Beheerdersaccount:** Maakt de `ADMIN_USER` aan (zoals ingesteld in de variabelen) met `sudo`-rechten.
  * **SSH-toegang:** Installeert automatisch de `ADMIN_PUBLIC_KEY` in het `authorized_keys`-bestand van de admin.
  * **Fallback Wachtwoord:** Genereert een veilig, willekeurig wachtwoord voor de admin (voor `sudo` en console-toegang) en toont dit aan het einde.

### 2\. Beveiliging (Altijd & Optioneel)

  * **Firewall (UFW):** Wordt *altijd* ingeschakeld.
      * **SSH-toegang** wordt beperkt tot de IP's in `FIREWALL_TRUSTED_IPS`. (Als de lijst leeg is, blijft SSH open met een waarschuwing).
      * Poorten voor geselecteerde services (Portainer, NPM, etc.) worden automatisch geopend.
  * **(Optie) Fail2Ban:** Installeert en configureert Fail2Ban om SSH te beschermen tegen brute-force aanvallen.
  * **(Optie) SSH Hardening:** Beveiligt de SSH-server door directe `root` login te verbieden (`PermitRootLogin no`).

### 3\. Optionele Software (Keuzemenu)

Je krijgt een menu waarin je de volgende componenten kunt selecteren:

  * **Docker & Docker Compose:** Installeert de laatste officiële versie.
  * **Portainer CE:** Geïnstalleerd via Docker Compose in `/opt/portainer`.
  * **Nginx Proxy Manager:** Geïnstalleerd via Docker Compose in `/opt/npm`.
  * **Jellyfin Server:** Geïnstalleerd via Docker Compose in `/opt/jellyfin`.
  * **OpenVPN Server:** Installeert de OpenVPN-software (vereist handmatige sleutelconfiguratie).
  * **Datto RMM Agent:** Het script vraagt je om de **Datto RMM-downloadlink** te plakken (deze staat om veiligheidsredenen *niet* in het script).

-----

## Standaard Padenstructuur

| Service | Installatie Pad / Data |
| :--- | :--- |
| **Systeem Tools** | Standaard Linux paden (bv. `/usr/bin`, `/etc/ufw`) |
| **Admin Gebruiker** | `/home/<ADMIN_USER>/` |
| **Docker Root** | `/var/lib/docker/` |
| **Docker Volumes** | `/var/lib/docker/volumes/` (bv. `portainer_data`) |
| **Nginx Proxy Manager**| `/opt/npm/` (bevat `docker-compose.yml` en data) |
| **Portainer** | `/opt/portainer/` (bevat `docker-compose.yml`) |
| **Jellyfin** | `/opt/jellyfin/` (bevat `docker-compose.yml`) |

-----

## Na Installatie

Wanneer het script klaar is, toont het een **"CONFIGURATIE VOLTOOID"** overzicht. Dit rapport bevat:

1.  Het **fallback-wachtwoord** voor de admin. **Sla dit direct op in Bitwarden.**
2.  Een lijst van alle geïnstalleerde services en hun paden/toegangspoorten.

Je kunt nu uitloggen als `root` en direct inloggen met je admin-account en je opgeslagen SSH-sleutel:

```bash
ssh <ADMIN_USER>@<server-ip>
```

