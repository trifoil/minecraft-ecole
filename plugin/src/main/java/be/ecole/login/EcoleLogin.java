package be.ecole.login;

import org.bukkit.Bukkit;
import org.bukkit.ChatColor;
import org.bukkit.command.Command;
import org.bukkit.command.CommandSender;
import org.bukkit.configuration.file.FileConfiguration;
import org.bukkit.configuration.file.YamlConfiguration;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.EventPriority;
import org.bukkit.event.Listener;
import org.bukkit.event.block.BlockBreakEvent;
import org.bukkit.event.block.BlockPlaceEvent;
import org.bukkit.event.entity.EntityDamageEvent;
import org.bukkit.event.entity.EntityPickupItemEvent;
import org.bukkit.event.inventory.InventoryClickEvent;
import org.bukkit.event.inventory.InventoryOpenEvent;
import org.bukkit.event.player.PlayerCommandPreprocessEvent;
import org.bukkit.event.player.PlayerDropItemEvent;
import org.bukkit.event.player.PlayerInteractEvent;
import org.bukkit.event.player.PlayerJoinEvent;
import org.bukkit.event.player.PlayerMoveEvent;
import org.bukkit.event.player.PlayerQuitEvent;
import org.bukkit.plugin.java.JavaPlugin;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;

/**
 * EcoleLogin — login by one chat command on a school Minecraft server.
 *
 * The server runs in offline mode, because the clients are not official. A
 * player who joins cannot move and cannot touch the world. The player types
 *
 *     /login &lt;user&gt; &lt;password&gt;
 *
 * The plugin compares the pair with the list of class accounts. The account
 * is not the name of the client, so a student keeps the name of the launcher.
 *
 * The accounts are in plugins/EcoleLogin/accounts.yml. Each line holds a salt
 * and a SHA-256 hash, never the password.
 */
public class EcoleLogin extends JavaPlugin implements Listener {

    /** Players that did not log in yet. The value is the time of the join. */
    private final Map<UUID, Long> pending = new HashMap<>();

    /** Players that logged in. The value is the account name. */
    private final Map<UUID, String> authenticated = new HashMap<>();

    /** Accounts of the class. The key is the account name in lower case. */
    private final Map<String, Account> accounts = new HashMap<>();

    private int timeoutSeconds = 120;
    private int reminderSeconds = 6;
    private boolean renameOnLogin = true;
    private String kickTimeout = "Temps ecoule. Reconnectez-vous et tapez /login <utilisateur> <mot de passe>.";

    /** One account: a salt and a hash. */
    private static final class Account {
        final String name;
        final String salt;
        final String hash;

        Account(String name, String salt, String hash) {
            this.name = name;
            this.salt = salt;
            this.hash = hash;
        }
    }

    // ------------------------------------------------------------------
    // Life of the plugin
    // ------------------------------------------------------------------

    @Override
    public void onEnable() {
        saveDefaultConfig();
        readSettings();
        loadAccounts();

        getServer().getPluginManager().registerEvents(this, this);

        // Remind the players, and kick the players that take too much time.
        Bukkit.getScheduler().runTaskTimer(this, this::tick, 20L, 20L * reminderSeconds);

        getLogger().info("EcoleLogin is active with " + accounts.size() + " accounts.");
    }

    @Override
    public void onDisable() {
        pending.clear();
        authenticated.clear();
    }

    private void readSettings() {
        FileConfiguration config = getConfig();
        timeoutSeconds = config.getInt("timeout-seconds", 120);
        reminderSeconds = Math.max(2, config.getInt("reminder-seconds", 6));
        renameOnLogin = config.getBoolean("rename-on-login", true);
        kickTimeout = config.getString("message-timeout", kickTimeout);
    }

    /** Read plugins/EcoleLogin/accounts.yml. */
    private void loadAccounts() {
        accounts.clear();
        File file = new File(getDataFolder(), "accounts.yml");
        if (!file.exists()) {
            getLogger().warning("The file accounts.yml is not present. Nobody can log in.");
            return;
        }
        YamlConfiguration data = YamlConfiguration.loadConfiguration(file);
        for (String name : data.getKeys(false)) {
            String salt = data.getString(name + ".salt");
            String hash = data.getString(name + ".hash");
            if (salt == null || hash == null) {
                getLogger().warning("The account " + name + " has no salt or no hash.");
                continue;
            }
            accounts.put(name.toLowerCase(Locale.ROOT), new Account(name, salt, hash));
        }
    }

