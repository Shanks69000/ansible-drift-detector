# Tunnel WireGuard - Accès runner CI/CD vers réseau privé homelab

## Contexte

Le pipeline de drift detection s'exécute sur un runner GitHub Actions hébergé (IP dynamique, cloud public). L'inventaire Ansible cible réside sur un réseau privé, non routable depuis Internet. Un tunnel WireGuard établit la connectivité entre le runner et le bastion du homelab.

## Architecture

```bash
Runner GitHub Actions (IP publique dynamique)
            │
            │ WireGuard UDP/41820
            ▼
Box FAI (NAT, port forwarding 41820 → 51820)
            │
            ▼
        Machine hôte

IP forwarding activé (net.ipv4.ip_forward=1)
DNAT: 51820 → x.x.x.x:51820
FORWARD: ACCEPT UDP/51820 vers x.x.x.x (position 1, prioritaire sur sous-chaînes libvirt)
            │
            ▼
Bastion - serveur WireGuard
Interface wg0, x.x.x.1/24
            │
            ▼
Réseau lab (x.x.x.0/24) — k8s-master, workers, db-server
```

## Prérequis

- Accès administrateur sur la box FAI (port forwarding).
- Accès root sur le bastion et sur la machine hôte hyperviseur.
- Service DDNS si absence d'IP publique fixe (DuckDNS utilisé ici).

## 1. Résolution IP publique dynamique - DuckDNS

FAI sans IP fixe garantie. Mise à jour automatique via cron.

```bash
mkdir -p ~/duckdns
cat > ~/duckdns/duck.sh << 'EOF'
echo url="https://www.duckdns.org/update?domains=<SUBDOMAIN>&token=<TOKEN>&ip=" | curl -k -o ~/duckdns/duck.log -K -
EOF
chmod 700 ~/duckdns/duck.sh
crontab -e
# */5 * * * * ~/duckdns/duck.sh >/dev/null 2>&1
```

Vérification :

```bash
cat ~/duckdns/duck.log
# OK = succès
```

> Réf : https://www.duckdns.org/spec.jsp

## 2. Port forwarding - contrainte plage restreinte

Certains équipementiers restreignent la plage de ports externes redirigeables. 
Port WireGuard standard (51820) hors plage impose un mapping port externe ≠ port interne.

Config retenue :

- Port externe : 41820
- Port interne : 51820
- Cible : IP de la machine hôte hyperviseur (pas directement le bastion, sauf si le bastion est en accès direct sur le LAN)

## 3. Forwarding réseau - machine hôte hyperviseur

Le bastion réside sur un réseau virtuel (`virbr-mgmt`, KVM/libvirt), non directement joignable depuis l'exterieur. La machine hôte assure le rôle de routeur/NAT.

Vérification IP forwarding :

```bash
sysctl net.ipv4.ip_forward
# doit retourner 1, sinon :
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
```

Règle DNAT (redirection du port reçu vers le bastion) :

```bash
sudo iptables -t nat -A PREROUTING -i <interface_wan> -p udp --dport 51820 -j DNAT --to-destination x.x.x.x:51820
```

Règle FORWARD :

```bash
sudo iptables -I FORWARD 1 -p udp -d x.x.x.x --dport 51820 -j ACCEPT
```

### Point d'attention critique - sous-chaînes libvirt

