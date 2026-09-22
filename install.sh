#!/usr/bin/env bash
# =============================================================================
#  minecraft-ecole — fully automated installer for a school game server
# =============================================================================
#  One command. No step in a browser.
#
#  The script installs and configures:
#    1. Docker CE and the Compose plugin
#    2. Pelican Panel      — the web panel (the active fork of Pterodactyl)
#    3. Pelican Wings      — the daemon that runs each game server
#    4. Portainer CE       — a web panel for the containers
#    5. A Paper Minecraft server, in offline mode, made through the panel
#    6. EcoleLogin — a plugin: one command /login <user> <password>
#    7. 50 student accounts, ready for the login
#    8. mcadmin            — a command-line tool for the teacher
#
#  Run the script as root:
#      sudo bash install.sh
#
#  Change a default with an environment variable. Example:
#      sudo ACCOUNT_COUNT=30 MC_MEMORY_MB=6144 bash install.sh
# =============================================================================

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-/opt/minecraft-ecole}"

SERVER_IP="${SERVER_IP:-}"              # Empty = the first address of the host
PANEL_HTTP_PORT="${PANEL_HTTP_PORT:-80}"
PANEL_HTTPS_PORT="${PANEL_HTTPS_PORT:-443}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@ecole.local}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"

WINGS_PORT="${WINGS_PORT:-8080}"
WINGS_SFTP_PORT="${WINGS_SFTP_PORT:-2022}"
WINGS_DATA="${WINGS_DATA:-/var/lib/pelican/volumes}"

MC_PORT="${MC_PORT:-25565}"
RCON_PORT="${RCON_PORT:-25575}"
MC_VERSION="${MC_VERSION:-1.21.11}"
MC_MEMORY_MB="${MC_MEMORY_MB:-4096}"
MC_DISK_MB="${MC_DISK_MB:-15360}"
MC_SERVER_NAME="${MC_SERVER_NAME:-Serveur ecole}"
MC_JAVA_IMAGE="${MC_JAVA_IMAGE:-ghcr.io/pelican-eggs/yolks:java_25}"

NODE_MEMORY_MB="${NODE_MEMORY_MB:-0}"   # 0 = take it from the machine
NODE_DISK_MB="${NODE_DISK_MB:-0}"       # 0 = take it from the machine

PORTAINER_PORT="${PORTAINER_PORT:-9443}"
INSTALL_PORTAINER="${INSTALL_PORTAINER:-yes}"

ACCOUNT_COUNT="${ACCOUNT_COUNT:-50}"
ACCOUNT_PREFIX="${ACCOUNT_PREFIX:-eleve}"
PASSWORD_LENGTH="${PASSWORD_LENGTH:-10}"

TZ_NAME="${TZ_NAME:-Europe/Brussels}"
SETUP_FIREWALL="${SETUP_FIREWALL:-no}"
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-no}"
REMOVE_OLD_STACK="${REMOVE_OLD_STACK:-yes}"

PASSWORD_ALPHABET='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'

# Pelican moved its images and its repository to the "pelican" namespace.
# The old name "pelican-dev" gives "error from registry: denied".
PANEL_IMAGE="${PANEL_IMAGE:-ghcr.io/pelican/panel:latest}"
PORTAINER_IMAGE="${PORTAINER_IMAGE:-portainer/portainer-ce:latest}"
MAVEN_IMAGE="${MAVEN_IMAGE:-maven:3-eclipse-temurin-21}"
WINGS_URL_BASE="https://github.com/pelican/wings/releases/latest/download"

# The folder that holds this script. The plugin source is next to it.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PAPER_EGG_URL="${PAPER_EGG_URL:-https://raw.githubusercontent.com/pelican-eggs/minecraft/refs/heads/main/java/paper/egg-paper.yaml}"

PANEL_CONTAINER="pelican-panel"
BOOT="/pelican-data/school-bootstrap.php"

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

detect_ip() {
    [ -n "$SERVER_IP" ] && return 0
    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')" || true
    [ -n "$SERVER_IP" ] || SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -n "$SERVER_IP" ] || die "The IP address of the server is not known. Set SERVER_IP."
    case "$SERVER_IP" in
        127.*|localhost|0.0.0.0) die "The panel needs a LAN address. Set SERVER_IP." ;;
    esac
    ok "The address of the server is $SERVER_IP."
}

detect_resources() {
    if [ "$NODE_MEMORY_MB" -eq 0 ]; then
        NODE_MEMORY_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    fi
    if [ "$NODE_DISK_MB" -eq 0 ]; then
        NODE_DISK_MB="$(df -Pm /var/lib | awk 'NR==2 {print $2}')"
    fi
    ok "The node offers ${NODE_MEMORY_MB} MB of memory and ${NODE_DISK_MB} MB of disk."
}

# The "|| true" is necessary, because "head" closes the pipe and "tr" stops.
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

# Run a command in the panel container.
pexec() { docker exec -i "$PANEL_CONTAINER" "$@"; }

# Run the bootstrap PHP script in the panel container.
pboot() { docker exec -i "$PANEL_CONTAINER" php "$BOOT" "$@"; }

# ----------------------------------------------------------------------------
# Step 1 — Docker and the small tools
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

install_tools() {
    log "Install the small tools that the script needs."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl python3 iproute2 >/dev/null
    ok "The tools are present."
}

