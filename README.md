# minecraft-ecole

A one-command installer for a Minecraft server on a school LAN.

The clients are not official, so the server runs in **offline mode**. The
**AuthMeReloaded** plugin gives the protection: a player who joins cannot move,
cannot chat and cannot touch the world. The player must first type a login
command in the chat. After the login, the player can play.

---

## 1. What the script installs

| Component | Purpose | Port |
|---|---|---|
| Docker CE + Compose plugin | Container runtime | — |
| Paper 1.21.11 (`itzg/minecraft-server`) | The Minecraft server | 25565/tcp |
| AuthMeReloaded 6.x | Login by chat command | — |
| Crafty Controller 4 | Web panel for Minecraft servers | 8443/tcp |
| Portainer CE | Web panel for the containers | 9443/tcp |
| `mcadmin` | Command-line tool for the teacher | — |

The script also makes 50 accounts (`eleve01` … `eleve50`) with random
passwords, and writes them to a CSV file and to printable slips.

---

## 2. Requirements

- A stock Debian server (Debian 12 or Debian 13), 64-bit.
- Root access.
- 4 GB RAM or more for the Minecraft server, plus 1 GB for the panels.
- An internet connection for the installation only. The lessons can be offline.

---

## 3. Installation

```bash
sudo bash install.sh
```

The first start downloads the images and builds the world. This step takes
5 to 15 minutes. Do not stop the script.

### Change the defaults

Give the values on the command line:

```bash
sudo MC_MEMORY=6G ACCOUNT_COUNT=30 ACCOUNT_PREFIX=etud bash install.sh
```

| Variable | Default | Purpose |
|---|---|---|
| `INSTALL_DIR` | `/opt/minecraft-ecole` | Where the stack is installed |
| `MC_VERSION` | `1.21.11` | Paper version |
| `MC_MEMORY` | `4G` | Java heap |
| `MC_PORT` | `25565` | Minecraft port |
| `MAX_PLAYERS` | `60` | Maximum players |
| `ACCOUNT_COUNT` | `50` | Number of student accounts |
| `ACCOUNT_PREFIX` | `eleve` | Start of each pseudo |
| `PASSWORD_LENGTH` | `10` | Password length |
| `CRAFTY_PORT` | `8443` | Crafty web panel |
| `PORTAINER_PORT` | `9443` | Portainer web panel |
| `ENABLE_WHITELIST` | `false` | Second lock (see part 7) |
| `SETUP_FIREWALL` | `no` | Set to `yes` to configure `ufw` |
| `SKIP_DOCKER_INSTALL` | `no` | Set to `yes` if Docker is present |

> **Caution:** `SETUP_FIREWALL=yes` enables `ufw`. The script opens port 22
> first. If you use a different SSH port, open it before you run the script.

---

## 4. The student accounts

The script writes two files. Both files have mode `600`:

```
/opt/minecraft-ecole/secrets/comptes-eleves.csv   numero,pseudo,motdepasse
/opt/minecraft-ecole/secrets/comptes-eleves.txt   printable slips
```

Print the second file and cut it. Give one slip to each student.

**Copy these files to a safe place. The passwords are not in the server
database in clear text.**

### How a student connects

1. In Prism Launcher, make an offline account. The name must be exactly the
   pseudo on the slip, for example `eleve07`.
2. Add the server: `<server-ip>:25565`.
3. Join. The screen is dark and the player cannot move.
4. In the chat, type: `/login <password>`
5. The player can now play.

### Texte pour les eleves (francais)

```
Serveur Minecraft de l'ecole

1. Dans Prism Launcher, cree un compte hors-ligne.
   Le pseudo doit etre exactement celui de ta fiche.
2. Ajoute le serveur : <adresse-du-serveur>:25565
3. Rejoins le serveur. Tu ne peux pas bouger.
4. Dans le chat, tape :  /login <ton-mot-de-passe>
5. Tu peux jouer.

Ne donne jamais ton mot de passe a un autre eleve.
```

---

## 5. Daily management — the `mcadmin` command

```
mcadmin start                  Start all containers
mcadmin stop                   Stop all containers
mcadmin restart                Restart all containers
mcadmin status                 Show the state of the containers
mcadmin logs [service]         Follow the logs (default: mc)
mcadmin console                Open the Minecraft console
mcadmin cmd "<command>"        Send one command to the server
mcadmin players                Show the players that are online

mcadmin accounts               Show the account list
mcadmin add <pseudo> [pwd]     Make one more account
mcadmin passwd <pseudo> <pwd>  Change a password
mcadmin remove <pseudo>        Delete an account

mcadmin backup                 Make a backup of the world
mcadmin update                 Pull new images and restart
```

Examples:

```bash
mcadmin add eleve51                 # new student, random password
mcadmin passwd eleve07 Nouveau2026  # a student lost the password
mcadmin cmd "say Le cours commence dans 5 minutes"
mcadmin cmd "kick eleve12 Pause"
```

---

## 6. The two web panels

