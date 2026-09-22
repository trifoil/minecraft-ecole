#!/usr/bin/env bash
# =============================================================================
#  minecraft-ecole — installer for a school LAN Minecraft server
# =============================================================================
#  This script does these steps on a stock Debian server:
#    1. It installs Docker CE and the Compose plugin.
#    2. It starts a Paper Minecraft server in a container (offline mode).
#    3. It starts Crafty Controller and Portainer as web admin panels.
#    4. It installs AuthMeReloaded, so each player must log in by chat command.
#    5. It makes N student accounts (default 50) and writes them to a CSV file.
#
#  Run the script as root:
#      sudo bash install.sh
#
#  You can change the defaults with environment variables. Example:
#      sudo MC_MEMORY=6G ACCOUNT_COUNT=30 bash install.sh
# =============================================================================

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Settings. Change them here, or give them on the command line.
# ----------------------------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-/opt/minecraft-ecole}"
MC_VERSION="${MC_VERSION:-1.21.11}"     # Paper version. AuthMe 6.x needs 1.21.11+
MC_MEMORY="${MC_MEMORY:-4G}"            # Java heap for the server
MC_PORT="${MC_PORT:-25565}"             # Minecraft port on the LAN
MAX_PLAYERS="${MAX_PLAYERS:-60}"
VIEW_DISTANCE="${VIEW_DISTANCE:-8}"
DIFFICULTY="${DIFFICULTY:-normal}"
MOTD="${MOTD:-Serveur Minecraft de l ecole - connectez-vous avec /login}"

ACCOUNT_COUNT="${ACCOUNT_COUNT:-50}"    # Number of student accounts
ACCOUNT_PREFIX="${ACCOUNT_PREFIX:-eleve}"
PASSWORD_LENGTH="${PASSWORD_LENGTH:-10}"

CRAFTY_PORT="${CRAFTY_PORT:-8443}"      # Crafty Controller web panel (HTTPS)
PORTAINER_PORT="${PORTAINER_PORT:-9443}" # Portainer web panel (HTTPS)
CRAFTY_MC_RANGE="${CRAFTY_MC_RANGE:-25601-25650}"  # Ports for Crafty servers

TZ_NAME="${TZ_NAME:-Europe/Brussels}"
ENABLE_WHITELIST="${ENABLE_WHITELIST:-false}"  # "true" adds a second lock
SETUP_FIREWALL="${SETUP_FIREWALL:-no}"         # "yes" configures ufw
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-no}"

# Characters for the passwords. Ambiguous characters are not in the list.
PASSWORD_ALPHABET='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'

COMPOSE="docker compose"

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------
C_OK=$'\033[1;32m'; C_INFO=$'\033[1;36m'; C_WARN=$'\033[1;33m'
C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'

log()  { printf '%s[ %s ]%s %s\n' "$C_INFO" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()   { printf '%s  OK %s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s  !! %s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s ERR %s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

trap 'die "The script stopped at line $LINENO."' ERR

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Run this script as root. Use: sudo bash $0"
}

check_debian() {
    [ -r /etc/os-release ] || die "The file /etc/os-release is not present."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *debian*|*ubuntu*) ok "The system is ${PRETTY_NAME:-unknown}." ;;
        *) warn "This script is made for Debian. The system is ${PRETTY_NAME:-unknown}." ;;
    esac
    [ -n "${VERSION_CODENAME:-}" ] || die "The Debian codename is not known."
}

# Make a random password from the safe alphabet.
# The "|| true" is necessary, because "head" closes the pipe and "tr" stops.
random_password() {
    local p=""
    p="$(LC_ALL=C tr -dc "$PASSWORD_ALPHABET" < /dev/urandom \
         | head -c "$PASSWORD_LENGTH")" || true
    printf '%s\n' "$p"
}

# Make a random secret for RCON.
random_secret() {
    local s=""
    s="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)" || true
    printf '%s\n' "$s"
}