# ----------------------------------------------------------------------------
# Step 2 — Remove an old stack
# ----------------------------------------------------------------------------
remove_old_stack() {
    local compose="$INSTALL_DIR/docker-compose.yml"
    [ -f "$compose" ] || return 0
    grep -qE 'crafty|itzg/minecraft-server' "$compose" 2>/dev/null || return 0

    [ "$REMOVE_OLD_STACK" = "yes" ] || \
        die "An old stack is in $INSTALL_DIR. Set REMOVE_OLD_STACK=yes to replace it."

    local stamp backup
    stamp="$(date +%Y%m%d-%H%M%S)"
    backup="${INSTALL_DIR}.old-${stamp}"

    log "Stop the old stack."
    (cd "$INSTALL_DIR" && docker compose down) || warn "The old stack did not stop."

    log "Move the old files to $backup."
    mv "$INSTALL_DIR" "$backup"
    mkdir -p "$INSTALL_DIR"
    if [ -d "$backup/secrets" ]; then
        cp -a "$backup/secrets" "$INSTALL_DIR/secrets"
        ok "The account list is kept."
    fi
    warn "The old world stays in $backup. Delete it when you do not need it."
}

# ----------------------------------------------------------------------------
# Step 3 — Directories, .env and compose
# ----------------------------------------------------------------------------
prepare_directories() {
    log "Make the directory $INSTALL_DIR."
    mkdir -p "$INSTALL_DIR"/{secrets,templates,bin}
    chmod 700 "$INSTALL_DIR/secrets"
    ok "The directories are ready."
}

write_env() {
    log "Write the file .env."
    cat > "$INSTALL_DIR/.env" <<EOF
PANEL_URL=http://$SERVER_IP
PANEL_IMAGE=$PANEL_IMAGE
PORTAINER_IMAGE=$PORTAINER_IMAGE
ADMIN_EMAIL=$ADMIN_EMAIL
PANEL_HTTP_PORT=$PANEL_HTTP_PORT
PANEL_HTTPS_PORT=$PANEL_HTTPS_PORT
PORTAINER_PORT=$PORTAINER_PORT
TZ=$TZ_NAME
EOF
    chmod 600 "$INSTALL_DIR/.env"
    ok "The panel URL is http://$SERVER_IP"
}

write_compose() {
    log "Write the file docker-compose.yml."
    cat > "$INSTALL_DIR/docker-compose.yml" <<'YAML_HEAD'
# =============================================================================
#  School game-server stack
#    panel      : Pelican Panel. It makes and controls the game servers.
#    portainer  : a web panel for the Docker containers.
#
#  The game servers are NOT in this file. Pelican Wings makes one container
#  for each server. Wings runs on the host as a systemd service.
# =============================================================================

services:

  panel:
    image: "${PANEL_IMAGE}"
    container_name: pelican-panel
    restart: always
    ports:
      - "${PANEL_HTTP_PORT}:80"
      - "${PANEL_HTTPS_PORT}:443"
    environment:
      XDG_DATA_HOME: /pelican-data
      APP_URL: "${PANEL_URL}"
      ADMIN_EMAIL: "${ADMIN_EMAIL}"
      TZ: "${TZ}"
    volumes:
      - pelican-data:/pelican-data
      - pelican-logs:/var/www/html/storage/logs
YAML_HEAD

    if [ "$INSTALL_PORTAINER" = "yes" ]; then
        cat >> "$INSTALL_DIR/docker-compose.yml" <<'YAML_PORTAINER'

  portainer:
    image: "${PORTAINER_IMAGE}"
    container_name: portainer-ecole
    restart: unless-stopped
    ports:
      - "${PORTAINER_PORT}:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
YAML_PORTAINER
    fi

    cat >> "$INSTALL_DIR/docker-compose.yml" <<'YAML_TAIL'

volumes:
  pelican-data:
  pelican-logs:
YAML_TAIL

    [ "$INSTALL_PORTAINER" = "yes" ] && \
        printf '  portainer_data:\n' >> "$INSTALL_DIR/docker-compose.yml"
    ok "The file docker-compose.yml is written."
}

# ----------------------------------------------------------------------------
# Step 4 — Templates: RCON client and PHP bootstrap
# ----------------------------------------------------------------------------

write_rcon_client() {
    cat > "$INSTALL_DIR/bin/rcon.py" <<'EOF'
#!/usr/bin/env python3
"""A small RCON client. It uses the standard library only.

Usage:
    rcon.py <host> <port> <password> "<command>"
    printf 'cmd1\ncmd2\n' | rcon.py <host> <port> <password>
"""
import socket
import struct
import sys

TYPE_AUTH = 3
TYPE_EXEC = 2


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
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    host, port, password = sys.argv[1], int(sys.argv[2]), sys.argv[3]

    if len(sys.argv) > 4:
        commands = [" ".join(sys.argv[4:])]
    else:
        commands = [line.strip() for line in sys.stdin if line.strip()]

    with socket.create_connection((host, port), timeout=10) as sock:
        sock.sendall(pack(1, TYPE_AUTH, password))
        pid, _, _ = recv_packet(sock)
        if pid == -1:
            print("RCON: the password is wrong.", file=sys.stderr)
            return 1

        failed = 0
        for index, command in enumerate(commands, start=2):
            sock.sendall(pack(index, TYPE_EXEC, command))
            try:
                _, _, body = recv_packet(sock)
            except (ConnectionError, socket.timeout) as error:
                print("RCON: %s" % error, file=sys.stderr)
                failed += 1
                continue
            body = body.strip()
            if body:
                print(body)
        return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
EOF
    chmod +x "$INSTALL_DIR/bin/rcon.py"
}