Each panel uses a self-signed certificate. The browser shows a warning.
Accept the warning.

### Portainer — `https://<server-ip>:9443`

Portainer manages the **containers**. Use it to start, stop and restart the
Minecraft container, to read the logs, and to open a shell in the container.
Portainer asks you to make the admin password at the first visit. Do this in
the first minutes. If the time is over, run `docker restart portainer-ecole`.

### Crafty Controller — `https://<server-ip>:8443`

The first password is in:

```
/opt/minecraft-ecole/crafty/config/default-creds.txt
```

Change the password at the first login.

#### Crafty does not show the school server. This is normal.

Crafty controls only the servers that **Crafty itself** starts. The school
server runs in a different container (`mc-ecole`), so Crafty cannot see it in
the server list, and Crafty cannot start or stop it.

```
  Portainer  ──controls──>  [ mc-ecole container ]   <── mcadmin (RCON)
  Crafty     ──controls──>  [ servers that Crafty made ]
```

Use Crafty for a **second** server (a creative world, a test world) on ports
25601–25650, and to browse or back up files. For the main server, use
Portainer or `mcadmin`.

The main server folder is mounted read-only in Crafty under
`import/mc-ecole`, so you can look at the files from the panel.

#### Option: move the main server into Crafty

Do this only if you want one panel for everything. You lose the automatic
plugin download and the `mcadmin` commands.

```bash
# 1. Stop the container that holds the server.
mcadmin stop

# 2. Make a zip of the server.
sudo apt-get install -y zip
cd /opt/minecraft-ecole/data
sudo zip -r /tmp/mc-ecole.zip . -x 'logs/*' 'cache/*'

# 3. In Crafty: Servers > Create New Server > Upload Zip Archive.
#    Give a name, upload /tmp/mc-ecole.zip, then click "Import Server!".

# 4. In Crafty, open the server, then Config:
#    - Server port: 25565
#    - Minimum and maximum memory: the same value as MC_MEMORY
#    - Start command: check that it points to the Paper jar in the zip.

# 5. Stop the old container for good.
cd /opt/minecraft-ecole
sudo docker compose stop mc
```

The AuthMe plugin, its configuration and its database are in the zip, so the
student accounts continue to work.

> **Caution:** two servers cannot use port 25565 at the same time. Stop the
> `mc-ecole` container before you start the Crafty copy.

---

## 7. Security notes

**What the setup protects against**

- A student who uses the pseudo of another student is blocked at the login.
- A student who does not have an account is kicked (`kickNonRegistered`).
- A player who is not logged in cannot move, chat, or use the inventory.
- The RCON port is **not** published on the LAN. It stays inside Docker.
- Passwords are stored with BCRYPT in an SQLite database.

**What the setup does not protect against**

- Offline mode has no cryptographic identity. The protection is the password
  only. This is correct for a closed LAN, but do not put this server on the
  public internet.
- A student who reads another slip can log in as that student. Keep the slips
  private.

**Second lock — the whitelist**

The script writes `/opt/minecraft-ecole/data/whitelist.json` with the correct
offline UUID of each student. The whitelist is **off** by default, because
AuthMe already blocks unknown names. To turn it on:

```bash
sudo sed -i 's/^ENABLE_WHITELIST=.*/ENABLE_WHITELIST=true/' /opt/minecraft-ecole/.env
mcadmin restart
```

**Session length**

After a login, a reconnection in the next 30 minutes does not ask for the
password again. Change `settings.sessions.timeout` in
`/opt/minecraft-ecole/data/plugins/AuthMe/config.yml`, then run
`mcadmin cmd "authme reload"`.

---

## 8. Files and folders

```
/opt/minecraft-ecole/
├── .env                        Settings that docker compose reads
├── docker-compose.yml          The three services
├── data/                       Minecraft server (world, plugins, logs)
│   ├── plugins/AuthMe/config.yml
│   ├── plugins/AuthMe/authme.db
│   └── whitelist.json
├── crafty/                     Crafty Controller data
├── backups/                    Made by "mcadmin backup"
└── secrets/
    ├── comptes-eleves.csv
    └── comptes-eleves.txt
```

---

## 9. Troubleshooting

**The server does not start.**
Run `mcadmin logs`. A common cause is not enough RAM. Lower `MC_MEMORY`
in `.env`, then run `mcadmin restart`.

**A student sees "You are not registered".**
The pseudo does not match. Check the exact spelling with `mcadmin accounts`.
Prism Launcher must use that exact name.

**AuthMe did not load.**
Run `mcadmin cmd "plugins"`. If AuthMe is not in the list, the Modrinth
download failed. Check the network, then run `mcadmin restart`.

**The Minecraft version and the plugin version do not match.**
AuthMeReloaded 6.x needs Paper 1.21.11 or later. If you lower `MC_VERSION`,
use AuthMeReloaded 5.6.0 instead, and put the jar in `data/plugins/` by hand.

**A student cannot connect at all.**
Check the firewall: `sudo ufw status`. Port 25565/tcp must be open.

