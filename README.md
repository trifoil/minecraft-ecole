# minecraft-ecole

An installer for a school game-server machine on Debian.

The panel is **Pelican Panel**, with the **Wings** daemon. Each game server
runs in its own Docker container. You make servers, install plugins, mods and
modpacks, and read the console from a web page.

The clients are not official, so the Minecraft server runs in **offline mode**.
The **AuthMeReloaded** plugin gives the protection: a player who joins cannot
move, cannot chat and cannot touch the world. The player must first type a
login command in the chat.

---

## 1. Why Pelican and not Pterodactyl

Pterodactyl had no release after **v1.15.1 of August 2024**. Pelican Panel is
the active fork, made by former Pterodactyl developers. It has the same
architecture, it reads Pterodactyl **eggs**, and it gets security patches.

The Wings daemon is at **v1.0.0-beta29**. It is a beta, but it is the version
that Pelican ships and that people use in production. Make backups.

---

## 2. What the script installs

| Component | Purpose | Port |
|---|---|---|
| Docker CE + Compose plugin | Container runtime | — |
| Pelican Panel (container) | Web panel: servers, console, files, users | 80, 443 |
| Pelican Wings (systemd) | Daemon that runs each game server | 8080, 2022 |
| Portainer CE (container) | Web panel for the containers | 9443 |
| `mcadmin` | Command-line tool for the teacher | — |

The script also makes 50 accounts (`eleve01` … `eleve50`) with random
passwords, and writes them to a CSV file and to printable slips.

The Minecraft server itself is **not** in the script. You make it in the
panel, because that is what gives you plugins, mods and modpacks later.

---

## 3. Requirements

- A stock Debian server (Debian 12 or Debian 13), 64-bit.
- Root access.
- 6 GB RAM or more: 4 GB for the game server, the rest for the panel.
- 20 GB free disk or more. A modpack can use 5 GB.
- An internet connection for the installation. The lessons can be offline.

---

## 4. Installation

```bash
sudo bash install.sh
```

The script does the automatic part. It then prints four steps that you do in
the browser. Part 5 explains those steps.

### Change the defaults

```bash
sudo ACCOUNT_COUNT=30 PANEL_URL=http://10.0.0.20 bash install.sh
```

| Variable | Default | Purpose |
|---|---|---|
| `INSTALL_DIR` | `/opt/minecraft-ecole` | Where the stack is installed |
| `PANEL_URL` | `http://<server-ip>` | The URL of the panel |
| `ADMIN_EMAIL` | `admin@ecole.local` | Used by the panel for certificates |
| `PANEL_HTTP_PORT` | `80` | Panel, HTTP |
| `PANEL_HTTPS_PORT` | `443` | Panel, HTTPS |
| `WINGS_PORT` | `8080` | Daemon port |
| `WINGS_SFTP_PORT` | `2022` | SFTP port of the daemon |
| `MC_PORT` | `25565` | Game port |
| `RCON_PORT` | `25575` | Console port |
| `MC_VERSION` | `1.21.11` | Used by `mcadmin prepare` |
| `ACCOUNT_COUNT` | `50` | Number of student accounts |
| `ACCOUNT_PREFIX` | `eleve` | Start of each pseudo |
| `PORTAINER_PORT` | `9443` | Portainer |
| `INSTALL_PORTAINER` | `yes` | `no` skips Portainer |
| `SETUP_FIREWALL` | `no` | `yes` configures `ufw` |
| `REMOVE_OLD_STACK` | `yes` | Replaces an old Crafty stack |

> **Caution:** `SETUP_FIREWALL=yes` enables `ufw`. The script opens port 22
> first. If you use a different SSH port, open it before you run the script.

> If an old Crafty stack is in `INSTALL_DIR`, the script stops it and moves
> the folder to `INSTALL_DIR.old-<date>`. The account list is copied to the
> new folder. The old world stays in the backup folder until you delete it.

---

## 5. The four steps in the browser

### Step 1 — Make the admin account

Open `http://<server-ip>/installer`. Follow the pages. Keep **SQLite** for the
database: it is enough for a school, and it needs no second container.

### Step 2 — Make the node

A "node" is a machine that runs game servers. You have one.

In the panel: **Admin → Nodes → Create Node**.

| Field | Value |
|---|---|
| Name | `local` |
| FQDN / IP | the IP address of the server |
| Communicate over | **HTTP** (this is a LAN, not the internet) |
| Daemon port | `8080` |
| SFTP port | `2022` |
| Memory / Disk | the values of this machine |

Open the node, tab **Configuration**, and click **Auto Deploy Command**. Copy
that command and run it on the server as root. It writes
`/etc/pelican/config.yml`. Then:

```bash
sudo systemctl enable --now wings
mcadmin wings status
```

The node must show a green heart in the panel.

### Step 3 — Add the ports

In the node, tab **Allocations**, add two ports for the server IP:

- `25565` — the game port
- `25575` — the console port (RCON)

### Step 4 — Make the Minecraft server

**Admin → Servers → Create Server**.

| Field | Value |
|---|---|
| Egg | Minecraft → Paper |
| Version | `1.21.11` |
| Primary allocation | `25565` |
| Extra allocation | `25575` |
| Memory | 4096 MB or more |

Start the server one time so that it makes its files, then stop it. Then, on
the server:

```bash
mcadmin servers            # it shows the UUID of the server
mcadmin prepare <uuid>     # AuthMe, PacketEvents, offline mode, RCON
```

`mcadmin prepare` does this:

- It downloads the Paper build of AuthMeReloaded from Modrinth.
- It downloads PacketEvents. AuthMe needs it for the inventory protection.
- It writes the AuthMe configuration.
- It sets `online-mode=false` and `enforce-secure-profile=false`.
- It turns on RCON with a new random password, and saves that password.

Start the server again in the panel, then:

```bash
mcadmin register           # it registers the 50 accounts
```

---

## 6. The student accounts

The script writes two files. Both have mode `600`:

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

## 7. Daily management — the `mcadmin` command

```
PANEL AND DAEMON
  mcadmin panel <start|stop|restart|status|logs>
  mcadmin wings <start|stop|restart|status|logs>
  mcadmin key                     Show the app key of the panel
  mcadmin status                  Show the state of everything

GAME SERVERS
  mcadmin servers                 List the server folders of Wings
  mcadmin prepare <uuid>          Install AuthMe + PacketEvents in a server

CONSOLE (RCON)
  mcadmin rcon-setup <port> <pwd> Save the console access
  mcadmin cmd "<command>"         Send one command
  mcadmin players                 Show the players that are online

STUDENT ACCOUNTS
  mcadmin accounts                Show the account list
  mcadmin register                Register all accounts of the CSV
  mcadmin add <pseudo> [pwd]      Make one more account
  mcadmin passwd <pseudo> <pwd>   Change a password
  mcadmin remove <pseudo>         Delete an account
```

Examples:

```bash
mcadmin add eleve51                 # new student, random password
mcadmin passwd eleve07 Nouveau2026  # a student lost the password
mcadmin cmd "say Le cours commence dans 5 minutes"
mcadmin cmd "kick eleve12 Pause"
mcadmin panel logs                  # the panel logs
mcadmin wings logs                  # the daemon logs
```

Press `Ctrl+C` to stop a log view.

---

## 8. Plugins, mods and modpacks

This is the reason for a panel. The panel keeps a **file manager**, a
**console**, a **backup** tool and a **startup** tab for each server.

**A plugin (Paper).** Put the `.jar` file in the `plugins` folder with the
file manager, then restart the server. You can also use the Modrinth or the
Spigot page and upload the file.

**A mod (Fabric or Forge).** Make a **new** server with the Fabric egg or the
Forge egg. Put the `.jar` files in the `mods` folder. A mod server needs the
same mods on each student computer.

**A modpack.** Pelican and Pterodactyl have eggs for CurseForge and for
Modrinth modpacks. In **Admin → Eggs → Import Egg**, import the egg JSON file,
then make a server with it and give the modpack ID.

> **Important for a mod or modpack server:** AuthMeReloaded is a Paper plugin.
> It does not work on Fabric or Forge. For those servers, use a different
> login mod, or a whitelist, or a separate LAN with no login.

> **Ports:** each new server needs its own allocation. Add more ports in the
> node, for example 25566 to 25580.

---

## 9. The two web panels

Each panel uses a certificate that the browser does not know. Accept the
warning.

### Pelican Panel — `http://<server-ip>`

This is the main tool. It gives the console, the files, the backups, the
players and the start/stop buttons of each game server.

Read the panel logs:

```bash
mcadmin panel logs
```

The same in plain Docker:

```bash
sudo docker logs -f --tail=200 pelican-panel
```

If you lose the admin password, make a new admin user from the container:

```bash
sudo docker exec -it pelican-panel php artisan p:user:make
```

### Portainer — `https://<server-ip>:9443`

Portainer manages the **containers**: the panel container, and the containers
that Wings makes for the game servers. Use it to read logs and to open a
shell.

Read the Portainer logs:

```bash
mcadmin panel status
sudo docker logs -f --tail=200 portainer-ecole
```

Portainer asks you to make the admin password at the first visit. Do this in
the first minutes. If the time is over, restart the container:

```bash
sudo docker restart portainer-ecole
```

---

## 10. Security notes

**What the setup protects against**

- A student who uses the pseudo of another student is blocked at the login.
- A student who does not have an account is kicked (`kickNonRegistered`).
- A player who is not logged in cannot move, chat, or use the inventory.
- Passwords are stored with BCRYPT in an SQLite database.
- The console port is open on the server only, not for the students. Do not
  put `25575` in the firewall rules.

