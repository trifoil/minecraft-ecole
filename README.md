# minecraft-ecole

One command installs a complete school game-server machine on Debian.

```bash
sudo bash install.sh
```

When the script stops, the Minecraft server runs, the web panel works, and
the 50 student accounts are registered. **No step in a browser.**

---

## 1. What you get

| Component | Purpose | Port |
|---|---|---|
| Docker CE + Compose plugin | Container runtime | — |
| Pelican Panel (container) | Web panel: servers, console, files, backups | 80, 443 |
| Pelican Wings (systemd) | Daemon that runs each game server | 8080, 2022 |
| Paper Minecraft server | The school server, in offline mode | 25565 |
| AuthMeReloaded + PacketEvents | Login by chat command | — |
| Portainer CE (container) | Web panel for the containers | 9443 |
| `mcadmin` | Command-line tool for the teacher | — |

The clients are not official, so the server runs in **offline mode**. A player
who joins cannot move, cannot chat and cannot touch the world. The player must
first type `/login <password>` in the chat.

### Why Pelican and not Pterodactyl

Pterodactyl had no release after **v1.15.1 of August 2024**. Pelican Panel is
the active fork, made by former Pterodactyl developers. It has the same
architecture, it reads Pterodactyl **eggs**, and it gets security patches.

The Wings daemon is at **v1.0.0-beta29**. It is a beta, but it is the version
that Pelican ships. Make backups.

---

## 2. How the script replaces the web installer

This is the part that is usually manual. The script does it with the panel's
own code, not with a browser robot.

| Manual step | What the script does |
|---|---|
| Installer wizard | It writes `APP_INSTALLED=true` in the panel `.env`, then runs `php artisan migrate --seed --force` |
| Admin account | `php artisan p:user:make --admin=1` with a random password |
| Create the node | `App\Models\Node::create(...)` |
| Wings configuration | `$node->getYamlConfiguration()` writes `/etc/pelican/config.yml` |
| Add the ports | `App\Services\Allocations\AssignmentService` |
| Import the Paper egg | `App\Services\Eggs\Sharing\EggImporterService::fromUrl()` |
| Create the server | `App\Services\Servers\ServerCreationService::handle()` |
| Start the server | `App\Repositories\Daemon\DaemonServerRepository::power('start')` |

The script puts a small PHP file (`school-bootstrap.php`) in the panel
container. That file boots the Laravel application of the panel and calls
these services. You can read it in `bin/school-bootstrap.php`.

---

## 3. Requirements

- A stock Debian server (Debian 12 or Debian 13), 64-bit.
- Root access.
- 6 GB RAM or more: 4 GB for the game server, the rest for the panel.
- 20 GB free disk or more. A modpack can use 5 GB.
- An internet connection during the installation. The lessons can be offline.

The installation downloads from these hosts. A school filter must let them
pass:

| Host | For |
|---|---|
| `download.docker.com` | Docker CE |
| `ghcr.io` | The panel image, and the Java images of the game servers |
| `github.com` | The Wings binary |
| `raw.githubusercontent.com` | The Paper egg |
| `api.modrinth.com` and `cdn.modrinth.com` | AuthMe and PacketEvents |
| `fill.papermc.io` | The Paper server jar |

---

## 4. Installation

```bash
sudo bash install.sh
```

The script takes 15 to 30 minutes. Most of that time is the download of the
images and of the Paper server. The script prints each step, so you see where
it is.

At the end it prints the addresses, the panel password file and the account
file.

### Change the defaults

```bash
sudo ACCOUNT_COUNT=30 MC_MEMORY_MB=6144 SETUP_FIREWALL=yes bash install.sh
```

| Variable | Default | Purpose |
|---|---|---|
| `INSTALL_DIR` | `/opt/minecraft-ecole` | Where the stack is installed |
| `SERVER_IP` | detected | The LAN address of the server |
| `MC_PORT` | `25565` | Game port |
| `RCON_PORT` | `25575` | Console port (host only) |
| `MC_VERSION` | `1.21.11` | Minecraft version |
| `MC_MEMORY_MB` | `4096` | Memory of the game server |
| `MC_DISK_MB` | `15360` | Disk of the game server |
| `MC_SERVER_NAME` | `Serveur ecole` | Name in the panel |
| `MC_JAVA_IMAGE` | `…/yolks:java_25` | Java image of the server |
| `ACCOUNT_COUNT` | `50` | Number of student accounts |
| `ACCOUNT_PREFIX` | `eleve` | Start of each pseudo |
| `ADMIN_EMAIL` | `admin@ecole.local` | Panel administrator |
| `ADMIN_USERNAME` | `admin` | Panel administrator |
| `PANEL_IMAGE` | `ghcr.io/pelican/panel:latest` | The panel image |
| `PANEL_HTTP_PORT` | `80` | Panel |
| `WINGS_PORT` | `8080` | Daemon |
| `WINGS_SFTP_PORT` | `2022` | SFTP of the daemon |
| `WINGS_DATA` | `/var/lib/pelican/volumes` | Where the server files live |
| `PORTAINER_PORT` | `9443` | Portainer |
| `INSTALL_PORTAINER` | `yes` | `no` skips Portainer |
| `SETUP_FIREWALL` | `no` | `yes` configures `ufw` |
| `REMOVE_OLD_STACK` | `yes` | Replaces an old Crafty or itzg stack |