write_php_bootstrap() {
    cat > "$INSTALL_DIR/bin/school-bootstrap.php" <<'EOF'
<?php
/**
 * school-bootstrap.php — headless setup of Pelican Panel.
 *
 * It boots the Laravel application of the panel and uses the panel's own
 * services. It replaces the steps that a person does in the web interface.
 *
 * Usage (inside the panel container):
 *   php school-bootstrap.php node:create   <ip> <memMB> <diskMB> <listen> <sftp> <dataDir>
 *   php school-bootstrap.php node:config   <nodeId>
 *   php school-bootstrap.php egg:paper     <url>
 *   php school-bootstrap.php alloc:create  <nodeId> <ip> <port> [<port> ...]
 *   php school-bootstrap.php server:create <nodeId> <eggId> <email> <name>
 *                                          <gamePort> <rconPort> <memMB>
 *                                          <diskMB> <mcVersion> <image>
 *   php school-bootstrap.php server:status <uuid>
 *   php school-bootstrap.php server:power  <uuid> <start|stop|restart|kill>
 */

require '/var/www/html/vendor/autoload.php';
$app = require '/var/www/html/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

use App\Models\Allocation;
use App\Models\Egg;
use App\Models\Node;
use App\Models\Server;
use App\Models\User;
use App\Repositories\Daemon\DaemonServerRepository;
use App\Services\Allocations\AssignmentService;
use App\Services\Eggs\Sharing\EggImporterService;
use App\Services\Servers\ServerCreationService;
use Illuminate\Support\Arr;

function fail(string $message): never
{
    fwrite(STDERR, 'ERROR: ' . $message . PHP_EOL);
    exit(1);
}

$command = $argv[1] ?? '';

try {
    switch ($command) {

        case 'node:create':
            [$ip, $memory, $disk, $listen, $sftp, $data] =
                array_slice($argv, 2, 6) + [null, null, null, null, null, null];

            $node = Node::query()->where('fqdn', $ip)->first();
            if (!$node) {
                $node = Node::create([
                    'name' => 'local',
                    'description' => 'Node of the school server',
                    'fqdn' => $ip,
                    'scheme' => 'http',
                    'public' => true,
                    'behind_proxy' => false,
                    'maintenance_mode' => false,
                    'memory' => (int) $memory,
                    'memory_overallocate' => 0,
                    'disk' => (int) $disk,
                    'disk_overallocate' => 0,
                    'cpu' => 0,
                    'cpu_overallocate' => -1,
                    'upload_size' => 256,
                    'daemon_base' => $data,
                    'daemon_listen' => (int) $listen,
                    'daemon_connect' => (int) $listen,
                    'daemon_sftp' => (int) $sftp,
                ]);
            }
            echo $node->id, PHP_EOL;
            break;

        case 'node:config':
            $node = Node::query()->findOrFail((int) $argv[2]);
            echo $node->getYamlConfiguration();
            break;

        case 'egg:paper':
            $egg = Egg::query()->where('name', 'Paper')->first();
            if (!$egg) {
                $egg = app(EggImporterService::class)->fromUrl($argv[2]);
            }
            echo $egg->id, PHP_EOL;
            break;

        case 'alloc:create':
            $node = Node::query()->findOrFail((int) $argv[2]);
            $ip = $argv[3];
            $ports = array_slice($argv, 4);

            $wanted = [];
            foreach ($ports as $port) {
                $exists = Allocation::query()
                    ->where('node_id', $node->id)
                    ->where('ip', $ip)
                    ->where('port', (int) $port)
                    ->exists();
                if (!$exists) {
                    $wanted[] = (string) $port;
                }
            }
            if ($wanted) {
                app(AssignmentService::class)->handle($node, [
                    'allocation_ip' => $ip,
                    'allocation_ports' => $wanted,
                ]);
            }
            foreach ($ports as $port) {
                $allocation = Allocation::query()
                    ->where('node_id', $node->id)
                    ->where('port', (int) $port)
                    ->firstOrFail();
                echo $allocation->id, ' ', $allocation->port, PHP_EOL;
            }
            break;

        case 'server:create':
            [$nodeId, $eggId, $email, $name, $gamePort, $rconPort,
             $memory, $disk, $version, $image] = array_slice($argv, 2, 10);

            $existing = Server::query()->where('name', $name)->first();
            if ($existing) {
                echo $existing->uuid, PHP_EOL;
                break;
            }

            $user = User::query()->where('email', $email)->firstOrFail();
            $egg = Egg::query()->findOrFail((int) $eggId);

            $primary = Allocation::query()
                ->where('node_id', (int) $nodeId)
                ->where('port', (int) $gamePort)
                ->firstOrFail();
            $extra = Allocation::query()
                ->where('node_id', (int) $nodeId)
                ->where('port', (int) $rconPort)
                ->firstOrFail();

            $server = app(ServerCreationService::class)->handle([
                'name' => $name,
                'description' => 'Serveur Minecraft de l ecole',
                'owner_id' => $user->id,
                'node_id' => (int) $nodeId,
                'egg_id' => $egg->id,
                'allocation_id' => $primary->id,
                'allocation_additional' => [$extra->id],
                'memory' => (int) $memory,
                'swap' => 0,
                'disk' => (int) $disk,
                'io' => 500,
                'cpu' => 0,
                'threads' => null,
                'oom_killer' => false,
                'image' => $image,
                'startup' => Arr::first($egg->startup_commands),
                'environment' => [
                    'SERVER_JARFILE' => 'server.jar',
                    'MINECRAFT_VERSION' => $version,
                    'BUILD_NUMBER' => 'latest',
                    'DL_PATH' => '',
                ],
                'start_on_completion' => false,
                'skip_scripts' => false,
                'database_limit' => 0,
                'allocation_limit' => 4,
                'backup_limit' => 5,
            ]);
            echo $server->uuid, PHP_EOL;
            break;

        case 'server:status':
            $server = Server::query()->where('uuid', $argv[2])->firstOrFail();
            echo $server->status?->value ?? 'ready', PHP_EOL;
            break;

        case 'server:power':
            $server = Server::query()->where('uuid', $argv[2])->firstOrFail();
            app(DaemonServerRepository::class)->setServer($server)->power($argv[3]);
            echo 'sent', PHP_EOL;
            break;

        default:
            fail('Unknown command: ' . $command);
    }
} catch (Throwable $error) {
    fail(get_class($error) . ': ' . $error->getMessage());
}
EOF
}

