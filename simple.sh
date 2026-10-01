#!/usr/bin/env bash
# =============================================================================
#  minecraft-ecole — simple installer: Docker only
# =============================================================================
#  No Pelican. No Wings. No Portainer. One container, one compose file.
#
#  The script installs and configures:
#    1. Docker CE and the Compose plugin
#    2. A Paper Minecraft server in one container (eclipse-temurin, Java 25)
#    3. EcoleLogin — the plugin of this repository: /login <user> <password>
#    4. 50 student accounts (the script keeps an old list if it finds one)
#    5. mcecole — a command-line tool for the teacher
#
#  The server does not depend on the IP address of the machine:
#    - The game port is published on all the addresses (0.0.0.0).
#    - server.properties has an empty "server-ip".
#    - The console (RCON) is published on 127.0.0.1 only.
#    - No file holds the IP address of the machine.
#  Thus you can change the address (DHCP -> static, or a new LAN) at any time.
#  The server continues to work after a reboot, with no change.
#
#  Run the installation ONE time with internet access. After the
#  installation, the server works on a LAN with no internet.
#
#  Run the script as root, from the folder of the repository:
#      sudo bash simple.sh
#
#  Change a default with an environment variable. Example:
#      sudo MC_MEMORY_MB=6144 ACCOUNT_COUNT=30 bash simple.sh
# =============================================================================

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-/opt/minecraft-simple}"
CONTAINER_NAME="${CONTAINER_NAME:-minecraft}"

MC_VERSION="${MC_VERSION:-26.3}"
MC_PORT="${MC_PORT:-25565}"              # The port on the host, for the clients
RCON_PORT="${RCON_PORT:-25575}"          # On 127.0.0.1 only
MC_MEMORY_MB="${MC_MEMORY_MB:-auto}"     # auto = machine memory - reserve
MEMORY_RESERVE_MB="${MEMORY_RESERVE_MB:-2048}"   # Debian, Docker, Java overhead
MAX_PLAYERS="${MAX_PLAYERS:-60}"
VIEW_DISTANCE="${VIEW_DISTANCE:-8}"
MOTD="${MOTD:-Serveur de l ecole - tapez /login <utilisateur> <mot de passe>}"

ACCOUNT_COUNT="${ACCOUNT_COUNT:-50}"
ACCOUNT_PREFIX="${ACCOUNT_PREFIX:-eleve}"
PASSWORD_LENGTH="${PASSWORD_LENGTH:-10}"

TZ_NAME="${TZ_NAME:-Europe/Brussels}"
RUN_UID="${RUN_UID:-1000}"               # The owner of the server files
RUN_GID="${RUN_GID:-1000}"

# yes = stop the containers and services that use the game port
#       (Pelican Wings, the Pelican game container, the panel, Portainer).
#       The script only stops them. It does not delete data.
STOP_OLD_STACK="${STOP_OLD_STACK:-yes}"
# yes = copy the world of the Pelican server, if this install has no world yet.
IMPORT_PELICAN_WORLD="${IMPORT_PELICAN_WORLD:-yes}"
PELICAN_VOLUMES="${PELICAN_VOLUMES:-/var/lib/pelican/volumes}"
OLD_SECRETS="${OLD_SECRETS:-/opt/minecraft-ecole/secrets}"

# yes = download the newest Paper build, also if paper.jar is present.
UPDATE_PAPER="${UPDATE_PAPER:-no}"
PAPER_JAR_URL="${PAPER_JAR_URL:-}"       # Empty = ask the PaperMC API

JAVA_IMAGE="${JAVA_IMAGE:-eclipse-temurin:25-jre}"
MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3-eclipse-temurin-25}"
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-no}"

PASSWORD_ALPHABET='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
USER_AGENT="minecraft-ecole/1.0 (school server installer)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DATA="$INSTALL_DIR/data"
SECRETS="$INSTALL_DIR/secrets"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
C_OK=$'\033[1;32m'; C_INFO=$'\033[1;36m'; C_WARN=$'\033[1;33m'
C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'

