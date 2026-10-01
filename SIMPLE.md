# minecraft-ecole — simple installation (Docker only)

This README is for `simple.sh` only. `simple.sh` installs the Minecraft
server in **one Docker container**. There is no Pelican, no Wings and no
Portainer. For the Pelican installation, see `README.md`.

```bash
sudo bash simple.sh
```

The procedure has two phases:

1. **Installation**, with internet access (DHCP).
2. **Use in the school**, on the LAN `192.168.15.0/24` with no internet, with
   the static address `192.168.15.230/24`.

---

## 1. What you get

| Component | Purpose | Port |
|---|---|---|
| Docker CE + Compose plugin | Container runtime | — |
| Container `minecraft` (`eclipse-temurin:25-jre`) | Runs `paper.jar` (Paper 26.3) | 25565, all addresses |
| EcoleLogin (plugin, in `plugin/`) | `/login <utilisateur> <mot de passe>` | — |
| RCON (the server console) | Used by `mcecole` | 25575, on `127.0.0.1` only |
| `mcecole` | Command-line tool for the teacher | — |

The clients are not official, so the server runs in **offline mode**. A player
who joins cannot move and cannot touch the world. The player types one command
in the chat:

```
/login <utilisateur> <mot de passe>
```

---

## 2. Requirements

- Debian 12 or 13, with ifupdown (the default on a Debian server).
- **Internet access during the installation** (section 3).
- The full repository. The folder `plugin/` must be next to `simple.sh`.
- 4 GB of memory or more. 2 GB stay for Debian and Docker. Java gets the
  remaining memory.

---

## 3. Phase 1 — Installation (with internet)

Connect the server to a LAN with internet and DHCP. Then:

```bash
git clone https://github.com/trifoil/minecraft-ecole.git
cd minecraft-ecole
sudo bash simple.sh
```

The script:

1. Installs Docker and the Compose plugin.
2. Stops Wings, the Pelican containers and Portainer, if they are present.
   It **does not delete** their data.
3. Downloads Paper and builds the EcoleLogin plugin.
4. Keeps the old student accounts of `/opt/minecraft-ecole/secrets/`, if they
   exist. Otherwise it makes 50 new accounts.
5. Copies the world of the Pelican server, if this installation has no world.
6. Starts the server **one time**. At this first start, Paper downloads files
   from Mojang. This takes some minutes.
7. Installs the command `mcecole`.

When the script stops, it shows `The Minecraft server runs.` Then make sure
that the server answers:

```bash
sudo mcecole status          # must show "The server answers."
```

**Do not go to phase 2 before this message.** The first start must be complete
while the server has internet.

### Change the defaults (optional)

| Variable | Default | Purpose |
|---|---|---|
| `MC_VERSION` | `26.3` | Minecraft and Paper version |
| `MC_MEMORY_MB` | `auto` | Java memory. `auto` = machine memory − `MEMORY_RESERVE_MB` |
| `MEMORY_RESERVE_MB` | `2048` | Memory for Debian, Docker and the Java overhead |
| `MC_PORT` | `25565` | Port for the clients |
| `ACCOUNT_COUNT` | `50` | Number of accounts |
| `STOP_OLD_STACK` | `yes` | Stop Wings, the Pelican containers and Portainer |
| `IMPORT_PELICAN_WORLD` | `yes` | Copy the world of the Pelican server |
| `UPDATE_PAPER` | `no` | `yes` = download the newest Paper build |
| `PAPER_JAR_URL` | empty | Use this URL for `paper.jar` |

Example:

```bash
sudo MC_MEMORY_MB=6144 ACCOUNT_COUNT=30 bash simple.sh
```

---

## 4. Phase 2 — Set the static IP `192.168.15.230/24` (ifupdown)

Do these steps **at the console of the server** (keyboard and screen, or the
Proxmox console). Do not use SSH: the network stops for a short time.

### Short version (server of the school, interface `enp42s0`)

This is the procedure that we used on the school server. Sections 4.1 to 4.6
give the details.

```bash
# 1. The first start is complete (with internet)
sudo mcecole status                 # "The server answers."

# 2. Only ifupdown controls the network
sudo apt purge network-manager

# 3. Stop the DHCP configuration
sudo ifdown enp42s0

# 4. Edit the network file (see 4.4)
sudo nano /etc/network/interfaces

# 5. Connect the cable to the school LAN, then
sudo reboot

# 6. Check
ip -br a show enp42s0               # 192.168.15.230/24 only
sudo mcecole status                 # "The server answers."
```

In step 4, replace:

```
allow-hotplug enp42s0
iface enp42s0 inet dhcp
```

with:

```
auto enp42s0
iface enp42s0 inet static
    address 192.168.15.230/24
```

### 4.1 Find the name of the interface

```bash
ip -br link
```

Example on the school server, after the installation:

```
a@debian:~$ ip -br link
lo               UNKNOWN        00:00:00:00:00:00 <LOOPBACK,UP,LOWER_UP>
enp42s0          UP             34:5a:60:b4:31:a6 <BROADCAST,MULTICAST,UP,LOWER_UP>
docker0          DOWN           ca:45:e5:5a:4c:e8 <NO-CARRIER,BROADCAST,MULTICAST,UP>
br-d3e804cf27e9  UP             56:ae:96:3f:8f:d2 <BROADCAST,MULTICAST,UP,LOWER_UP>
veth36f2ac3@if2  UP             12:e4:7a:8b:df:44 <BROADCAST,MULTICAST,UP,LOWER_UP>
```

| Interface | What it is | Action |
|---|---|---|
| `enp42s0` | The Ethernet card of the server | **Configure this one** |
| `lo` | Loopback (127.0.0.1) | Do not change |
| `docker0` | Default Docker bridge (not used) | Do not change |
| `br-…` | Docker Compose network of the stack | Do not change |
| `veth…` | Link to the `minecraft` container | Do not change |

On a different machine, the Ethernet interface can have a different name,
for example `ens18` (Proxmox VM) or `eth0`. Use the name of **your**
interface in all the commands below.

### 4.2 Make sure that only ifupdown controls the interface

Debian can have two network tools: ifupdown (`/etc/network/interfaces`) and
NetworkManager (`nmtui`, `nmcli`). Use **only ifupdown**.

If NetworkManager is installed, `nmtui` shows a configuration that has no
effect on the interface. This causes confusion. Remove NetworkManager:

```bash
sudo apt purge network-manager
```

If you want to keep NetworkManager, delete its profile for the interface at
least:

```bash
nmcli con show                          # find the profile, e.g. "Wired connection 1"
sudo nmcli con delete "Wired connection 1"
```

Also look in `/etc/network/interfaces.d/`. This folder must not have a file
for `enp42s0`:

```bash
ls /etc/network/interfaces.d/
```

### 4.3 Stop the DHCP configuration

Stop the interface **before** you edit the file. `ifdown` reads the old
configuration to stop the DHCP client:

```bash
sudo ifdown enp42s0
```

If `ifdown` shows `interface enp42s0 not configured`, this is not a problem.
Continue with the next step.

### 4.4 Edit `/etc/network/interfaces`

```bash
sudo nano /etc/network/interfaces
```

Find these two lines:

```
allow-hotplug enp42s0
iface enp42s0 inet dhcp
```

Replace them with these three lines:

```
auto enp42s0
iface enp42s0 inet static
    address 192.168.15.230/24
```

The full file then has this content:

```
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto enp42s0
iface enp42s0 inet static
    address 192.168.15.230/24
```

Save with `Ctrl+O`, `Enter`, then quit with `Ctrl+X`.

Notes:

- `auto` (not `allow-hotplug`) starts the interface at boot, also when the
  cable is not connected yet. This is better for a server.
- There is **no `gateway` line**. The school LAN has no internet, so a
  gateway is not necessary. The students and the server are on the same
  network `192.168.15.0/24`.
- There is **no `dns-nameservers` line**. The server does not need DNS on a
  LAN with no internet.

### 4.5 Apply the change

Connect the server to the school LAN. Then reboot:

```bash
sudo reboot
```

A reboot is the most reliable method. It also makes sure that the
configuration stays after each start.

If you cannot reboot, use these commands. They stop the old DHCP client,
remove the old address and start the interface with the new configuration:

```bash
sudo dhcpcd -k enp42s0 2>/dev/null; sudo dhclient -r enp42s0 2>/dev/null
sudo ip addr flush dev enp42s0
sudo ifup enp42s0
```

### 4.6 Check

```bash
ip -br a show enp42s0
```

The result must be:

```
enp42s0   UP   192.168.15.230/24 ...
```

There must be only one IPv4 address, and the word `dynamic` must not show
with `ip a`. Then:

```bash
sudo mcecole status          # "The server answers."
mcecole ip              # 192.168.15.230:25565
```

From a computer of a student, connect to `192.168.15.230` (the port 25565 is
the default port, so you do not have to type it).

### 4.7 Why the Minecraft server needs no change

No file of the installation holds the IP address of the machine:

- `docker-compose.yml` publishes the game port as `"25565:25565"`. Docker
  then listens on **all** the addresses of the host.
- `server.properties` has an empty `server-ip=`. Paper listens on all the
  addresses of the container.
- The console (RCON) is on `127.0.0.1`. This address is always present.

Thus the server works with the DHCP address, with `192.168.15.230`, and with
a different address in the future.

**Do not** write an IP address in `docker-compose.yml`, for example
`"192.168.15.230:25565:25565"`. If you do this, the server stops working when
the address changes.

---

## 5. Work with no internet

After phase 1, the server works with no internet:

- The Docker images are on the disk. A start or a restart does not download
  them again.
