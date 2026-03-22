#!/usr/bin/env bash
# =============================================================================
# one-shot-cleanup.sh — Nettoyage complet de l'environnement DevSecOps Labs
# =============================================================================
#
# Supprime tous les composants installés par one-shot-installation.sh.
# Remet la machine EC2 dans un état propre sans réinstaller l'OS.
#
# UTILISATION
#   chmod +x one-shot-cleanup.sh
#   ./one-shot-cleanup.sh
#
# ATTENTION : Opération IRRÉVERSIBLE.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
}

# ─── Confirmation ─────────────────────────────────────────────────────────────
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║   ATTENTION — Opération IRRÉVERSIBLE                 ║${NC}"
echo -e "${RED}║   Tous les conteneurs, images Docker et le cluster   ║${NC}"
echo -e "${RED}║   Kubernetes seront supprimés définitivement.        ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
read -r -p "Confirmer le nettoyage complet ? [oui/N] : " CONFIRM
[[ "$CONFIRM" == "oui" ]] || { echo "Annulé."; exit 0; }

# ─── 1. Ressources Kubernetes de labs ─────────────────────────────────────────
section "1 · Suppression des ressources Kubernetes de labs"

if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
    for ns in production cyberwatch-prod monitoring falco \
               app-frontend app-backend app-data ebank gatekeeper-system; do
        if kubectl get namespace "$ns" &>/dev/null 2>&1; then
            kubectl delete namespace "$ns" --timeout=60s 2>/dev/null && \
                success "Namespace $ns supprimé." || \
                warn "Timeout suppression $ns."
        fi
    done
    kubectl delete constrainttemplate --all 2>/dev/null || true
    kubectl delete pod kube-bench-master kube-bench-worker \
        -n kube-system --ignore-not-found 2>/dev/null || true
    kubectl delete cronjob security-audit \
        -n kube-system --ignore-not-found 2>/dev/null || true
    success "Ressources de labs supprimées."
else
    info "Cluster non accessible — skipping."
fi

# ─── 2. Reset kubeadm ─────────────────────────────────────────────────────────
section "2 · Reset du cluster (kubeadm reset)"

sudo kubeadm reset -f 2>/dev/null || true
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet \
            /var/run/kubernetes /etc/cni/net.d
rm -rf "$HOME/.kube"

# Nettoyer les interfaces réseau laissées par Kubernetes
for iface in cni0 flannel.1 kube-ipvs0 tunl0; do
    sudo ip link delete "$iface" 2>/dev/null || true
done

# Vider les règles iptables
sudo iptables -F 2>/dev/null || true
sudo iptables -X 2>/dev/null || true
sudo iptables -t nat -F 2>/dev/null || true
sudo iptables -t nat -X 2>/dev/null || true
sudo iptables -t mangle -F 2>/dev/null || true
sudo ipvsadm --clear 2>/dev/null || true

success "Cluster réinitialisé."

# ─── 3. Désinstallation Kubernetes ────────────────────────────────────────────
section "3 · Désinstallation kubeadm / kubelet / kubectl / Helm"

sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
sudo apt-get remove -y --purge kubelet kubeadm kubectl 2>/dev/null || true
sudo apt-get autoremove -y 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo rm -f /etc/default/kubelet
sudo rm -f /etc/sysctl.d/k8s.conf
sudo rm -f /etc/modules-load.d/k8s.conf
sudo rm -f /usr/local/bin/helm
success "Kubernetes et Helm supprimés."

# ─── 4. containerd ────────────────────────────────────────────────────────────
section "4 · Suppression de containerd"

sudo systemctl stop containerd 2>/dev/null || true
sudo systemctl disable containerd 2>/dev/null || true
sudo apt-get remove -y --purge containerd.io containerd 2>/dev/null || true
sudo rm -rf /etc/containerd /var/lib/containerd
sudo rm -f /run/containerd/containerd.sock
sudo rm -f /etc/apt/sources.list.d/docker.list
sudo rm -f /usr/share/keyrings/docker.gpg
success "containerd supprimé."

# ─── 5. Restauration du swap ──────────────────────────────────────────────────
section "5 · Restauration du swap"

sudo sed -i '/\bswap\b/s/^#//' /etc/fstab 2>/dev/null || true
sudo systemctl unmask swap.target 2>/dev/null || true
sudo swapon -a 2>/dev/null || true
SWAP=$(free | awk '/Swap:/ {print $2}')
[[ $SWAP -gt 0 ]] && success "Swap restauré ($SWAP kB)." || info "Aucune partition swap."

# ─── 6. Conteneurs et images Docker ───────────────────────────────────────────
section "6 · Suppression des conteneurs et images Docker"