    // ------------------------------------------------------------------
    // The command
    // ------------------------------------------------------------------

    @Override
    public boolean onCommand(CommandSender sender, Command command, String label, String[] args) {
        String name = command.getName().toLowerCase(Locale.ROOT);

        if (name.equals("ecolelogin")) {
            if (args.length == 1 && args[0].equalsIgnoreCase("reload")) {
                reloadConfig();
                readSettings();
                loadAccounts();
                sender.sendMessage(ChatColor.GREEN + "EcoleLogin: " + accounts.size() + " comptes charges.");
            } else {
                sender.sendMessage(ChatColor.YELLOW + "Utilisation: /ecolelogin reload");
            }
            return true;
        }

        if (!(sender instanceof Player)) {
            sender.sendMessage("Cette commande est pour un joueur.");
            return true;
        }
        Player player = (Player) sender;

        if (authenticated.containsKey(player.getUniqueId())) {
            player.sendMessage(ChatColor.YELLOW + "Vous etes deja connecte.");
            return true;
        }

        if (args.length != 2) {
            player.sendMessage(ChatColor.RED + "Utilisation: /login <utilisateur> <mot de passe>");
            return true;
        }

        Account account = accounts.get(args[0].toLowerCase(Locale.ROOT));
        if (account == null || !matches(account, args[1])) {
            // The same message for the two errors. It gives no information
            // to a person that tries many user names.
            player.sendMessage(ChatColor.RED + "Utilisateur ou mot de passe incorrect.");
            getLogger().info("Failed login from " + player.getName() + " for account " + args[0]);
            return true;
        }

        if (isAccountInUse(account.name, player.getUniqueId())) {
            player.sendMessage(ChatColor.RED + "Ce compte est deja utilise par un autre joueur.");
            return true;
        }

        login(player, account);
        return true;
    }

    private boolean isAccountInUse(String accountName, UUID except) {
        for (Map.Entry<UUID, String> entry : authenticated.entrySet()) {
            if (entry.getValue().equalsIgnoreCase(accountName) && !entry.getKey().equals(except)) {
                Player other = Bukkit.getPlayer(entry.getKey());
                if (other != null && other.isOnline()) {
                    return true;
                }
            }
        }
        return false;
    }

    private void login(Player player, Account account) {
        pending.remove(player.getUniqueId());
        authenticated.put(player.getUniqueId(), account.name);

        if (renameOnLogin) {
            player.setDisplayName(account.name);
            player.setPlayerListName(account.name);
        }

        player.sendMessage(ChatColor.GREEN + "Connexion reussie. Bon jeu, " + account.name + " !");
        getLogger().info(player.getName() + " logged in as " + account.name);
    }

    // ------------------------------------------------------------------
    // The reminder and the time limit
    // ------------------------------------------------------------------

    private void tick() {
        long now = System.currentTimeMillis();
        for (Player player : Bukkit.getOnlinePlayers()) {
            Long joined = pending.get(player.getUniqueId());
            if (joined == null) {
                continue;
            }
            long seconds = (now - joined) / 1000L;
            if (seconds >= timeoutSeconds) {
                pending.remove(player.getUniqueId());
                player.kickPlayer(kickTimeout);
                continue;
            }
            long left = timeoutSeconds - seconds;
            player.sendMessage(ChatColor.GOLD + "Tapez " + ChatColor.WHITE
                    + "/login <utilisateur> <mot de passe>" + ChatColor.GOLD
                    + "  (" + left + " s)");
        }
    }

    // ------------------------------------------------------------------
    // The protection before the login
    // ------------------------------------------------------------------

    private boolean locked(Player player) {
        return !authenticated.containsKey(player.getUniqueId());
    }