write_templates() {
    log "Write the templates."
    write_rcon_client
    write_php_bootstrap
    ok "The templates are written."
}

# ----------------------------------------------------------------------------
# Step 5 — Start the panel and configure it without a browser
# ----------------------------------------------------------------------------
pull_image() {
    local image="$1" what="$2"
    log "Pull the $what image: $image"
    if docker pull "$image" >/dev/null 2>"$INSTALL_DIR/pull.log"; then
        ok "The $what image is present."
        rm -f "$INSTALL_DIR/pull.log"
        return 0
    fi

    cat >&2 <<EOF

${C_ERR} The image $image did not pull.${C_OFF}

 The message from Docker:
$(sed 's/^/   /' "$INSTALL_DIR/pull.log")

 Look at the three usual causes:

 1. The name changed. Pelican moved from "pelican-dev" to "pelican".
    Test the two names:
      sudo docker pull ghcr.io/pelican/panel:latest
      sudo docker pull ghcr.io/pelican-dev/panel:latest
    If the other name works, run the script again with it:
      sudo PANEL_IMAGE=<the name that works> bash install.sh

 2. The registry is not reachable. A school filter often blocks ghcr.io.
      curl -sSI https://ghcr.io/v2/ | head -1
    Ask the network administrator to allow ghcr.io.

 3. The container has no DNS. Read part 11 of the README.

EOF
    exit 1
}

start_panel() {
    pull_image "$PANEL_IMAGE" "panel"
    [ "$INSTALL_PORTAINER" = "yes" ] && pull_image "$PORTAINER_IMAGE" "Portainer"
    log "Start the panel."
    (cd "$INSTALL_DIR" && docker compose up -d) \
        || die "The containers did not start. Use: docker compose logs"
}

wait_for_panel() {
    log "Wait for the panel."
    local tries=0
    until pexec php artisan --version >/dev/null 2>&1; do
        tries=$((tries + 1))
        [ "$tries" -le 60 ] || die "The panel did not start. Use: mcadmin panel logs"
        sleep 5
        printf '.'
    done
    printf '\n'
    ok "The panel answers."
}

# Set one key in the .env file of the panel, inside the container.
panel_set_env() {
    local key="$1" value="$2"
    pexec sh -c "
        f=/pelican-data/.env
        if grep -q '^${key}=' \"\$f\"; then
            sed -i 's|^${key}=.*|${key}=${value}|' \"\$f\"
        else
            printf '%s=%s\n' '${key}' '${value}' >> \"\$f\"
        fi"
}

configure_panel() {
    log "Configure the panel without the browser."

    panel_set_env APP_URL "http://$SERVER_IP"
    panel_set_env APP_TIMEZONE "$TZ_NAME"
    panel_set_env APP_LOCALE "fr"
    panel_set_env DB_CONNECTION "sqlite"
    # The cache and the session use files, not the database.
    # The panel reads the cache while it starts. With "database", that read
    # happens before the migration makes the "cache" table, and the
    # migration fails with "no such table: cache".
    panel_set_env CACHE_STORE "file"
    panel_set_env SESSION_DRIVER "file"
    panel_set_env QUEUE_CONNECTION "database"
    panel_set_env PANEL_USE_BINARY_PREFIX "true"

    # The school has no mail server. Write the mails to the log, and do not
    # send a mail for a new account or for a new server.
    panel_set_env MAIL_MAILER "log"
    panel_set_env PANEL_SEND_ACCOUNT_CREATED_NOTIFICATION "false"
    panel_set_env PANEL_SEND_INSTALL_NOTIFICATION "false"
    panel_set_env PANEL_SEND_REINSTALL_NOTIFICATION "false"

    # The image makes a symbolic link to this file. It must exist.
    pexec sh -c 'mkdir -p /pelican-data/database && touch /pelican-data/database/database.sqlite'

    log "Run the database migrations. This step takes some minutes."
    # CACHE_STORE and QUEUE_CONNECTION are forced for this one command. Their
    # tables do not exist yet.
    if ! docker exec -i \
            -e CACHE_STORE=file \
            -e SESSION_DRIVER=file \
            -e QUEUE_CONNECTION=sync \
            "$PANEL_CONTAINER" php artisan migrate --seed --force \
            > "$INSTALL_DIR/migrate.log" 2>&1; then
        tail -25 "$INSTALL_DIR/migrate.log" >&2
        cat >&2 <<EOF

 If the database is in a bad state, clean it and start again:
   cd $INSTALL_DIR && sudo docker compose down -v && sudo bash install.sh
 This deletes the panel database only. The account list is kept.

EOF
        die "The migrations failed. The full log is in $INSTALL_DIR/migrate.log"
    fi
    ok "The database is ready."

    # The installer page is now not necessary any more.
    panel_set_env APP_INSTALLED "true"
    ok "The web installer is disabled."
}

