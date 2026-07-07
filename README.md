# ansible-drift-detector

Pipeline de détection de drift de configuration Ansible, exécuté via GitHub Actions sur runner self-hosted. Compare l'état déclaré (playbooks du repo `infra-as-code-homelab`) à l'état réel de l'infrastructure via `ansible-playbook --check --diff`, notifie par email en cas d'écart ou d'hôte injoignable, historise les rapports dans le repo.

## Architecture

Runner self-hosted (GitHub Actions)
-> Montée tunnel WireGuard vers réseau privé homelab (10.10.1.0/24)
-> Checkout infra-as-code-homelab (playbooks + inventaire injecté via secret)
-> ansible-playbook --check --diff (base.yml)
-> Parsing changed= et unreachable= (PLAY RECAP)
-> Email si drift_detected=true (changed>0 OU unreachable>0)
-> Commit rapport dans reports/
-> Démontage tunnel WireGuard

## Prérequis

- Runner self-hosted enregistré sur ce repo, exécuté sur machine avec accès au tunnel WireGuard.
- Sudoers NOPASSWD configuré pour l'utilisateur exécutant le service runner (commandes `ip`, `wg`, `tee`, `rm`, `chmod`, `apt-get`) — le service systemd runner n'a pas de session PAM interactive, `sudo` avec mot de passe échoue systématiquement en contexte non-TTY.
- Secrets GitHub Actions :
  - `WG_PRIVATE_KEY`, `WG_SERVER_PUBLIC_KEY`, `WG_SERVER_ENDPOINT` — tunnel WireGuard.
  - `SMTP_USERNAME`, `SMTP_PASSWORD`, `NOTIFY_EMAIL` — notification email (Gmail SMTP, App Password requis).
  - `ANSIBLE_INVENTORY` — contenu YAML de l'inventaire, injecté dynamiquement (le fichier `hosts.yml` du repo source est gitignored, non commité pour éviter l'exposition des IP internes en repo public).

## Setup tunnel WireGuard

Procédure complète dans `docs/wireguard-tunnel-setup.md` : DDNS (DuckDNS), port forwarding avec plage restreinte (cas Bbox 6, ports 40960-49151), résolution AppArmor (`fopen` restreint à `/etc/wireguard/`), résolution conflit chaînes `LIBVIRT_FWI`/`FORWARD` (régénération dynamique par libvirt, insertion règle en position 1 top-level).

## Scripts

- `scripts/wglab-up.sh` : montée manuelle du tunnel (tests locaux hors CI).
- `scripts/wglab-down.sh` : fermeture manuelle du tunnel.

Le tunnel est monté/démonté à chaque exécution du job CI (pas de persistance permanente), réduisant la fenêtre d'exposition réseau du homelab.

## Schedule

`workflow_dispatch` (déclenchement manuel) et `cron: "0 */12 * * *"` (toutes les 12h).

Limite connue : le schedule automatique suppose runner et infrastructure cible actifs en permanence. En usage réel (hyperviseur et VMs non maintenus allumés en continu), les runs schedulés échoueront en `unreachable` hors des fenêtres d'activité, comportement attendu, pas un bug. Le déclenchement manuel reste la modalité principale d'usage dans ce contexte.

## Limitation portée fonctionnelle

Couverture actuelle : `playbooks/base.yml` uniquement. Extension possible aux autres playbooks du repo source (`k3s.yml`, `db-server.yml`, `nfs-server.yml`) via steps additionnels ou boucle sur liste de playbooks, non implémenté à ce stade.

## Ce que ce projet démontre

- Drift detection Ansible (`--check --diff`) hors écosystème Kubernetes, applicable à tout environnement piloté par Ansible pur.
- Tunnel WireGuard point-à-point pour connecter un runner CI/CD à un réseau privé, avec troubleshooting documenté (AppArmor, iptables/libvirt, NAT hairpin).
- Cycle de vie réseau éphémère scopé à l'exécution du job.
- Notification conditionnelle par email (SMTP Gmail, action tierce `dawidd6/action-send-mail`).
- Runner self-hosted GitHub Actions avec configuration sudoers adaptée à un contexte non-interactif.
- Injection de données sensibles via secrets plutôt que commit en clair (inventaire IP internes).