log()  { printf '%s[ %s ]%s %s\n' "$C_INFO" "$(date +%H:%M:%S)" "$C_OFF" "$*"; }
ok()   { printf '%s  OK %s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s  !! %s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s ERR %s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

trap 'die "The script stopped at line $LINENO."' ERR

random_password() {
    local p=""
    p="$(LC_ALL=C tr -dc "$PASSWORD_ALPHABET" < /dev/urandom \
         | head -c "$PASSWORD_LENGTH")" || true
    printf '%s\n' "$p"
}

random_secret() {
    local n="${1:-32}" s=""
    s="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$n")" || true
    printf '%s\n' "$s"
}

set_prop() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

current_ips() {
    ip -4 -o addr show scope global 2>/dev/null \
        | awk '$2 !~ /^(docker|br-|veth|pelican)/ {split($4, a, "/"); print a[1]}'
}

# ----------------------------------------------------------------------------
# Step 1 — Checks
# ----------------------------------------------------------------------------
require_root() {
    [ "$(id -u)" -eq 0 ] || die "Run this script as root. Use: sudo bash $0"
}

check_system() {
    [ -r /etc/os-release ] || die "The file /etc/os-release is not present."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *debian*) ok "The system is ${PRETTY_NAME:-unknown}." ;;
        *) warn "This script is made for Debian. The system is ${PRETTY_NAME:-unknown}." ;;
    esac
    [ -d "$SCRIPT_DIR/plugin" ] || \
        die "The folder plugin/ is not next to simple.sh. Clone the full repository."
}

check_internet() {
    log "Make sure that the machine has internet access."
    if ! curl -fsS -m 10 -o /dev/null -A "$USER_AGENT" https://fill.papermc.io/v3/projects/paper; then
        die "No internet access. Connect the server to a LAN with internet for the installation."
    fi
    ok "The machine has internet access."
}

# ----------------------------------------------------------------------------
# Step 2 — Docker
# ----------------------------------------------------------------------------
install_tools() {
    log "Install the small tools that the script needs."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl python3 iproute2 >/dev/null
    ok "The tools are present."
}

install_docker() {
    if [ "$SKIP_DOCKER_INSTALL" = "yes" ]; then
        ok "The Docker installation is disabled."
        return
    fi
    if docker compose version >/dev/null 2>&1; then
        ok "Docker and the Compose plugin are already present."
        systemctl enable --now docker >/dev/null 2>&1 || true
        return
    fi

    log "Add the official Docker repository."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091
    . /etc/os-release
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] %s %s stable\n' \
        "$(dpkg --print-architecture)" "https://download.docker.com/linux/debian" \
        "${VERSION_CODENAME}" > /etc/apt/sources.list.d/docker.list

    log "Install Docker CE."
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin >/dev/null
    # Docker must start at boot. It does not need the network to start.
    systemctl enable --now docker
    ok "Docker is installed. Version: $(docker --version)"
}

# ----------------------------------------------------------------------------
# Step 3 — Stop the old stack (Pelican, Portainer). No data is deleted.
# ----------------------------------------------------------------------------
stop_container_for_good() {
    local id="$1" name
    name="$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's|^/||')" || name="$id"
    [ "$name" = "$CONTAINER_NAME" ] && return 0
    docker update --restart=no "$id" >/dev/null 2>&1 || true
    docker stop "$id" >/dev/null 2>&1 || true
    ok "Stopped the container $name (restart policy: no)."
}

stop_old_stack() {
    if [ "$STOP_OLD_STACK" != "yes" ]; then
        ok "The old stack stays as it is (STOP_OLD_STACK=no)."
        return
    fi

    # Wings restarts its game containers. Stop Wings first.
    if systemctl is-active --quiet wings 2>/dev/null \
       || systemctl is-enabled --quiet wings 2>/dev/null; then
        log "Stop and disable Pelican Wings."
        systemctl disable --now wings >/dev/null 2>&1 || true
        ok "Wings is stopped. Start it again with: systemctl enable --now wings"
    fi

    local id
    # The containers that publish the game port or the RCON port.
    for id in $(docker ps -q --filter "publish=${MC_PORT}") \
              $(docker ps -q --filter "publish=${RCON_PORT}"); do
        stop_container_for_good "$id"
    done
    # The panel and Portainer.
    for id in $(docker ps -q --filter "name=^pelican-panel$") \
              $(docker ps -q --filter "name=^portainer$"); do
        stop_container_for_good "$id"
    done

    # On a second run, our own container uses the port. This is correct.
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
        ok "The port ${MC_PORT} belongs to the container $CONTAINER_NAME."
        return
    fi
    if ss -Hltn "( sport = :${MC_PORT} )" 2>/dev/null | grep -q .; then
        ss -ltnp "( sport = :${MC_PORT} )" >&2 || true
        die "A program still uses the port ${MC_PORT}. Stop it, or set MC_PORT."
    fi
    ok "The port ${MC_PORT} is free."
}

