# ansible-drift-detector

Detection de drift de configuration Ansible via pipeline schedule GitHub Actions. Compare l'etat declare (playbooks) a l'etat reel de l'infrastructure via `ansible-playbook --check --diff`, notifie par email en cas d'ecart, historise les rapports en JSON/texte dans le repo.

## Architecture

Runner self-hosted (GitHub Actions)
-> Tunnel WireGuard vers reseau prive homelab
-> Checkout infra-as-code-homelab (playbooks source)
-> ansible-playbook --check --diff --diff-always
-> Parsing du resultat (changed > 0 = drift)
-> Email si drift detecte
-> Commit rapport dans reports/
-> Fermeture tunnel

## Prerequis

- Runner self-hosted enregistre sur ce repo, execute sur machine ayant acces au tunnel WireGuard.
- Secrets GitHub Actions requis :
  - `WG_PRIVATE_KEY`, `WG_SERVER_PUBLIC_KEY`, `WG_SERVER_ENDPOINT`
  - `SMTP_USERNAME`, `SMTP_PASSWORD`, `NOTIFY_EMAIL`

## Setup tunnel WireGuard

Voir `docs/wireguard-tunnel-setup.md` pour la procedure complete (DDNS, port forwarding, resolution des conflits libvirt/AppArmor rencontres).

## Scripts

- `scripts/wglab-up.sh` : montee manuelle du tunnel (tests locaux).
- `scripts/wglab-down.sh` : fermeture manuelle du tunnel.

## Schedule

Execution automatique toutes les 12h (`cron: "0 */12 * * *"`), declenchement manuel possible via `workflow_dispatch`.

## Ce que ce projet demontre

- Drift detection Ansible (`--check --diff`) hors ecosysteme Kubernetes.
- Tunnel WireGuard point-a-point pour connecter un runner CI/CD a un reseau prive.
- Gestion du cycle de vie reseau ephemere (tunnel monte/demonte par execution, reduction de la surface d'exposition).
- Notification conditionnelle par email (SMTP Gmail, action tierce).
- Runner self-hosted GitHub Actions.

Permissions execution scripts avant commit :

``chmod +x scripts/wglab-up.sh scripts/wglab-down.sh``

Verification secrets manquants sur ce repo avant premier declenchement :

**https://github.com/Shanks69000/ansible-drift-detector/settings/secrets/actions**