- The Mojang files are in `data/cache/`, `data/libraries/` and
  `data/versions/`.
- The server runs in offline mode. It does not ask Mojang to verify the
  players.
- The container has `restart: unless-stopped`, and Docker starts at boot.
  The server starts again after a reboot or a crash.
- All the `mcecole` commands work offline.

These actions **need internet**. Do not do them on the school LAN:

- Run `simple.sh` again.
- `UPDATE_PAPER=yes`, or a new `MC_VERSION`.
- `docker compose pull`.
- `docker system prune -a`. It can delete the Java image.

### Test before the class

1. Make sure that `sudo mcecole status` shows `The server answers.`
2. Connect the server to the school LAN (no internet).
3. `sudo reboot`
4. `sudo mcecole status`, then connect with a client.

### Connect the internet again for a short time (updates)

1. Connect the cable to a LAN with internet and DHCP.
2. In `/etc/network/interfaces`, replace `inet static` and the `address`
   line with `inet dhcp`.
3. `sudo reboot`
4. Do the updates, for example `sudo apt update && sudo apt upgrade`, or
   `sudo UPDATE_PAPER=yes bash simple.sh`.
5. Set the static configuration again (section 4.4) and reboot.

---

## 6. Daily management — `mcecole`

```
mcecole status              State of the container and of the server
mcecole start | stop | restart
mcecole logs                Follow the log (Ctrl+C to quit)
mcecole console             Live console (Ctrl+P then Ctrl+Q to quit)
mcecole cmd <command>       Send one command, e.g.: sudo mcecole cmd list
mcecole ip                  Addresses that the students can use
mcecole accounts            Accounts and passwords
mcecole newpass <user>      New password for one account
mcecole add <user>          Add one account
mcecole sync                Rebuild accounts.yml from the CSV and reload
mcecole backup              Backup of the server folder
```

In `mcecole console`, **do not** push Ctrl+C. Ctrl+C stops the server.

### Show the users and the passwords

```bash
sudo mcecole accounts
```

This shows the table `numero  pseudo  motdepasse`. The same data is in the
CSV file:

```bash
sudo cat /opt/minecraft-simple/secrets/comptes-eleves.csv
```

Show one account only:

```bash
sudo grep eleve07 /opt/minecraft-simple/secrets/comptes-eleves.csv
```

### Give the slips to the students

The file `/opt/minecraft-simple/secrets/comptes-eleves.txt` holds one slip
for each account. Print it and cut it.

```bash
sudo cat /opt/minecraft-simple/secrets/comptes-eleves.txt
```

### Add a plugin

Put the `.jar` file in `/opt/minecraft-simple/data/plugins/`, then:

```bash
sudo chown 1000:1000 /opt/minecraft-simple/data/plugins/*.jar
sudo mcecole restart
```

---

## 7. Files and folders

```
/opt/minecraft-simple/
├── docker-compose.yml          The stack (no IP address in it)
├── data/                       The server folder (/data in the container)
│   ├── paper.jar
│   ├── server.properties
│   ├── plugins/ecole-login.jar
│   ├── plugins/EcoleLogin/accounts.yml   salt + SHA-256, no password
│   └── world/ ...
├── secrets/
│   ├── comptes-eleves.csv      The accounts and the passwords
│   ├── comptes-eleves.txt      The slips to print
│   └── rcon.env                The console password
├── backups/                    The files of "mcecole backup"
└── bin/rcon.py                 The console client
```

---

## 8. Troubleshooting

**The client says "Connection refused".**
The client reaches the server, but nothing listens on the port.

```bash
sudo mcecole status
sudo ss -ltnp | grep 25565      # must show 0.0.0.0:25565
```

If the container is stopped: `sudo mcecole start`, then `mcecole logs`.

**The client says "Connection timed out".**
The client does not reach the server. Do these checks:

- `ip -br a show enp42s0` on the server: the address must be
  `192.168.15.230/24`.
- The address of the client must be in `192.168.15.0/24`.
- From the client: `ping 192.168.15.230`.
- The cable and the switch.

**`ip a` shows the old DHCP address and the new address.**
A DHCP client is still active. Do the commands of section 4.5 again, or
reboot. Make sure that `/etc/network/interfaces` has no `inet dhcp` line for
the interface.

**`nmtui` shows an address, but `ip a` shows a different address.**
NetworkManager does not control the interface. ifupdown controls it. Use
only `/etc/network/interfaces` (section 4.2).

**The server does not start on the LAN with no internet.**
The first start was not complete with internet. Connect the internet again
(section 5), then `sudo mcecole restart` and wait for `The server answers.`

---

## 9. Remove the stack

```bash
cd /opt/minecraft-simple && sudo docker compose down
sudo rm -rf /opt/minecraft-simple /usr/local/bin/mcecole
```

To go back to Pelican: `sudo systemctl enable --now wings`, then start the
panel containers again.