if command -v docker &>/dev/null; then
    for name in sonarqube juiceshop cyberwatch-test; do
        if sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
            sudo docker stop "$name" 2>/dev/null || true
            sudo docker rm   "$name" 2>/dev/null || true
            success "Conteneur $name supprimé."
        fi
    done
    sudo docker ps -aq -f status=exited 2>/dev/null \
        | xargs sudo docker rm 2>/dev/null || true
    for img in sonarqube:community bkimminich/juice-shop \
               aquasec/kube-bench:v0.8.0 curlimages/curl:8.11.0; do
        sudo docker rmi "$img" 2>/dev/null && success "Image $img supprimée." || true
    done
    sudo docker volume prune -f 2>/dev/null || true
    sudo docker image prune -f  2>/dev/null || true
    success "Conteneurs et images nettoyés."
else
    info "Docker non disponible — skipping."
fi

# ─── 7. Désinstallation Docker et outils ──────────────────────────────────────
section "7 · Désinstallation Docker, Trivy, Hadolint, Node.js, outils Python"

sudo systemctl stop docker docker.socket 2>/dev/null || true
sudo systemctl disable docker docker.socket 2>/dev/null || true
sudo apt-get remove -y --purge docker.io docker-compose 2>/dev/null || true
sudo rm -rf /var/lib/docker /etc/docker
sudo rm -f /var/run/docker.sock
sudo gpasswd -d "$USER" docker 2>/dev/null || true
sudo groupdel docker 2>/dev/null || true

sudo apt-get remove -y --purge trivy 2>/dev/null || true
sudo rm -f /usr/share/keyrings/trivy.gpg
sudo rm -f /etc/apt/sources.list.d/trivy.list

sudo rm -f /usr/local/bin/hadolint

sudo apt-get remove -y --purge nodejs 2>/dev/null || true
sudo rm -f /etc/apt/sources.list.d/nodesource.list* 2>/dev/null || true

pip3 uninstall -y bandit semgrep safety 2>/dev/null || true
sudo npm uninstall -g snyk 2>/dev/null || true

sudo apt-get autoremove -y 2>/dev/null || true
success "Docker et outils supprimés."

# ─── 8. Nettoyage ~/.bashrc ───────────────────────────────────────────────────
section "8 · Nettoyage des entrées dans ~/.bashrc"

if [ -f "$HOME/.bashrc" ]; then
    # Supprimer les lignes ajoutées par le script d'installation
    sed -i '/KUBECONFIG/d' "$HOME/.bashrc" 2>/dev/null || true
    sed -i '/alias k=kubectl/d' "$HOME/.bashrc" 2>/dev/null || true
    sed -i '/kubectl completion bash/d' "$HOME/.bashrc" 2>/dev/null || true
    sed -i '/__start_kubectl/d' "$HOME/.bashrc" 2>/dev/null || true
    sed -i '/# kubectl alias/d' "$HOME/.bashrc" 2>/dev/null || true
    sed -i '/\.local\/bin/d' "$HOME/.bashrc" 2>/dev/null || true
    success "~/.bashrc nettoyé."
fi

# ─── 9. Fichiers temporaires ───────────────────────────────────────────────────
section "9 · Nettoyage des fichiers temporaires"

rm -f \
    /tmp/kube-flannel.yml \
    /tmp/kubeadm-config.yaml \
    /tmp/kubeadm-init.log \
    /tmp/cluster-export.yaml \
    /tmp/deployed-images.txt \
    /tmp/checkov-report.json \
    /tmp/trivy-*.json \
    /tmp/snyk-*.json \
    /tmp/bandit-report.json \
    /tmp/semgrep-report.json

sudo apt-get update -qq 2>/dev/null || true
sudo apt-get autoclean -qq 2>/dev/null || true
success "Fichiers temporaires supprimés."

# ─── Vérification finale ──────────────────────────────────────────────────────
section "Vérification finale"

chk_absent() {
    local label="$1" cmd="$2"
    if eval "$cmd" &>/dev/null 2>&1; then
        printf "${YELLOW}[RESTE]${NC}    %s\n" "$label"
    else
        printf "${GREEN}[SUPPRIMÉ]${NC} %s\n" "$label"
    fi
}

chk_absent "docker"           "command -v docker"
chk_absent "trivy"            "command -v trivy"
chk_absent "hadolint"         "command -v hadolint"
chk_absent "node"             "command -v node"
chk_absent "kubectl"          "command -v kubectl"
chk_absent "kubeadm"          "command -v kubeadm"
chk_absent "kubelet service"  "systemctl is-active kubelet"
chk_absent "containerd"       "systemctl is-active containerd"
chk_absent "helm"             "command -v helm"
chk_absent "/etc/kubernetes"  "ls /etc/kubernetes"
chk_absent "/var/lib/etcd"    "ls /var/lib/etcd"
chk_absent "~/.kube"          "ls $HOME/.kube"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Nettoyage terminé.                                 ║"
echo "║   La machine est prête pour une réinstallation.      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
