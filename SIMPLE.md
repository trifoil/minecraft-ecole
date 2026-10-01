# minecraft-ecole — simple installation (Docker only)

`simple.sh` is an alternative to `install.sh`. It installs the Minecraft
server in **one Docker container**. There is no Pelican, no Wings and no
Portainer.

```bash
sudo bash simple.sh
```

## 1. What you get

| Component | Purpose | Port |
|---|---|---|
| Docker CE + Compose plugin | Container runtime | — |
| Container `minecraft` (`eclipse-temurin:25-jre`) | Runs `paper.jar` | 25565 (all addresses) |
| EcoleLogin (plugin, in `plugin/`) | `/login <utilisateur> <mot de passe>` | — |
| RCON (the server console) | Used by `mcecole` | 25575 on `127.0.0.1` only |
| `mcecole` | Command-line tool for the teacher | — |

## 2. The IP address of the server can change

No file holds the IP address of the machine:

- The compose file publishes the game port as `"25565:25565"`. Docker then
  listens on **all** the addresses of the host.
- `server.properties` has an empty `server-ip=`. Paper listens on all the
  addresses of the container.
- The console (RCON) is on `127.0.0.1`. This address is always present.

Thus you can change the address of the machine (DHCP to static, or a move to
a different LAN). Reboot or not: the server continues to work. The students
use the new address. To show the current addresses:

```bash
mcecole ip
```

**Do not** write an IP address in `docker-compose.yml` (for example
`"192.168.15.230:25565:25565"`). If you do this, the server stops working when
the address changes.

### Change the IP address on Debian (ifupdown)

Use only one network tool. On a Debian server, this is ifupdown. Edit
`/etc/network/interfaces`:

```
auto enp42s0
iface enp42s0 inet static
    address 192.168.15.230/24
```

Then reboot. Do not use `nmtui` on this machine. `nmtui` does not control an
interface that is in `/etc/network/interfaces`.

## 3. Requirements

- Debian 12 or 13.
- **Internet access during the installation.** The script downloads Docker,
  Paper, the Java image, the Maven image, and the files from Mojang (first
  start). After the installation, the server works on a LAN with no internet.
- The full repository (the folder `plugin/` must be next to `simple.sh`).

## 4. Installation

```bash
git clone https://github.com/trifoil/minecraft-ecole.git
cd minecraft-ecole
sudo bash simple.sh
```

Then move the network cable to the school LAN, and set the static IP
(section 2).

### Change the defaults

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

### If Pelican is installed

With `STOP_OLD_STACK=yes`, the script **stops** Wings and the containers that
use the port 25565, the panel and Portainer. It sets their restart policy to
`no`. It **does not delete** data.

The script also keeps the student accounts of `/opt/minecraft-ecole/secrets/`.
The students keep their passwords. If this install has no world, the script
copies the world of the Pelican server. The original world stays in
`/var/lib/pelican/volumes/`.

### If you run the script two times

The script keeps `paper.jar`, the world, the accounts and the RCON password.
It builds the plugin again and starts the container again.

## 5. Daily management — `mcecole`

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

## 6. Files and folders

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
├── backups/
└── bin/rcon.py
```

Add a plugin: put the `.jar` in `data/plugins/`, then `sudo mcecole restart`.

## 7. Troubleshooting

**The client says "Connection refused".**
The client reaches the machine, but nothing listens on the port.

```bash
mcecole status
sudo ss -ltnp | grep 25565      # must show 0.0.0.0:25565
```

If the container is stopped: `sudo mcecole start`, then `mcecole logs`.

**The client says "Connection timed out".**
The client does not reach the machine. Look at the IP (`mcecole ip`), the
cable, and the LAN of the client.

**The server does not start after the move to the LAN with no internet.**
The first start must be done with internet. Paper downloads files from Mojang
one time. Connect the internet again, then `sudo mcecole restart`.

## 8. Remove the stack

```bash
cd /opt/minecraft-simple && sudo docker compose down
sudo rm -rf /opt/minecraft-simple /usr/local/bin/mcecole
```

To go back to Pelican: `sudo systemctl enable --now wings`, then start the
panel containers again.