# ----------------------------------------------------------------------------
# Step 4 — Folders, Paper, plugin, world
# ----------------------------------------------------------------------------
prepare_directories() {
    log "Make the directory $INSTALL_DIR."
    mkdir -p "$DATA/plugins/EcoleLogin" "$SECRETS" "$INSTALL_DIR/bin" "$INSTALL_DIR/backups"
    chmod 700 "$SECRETS"
}

download_paper() {
    local jar="$DATA/paper.jar"
    if [ -f "$jar" ] && [ "$UPDATE_PAPER" != "yes" ]; then
        ok "paper.jar is already present. Set UPDATE_PAPER=yes to update it."
        return
    fi

    local url="$PAPER_JAR_URL" sha=""
    if [ -z "$url" ]; then
        log "Ask the PaperMC API for the newest build of Paper $MC_VERSION."
        local api="https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}/builds/latest"
        local json
        json="$(curl -fsSL -A "$USER_AGENT" "$api")" || \
            die "The PaperMC API does not know the version $MC_VERSION. Set MC_VERSION."
        local parsed
        parsed="$(printf '%s' "$json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if isinstance(d, list):           # a list of builds: take the newest
    d = max(d, key=lambda b: b.get("id", 0))
dl = d["downloads"]["server:default"]
print(dl["url"], dl.get("checksums", {}).get("sha256", ""))
' 2>/dev/null)" || die "The PaperMC answer is not known. Set PAPER_JAR_URL to the URL of the jar."
        url="${parsed%% *}"
        sha="${parsed#* }"
    fi

    log "Download Paper."
    curl -fsSL -A "$USER_AGENT" -o "$jar.part" "$url" || die "The download of Paper failed."
    if [ -n "$sha" ]; then
        echo "$sha  $jar.part" | sha256sum -c --quiet - || die "The checksum of paper.jar is wrong."
    fi
    mv "$jar.part" "$jar"
    ok "Paper is in $jar ($(basename "$url"))."
}

build_plugin() {
    log "Download the Maven image."
    docker pull -q "$MAVEN_IMAGE" >/dev/null

    log "Build the EcoleLogin plugin for Minecraft $MC_VERSION."
    rm -rf "$INSTALL_DIR/plugin-src"
    cp -a "$SCRIPT_DIR/plugin" "$INSTALL_DIR/plugin-src"
    mkdir -p "$INSTALL_DIR/.m2"

    # Up to 1.21.x the API version is "<mc>-R0.1-SNAPSHOT".
    # From 26.1 it is "<mc>.build.<n>-<channel>": use a Maven range.
    local api_version
    case "$MC_VERSION" in
        1.*) api_version="${MC_VERSION}-R0.1-SNAPSHOT" ;;
        *)   local head="${MC_VERSION%.*}" last="${MC_VERSION##*.}"
             api_version="[${MC_VERSION}.build,${head}.$((last + 1)))" ;;
    esac
    sed -i "s|<paper.version>.*</paper.version>|<paper.version>${api_version}</paper.version>|" \
        "$INSTALL_DIR/plugin-src/pom.xml"

    if ! docker run --rm \
            -v "$INSTALL_DIR/plugin-src":/work -w /work \
            -v "$INSTALL_DIR/.m2":/root/.m2 \
            "$MAVEN_IMAGE" mvn -B -q -DskipTests package \
            > "$INSTALL_DIR/build.log" 2>&1; then
        tail -30 "$INSTALL_DIR/build.log" >&2
        die "The plugin did not build. The log is in $INSTALL_DIR/build.log"
    fi
    cp "$INSTALL_DIR/plugin-src/target/ecole-login.jar" "$DATA/plugins/ecole-login.jar"
    ok "The plugin is in $DATA/plugins/ecole-login.jar"
}