    @EventHandler(priority = EventPriority.LOWEST)
    public void onJoin(PlayerJoinEvent event) {
        Player player = event.getPlayer();
        authenticated.remove(player.getUniqueId());
        pending.put(player.getUniqueId(), System.currentTimeMillis());

        player.sendMessage("");
        player.sendMessage(ChatColor.AQUA + "=== Serveur Minecraft de l ecole ===");
        player.sendMessage(ChatColor.WHITE + "Vous ne pouvez pas bouger.");
        player.sendMessage(ChatColor.WHITE + "Tapez dans le chat : " + ChatColor.GREEN
                + "/login <utilisateur> <mot de passe>");
        player.sendMessage(ChatColor.GRAY + "Les identifiants sont sur votre fiche.");
        player.sendMessage("");
    }

    @EventHandler
    public void onQuit(PlayerQuitEvent event) {
        pending.remove(event.getPlayer().getUniqueId());
        authenticated.remove(event.getPlayer().getUniqueId());
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onCommandPreprocess(PlayerCommandPreprocessEvent event) {
        if (!locked(event.getPlayer())) {
            return;
        }
        String message = event.getMessage().toLowerCase(Locale.ROOT);
        if (message.equals("/login") || message.startsWith("/login ")) {
            return;
        }
        event.setCancelled(true);
        event.getPlayer().sendMessage(ChatColor.RED
                + "Connectez-vous d abord : /login <utilisateur> <mot de passe>");
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onMove(PlayerMoveEvent event) {
        if (!locked(event.getPlayer()) || event.getTo() == null) {
            return;
        }
        // The player can turn the head, but cannot change the block.
        if (event.getFrom().getBlockX() != event.getTo().getBlockX()
                || event.getFrom().getBlockY() != event.getTo().getBlockY()
                || event.getFrom().getBlockZ() != event.getTo().getBlockZ()) {
            event.setCancelled(true);
        }
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onInteract(PlayerInteractEvent event) {
        if (locked(event.getPlayer())) {
            event.setCancelled(true);
        }
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onBreak(BlockBreakEvent event) {
        if (locked(event.getPlayer())) {
            event.setCancelled(true);
        }
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onPlace(BlockPlaceEvent event) {
        if (locked(event.getPlayer())) {
            event.setCancelled(true);
        }
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onInventoryOpen(InventoryOpenEvent event) {
        if (event.getPlayer() instanceof Player && locked((Player) event.getPlayer())) {
            event.setCancelled(true);
        }
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onInventoryClick(InventoryClickEvent event) {
        if (event.getWhoClicked() instanceof Player && locked((Player) event.getWhoClicked())) {
            event.setCancelled(true);
        }
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onDrop(PlayerDropItemEvent event) {
        if (locked(event.getPlayer())) {
            event.setCancelled(true);
        }
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onPickup(EntityPickupItemEvent event) {
        if (event.getEntity() instanceof Player && locked((Player) event.getEntity())) {
            event.setCancelled(true);
        }
    }

    @EventHandler(priority = EventPriority.LOWEST, ignoreCancelled = true)
    public void onDamage(EntityDamageEvent event) {
        if (event.getEntity() instanceof Player && locked((Player) event.getEntity())) {
            event.setCancelled(true);
        }
    }

    // ------------------------------------------------------------------
    // The password
    // ------------------------------------------------------------------

    private boolean matches(Account account, String password) {
        String computed = sha256Hex(account.salt + password);
        return constantTimeEquals(computed, account.hash.toLowerCase(Locale.ROOT));
    }

    static String sha256Hex(String text) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] bytes = digest.digest(text.getBytes(StandardCharsets.UTF_8));
            StringBuilder out = new StringBuilder(bytes.length * 2);
            for (byte b : bytes) {
                out.append(Character.forDigit((b >> 4) & 0x0f, 16));
                out.append(Character.forDigit(b & 0x0f, 16));
            }
            return out.toString();
        } catch (NoSuchAlgorithmException error) {
            throw new IllegalStateException("SHA-256 is not available.", error);
        }
    }

    /** Compare two texts in a constant time. It gives no timing information. */
    private static boolean constantTimeEquals(String a, String b) {
        if (a.length() != b.length()) {
            return false;
        }
        int result = 0;
        for (int i = 0; i < a.length(); i++) {
            result |= a.charAt(i) ^ b.charAt(i);
        }
        return result == 0;
    }
}