create_admin_user() {
    local pw_file="$INSTALL_DIR/secrets/panel-admin.txt"
    if [ -f "$pw_file" ]; then
        ok "The panel administrator is already made."
        return
    fi

    log "Make the panel administrator."
    local pw
    pw="$(random_secret 20)"

    if ! pexec php artisan p:user:make \
            --email="$ADMIN_EMAIL" \
            --username="$ADMIN_USERNAME" \
            --password="$pw" \
            --admin=1 > "$INSTALL_DIR/user.log" 2>&1; then
        tail -20 "$INSTALL_DIR/user.log" >&2
        die "The administrator was not made. The log is in $INSTALL_DIR/user.log"
    fi
    rm -f "$INSTALL_DIR/user.log"

    cat > "$pw_file" <<EOF
Pelican Panel administrator
  URL      : http://$SERVER_IP
  User     : $ADMIN_USERNAME
  Email    : $ADMIN_EMAIL
  Password : $pw
EOF
    chmod 600 "$pw_file"
    ok "The administrator is made. The password is in $pw_file"
}

restart_panel() {
    log "Restart the panel with the new configuration."
    (cd "$INSTALL_DIR" && docker compose restart panel) >/dev/null
    wait_for_panel
}

copy_bootstrap() {
    docker cp "$INSTALL_DIR/bin/school-bootstrap.php" \
        "$PANEL_CONTAINER:$BOOT" >/dev/null
}

# ----------------------------------------------------------------------------
# Step 6 — The node and Wings
# ----------------------------------------------------------------------------
create_node() {
    log "Make the node in the panel."
    NODE_ID="$(pboot node:create "$SERVER_IP" "$NODE_MEMORY_MB" "$NODE_DISK_MB" \
        "$WINGS_PORT" "$WINGS_SFTP_PORT" "$WINGS_DATA" | tail -1)"
    [ -n "$NODE_ID" ] || die "The node was not made."
    ok "The node has the number $NODE_ID."
}

install_wings() {
    log "Install Pelican Wings."
    mkdir -p /etc/pelican /var/run/wings "$WINGS_DATA"

    local arch asset
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  asset="wings_linux_amd64" ;;
        aarch64) asset="wings_linux_arm64" ;;
        *) die "The processor $arch is not supported by Wings." ;;
    esac
    curl -fsSL -o /usr/local/bin/wings "${WINGS_URL_BASE}/${asset}"
    chmod u+x /usr/local/bin/wings

    log "Write /etc/pelican/config.yml from the panel."
    pboot node:config "$NODE_ID" > /etc/pelican/config.yml
    chmod 600 /etc/pelican/config.yml
    grep -q 'token:' /etc/pelican/config.yml || die "The node configuration is empty."

    cat > /etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pelican
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now wings
    ok "Wings runs."
}

wait_for_wings() {
    log "Wait for the daemon."
    local tries=0 code
    while :; do
        code="$(curl -s -o /dev/null -w '%{http_code}' \
            "http://127.0.0.1:${WINGS_PORT}/api/system" || true)"
        # Any answer means that the daemon listens. 401 is normal without a token.
        case "$code" in
            000|"") : ;;
            *) break ;;
        esac
        tries=$((tries + 1))
        [ "$tries" -le 36 ] || die "Wings did not answer. Use: mcadmin wings logs"
        sleep 5
        printf '.'
    done
    printf '\n'
    ok "The daemon answers on port $WINGS_PORT."
}

# ----------------------------------------------------------------------------
# Step 7 — The egg, the ports and the Minecraft server
# ----------------------------------------------------------------------------
import_egg() {
    log "Import the Paper egg."
    local tries=0
    while :; do
        EGG_ID="$(pboot egg:paper "$PAPER_EGG_URL" 2>/dev/null | tail -1)" || true
        case "$EGG_ID" in
            ''|*[!0-9]*) : ;;
            *) break ;;
        esac
        tries=$((tries + 1))
        [ "$tries" -le 5 ] || die "The Paper egg was not imported. Check the network."
        sleep 5
    done
    ok "The Paper egg has the number $EGG_ID."
}

create_allocations() {
    log "Add the ports $MC_PORT and $RCON_PORT."
    pboot alloc:create "$NODE_ID" "$SERVER_IP" "$MC_PORT" "$RCON_PORT" >/dev/null
    ok "The ports are added."
}

create_server() {
    log "Make the Minecraft server. Wings now downloads Paper."
    SERVER_UUID="$(pboot server:create "$NODE_ID" "$EGG_ID" "$ADMIN_EMAIL" \
        "$MC_SERVER_NAME" "$MC_PORT" "$RCON_PORT" "$MC_MEMORY_MB" "$MC_DISK_MB" \
        "$MC_VERSION" "$MC_JAVA_IMAGE" | tail -1)"
    [ -n "$SERVER_UUID" ] || die "The server was not made."
    ok "The server has the identifier $SERVER_UUID."
}

wait_for_install() {
    log "Wait for the installation of the server. This step takes some minutes."
    local tries=0 state
    while :; do
        state="$(pboot server:status "$SERVER_UUID" 2>/dev/null | tail -1)" || true
        case "$state" in
            ready) break ;;
            install_failed|reinstall_failed)
                die "The installation of the server failed. Look at the panel." ;;
        esac
        tries=$((tries + 1))
        [ "$tries" -le 180 ] || die "The installation did not finish."
        sleep 10
        printf '.'
    done
    printf '\n'
    ok "The server is installed."
}