**What the setup does not protect against**

- Offline mode has no cryptographic identity. The protection is the password
  only. This is correct for a closed LAN. Do not put this server on the
  public internet.
- A student who reads another slip can log in as that student. Keep the slips
  private.
- Wings runs as root and it controls Docker. Give the panel admin account to
  teachers only.

**Session length**

After a login, a reconnection in the next 30 minutes does not ask for the
password again. Change `settings.sessions.timeout` in the file
`plugins/AuthMe/config.yml` of the server (use the file manager of the
panel), then run `mcadmin cmd "authme reload"`.

---

## 11. Files and folders

```
/opt/minecraft-ecole/
├── .env                        Settings that docker compose reads
├── docker-compose.yml          Panel and Portainer
├── bin/rcon.py                 Small RCON client (standard library only)
├── templates/authme-config.yml Model configuration for AuthMe
└── secrets/
    ├── comptes-eleves.csv
    ├── comptes-eleves.txt
    └── rcon.env                Console port and password

/etc/pelican/config.yml         Wings configuration (from the panel)
/var/lib/pelican/volumes/<uuid> The files of one game server
/etc/systemd/system/wings.service
```

---

## 12. Troubleshooting

**The node stays red in the panel.**
Wings does not run, or the panel cannot reach it.

```bash
mcadmin wings status
mcadmin wings logs
```

Check that the node uses **HTTP**, port `8080`, and the correct IP address.
Run the Auto Deploy Command again if `/etc/pelican/config.yml` is wrong.

**The panel page does not open.**
Port 80 can be used by another web server.

```bash
sudo ss -tlnp | grep ':80 '
mcadmin panel logs
```

Stop the other web server, or set `PANEL_HTTP_PORT=8081` and install again.

**The game server does not start.**
Read the console in the panel first. A common cause is not enough memory.
Lower the memory of the server in the panel, or add RAM.

**A student sees "You are not registered".**
The pseudo does not match. Check the exact spelling with `mcadmin accounts`.
Prism Launcher must use that exact name.

**`mcadmin register` says that the console access is not set.**
Run `mcadmin prepare <uuid>` first, or set it by hand:

```bash
mcadmin rcon-setup 25575 <the-rcon-password>
```

The password is in the `server.properties` of the server, in the panel file
manager.

**AuthMe says that PacketEvents is missing.**
`mcadmin prepare` downloads it. If the download failed, take the Paper build
from <https://modrinth.com/plugin/packetevents> and upload it to the
`plugins` folder with the panel.

**A container cannot resolve a name
("Temporary failure in name resolution").**

Look at the file first:

```bash
sudo docker exec <container> cat /etc/resolv.conf
```

*Case 1 — the file says `NO EXTERNAL NAMESERVERS DEFINED`.*
Docker writes this file one time only: when it **creates** the container. A
`restart` does not repair it. You must recreate the container:

```bash
cd /opt/minecraft-ecole
sudo docker compose up -d --force-recreate
```

*Case 2 — the file has a nameserver, but the name does not resolve.*
Find the DNS server that the host uses, then give it to Docker:

```bash
grep nameserver /etc/resolv.conf
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "dns": ["10.0.0.1", "9.9.9.9"]
}
EOF
sudo systemctl restart docker
```

Replace `10.0.0.1` with the real address. If `/etc/resolv.conf` shows
`127.0.0.53`, the host uses systemd-resolved; a container cannot use that
address, and Docker then falls back to `8.8.8.8`, which a school filter often
blocks.

---

## 13. Backups

The panel makes backups of one server: open the server, tab **Backups**.

You can also make a backup from the command line:

```bash
sudo tar -C /var/lib/pelican/volumes -czf /root/backup-$(date +%F).tar.gz <uuid>
```

Copy the file `comptes-eleves.csv` at the same time. It is not in the server
folder.

---

## 14. Remove the stack

```bash
cd /opt/minecraft-ecole
sudo docker compose down -v
sudo systemctl disable --now wings
sudo rm -f /usr/local/bin/wings /etc/systemd/system/wings.service
sudo rm -rf /etc/pelican /var/lib/pelican
sudo rm -rf /opt/minecraft-ecole /usr/local/bin/mcadmin
```

This deletes every world and every account. Make a backup first.

---

## 15. Licences and sources

- Pelican Panel — MIT — <https://pelican.dev>
- Pelican Wings — MIT — <https://github.com/pelican-dev/wings>
- Paper — GPL-3.0 — <https://papermc.io>
- AuthMeReloaded — GPL-3.0 — <https://modrinth.com/plugin/authmereloaded>
- PacketEvents — GPL-3.0 — <https://modrinth.com/plugin/packetevents>
- Portainer CE — zlib — <https://www.portainer.io>

Minecraft is a product of Mojang Studios. Each player needs a licence of the
game. This setup is for a classroom laboratory only.