> **Caution:** `SETUP_FIREWALL=yes` enables `ufw`. The script opens port 22
> first. If you use a different SSH port, open it before you run the script.

> If an old stack is in `INSTALL_DIR`, the script stops it and moves the
> folder to `INSTALL_DIR.old-<date>`. The account list is copied to the new
> folder. The old world stays in the backup until you delete it.

### If you run the script two times

The script does not make a second copy of anything. It finds the node by its
address, the egg by its name, the server by its name and the accounts by the
CSV file. A second run repairs a step that failed, and it keeps the passwords.

---

## 5. The student accounts

Two files, both with mode `600`:

```
/opt/minecraft-ecole/secrets/comptes-eleves.csv   numero,pseudo,motdepasse
/opt/minecraft-ecole/secrets/comptes-eleves.txt   printable slips
/opt/minecraft-ecole/secrets/panel-admin.txt      the panel login
```

Print the slips file and cut it. Give one slip to each student.

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

## 6. Daily management — the `mcadmin` command

```
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
  mcadmin register                Register all accounts of the CSV
  mcadmin add <pseudo> [pwd]      Make one more account
  mcadmin passwd <pseudo> <pwd>   Change a password
  mcadmin remove <pseudo>         Delete an account

FILES
  mcadmin files                   Show the folder of the server
  mcadmin backup                  Make a backup of the server folder
```

Examples:

```bash
mcadmin console "say Le cours commence dans 5 minutes"
mcadmin console "kick eleve12 Pause"
mcadmin add eleve51                 # new student, random password
mcadmin passwd eleve07 Nouveau2026  # a student lost the password
mcadmin restart
```

Press `Ctrl+C` to stop a log view.

---

## 7. Plugins, mods and modpacks

The panel keeps a **file manager**, a **console**, a **backup** tool and a
**startup** tab for each server.

**A plugin (Paper).** Put the `.jar` file in the `plugins` folder with the
file manager, then restart the server. The folder is also on the disk:

```bash
mcadmin files      # it prints the path of the server folder
```

**A mod (Fabric or Forge).** Make a **new** server in the panel with the
Fabric egg or the Forge egg. Put the `.jar` files in the `mods` folder. A mod
server needs the same mods on each student computer.

**A modpack.** Pelican reads Pterodactyl eggs. In **Admin → Eggs → Import
Egg**, import the CurseForge or Modrinth modpack egg, then make a server with
it and give the modpack ID.

> **Important for a mod or modpack server:** AuthMeReloaded is a Paper plugin.
> It does not work on Fabric or Forge. For those servers, use a whitelist, or
> a different login mod, or a separate lesson with no login.

> **Ports:** each new server needs its own allocation. In the panel, open
> **Admin → Nodes → local → Allocations** and add more ports, for example
> 25566 to 25580.

---

## 8. The two web panels

### Pelican Panel — `http://<server-ip>`

The main tool. Console, files, backups, players, start and stop.

```bash
mcadmin admin        # show the login and the password
mcadmin panel logs   # the panel logs
```

If you lose the password, make a second administrator:

```bash
sudo docker exec -it pelican-panel php artisan p:user:make
```

### Portainer — `https://<server-ip>:9443`

Portainer manages the **containers**: the panel container, and the containers
that Wings makes for the game servers.

```bash
sudo docker logs -f --tail=200 portainer-ecole
```

Portainer asks you to make the admin password at the first visit. Do this in
the first minutes. If the time is over, restart the container:

```bash
sudo docker restart portainer-ecole
```

---

## 9. Security notes

**What the setup protects against**

- A student who uses the pseudo of another student is blocked at the login.
- A student who does not have an account is kicked (`kickNonRegistered`).
- A player who is not logged in cannot move, chat, or use the inventory.
  PacketEvents gives the inventory and tab-complete protection; the script
  installs it.
- Passwords are stored with BCRYPT in an SQLite database.
- The console port (25575) and the daemon port (8080) stay closed in the
  firewall rules. They are used on the host only.

**What the setup does not protect against**