# Compute the offline-mode UUID of a player name.
# Minecraft uses UUID version 3 of the string "OfflinePlayer:<name>".
offline_uuid() {
    local name="$1" h b6 b8
    h="$(printf 'OfflinePlayer:%s' "$name" | md5sum | awk '{print $1}')"
    b6="$(printf '%02x' $(( ( 0x${h:12:2} & 0x0f ) | 0x30 )) )"
    b8="$(printf '%02x' $(( ( 0x${h:16:2} & 0x3f ) | 0x80 )) )"
    printf '%s-%s-%s%s-%s%s-%s\n' \
        "${h:0:8}" "${h:8:4}" "$b6" "${h:14:2}" "$b8" "${h:18:2}" "${h:20:12}"
}

# ----------------------------------------------------------------------------
# Step 1 — Install Docker CE
# ----------------------------------------------------------------------------
install_docker() {
    if [ "$SKIP_DOCKER_INSTALL" = "yes" ]; then
        ok "The Docker installation is disabled."
        return
    fi
    if docker compose version >/dev/null 2>&1; then
        ok "Docker and the Compose plugin are already present."
        return
    fi

    log "Install the packages that Docker needs."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg apt-transport-https

    log "Add the official Docker repository."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    . /etc/os-release
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] %s %s stable\n' \
        "$(dpkg --print-architecture)" \
        "https://download.docker.com/linux/debian" \
        "${VERSION_CODENAME}" > /etc/apt/sources.list.d/docker.list

    log "Install Docker CE."
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker
    ok "Docker is installed. Version: $(docker --version)"
}

# ----------------------------------------------------------------------------
# Step 2 — Make the directories and the .env file
# ----------------------------------------------------------------------------
prepare_directories() {
    log "Make the directory $INSTALL_DIR."
    mkdir -p "$INSTALL_DIR"/{data,crafty/{backups,logs,servers,config,import},secrets}
    mkdir -p "$INSTALL_DIR/data/plugins/AuthMe"
    chmod 700 "$INSTALL_DIR/secrets"
    # The itzg image runs as user 1000.
    chown -R 1000:1000 "$INSTALL_DIR/data"
    ok "The directories are ready."
}

write_env() {
    local env_file="$INSTALL_DIR/.env"
    if [ -f "$env_file" ]; then
        ok "The file .env is already present. The script keeps it."
        return
    fi
    log "Write the file .env."
    cat > "$env_file" <<EOF
# Configuration of the school Minecraft stack.
# Change a value, then run: mcadmin restart
MC_VERSION=$MC_VERSION
MC_MEMORY=$MC_MEMORY
MC_PORT=$MC_PORT
MAX_PLAYERS=$MAX_PLAYERS
VIEW_DISTANCE=$VIEW_DISTANCE
DIFFICULTY=$DIFFICULTY
MOTD=$MOTD
ENABLE_WHITELIST=$ENABLE_WHITELIST
RCON_PASSWORD=$(random_secret)
CRAFTY_PORT=$CRAFTY_PORT
CRAFTY_MC_RANGE=$CRAFTY_MC_RANGE
PORTAINER_PORT=$PORTAINER_PORT
TZ=$TZ_NAME
EOF
    chmod 600 "$env_file"
    ok "The file .env is written."
}