# ----------------------------------------------------------------------------
# Step 8 — The EcoleLogin plugin, offline mode and RCON
# ----------------------------------------------------------------------------

# Build the plugin from the source in the folder plugin/.
build_plugin() {
    local src="$SCRIPT_DIR/plugin"
    [ -d "$src" ] || die "The folder plugin/ is not next to install.sh. Clone the full repository."

    pull_image "$MAVEN_IMAGE" "Maven"

    log "Build the EcoleLogin plugin for Minecraft $MC_VERSION."
    rm -rf "$INSTALL_DIR/plugin-src"
    cp -a "$src" "$INSTALL_DIR/plugin-src"
    mkdir -p "$INSTALL_DIR/.m2"

    # Use the API of the same Minecraft version as the server.
    sed -i "s|<paper.version>.*</paper.version>|<paper.version>${MC_VERSION}-R0.1-SNAPSHOT</paper.version>|" \
        "$INSTALL_DIR/plugin-src/pom.xml"

    if ! docker run --rm \
            -v "$INSTALL_DIR/plugin-src":/work -w /work \
            -v "$INSTALL_DIR/.m2":/root/.m2 \
            "$MAVEN_IMAGE" mvn -B -q -DskipTests package \
            > "$INSTALL_DIR/build.log" 2>&1; then
        tail -30 "$INSTALL_DIR/build.log" >&2
        cat >&2 <<EOF

 The build needs these hosts:
   repo.papermc.io          the Paper API
   repo.maven.apache.org    the Maven tools
 Test them:
   curl -sSI https://repo.papermc.io/repository/maven-public/ | head -1

EOF
        die "The plugin did not build. The log is in $INSTALL_DIR/build.log"
    fi

    PLUGIN_JAR="$INSTALL_DIR/plugin-src/target/ecole-login.jar"
    [ -f "$PLUGIN_JAR" ] || die "The jar is not present after the build."
    ok "The plugin is built: $(basename "$PLUGIN_JAR")"
}

# Write the list of accounts that the plugin reads.
# The file holds a salt and a SHA-256 hash, never a password.
write_accounts_file() {
    local srv="$1"
    local out="$srv/plugins/EcoleLogin/accounts.yml"
    local csv="$INSTALL_DIR/secrets/comptes-eleves.csv"

    mkdir -p "$srv/plugins/EcoleLogin"
    {
        printf '# Accounts of the class.\n'
        printf '# The password is not in this file. Each line holds a salt and\n'
        printf '# the SHA-256 of salt+password. Use "mcadmin sync" to rebuild it\n'
        printf '# from %s\n\n' "$csv"
        local _num user pass salt hash
        while IFS=, read -r _num user pass; do
            [ "$user" = "pseudo" ] && continue
            [ -z "$user" ] && continue
            pass="${pass%$'\r'}"
            salt="$(random_secret 16)"
            hash="$(printf '%s%s' "$salt" "$pass" | sha256sum | awk '{print $1}')"
            printf '%s:\n  salt: "%s"\n  hash: "%s"\n' "$user" "$salt" "$hash"
        done < "$csv"
    } > "$out"
    chmod 600 "$out"
}

set_prop() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

prepare_server_files() {
    local srv="$WINGS_DATA/$SERVER_UUID"
    [ -d "$srv" ] || die "The folder $srv is not present."

    local owner
    owner="$(stat -c '%u:%g' "$srv")"

    log "Install the EcoleLogin plugin."
    mkdir -p "$srv/plugins"
    cp "$PLUGIN_JAR" "$srv/plugins/ecole-login.jar"
    write_accounts_file "$srv"
    ok "The plugin and the accounts are in place."

    log "Set offline mode and the console."
    RCON_PASSWORD="$(random_secret 24)"
    local props="$srv/server.properties"
    touch "$props"
    set_prop "$props" online-mode false
    set_prop "$props" enforce-secure-profile false
    set_prop "$props" enable-rcon true
    set_prop "$props" "rcon.port" "$RCON_PORT"
    set_prop "$props" "rcon.password" "$RCON_PASSWORD"
    set_prop "$props" broadcast-rcon-to-ops false
    set_prop "$props" white-list false
    set_prop "$props" max-players 60
    set_prop "$props" view-distance 8
    set_prop "$props" difficulty normal
    set_prop "$props" spawn-protection 0
    set_prop "$props" motd "Serveur de l ecole - tapez /login <utilisateur> <mot de passe>"

    printf 'eula=true\n' > "$srv/eula.txt"

    chown -R "$owner" "$srv/plugins" "$props" "$srv/eula.txt"

    printf 'RCON_PORT=%s\nRCON_PASSWORD=%s\nSERVER_UUID=%s\n' \
        "$RCON_PORT" "$RCON_PASSWORD" "$SERVER_UUID" \
        > "$INSTALL_DIR/secrets/rcon.env"
    chmod 600 "$INSTALL_DIR/secrets/rcon.env"
    ok "The server accepts unofficial clients and the console."
}

start_server() {
    log "Start the Minecraft server."
    pboot server:power "$SERVER_UUID" start >/dev/null || die "The start failed."
}

wait_for_minecraft() {
    log "Wait for the Minecraft server."
    local tries=0
    until "$INSTALL_DIR/bin/rcon.py" 127.0.0.1 "$RCON_PORT" "$RCON_PASSWORD" list \
          >/dev/null 2>&1; do
        tries=$((tries + 1))
        [ "$tries" -le 120 ] || die "The server did not answer. Look at the panel console."
        sleep 5
        printf '.'
    done
    printf '\n'
    ok "The Minecraft server answers."
}