import_pelican_world() {
    [ "$IMPORT_PELICAN_WORLD" = "yes" ] || return 0
    [ -d "$PELICAN_VOLUMES" ] || return 0

    local level
    level="$(awk -F= '$1 == "level-name" {print $2}' "$DATA/server.properties" 2>/dev/null)"
    level="${level:-world}"
    if [ -d "$DATA/$level" ]; then
        ok "This install already has a world. The script does not import a world."
        return
    fi

    # Use the Pelican server folder that has a server.properties file.
    local src="" dir
    for dir in "$PELICAN_VOLUMES"/*/; do
        [ -f "$dir/server.properties" ] && { src="${dir%/}"; break; }
    done
    [ -n "$src" ] || return 0

    local old_level
    old_level="$(awk -F= '$1 == "level-name" {print $2}' "$src/server.properties")"
    old_level="${old_level:-world}"
    [ -d "$src/$old_level" ] || return 0

    log "Copy the world of the Pelican server ($src)."
    local w
    for w in "$src/$old_level" "$src/${old_level}"_*; do
        [ -d "$w" ] || continue
        cp -a "$w" "$DATA/$(basename "$w" | sed "s|^${old_level}|${level}|")"
    done
    for f in ops.json banned-players.json banned-ips.json whitelist.json; do
        [ -f "$src/$f" ] && [ ! -f "$DATA/$f" ] && cp -a "$src/$f" "$DATA/$f"
    done
    ok "The world is copied. The original stays in $src."
}

write_server_properties() {
    log "Write server.properties."
    local props="$DATA/server.properties"
    touch "$props"

    RCON_PASSWORD=""
    if [ -f "$SECRETS/rcon.env" ]; then
        RCON_PASSWORD="$(awk -F= '$1 == "RCON_PASSWORD" {print $2}' "$SECRETS/rcon.env")"
    fi
    [ -n "$RCON_PASSWORD" ] || RCON_PASSWORD="$(random_secret 24)"

    # server-ip MUST stay empty: the server then listens on all the
    # addresses of the container, and the IP of the host has no effect.
    set_prop "$props" server-ip ""
    set_prop "$props" server-port 25565
    set_prop "$props" online-mode false
    set_prop "$props" enforce-secure-profile false
    set_prop "$props" prevent-proxy-connections false
    set_prop "$props" enable-rcon true
    set_prop "$props" "rcon.port" 25575
    set_prop "$props" "rcon.password" "$RCON_PASSWORD"
    set_prop "$props" broadcast-rcon-to-ops false
    set_prop "$props" enable-query false
    set_prop "$props" white-list false
    set_prop "$props" max-players "$MAX_PLAYERS"
    set_prop "$props" view-distance "$VIEW_DISTANCE"
    set_prop "$props" difficulty normal
    set_prop "$props" spawn-protection 0
    set_prop "$props" motd "$MOTD"
    printf 'eula=true\n' > "$DATA/eula.txt"

    printf 'RCON_PORT=%s\nRCON_PASSWORD=%s\n' "$RCON_PORT" "$RCON_PASSWORD" > "$SECRETS/rcon.env"
    chmod 600 "$SECRETS/rcon.env"
    ok "Offline mode, empty server-ip, RCON on 127.0.0.1:${RCON_PORT}."
}

# ----------------------------------------------------------------------------
# Step 5 — Accounts
# ----------------------------------------------------------------------------
generate_accounts() {
    local csv="$SECRETS/comptes-eleves.csv"
    local slips="$SECRETS/comptes-eleves.txt"

    if [ -f "$csv" ]; then
        ok "The account list is already present. The script keeps it."
        return
    fi
    if [ -f "$OLD_SECRETS/comptes-eleves.csv" ]; then
        cp -a "$OLD_SECRETS/comptes-eleves.csv" "$csv"
        [ -f "$OLD_SECRETS/comptes-eleves.txt" ] && cp -a "$OLD_SECRETS/comptes-eleves.txt" "$slips"
        ok "The accounts of the Pelican install are kept. The students keep their passwords."
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
            printf -- ' Utilisateur  : %s\n' "$user"
            printf -- ' Mot de passe : %s\n' "$pass"
            printf -- ' Dans le jeu  : /login %s %s\n' "$user" "$pass"
            printf -- '---------------------------------------------\n\n'
        } >> "$slips"
    done
    chmod 600 "$csv" "$slips"
    ok "The accounts are in $csv"
}

# ----------------------------------------------------------------------------
# Step 6 — Compose file
# ----------------------------------------------------------------------------
compute_memory() {
    if [ "$MC_MEMORY_MB" = "auto" ]; then
        local total
        total="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
        MC_MEMORY_MB=$(( total - MEMORY_RESERVE_MB ))
    fi
    case "$MC_MEMORY_MB" in ''|*[!0-9]*) die "MC_MEMORY_MB must be a number or \"auto\"." ;; esac
    [ "$MC_MEMORY_MB" -ge 1024 ] || die "Only ${MC_MEMORY_MB} MB for Java. Give the machine more memory."
    ok "Java gets ${MC_MEMORY_MB} MB of memory."
}

write_compose() {
    log "Write docker-compose.yml."
    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
# minecraft-ecole — simple stack. Made by simple.sh.
#
# IMPORTANT: no line in this file holds the IP address of the machine.
# Thus a change of the IP address has no effect on the server.
#   "${MC_PORT}:25565"            = all the addresses of the host
#   "127.0.0.1:${RCON_PORT}:25575" = the console, only from the server itself
services:
  minecraft:
    image: ${JAVA_IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    user: "${RUN_UID}:${RUN_GID}"
    working_dir: /data
    environment:
      TZ: "${TZ_NAME}"
      HOME: /data
    command:
      - java
      - -Xms${MC_MEMORY_MB}M
      - -Xmx${MC_MEMORY_MB}M
      - -XX:+UseG1GC
      - -XX:+ParallelRefProcEnabled
      - -XX:MaxGCPauseMillis=200
      - -XX:+UnlockExperimentalVMOptions
      - -XX:+DisableExplicitGC
      - -XX:+AlwaysPreTouch
      - -XX:G1HeapRegionSize=8M
      - -Dfile.encoding=UTF-8
      - -jar
      - paper.jar
      - --nogui
    volumes:
      - ./data:/data
    ports:
      - "${MC_PORT}:25565"
      - "127.0.0.1:${RCON_PORT}:25575"
    stdin_open: true
    tty: true
    stop_grace_period: 90s
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
EOF
    ok "The compose file is in $INSTALL_DIR/docker-compose.yml"
}

# ----------------------------------------------------------------------------
# Step 7 — Tools: rcon.py and mcecole
# ----------------------------------------------------------------------------
write_rcon_client() {
    cat > "$INSTALL_DIR/bin/rcon.py" <<'EOF'
#!/usr/bin/env python3
"""A small RCON client. Standard library only.

Usage:
    rcon.py <host> <port> <password> "<command>"
"""
import socket
import struct
import sys


def pack(pid, ptype, body):
    payload = struct.pack("<ii", pid, ptype) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def recv_exact(sock, size):
    buf = b""
    while len(buf) < size:
        chunk = sock.recv(size - len(buf))
        if not chunk:
            raise ConnectionError("the server closed the connection")
        buf += chunk
    return buf


def recv_packet(sock):
    length = struct.unpack("<i", recv_exact(sock, 4))[0]
    data = recv_exact(sock, length)
    pid, ptype = struct.unpack("<ii", data[:8])
    return pid, ptype, data[8:-2].decode("utf-8", "replace")


def main():
    if len(sys.argv) < 5:
        print(__doc__, file=sys.stderr)
        return 2
    host, port, password = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    command = " ".join(sys.argv[4:])
    with socket.create_connection((host, port), timeout=10) as sock:
        sock.sendall(pack(1, 3, password))
        pid, _, _ = recv_packet(sock)
        if pid == -1:
            print("RCON: the password is wrong.", file=sys.stderr)
            return 1
        sock.sendall(pack(2, 2, command))
        _, _, body = recv_packet(sock)
        if body.strip():
            print(body.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF
    chmod 755 "$INSTALL_DIR/bin/rcon.py"
}

install_cli() {
    log "Install the command mcecole."
    cat > /usr/local/bin/mcecole <<EOF
#!/usr/bin/env bash
# mcecole — manage the simple school Minecraft server (Docker only).
set -Eeuo pipefail
DIR="$INSTALL_DIR"
CONTAINER="$CONTAINER_NAME"
RUN_OWNER="${RUN_UID}:${RUN_GID}"
MC_PORT="$MC_PORT"
EOF
    cat >> /usr/local/bin/mcecole <<'EOF'
DATA="$DIR/data"
CSV="$DIR/secrets/comptes-eleves.csv"
RCON="$DIR/bin/rcon.py"
ALPHA='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'

usage() {
cat <<'USAGE'
mcecole — manage the school Minecraft server

  mcecole status              State of the container and of the server
  mcecole start | stop | restart
  mcecole logs                Follow the log (Ctrl+C to quit)
  mcecole console             Open the live console (Ctrl+P then Ctrl+Q to quit)
  mcecole cmd <command>       Send one command, e.g.: mcecole cmd list
  mcecole ip                  Show the addresses that the students can use
  mcecole accounts            Show the accounts and the passwords
  mcecole newpass <user>      Give a new password to one account
  mcecole add <user>          Add one account
  mcecole sync                Rebuild accounts.yml from the CSV and reload
  mcecole backup              Make a backup of the server folder
USAGE
}

need_root() { [ "$(id -u)" -eq 0 ] || { echo "Use: sudo mcecole $*" >&2; exit 1; }; }
dc() { (cd "$DIR" && docker compose "$@"); }

rcon_run() {
    # shellcheck disable=SC1091
    . "$DIR/secrets/rcon.env"
    "$RCON" 127.0.0.1 "$RCON_PORT" "$RCON_PASSWORD" "$@"
}

newpass() {
    local p=""
    p="$(LC_ALL=C tr -dc "$ALPHA" < /dev/urandom | head -c 10)" || true
    printf '%s\n' "$p"
}

salt16() {
    local s=""
    s="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)" || true
    printf '%s\n' "$s"
}

# Write plugins/EcoleLogin/accounts.yml: a salt and a SHA-256, no password.
write_accounts() {
    local out="$DATA/plugins/EcoleLogin/accounts.yml" _num user pass salt hash
    mkdir -p "$DATA/plugins/EcoleLogin"
    {
        printf '# Accounts of the class. Rebuilt by "mcecole sync".\n\n'
        while IFS=, read -r _num user pass; do
            [ "$user" = "pseudo" ] && continue
            [ -z "$user" ] && continue
            pass="${pass%$'\r'}"
            salt="$(salt16)"
            hash="$(printf '%s%s' "$salt" "$pass" | sha256sum | awk '{print $1}')"
            printf '%s:\n  salt: "%s"\n  hash: "%s"\n' "$user" "$salt" "$hash"
        done < "$CSV"
    } > "$out"
    chmod 600 "$out"
    chown "$RUN_OWNER" "$out"
}

sync_accounts() {
    write_accounts
    if rcon_run ecolelogin reload 2>/dev/null; then :; else
        echo "The server is stopped. The accounts load at the next start."
    fi
}

case "${1:-}" in
    status)
        dc ps
        if rcon_run list 2>/dev/null; then echo "The server answers."; \
        else echo "The server does not answer (it is stopped or it starts)."; fi ;;
    start)   need_root "$@"; dc up -d ;;
    stop)    need_root "$@"; dc stop ;;
    restart) need_root "$@"; dc restart ;;
    logs)    dc logs -f --tail 100 ;;
    console) echo "Ctrl+P then Ctrl+Q to quit. Do NOT use Ctrl+C: it stops the server."
             docker attach "$CONTAINER" ;;
    cmd)     shift; [ $# -gt 0 ] || { usage; exit 1; }; need_root; rcon_run "$@" ;;
    ip)
        echo "The students connect to one of these addresses, port $MC_PORT:"
        ip -4 -o addr show scope global \
            | awk '$2 !~ /^(docker|br-|veth|pelican)/ {split($4,a,"/"); print "   " a[1] ":'"$MC_PORT"'   (" $2 ")"}' ;;
    accounts) need_root "$@"; column -t -s, "$CSV" 2>/dev/null || cat "$CSV" ;;
    newpass)
        need_root "$@"; user="${2:-}"; [ -n "$user" ] || { usage; exit 1; }
        grep -q "^[0-9]*,${user}," "$CSV" || { echo "The account $user is not known." >&2; exit 1; }
        pass="$(newpass)"
        awk -F, -v OFS=, -v u="$user" -v p="$pass" '$2 == u {$3 = p} {print}' "$CSV" > "$CSV.tmp"
        mv "$CSV.tmp" "$CSV"; chmod 600 "$CSV"
        sync_accounts
        echo "New password for $user: $pass" ;;
    add)
        need_root "$@"; user="${2:-}"; [ -n "$user" ] || { usage; exit 1; }
        grep -q "^[0-9]*,${user}," "$CSV" && { echo "The account $user already exists." >&2; exit 1; }
        num="$(awk -F, 'NR > 1 && $1 > m {m = $1} END {print m + 1}' "$CSV")"
        pass="$(newpass)"
        printf '%s,%s,%s\n' "$num" "$user" "$pass" >> "$CSV"
        sync_accounts
        echo "New account: $user  password: $pass" ;;
    sync)    need_root "$@"; sync_accounts; echo "The accounts are loaded." ;;
    backup)
        need_root "$@"
        out="$DIR/backups/minecraft-$(date +%Y%m%d-%H%M%S).tar.gz"
        rcon_run save-off >/dev/null 2>&1 || true
        rcon_run save-all flush >/dev/null 2>&1 || true
        sleep 3
        tar -czf "$out" -C "$DIR" data secrets || true
        rcon_run save-on >/dev/null 2>&1 || true
        echo "Backup: $out" ;;
    *) usage ;;
esac
EOF
    chmod 755 /usr/local/bin/mcecole
    ok "The command mcecole is installed. Type: mcecole"
}

# ----------------------------------------------------------------------------
# Step 8 — Start
# ----------------------------------------------------------------------------
start_server() {
    chown -R "${RUN_UID}:${RUN_GID}" "$DATA"
    log "Download the Java image."
    docker pull -q "$JAVA_IMAGE" >/dev/null
    log "Start the Minecraft server."
    (cd "$INSTALL_DIR" && docker compose up -d --force-recreate)
}

wait_for_server() {
    log "Wait for the server. The first start downloads files from Mojang (some minutes)."
    local tries=0
    until "$INSTALL_DIR/bin/rcon.py" 127.0.0.1 "$RCON_PORT" "$RCON_PASSWORD" list >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" != "true" ]; then
            docker logs --tail 40 "$CONTAINER_NAME" >&2 || true
            die "The container stopped. Look at the log above."
        fi
        [ "$tries" -le 120 ] || die "The server did not answer in 10 minutes. Use: mcecole logs"
        sleep 5
        printf '.'
    done
    printf '\n'
    ok "The Minecraft server answers."
}

load_accounts() {
    /usr/local/bin/mcecole sync >/dev/null
    local count
    count="$(grep -c '^  hash:' "$DATA/plugins/EcoleLogin/accounts.yml" || true)"
    [ "$count" -gt 0 ] || die "The file accounts.yml is empty."
    ok "$count accounts are ready for the login."
}

summary() {
    printf '\n%s=============================================================%s\n' "$C_OK" "$C_OFF"
    printf ' The Minecraft server runs.\n\n'
    printf ' Addresses for the students (port %s):\n' "$MC_PORT"
    current_ips | sed "s|^|    |; s|$|:${MC_PORT}|"
    printf '\n These addresses are not in any configuration file.\n'
    printf ' You can change the IP of the machine. The server needs no change.\n\n'
    printf ' Accounts : %s\n' "$SECRETS/comptes-eleves.csv"
    printf ' Slips    : %s\n' "$SECRETS/comptes-eleves.txt"
    printf ' Files    : %s\n' "$DATA"
    printf ' Command  : mcecole\n'
    printf '%s=============================================================%s\n\n' "$C_OK" "$C_OFF"
}

main() {
    require_root
    check_system
    install_tools
    check_internet
    install_docker
    stop_old_stack
    prepare_directories
    download_paper
    build_plugin
    import_pelican_world
    write_server_properties
    generate_accounts
    compute_memory
    write_compose
    write_rcon_client
    install_cli
    /usr/local/bin/mcecole sync >/dev/null 2>&1 || true   # accounts.yml before the start
    start_server
    wait_for_server
    load_accounts
    summary
}

main "$@"