# ----------------------------------------------------------------------------
# Step 3 — Write docker-compose.yml
# ----------------------------------------------------------------------------
write_compose() {
    log "Write the file docker-compose.yml."
    # The quotes around YAML stop the shell from expanding ${...}.
    # Docker Compose reads those values from the .env file.
    cat > "$INSTALL_DIR/docker-compose.yml" <<'YAML'
# =============================================================================
#  School Minecraft stack
#    mc         : Paper server, offline mode, protected by AuthMeReloaded
#    crafty     : web panel to make and manage more Minecraft servers
#    portainer  : web panel to manage the containers of this stack
# =============================================================================

services:

  mc:
    image: itzg/minecraft-server:latest
    container_name: mc-ecole
    restart: unless-stopped
    stdin_open: true
    tty: true
    ports:
      - "${MC_PORT}:25565"
      # The RCON port stays inside Docker. Do not publish it on the LAN.
    environment:
      EULA: "TRUE"
      TYPE: "PAPER"
      VERSION: "${MC_VERSION}"
      MEMORY: "${MC_MEMORY}"
      TZ: "${TZ}"
      USE_AIKAR_FLAGS: "true"

      # --- Offline mode -------------------------------------------------
      # The clients are not official, so the server must not check the
      # Mojang session servers. AuthMeReloaded gives the login protection.
      ONLINE_MODE: "FALSE"
      ENFORCE_SECURE_PROFILE: "false"

      # --- Game settings ------------------------------------------------
      MOTD: "${MOTD}"
      DIFFICULTY: "${DIFFICULTY}"
      MAX_PLAYERS: "${MAX_PLAYERS}"
      VIEW_DISTANCE: "${VIEW_DISTANCE}"
      SIMULATION_DISTANCE: "6"
      SPAWN_PROTECTION: "0"
      ALLOW_FLIGHT: "false"
      ENABLE_COMMAND_BLOCK: "false"
      OVERRIDE_SERVER_PROPERTIES: "true"
      ENABLE_WHITELIST: "${ENABLE_WHITELIST}"

      # --- Remote console -----------------------------------------------
      ENABLE_RCON: "true"
      RCON_PASSWORD: "${RCON_PASSWORD}"
      RCON_PORT: "25575"

      # --- Plugins ------------------------------------------------------
      # The image downloads the Paper build of AuthMeReloaded from Modrinth.
      MODRINTH_PROJECTS: "paper:authmereloaded"
      MODRINTH_DOWNLOAD_DEPENDENCIES: "required"
    volumes:
      - ./data:/data
    healthcheck:
      test: ["CMD", "mc-health"]
      start_period: 3m
      interval: 30s
      retries: 10

  crafty:
    image: registry.gitlab.com/crafty-controller/crafty-4:latest
    container_name: crafty-ecole
    restart: unless-stopped
    environment:
      TZ: "${TZ}"
    ports:
      - "${CRAFTY_PORT}:8443"              # Web panel, HTTPS
      - "${CRAFTY_MC_RANGE}:${CRAFTY_MC_RANGE}"   # Ports for extra servers
    volumes:
      - ./crafty/backups:/crafty/backups
      - ./crafty/logs:/crafty/logs
      - ./crafty/servers:/crafty/servers
      - ./crafty/config:/crafty/app/config
      - ./crafty/import:/crafty/import
      # Read-only view of the main server, for backups and file checks.
      - ./data:/crafty/import/mc-ecole:ro

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer-ecole
    restart: unless-stopped
    ports:
      - "${PORTAINER_PORT}:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data

volumes:
  portainer_data:
YAML
    ok "The file docker-compose.yml is written."
}

# ----------------------------------------------------------------------------
# Step 4 — Write the AuthMe configuration
#   $1 = "true"  : players can use /register (only during the installation)
#        "false" : players cannot register. Only the teacher can.
# ----------------------------------------------------------------------------
write_authme_config() {
    local reg_enabled="$1"
    cat > "$INSTALL_DIR/data/plugins/AuthMe/config.yml" <<EOF
# =============================================================================
#  AuthMeReloaded — login protection for the school server
#  AuthMe adds the keys that are not in this file when it starts.
# =============================================================================

DataSource:
    backend: SQLITE
    caching: true

settings:
    # Language of the in-game messages.
    messagesLanguage: fr

    sessions:
        # A player who reconnects in the next 30 minutes skips the login.
        enabled: true
        timeout: 30

    registration:
        # false = a student cannot make an account. The teacher makes them.
        enabled: $reg_enabled
        force: true

    restrictions:
        # A player who is not logged in cannot move, chat or use items.
        allowMovement: false
        allowedMovementRadius: 0
        allowChat: false
        ProtectInventoryBeforeLogIn: true
        DenyTabCompleteBeforeLogin: true
        hideTablistBeforeLogin: true
        teleportUnAuthedToSpawn: true
        ForceSingleSession: true

        # The server kicks a name that has no account.
        kickNonRegistered: true

        # The player has 90 seconds to type the login command.
        timeout: 90
        maxLoginTry: 5

        # Many students share one LAN. Do not limit by IP address.
        maxRegPerIp: 0
        maxJoinPerIp: 0

        minNicknameLength: 3
        maxNicknameLength: 16
        allowedNicknameCharacters: '[a-zA-Z0-9_]*'

        # These commands work before the login.
        allowCommands:
        - /login
        - /l
        - /register
        - /reg

    security:
        minPasswordLength: 5
        passwordHash: BCRYPT

    unrestrictions:
        UnrestrictedName: []
EOF
    chown -R 1000:1000 "$INSTALL_DIR/data/plugins"
}