libvirt insère des sous-chaînes dédiées (`LIBVIRT_FWI`, `LIBVIRT_FWO`, `LIBVIRT_FWX`) dans la chaîne `FORWARD`, régénérées dynamiquement à chaque cycle `virsh net-start`/`net-destroy` ou redémarrage de `libvirtd`/`virtnetworkd`. Toute règle insérée manuellement dans ces sous-chaînes est perdue à la prochaine régénération, y compris via hook `/etc/libvirt/hooks/network` (ordre d'exécution non déterministe entre réseaux virtuels).

Solution robuste : insertion en position 1 de la chaîne `FORWARD` elle-même (top-level), non gérée dynamiquement par libvirt. Le paquet est traité avant d'atteindre le `jump` vers les sous-chaînes `LIBVIRT_FW*`, contournant tout REJECT interne à ces dernières.

Validé par test de non-régression (`virsh net-destroy`/`net-start` répété, règle position 1 stable).

Persistance :

```bash
sudo apt install iptables-persistent
sudo netfilter-persistent save
```

> Réf netfilter NAT HOWTO : https://www.netfilter.org/documentation/HOWTO/NAT-HOWTO.html

## 4. Serveur WireGuard - bastion

```bash
sudo apt install wireguard
umask 077
wg genkey | tee server_private.key | wg pubkey > server_public.key
sudo mv server_private.key server_public.key /etc/wireguard/
```

`/etc/wireguard/wg0.conf` :

```ini
[Interface]
Address = x.x.x.1/24
ListenPort = 51820
PrivateKey = <server_private_key>

[Peer]
PublicKey = <client_public_key>
AllowedIPs = x.x.x.2/32
```

```bash
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0
```

## 5. Client - runner CI/CD

Génération clés :

```bash
wg genkey | tee client_private.key | wg pubkey > client_public.key
```

Config client (`wg0-client.conf`), nom de fichier contraint à ≤ 15 caractères (limite `IFNAMSIZ` du noyau Linux, le nom d'interface étant dérivé du nom de fichier par `wg-quick`) :

```ini
[Interface]
PrivateKey = <client_private_key>
Address = x.x.x.2/24

[Peer]
PublicKey = <server_public_key>
Endpoint = <subdomain>.duckdns.org:41820
AllowedIPs = 192.0.2.0/24, 198.51.100.0/24
PersistentKeepalive = 25
```

> Réf WireGuard quickstart : https://www.wireguard.com/quickstart/

## 6. Anomalies rencontrées et résolutions

### 6.1 — `wg-quick` : `stat: cannot read table of mounted file systems`

Symptôme :

```
stat: cannot read table of mounted file systems: Permission denied
/usr/bin/wg-quick: line 47: ((: ( &  & 0007) == 0: syntax error
```

Cause : confinement AppArmor du profil `/etc/apparmor.d/wg`, restreignant l'accès fichier (`fopen`) au chemin `@{etc_rw}/wireguard/{,**}` exclusivement. Tout fichier hors `/etc/wireguard/` (`~/wg0-client.conf`, `/tmp/*`) provoque un échec silencieux de `fopen`, cascadant en erreur de syntaxe sur le calcul de umask dans le script `wg-quick`.

Vérification :

```bash
cat /etc/apparmor.d/wg
```


Résolution - déplacement des fichiers de configuration/clés sous `/etc/wireguard/` :

```bash
sudo cp <fichier> /etc/wireguard/<fichier>
sudo chmod 600 /etc/wireguard/<fichier>
sudo wg setconf <interface> /etc/wireguard/<fichier>
```

Alternative pour configuration manuelle sans `wg-quick` (bypass complet du script bash défaillant) :

```bash
sudo ip link add <iface> type wireguard
sudo wg set <iface> private-key /etc/wireguard/<privkey_file>
sudo wg set <iface> peer <pubkey> endpoint <host>:<port> allowed-ips <cidr> persistent-keepalive 25
sudo ip address add <local_ip>/24 dev <iface>
sudo ip link set <iface> up
```

> Réf profil AppArmor tunables : https://gitlab.com/apparmor/apparmor/-/wikis/AppArmor_Core_Policy_Reference#tunables

## 7. Validation

Depuis réseau externe :

```bash
sudo wg-quick up <config>
sudo wg show
```

`latest handshake` renseigné + `transfer` bidirectionnel non nul confirment le tunnel opérationnel.

Test de connectivité applicative :

```bash
ping -c 3 x.x.x.x
ssh -i ~/.ssh/keybastion user@x.x.x.x
```