# ----------------------------------------------------------------------------
# Step 9 — The student accounts
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
            printf -- ' Utilisateur  : %s\n' "$user"
            printf -- ' Mot de passe : %s\n' "$pass"
            printf -- ' Dans le jeu  : /login %s %s\n' "$user" "$pass"
            printf -- '---------------------------------------------\n\n'
        } >> "$slips"
    done
    chmod 600 "$csv" "$slips"
    ok "The accounts are in $csv"
}

verify_accounts() {
    local srv="$WINGS_DATA/$SERVER_UUID"
    local count
    count="$(grep -c '^  hash:' "$srv/plugins/EcoleLogin/accounts.yml" || true)"
    [ "$count" -gt 0 ] || die "The file accounts.yml is empty."
    ok "$count accounts are ready for the login."
}

# ----------------------------------------------------------------------------
# Step 10 — mcadmin
# ----------------------------------------------------------------------------
install_cli() {
    log "Install the command mcadmin."
    cat > /usr/local/bin/mcadmin <<EOF
#!/usr/bin/env bash
# mcadmin — manage the school game-server stack (Pelican Panel + Wings).
set -Eeuo pipefail
DIR="$INSTALL_DIR"
PANEL_CONTAINER="$PANEL_CONTAINER"
BOOT="$BOOT"
WINGS_DATA="$WINGS_DATA"
EOF
    cat >> /usr/local/bin/mcadmin <<'EOF'
CSV="$DIR/secrets/comptes-eleves.csv"
RCONF="$DIR/secrets/rcon.env"
RCON="$DIR/bin/rcon.py"
ALPHA='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'

usage() {
cat <<'USAGE'
mcadmin — manage the school game server

  SERVER
    mcadmin start | stop | restart | kill
    mcadmin console "<command>"     Send one command to the server
    mcadmin players                 Show the players that are online
    mcadmin state                   Show the state of the server

  PANEL AND DAEMON
    mcadmin panel <start|stop|restart|status|logs>
    mcadmin wings <start|stop|restart|status|logs>
    mcadmin admin                   Show the panel administrator account
    mcadmin status                  Show the state of everything

  STUDENT ACCOUNTS
    mcadmin accounts                Show the account list
    mcadmin sync                    Rebuild accounts.yml from the CSV
    mcadmin add <user> [pwd]        Make one more account
    mcadmin passwd <user> <pwd>     Change a password
    mcadmin remove <user>           Delete an account

  FILES
    mcadmin files                   Show the folder of the server
    mcadmin backup                  Make a backup of the server folder
USAGE
}

newpass() {
    local p=""
    p="$(LC_ALL=C tr -dc "$ALPHA" < /dev/urandom | head -c 10)" || true
    printf '%s\n' "$p"
}

load_rcon() {
    [ -f "$RCONF" ] || { echo "The console access is not set." >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$RCONF"
}

rcon_run() { load_rcon; "$RCON" 127.0.0.1 "$RCON_PORT" "$RCON_PASSWORD" "$@"; }
pboot()    { docker exec -i "$PANEL_CONTAINER" php "$BOOT" "$@"; }
power()    { load_rcon; pboot server:power "$SERVER_UUID" "$1"; }

salt16() {
    local s=""
    s="$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 16)" || true
    printf '%s\n' "$s"
}

# Rebuild plugins/EcoleLogin/accounts.yml from the CSV, then tell the plugin
# to read it again. The password is never written in the file.
sync_accounts() {
    load_rcon
    local srv="$WINGS_DATA/$SERVER_UUID"
    local out="$srv/plugins/EcoleLogin/accounts.yml"
    [ -d "$srv" ] || { echo "The server folder is not present." >&2; exit 1; }
    mkdir -p "$srv/plugins/EcoleLogin"

    local owner _num user pass salt hash
    owner="$(stat -c '%u:%g' "$srv")"
    {
        printf '# Accounts of the class. Rebuilt by "mcadmin sync".\n\n'
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
    chown "$owner" "$out" 2>/dev/null || true
    "$RCON" 127.0.0.1 "$RCON_PORT" "$RCON_PASSWORD" ecolelogin reload >/dev/null 2>&1 \
        || echo "The server is stopped. The accounts load at the next start."
}

case "${1:-}" in
  start|stop|restart|kill) power "$1"; echo "The action $1 is sent." ;;
  console) shift; rcon_run "$@" ;;
  players) rcon_run list ;;
  state)   load_rcon; pboot server:status "$SERVER_UUID" ;;

  panel)
      case "${2:-status}" in
        start)   (cd "$DIR" && docker compose up -d panel) ;;
        stop)    (cd "$DIR" && docker compose stop panel) ;;
        restart) (cd "$DIR" && docker compose restart panel) ;;
        status)  (cd "$DIR" && docker compose ps) ;;
        logs)    (cd "$DIR" && docker compose logs -f --tail=200 panel) ;;
        *) echo "Use: mcadmin panel <start|stop|restart|status|logs>"; exit 1 ;;
      esac
      ;;
  wings)
      case "${2:-status}" in
        start)   systemctl start wings ;;
        stop)    systemctl stop wings ;;
        restart) systemctl restart wings ;;
        status)  systemctl status wings --no-pager ;;
        logs)    journalctl -u wings -f -n 200 ;;
        *) echo "Use: mcadmin wings <start|stop|restart|status|logs>"; exit 1 ;;
      esac
      ;;
  admin)  cat "$DIR/secrets/panel-admin.txt" ;;
  status)
      echo "--- containers ---"; (cd "$DIR" && docker compose ps)
      echo; echo "--- wings ---";  systemctl is-active wings || true
      echo; echo "--- server ---"
      if [ -f "$RCONF" ]; then load_rcon; pboot server:status "$SERVER_UUID"; fi
      ;;

  accounts) column -s, -t < "$CSV" 2>/dev/null || cat "$CSV" ;;
  sync)     sync_accounts; echo "The accounts are rebuilt from $CSV." ;;
  add)
      [ $# -ge 2 ] || { echo "Use: mcadmin add <user> [password]"; exit 1; }
      USER="$2"; PASS="${3:-$(newpass)}"
      if awk -F, -v u="$USER" 'NR>1 && $2 == u {found=1} END {exit !found}' "$CSV"; then
          echo "The account $USER is already in the list. Use: mcadmin passwd"; exit 1
      fi
      printf '%s,%s,%s\n' "$(wc -l < "$CSV")" "$USER" "$PASS" >> "$CSV"
      sync_accounts
      echo "Account $USER is made. Password: $PASS"
      ;;
  passwd)
      [ $# -eq 3 ] || { echo "Use: mcadmin passwd <user> <password>"; exit 1; }
      awk -F, -v OFS=, -v u="$2" -v p="$3" \
          'NR==1 || $2 != u {print; next} {$3 = p; print}' "$CSV" > "$CSV.new"
      mv "$CSV.new" "$CSV"; chmod 600 "$CSV"
      sync_accounts
      echo "The password of $2 is changed."
      ;;
  remove)
      [ $# -eq 2 ] || { echo "Use: mcadmin remove <user>"; exit 1; }
      awk -F, -v u="$2" 'NR==1 || $2 != u' "$CSV" > "$CSV.new"
      mv "$CSV.new" "$CSV"; chmod 600 "$CSV"
      sync_accounts
      echo "The account $2 is deleted."
      ;;

  files) load_rcon; echo "$WINGS_DATA/$SERVER_UUID" ;;
  backup)
      load_rcon
      STAMP="$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$DIR/backups"
      rcon_run save-all >/dev/null 2>&1 || true
      sleep 3
      tar -C "$WINGS_DATA" -czf "$DIR/backups/server-$STAMP.tar.gz" "$SERVER_UUID"
      echo "Backup: $DIR/backups/server-$STAMP.tar.gz"
      ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