# ----------------------------------------------------------------------------
# Step 5 — Make the student accounts
# ----------------------------------------------------------------------------
generate_accounts() {
    local csv="$INSTALL_DIR/secrets/comptes-eleves.csv"
    local slips="$INSTALL_DIR/secrets/comptes-eleves.txt"

    if [ -f "$csv" ]; then
        ok "The account list is already present. The script keeps it."
        return
    fi

    log "Make $ACCOUNT_COUNT accounts."
    printf 'numero,pseudo,motdepasse\n' > "$csv"
    : > "$slips"

    local i user pass
    for i in $(seq 1 "$ACCOUNT_COUNT"); do
        user="$(printf '%s%02d' "$ACCOUNT_PREFIX" "$i")"
        pass="$(random_password)"
        printf '%d,%s,%s\n' "$i" "$user" "$pass" >> "$csv"
        {
            printf -- '---------------------------------------------\n'
            printf -- ' Serveur Minecraft de l ecole\n'
            printf -- ' Pseudo       : %s\n' "$user"
            printf -- ' Mot de passe : %s\n' "$pass"
            printf -- ' Dans le jeu  : /login %s\n' "$pass"
            printf -- '---------------------------------------------\n\n'
        } >> "$slips"
    done

    chmod 600 "$csv" "$slips"
    ok "The accounts are in $csv"
}

# ----------------------------------------------------------------------------
# Step 6 — Start the stack and wait for the server
# ----------------------------------------------------------------------------
start_stack() {
    log "Pull the images. This step can take some minutes."
    (cd "$INSTALL_DIR" && $COMPOSE pull -q) || warn "One image did not pull."
    log "Start the containers."
    (cd "$INSTALL_DIR" && $COMPOSE up -d)
    ok "The containers run."
}

# Send a command to the server console.
# The "< /dev/null" is important. Without it, "docker compose exec -T"
# reads the file that a "while read" loop uses.
rcon() {
    (cd "$INSTALL_DIR" && $COMPOSE exec -T mc rcon-cli "$@" < /dev/null)
}

wait_for_server() {
    log "Wait for the Minecraft server. The first start builds the world."
    local tries=0
    until rcon list >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$tries" -gt 120 ]; then
            die "The server did not start after 20 minutes. Use: mcadmin logs"
        fi
        sleep 10
        printf '.'
    done
    printf '\n'
    ok "The Minecraft server answers."

    log "Wait for the AuthMe plugin."
    tries=0
    until rcon authme version >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$tries" -gt 30 ]; then
            die "AuthMeReloaded did not load. Use: mcadmin logs"
        fi
        sleep 5
    done
    ok "AuthMeReloaded is loaded."
}

# ----------------------------------------------------------------------------
# Step 7 — Put the accounts in the AuthMe database
# ----------------------------------------------------------------------------
register_accounts() {
    local csv="$INSTALL_DIR/secrets/comptes-eleves.csv"
    log "Register the accounts in AuthMe."
    local count=0 user pass
    while IFS=',' read -r _num user pass; do
        [ "$user" = "pseudo" ] && continue
        [ -z "$user" ] && continue
        if rcon authme register "$user" "$pass" >/dev/null 2>&1; then
            count=$((count + 1))
        else
            warn "The account $user was not registered."
        fi
    done < "$csv"
    ok "$count accounts are registered."
}