**Crafty shows "Crafty is having trouble accessing the internet.
Server Creation has been disabled."**

Crafty makes one test at each page load: an HTTPS GET to `https://google.com`
with a timeout of **1 second**. If the test fails, Crafty disables the form
that makes a new server, because that form downloads a server jar.

This message does **not** stop the school server. The `mc-ecole` container
runs and the students can play. Only the Crafty "Create New Server" form is
off. The "Upload Zip Archive" import on the same page continues to work.

Find the cause. Do the same test from inside the container. Crafty keeps its
Python packages in a virtualenv, so you must use the Python of that
virtualenv. The system `python3` does not have the `requests` module.

```bash
sudo docker exec crafty-ecole /crafty/.venv/bin/python3 -c \
  "import requests; print(requests.get('https://google.com', timeout=1).status_code)"
```

This next test uses the standard library only. It also shows the time, which
is the important number:

```bash
sudo docker exec crafty-ecole python3 -c "
import urllib.request, time
t = time.time()
r = urllib.request.urlopen('https://google.com', timeout=5)
print('status', r.status, '- time', round(time.time() - t, 2), 's')
"
```

| Result | Cause | What to do |
|---|---|---|
| `status 200 - time 0.3 s` | The network is good. | Do the venv test above for a DNS or TLS problem. |
| `status 200 - time 1.5 s` | Too slow. Crafty stops at 1 second. | See "Slow network" below. |
| `Name or service not known` | The container cannot resolve names. | Add a DNS server (below). |
| `timed out` or connection refused | A school filter or a proxy blocks it. | Allow `google.com` for the server IP, or set a proxy (below). |

**Add a DNS server.** A "Temporary failure in name resolution" error means
that the container cannot resolve a name. Look at the file first:

```bash
sudo docker exec crafty-ecole cat /etc/resolv.conf
```

*Case 1 — the file says `NO EXTERNAL NAMESERVERS DEFINED`.*

Docker writes this file one time only: when it **creates** the container. If
the host had no usable nameserver at that moment, the container keeps an
empty resolver for its full life. A `restart` does not repair this, because a
restart uses the same container. You must recreate it:

```bash
cd /opt/minecraft-ecole
sudo docker compose up -d --force-recreate crafty
```

The data is in bind mounts, so nothing is lost. Do the same for `mc` if that
container has the same problem.

*Case 2 — the file has a nameserver, but the name still does not resolve.*

The host DNS is not good for the containers.

Find the DNS server that the host really uses:

```bash
grep nameserver /etc/resolv.conf
resolvectl status 2>/dev/null | grep -i 'DNS Server'
```

If `/etc/resolv.conf` shows `127.0.0.53`, the host uses systemd-resolved.
A container cannot use that address. Docker then falls back to `8.8.8.8`,
and a school filter often blocks that address.

Give Docker the real DNS server. Replace `10.0.0.1` with the address from
`resolvectl status`:

```bash
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "dns": ["10.0.0.1", "9.9.9.9"]
}
EOF
sudo systemctl restart docker
```

Verify. A line with an IP address means the fix works:

```bash
sudo docker exec crafty-ecole getent hosts google.com
```

For one container only, you can instead put this in the `crafty` service in
`/opt/minecraft-ecole/docker-compose.yml`:

```yaml
    dns:
      - 10.0.0.1
      - 9.9.9.9
```

**Set a proxy.** If the school uses an HTTP proxy, add this to the
`environment:` block of the `crafty` service:

```yaml
      HTTP_PROXY: "http://proxy.ecole.local:3128"
      HTTPS_PROXY: "http://proxy.ecole.local:3128"
      NO_PROXY: "localhost,127.0.0.1"
```

**Slow network.** The 1-second timeout is in the Crafty code. You cannot
change it from the configuration. Ask the network administrator to allow
`google.com` for the server. If this is not possible, use the zip import,
or do not use Crafty to make new servers.

After each change:

```bash
cd /opt/minecraft-ecole && sudo docker compose up -d crafty
```

Then refresh the Crafty page in the browser.

**Crafty does not show the school Minecraft server.**
This is normal. Crafty controls only the servers that Crafty made. Read
part 6 of this file.

---

## 10. Remove the stack

```bash
cd /opt/minecraft-ecole
docker compose down -v
sudo rm -rf /opt/minecraft-ecole /usr/local/bin/mcadmin
```

This deletes the world. Make a backup first with `mcadmin backup`.

---

## 11. Licences and sources

- Paper — GPL-3.0 — <https://papermc.io>
- AuthMeReloaded — GPL-3.0 — <https://modrinth.com/plugin/authmereloaded>
- `itzg/minecraft-server` — Apache-2.0 — <https://docker-minecraft-server.readthedocs.io>
- Crafty Controller — GPL-3.0 — <https://docs.craftycontrol.com>
- Portainer CE — zlib — <https://www.portainer.io>

Minecraft is a product of Mojang Studios. Each player needs a licence of the
game. This setup is for a classroom laboratory only.