EOF
    chmod +x /usr/local/bin/mcadmin
    ok "The command mcadmin is ready."
}

# ----------------------------------------------------------------------------
# Step 11 — Firewall
# ----------------------------------------------------------------------------
setup_firewall() {
    [ "$SETUP_FIREWALL" = "yes" ] || return 0
    log "Configure the firewall with ufw."
    apt-get install -y -qq ufw
    ufw allow 22/tcp comment 'SSH'
    ufw allow "${PANEL_HTTP_PORT}/tcp" comment 'Pelican panel'
    ufw allow "${MC_PORT}/tcp" comment 'Minecraft'
    ufw allow "${WINGS_SFTP_PORT}/tcp" comment 'Wings SFTP'
    [ "$INSTALL_PORTAINER" = "yes" ] && \
        ufw allow "${PORTAINER_PORT}/tcp" comment 'Portainer'
    # The daemon port and the RCON port stay closed. They are used on the
    # host only.
    ufw --force enable
    ok "The firewall is active."
}

# ----------------------------------------------------------------------------
# Final report
# ----------------------------------------------------------------------------
summary() {
    cat <<EOF

${C_OK}===============================================================${C_OFF}
 The installation is complete. The server runs.
${C_OK}===============================================================${C_OFF}

 Minecraft server  : $SERVER_IP:$MC_PORT   (Paper $MC_VERSION, offline mode)
 Pelican Panel     : http://$SERVER_IP
 Portainer         : https://$SERVER_IP:$PORTAINER_PORT

 Panel login       : $INSTALL_DIR/secrets/panel-admin.txt
 Student accounts  : $INSTALL_DIR/secrets/comptes-eleves.csv
 Printable slips   : $INSTALL_DIR/secrets/comptes-eleves.txt

 How a student connects:
   1. In Prism Launcher, make an offline account. The name is free,
      but two students cannot use the same name at the same time.
   2. Join $SERVER_IP:$MC_PORT. The player cannot move.
   3. In the chat, type:  /login <user> <password>
      for example:        /login ${ACCOUNT_PREFIX}01 xxxxxxxxxx
   4. After the login, the name in the chat becomes the account name.

 Useful commands:
   mcadmin status         Show the state of everything
   mcadmin accounts       Show the account list
   mcadmin console "say bonjour"
   mcadmin admin          Show the panel login
   mcadmin --help         Show all commands

EOF
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    require_root
    check_debian
    detect_ip
    detect_resources

    install_docker
    install_tools
    remove_old_stack
    prepare_directories
    write_env
    write_compose
    write_templates
    generate_accounts

    start_panel
    wait_for_panel
    configure_panel
    create_admin_user
    restart_panel
    copy_bootstrap

    create_node
    install_wings
    wait_for_wings

    build_plugin
    import_egg
    create_allocations
    create_server
    wait_for_install

    prepare_server_files
    verify_accounts
    start_server
    wait_for_minecraft

    install_cli
    setup_firewall
    summary
}

main "$@"