# ----------------------------------------------------------------------------
# Step 8 — Write the whitelist (second lock, off by default)
# ----------------------------------------------------------------------------
write_whitelist() {
    local csv="$INSTALL_DIR/secrets/comptes-eleves.csv"
    local wl="$INSTALL_DIR/data/whitelist.json"
    log "Write the file whitelist.json."
    local first=1 user uuid
    printf '[\n' > "$wl"
    while IFS=',' read -r _num user _pass; do
        [ "$user" = "pseudo" ] && continue
        [ -z "$user" ] && continue
        uuid="$(offline_uuid "$user")"
        [ "$first" -eq 0 ] && printf ',\n' >> "$wl"
        printf '  { "uuid": "%s", "name": "%s" }' "$uuid" "$user" >> "$wl"
        first=0
    done < "$csv"
    printf '\n]\n' >> "$wl"
    chown 1000:1000 "$wl"
    rcon whitelist reload >/dev/null 2>&1 || true
    ok "The file whitelist.json holds all student names."
}

# ----------------------------------------------------------------------------
# Step 9 — Install the mcadmin command
# ----------------------------------------------------------------------------
install_cli() {
    log "Install the command mcadmin."
    cat > /usr/local/bin/mcadmin <<EOF
#!/usr/bin/env bash
# mcadmin — small tool to manage the school Minecraft stack.
set -Eeuo pipefail
DIR="$INSTALL_DIR"
EOF
    cat >> /usr/local/bin/mcadmin <<'EOF'
cd "$DIR"

usage() {
cat <<'USAGE'
mcadmin — manage the school Minecraft server

  mcadmin start                  Start all containers
  mcadmin stop                   Stop all containers
  mcadmin restart                Restart all containers
  mcadmin status                 Show the state of the containers
  mcadmin logs [service]         Follow the logs (default: mc)
  mcadmin console                Open the Minecraft console (RCON)
  mcadmin cmd "<command>"        Send one command to the server
  mcadmin players                Show the players that are online

  mcadmin accounts               Show the account list
  mcadmin add <pseudo> [pwd]     Make one more account
  mcadmin passwd <pseudo> <pwd>  Change the password of an account
  mcadmin remove <pseudo>        Delete an account

  mcadmin backup                 Make a backup of the world
  mcadmin update                 Pull new images and restart
USAGE
}

rcon() { docker compose exec -T mc rcon-cli "$@" < /dev/null; }
CSV="$DIR/secrets/comptes-eleves.csv"
newpass() {
    local p=""
    p="$(LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789' \
         < /dev/urandom | head -c 10)" || true
    printf '%s\n' "$p"
}

case "${1:-}" in
  start)    docker compose up -d ;;
  stop)     docker compose stop ;;
  restart)  docker compose restart ;;
  status)   docker compose ps ;;
  logs)     docker compose logs -f --tail=200 "${2:-mc}" ;;
  console)  docker compose exec mc rcon-cli ;;
  cmd)      shift; rcon "$@" ;;
  players)  rcon list ;;
  accounts) column -s, -t < "$CSV" 2>/dev/null || cat "$CSV" ;;
  add)
      [ $# -ge 2 ] || { echo "Use: mcadmin add <pseudo> [password]"; exit 1; }
      USER="$2"
      PASS="${3:-$(newpass)}"
      rcon authme register "$USER" "$PASS"
      printf '%s,%s,%s\n' "$(( $(wc -l < "$CSV") ))" "$USER" "$PASS" >> "$CSV"
      echo "Account $USER is made. Password: $PASS"
      ;;
  passwd)
      [ $# -eq 3 ] || { echo "Use: mcadmin passwd <pseudo> <password>"; exit 1; }
      rcon authme password "$2" "$3"
      echo "The password of $2 is changed. Write the new password in $CSV."
      ;;
  remove)
      [ $# -eq 2 ] || { echo "Use: mcadmin remove <pseudo>"; exit 1; }
      rcon authme unregister "$2"
      echo "The account $2 is deleted. Remove the line from $CSV."
      ;;
  backup)
      STAMP="$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$DIR/backups"
      rcon save-off >/dev/null 2>&1 || true
      rcon save-all >/dev/null 2>&1 || true
      sleep 3
      tar -C "$DIR/data" -czf "$DIR/backups/world-$STAMP.tar.gz" \
          world world_nether world_the_end plugins 2>/dev/null || true
      rcon save-on >/dev/null 2>&1 || true
      echo "Backup: $DIR/backups/world-$STAMP.tar.gz"
      ;;
  update)
      docker compose pull
      docker compose up -d
      ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
