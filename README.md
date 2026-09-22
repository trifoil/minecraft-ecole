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
| EcoleLogin (plugin, in `plugin/`) | One command: `/login <user> <password>` | — |
| Portainer CE (container) | Web panel for the containers | 9443 |
| `mcadmin` | Command-line tool for the teacher | — |

The clients are not official, so the server runs in **offline mode**. A player
who joins cannot move and cannot touch the world. The player types one command
in the chat:

```
/login <utilisateur> <mot de passe>
```

The account is **not** the name of the launcher. A student keeps the pseudo of
his choice, and proves who he is with the pair on his slip. The plugin that
does this is in the folder `plugin/`, with its source.

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
| Build the login plugin | `mvn package` in a temporary Maven container |
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
| `fill.papermc.io` | The Paper server jar |
| `repo.papermc.io` | The Paper API, to build the login plugin |
| `repo.maven.apache.org` | The Maven tools |
| `docker.io` | Portainer and the Maven image |

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
| `MC_VERSION` | `26.3` | Minecraft version |
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

> **Minecraft 26.3:** In September 2026, Paper for 26.3 has only
> experimental builds. If the server is not stable, use the last stable
> version: `sudo MC_VERSION=26.2 bash install.sh`. The students must use
> the same Minecraft version in Prism Launcher. Versions 26.x need Java 25.

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

1. In Prism Launcher, make an offline account. **The name is free.** Two
   students cannot use the same name at the same time, because Minecraft
   makes the identity of a player from that name.
2. Add the server: `<server-ip>:25565`.
3. Join. The player cannot move.
4. In the chat, type: `/login <user> <password>`, for example
   `/login eleve07 K7mNp2rQxZ`
5. The player can now play. The name in the chat and in the player list
   becomes `eleve07`, so you see who is who.

A player who does not log in is kicked after 120 seconds.

### Texte pour les eleves (francais)

```
Serveur Minecraft de l'ecole

1. Dans Prism Launcher, cree un compte hors-ligne.
   Tu choisis le pseudo que tu veux.
2. Ajoute le serveur : <adresse-du-serveur>:25565
3. Rejoins le serveur. Tu ne peux pas bouger.
4. Dans le chat, tape :  /login <utilisateur> <mot de passe>
   Les deux sont sur ta fiche.
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
  mcadmin sync                    Rebuild accounts.yml from the CSV
  mcadmin add <user> [pwd]        Make one more account
  mcadmin passwd <user> <pwd>     Change a password
  mcadmin remove <user>           Delete an account

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

> **Important for a mod or modpack server:** EcoleLogin is a Paper plugin.
> It does not work on Fabric or Forge. For those servers, use a whitelist, or
> a separate lesson with no login.

> **Ports:** each new server needs its own allocation. In the panel, open
> **Admin → Nodes → local → Allocations** and add more ports, for example
> 25566 to 25580.

---

## 8. The two web panels

### Pelican Panel — `http://<server-ip>`

The main tool. Console, files, backups, players, start and stop.

```bash
sudo mcadmin admin   # show the login and the password
mcadmin panel logs   # the panel logs
```

#### Find the panel password

The installer makes the administrator account with a random password. It
writes the password in one file:

```
/opt/minecraft-ecole/secrets/panel-admin.txt
```

The file has mode `600` and root is the owner. Thus you must use `sudo`.
Use one of these commands:

```bash
sudo mcadmin admin
sudo cat /opt/minecraft-ecole/secrets/panel-admin.txt
```

The output shows the URL, the user name, the email and the password:

```
Pelican Panel administrator
  URL      : http://<server-ip>
  User     : admin
  Email    : admin@ecole.local
  Password : <random password>
```

On the login page, type the user name or the email, and then the password.

The installer also shows the path of this file at the end of the
installation. A second run of `install.sh` does not change the password.

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

- A student who does not know a pair user/password cannot play.
- The error message is the same for a wrong user and for a wrong password.
  It gives no information to a student that tries many names.
- A player who is not logged in cannot move, break or place a block, use an
  item, open the inventory, pick up or drop an item, or take damage. Every
  command except `/login` is blocked.
- One account can be used by one player at a time.
- Passwords are stored as a salt and a SHA-256 hash, one salt per account.
  The clear passwords exist only in `secrets/comptes-eleves.csv`.
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

**The chat before the login**

A player that is not logged in can still write in the chat. That is what you
asked for, because the login is a chat command. The risk is small but real: a
student can type his password in the chat by mistake, and the others see it.
Tell the students to look at the line before they press Enter.

**Settings of the plugin**

The file is `plugins/EcoleLogin/config.yml` in the server folder:

| Key | Default | Purpose |
|---|---|---|
| `timeout-seconds` | `120` | Seconds before the kick |
| `reminder-seconds` | `6` | Seconds between two reminders |
| `rename-on-login` | `true` | Show the account name after the login |

After a change:

```bash
mcadmin console "ecolelogin reload"
```

---

## 10. Files and folders

```
/opt/minecraft-ecole/
├── .env                          Settings that docker compose reads
├── docker-compose.yml            Panel and Portainer
├── bin/rcon.py                   Small RCON client (standard library only)
├── bin/school-bootstrap.php      Headless setup of the panel
├── plugin-src/                   Copy of plugin/, and the built jar
├── build.log                     Log of the plugin build
├── backups/                      Made by "mcadmin backup"
└── secrets/
    ├── panel-admin.txt           Panel login
    ├── comptes-eleves.csv        Student accounts
    ├── comptes-eleves.txt        Printable slips
    └── rcon.env                  Console port, password, server UUID

/etc/pelican/config.yml           Wings configuration
/var/lib/pelican/volumes/<uuid>   The files of one game server
  plugins/ecole-login.jar           The login plugin
  plugins/EcoleLogin/accounts.yml   Salt and hash of each account
  plugins/EcoleLogin/config.yml     Settings of the plugin
/etc/systemd/system/wings.service
```

The repository also holds the source of the plugin:

```
plugin/
├── pom.xml
└── src/main/java/be/ecole/login/EcoleLogin.java
    src/main/resources/plugin.yml
    src/main/resources/config.yml
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
Read `/opt/minecraft-ecole/migrate.log`. If the database is in a bad state
after a failed run, clean it and start again:

```bash
cd /opt/minecraft-ecole
sudo docker compose down -v
sudo bash install.sh
```

`down -v` deletes the panel database only. The account list is in
`secrets/`, and the script keeps it.

A `no such table` error means that the panel tried to use the database for
the cache or the session before the migration made those tables. The script
sets `CACHE_STORE=file` and `SESSION_DRIVER=file` to prevent this. Check
those two lines if you changed them:

```bash
sudo docker exec pelican-panel grep -E 'CACHE_STORE|SESSION_DRIVER' /pelican-data/.env
```

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

**A student sees "Utilisateur ou mot de passe incorrect".**
Check the pair with `mcadmin accounts`. The user name is not the name of the
launcher: it is the first word after `/login`.

**A student sees "Ce compte est deja utilise par un autre joueur".**
Two students use the same account. Give each student his own slip.

**The script stops at "The plugin did not build".**
Read `/opt/minecraft-ecole/build.log`. The build needs `repo.papermc.io` and
`repo.maven.apache.org`. Test them:

```bash
curl -sSI https://repo.papermc.io/repository/maven-public/ | head -1
```

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
- EcoleLogin — the plugin of this repository, folder `plugin/`
- Portainer CE — zlib — <https://www.portainer.io>

Minecraft is a product of Mojang Studios. Each player needs a licence of the
game. This setup is for a classroom laboratory only.