- Offline mode has no cryptographic identity. The protection is the password
  only. This is correct for a closed LAN. Do not put this server on the
  public internet.
- A student who reads another slip can log in as that student. Keep the slips
  private.
- Wings runs as root and it controls Docker. Give the panel administrator
  account to teachers only.

**Session length**

After a login, a reconnection in the next 30 minutes does not ask for the
password again. Change `settings.sessions.timeout` in the file
`plugins/AuthMe/config.yml` of the server, then:

```bash
mcadmin console "authme reload"
```

---

## 10. Files and folders

```
/opt/minecraft-ecole/
├── .env                          Settings that docker compose reads
├── docker-compose.yml            Panel and Portainer
├── bin/rcon.py                   Small RCON client (standard library only)
├── bin/school-bootstrap.php      Headless setup of the panel
├── templates/authme-config.yml   Model configuration for AuthMe
├── backups/                      Made by "mcadmin backup"
└── secrets/
    ├── panel-admin.txt           Panel login
    ├── comptes-eleves.csv        Student accounts
    ├── comptes-eleves.txt        Printable slips
    └── rcon.env                  Console port, password, server UUID

/etc/pelican/config.yml           Wings configuration
/var/lib/pelican/volumes/<uuid>   The files of one game server
/etc/systemd/system/wings.service
```

---

## 11. Troubleshooting

**The script stops with "error from registry: denied".**

Pelican moved its images from the `pelican-dev` namespace to `pelican`. A
registry does not redirect a namespace, so an old name gives `denied`. Test
the two names:

```bash
sudo docker pull ghcr.io/pelican/panel:latest
sudo docker pull ghcr.io/pelican-dev/panel:latest
```

Run the script again with the name that works:

```bash
sudo PANEL_IMAGE=ghcr.io/pelican/panel:latest bash install.sh
```

If both names fail, `ghcr.io` is blocked. Test it:

```bash
curl -sSI https://ghcr.io/v2/ | head -1
```

A line with `401` is correct: the registry answers, and it asks for a token.
No answer means that a filter blocks the host. Ask the network administrator
to allow `ghcr.io`. The game servers also need it, for the Java images.

**The script stops at the migrations.**
Read `/opt/minecraft-ecole/migrate.log`. A common cause is no network in the
panel container. See the DNS part below.

**The script stops at "The Paper egg was not imported".**
The panel container cannot reach `raw.githubusercontent.com`. The panel gives
the egg import a short timeout. Check the network, then run the script again.

**The script stops at "The installation of the server failed".**
Wings could not download the Paper jar or the Java image. Look at the install
log in the panel, or:

```bash
mcadmin wings logs
```

**The node stays red in the panel.**

```bash
mcadmin wings status
mcadmin wings logs
```

Check that `/etc/pelican/config.yml` holds a `token:` line and that `remote:`
points to `http://<server-ip>`.

**The panel page does not open.**
Port 80 can be used by another web server.

```bash
sudo ss -tlnp | grep ':80 '
mcadmin panel logs
```

Stop the other web server, or run the script with `PANEL_HTTP_PORT=8081`.

**A student sees "You are not registered".**
The pseudo does not match. Check the exact spelling with `mcadmin accounts`.
Prism Launcher must use that exact name.

**A container cannot resolve a name
("Temporary failure in name resolution").**

Look at the file first:

```bash
sudo docker exec pelican-panel cat /etc/resolv.conf
```

*Case 1 — the file says `NO EXTERNAL NAMESERVERS DEFINED`.*
Docker writes this file one time only: when it **creates** the container. A
`restart` does not repair it. You must recreate the container:

```bash
cd /opt/minecraft-ecole
sudo docker compose up -d --force-recreate
```

*Case 2 — the file has a nameserver, but the name does not resolve.*
Give Docker a real DNS server:

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

## 12. Backups

```bash
mcadmin backup
```

The file goes to `/opt/minecraft-ecole/backups/`. The panel can also make
backups: open the server, tab **Backups**.

Copy `secrets/comptes-eleves.csv` at the same time. It is not in the server
folder.

---

## 13. Remove the stack

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

## 14. Licences and sources

- Pelican Panel — MIT — <https://pelican.dev>
- Pelican Wings — MIT — <https://github.com/pelican-dev/wings>
- Paper — GPL-3.0 — <https://papermc.io>
- AuthMeReloaded — GPL-3.0 — <https://modrinth.com/plugin/authmereloaded>
- PacketEvents — GPL-3.0 — <https://modrinth.com/plugin/packetevents>
- Portainer CE — zlib — <https://www.portainer.io>

Minecraft is a product of Mojang Studios. Each player needs a licence of the
game. This setup is for a classroom laboratory only.