EOF
    chmod +x /usr/local/bin/mcadmin
    ok "The command mcadmin is ready."
}

# ----------------------------------------------------------------------------
# Step 10 — Optional firewall
# ----------------------------------------------------------------------------
setup_firewall() {
    [ "$SETUP_FIREWALL" = "yes" ] || return 0
    log "Configure the firewall with ufw."
    apt-get install -y -qq ufw
    ufw allow 22/tcp comment 'SSH'
    ufw allow "${MC_PORT}/tcp" comment 'Minecraft'
    ufw allow "${CRAFTY_PORT}/tcp" comment 'Crafty'
    ufw allow "${PORTAINER_PORT}/tcp" comment 'Portainer'
    ufw --force enable
    ok "The firewall is active."
}

# ----------------------------------------------------------------------------
# Final report
# ----------------------------------------------------------------------------
summary() {
    local ip creds
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$ip" ] || ip="<server-ip>"
    creds="$INSTALL_DIR/crafty/config/default-creds.txt"

    cat <<EOF

${C_OK}===============================================================${C_OFF}
 The installation is complete.
${C_OK}===============================================================${C_OFF}

 Minecraft server   : $ip:$MC_PORT     (Paper $MC_VERSION, offline mode)
 Crafty Controller  : https://$ip:$CRAFTY_PORT
 Portainer          : https://$ip:$PORTAINER_PORT

 Student accounts   : $INSTALL_DIR/secrets/comptes-eleves.csv
 Printable slips    : $INSTALL_DIR/secrets/comptes-eleves.txt

 How a student connects:
   1. In Prism Launcher, set the account name to the pseudo, for
      example "${ACCOUNT_PREFIX}01". The name must match exactly.
   2. Join the server. The player cannot move and cannot chat.
   3. In the chat, type:  /login <password>
   4. After the login, the player can play.

 Useful commands:
   mcadmin status         Show the containers
   mcadmin console        Open the server console
   mcadmin accounts       Show the account list
   mcadmin backup         Make a backup of the world
   mcadmin --help         Show all commands

EOF

    if [ -f "$creds" ]; then
        echo " Crafty Controller first login:"
        sed 's/^/   /' "$creds"
        echo
        echo " Change this password at the first login."
        echo
    else
        warn "The Crafty credentials file is not yet written."
        echo "   Look at: $creds"
        echo "   Or use:  docker logs crafty-ecole"
        echo
    fi

    echo " Portainer asks you to make the admin password at the first visit."
    echo " Do this step in the next few minutes, or restart the container."
    echo
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    require_root
    check_debian

    install_docker
    prepare_directories
    write_env
    write_compose

    # Phase 1: /register is on, so the console can make the accounts.
    write_authme_config "true"

    generate_accounts
    start_stack
    wait_for_server
    register_accounts

    # Phase 2: /register is off. Only the teacher can make an account.
    log "Apply the final AuthMe configuration."
    write_authme_config "false"
    rcon authme reload >/dev/null 2>&1 || warn "The AuthMe reload failed."
    ok "The students cannot make their own account."

    write_whitelist
    install_cli
    setup_firewall
    summary
}

main "$@"
