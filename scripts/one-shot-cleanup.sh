#!/usr/bin/env bash
# =============================================================================
# one-shot-cleanup.sh — Nettoyage complet DevSecOps Labs
# =============================================================================
#
# OS          : Ubuntu 22.04 LTS ou Ubuntu 24.04 LTS
# Utilisateur : ubuntu
#
# UTILISATION
#   chmod +x one-shot-cleanup.sh
#   ./one-shot-cleanup.sh
#
# CE QUI EST SUPPRIMÉ
#   Cluster Kubernetes (kubeadm reset)
#   kubelet, kubeadm, kubectl
#   containerd
#   Flannel (CNI + fichiers réseau)
#   Helm
#   Docker
#   Node.js 20
#   Fichiers de configuration et données résiduelles
#   Alias et exports dans ~/.bashrc
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

export DEBIAN_FRONTEND=noninteractive

# ─── 0. Confirmation ─────────────────────────────────────────────────────────
section "0 · Confirmation"

echo -e "${RED}ATTENTION : ce script supprime entièrement l'environnement installé.${NC}"
echo ""
echo "  Ce qui sera supprimé :"
echo "    - Cluster Kubernetes et toutes ses données"
echo "    - kubelet / kubeadm / kubectl"
echo "    - containerd"
echo "    - Flannel"
echo "    - Helm"
echo "    - Docker et toutes les images/conteneurs"
echo "    - Node.js"
echo "    - Fichiers de configuration résiduels"
echo ""
read -rp "Confirmer la suppression ? [oui/NON] : " CONFIRM
[[ "$CONFIRM" == "oui" ]] || { echo "Annulé."; exit 0; }

# ─── 1. Kubernetes — reset du cluster ────────────────────────────────────────
section "1 · Reset du cluster Kubernetes"

if command -v kubeadm &>/dev/null; then
    info "kubeadm reset en cours..."
    sudo kubeadm reset -f 2>/dev/null || true
    success "kubeadm reset terminé."
else
    warn "kubeadm non trouvé — skip."
fi

# Supprimer les fichiers CNI et réseau Flannel
info "Suppression des interfaces réseau Flannel..."
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete cni0       2>/dev/null || true
sudo ip link delete kube-bridge 2>/dev/null || true

info "Suppression des fichiers CNI..."
sudo rm -rf /etc/cni /opt/cni /var/lib/cni

info "Nettoyage des règles iptables..."
sudo iptables -F 2>/dev/null || true
sudo iptables -t nat -F 2>/dev/null || true
sudo iptables -t mangle -F 2>/dev/null || true
sudo iptables -X 2>/dev/null || true

success "Réseau Kubernetes nettoyé."

# ─── 2. Suppression des composants Kubernetes ────────────────────────────────
section "2 · Suppression de kubelet / kubeadm / kubectl"

sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
sudo apt-get remove -y --purge kubelet kubeadm kubectl 2>/dev/null || true
sudo apt-get autoremove -y 2>/dev/null || true

info "Suppression des fichiers Kubernetes résiduels..."
sudo rm -rf \
    /etc/kubernetes \
    /var/lib/etcd \
    /var/lib/kubelet \
    /var/lib/kube-proxy \
    /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    /etc/apt/sources.list.d/kubernetes.list \
    /etc/default/kubelet \
    "$HOME/.kube"

success "kubelet / kubeadm / kubectl supprimés."

# ─── 3. containerd ───────────────────────────────────────────────────────────
section "3 · Suppression de containerd"

sudo systemctl stop containerd 2>/dev/null || true
sudo systemctl disable containerd 2>/dev/null || true
sudo apt-get remove -y --purge containerd.io 2>/dev/null || true
sudo apt-get autoremove -y 2>/dev/null || true

info "Suppression des fichiers containerd..."
sudo rm -rf \
    /etc/containerd \
    /var/lib/containerd \
    /run/containerd \
    /usr/share/keyrings/docker.gpg \
    /etc/apt/sources.list.d/docker.list

success "containerd supprimé."

# ─── 4. Helm ─────────────────────────────────────────────────────────────────
section "4 · Suppression de Helm"

if command -v helm &>/dev/null; then
    sudo rm -f /usr/local/bin/helm
    rm -rf "$HOME/.config/helm" "$HOME/.cache/helm" "$HOME/.local/share/helm"
    success "Helm supprimé."
else
    warn "Helm non trouvé — skip."
fi

# ─── 5. Docker ───────────────────────────────────────────────────────────────
section "5 · Suppression de Docker"

if command -v docker &>/dev/null; then
    info "Arrêt de tous les conteneurs en cours..."
    sudo docker stop $(sudo docker ps -aq) 2>/dev/null || true
    sudo docker rm -f $(sudo docker ps -aq) 2>/dev/null || true

    info "Suppression de toutes les images Docker..."
    sudo docker rmi -f $(sudo docker images -aq) 2>/dev/null || true

    info "Nettoyage des volumes et réseaux Docker..."
    sudo docker volume prune -f 2>/dev/null || true
    sudo docker network prune -f 2>/dev/null || true
    sudo docker system prune -af --volumes 2>/dev/null || true

    info "Désinstallation de Docker..."
    sudo systemctl stop docker 2>/dev/null || true
    sudo systemctl disable docker 2>/dev/null || true
    sudo apt-get remove -y --purge docker.io docker-compose docker-compose-plugin 2>/dev/null || true
    sudo apt-get autoremove -y 2>/dev/null || true

    info "Suppression des fichiers Docker résiduels..."
    sudo rm -rf \
        /var/lib/docker \
        /var/lib/docker-engine \
        /etc/docker \
        /var/run/docker.sock \
        /usr/libexec/docker

    success "Docker supprimé."
else
    warn "Docker non trouvé — skip."
fi

# ─── 6. Node.js ──────────────────────────────────────────────────────────────
section "6 · Suppression de Node.js"

if command -v node &>/dev/null; then
    sudo apt-get remove -y --purge nodejs 2>/dev/null || true
    sudo apt-get autoremove -y 2>/dev/null || true
    sudo rm -f /etc/apt/sources.list.d/nodesource.list
    sudo rm -f /usr/share/keyrings/nodesource.gpg
    sudo rm -rf "$HOME/.npm" "$HOME/.node_repl_history"
    success "Node.js supprimé."
else
    warn "Node.js non trouvé — skip."
fi

# ─── 7. Fichiers système résiduels ───────────────────────────────────────────
section "7 · Nettoyage des fichiers système résiduels"

info "Suppression des modules kernel Kubernetes..."
sudo rm -f /etc/modules-load.d/k8s.conf
sudo rm -f /etc/sysctl.d/k8s.conf

info "Suppression de la config needrestart..."
sudo rm -f /etc/needrestart/conf.d/autorestart.conf

info "Suppression des fichiers temporaires..."
sudo rm -f \
    /tmp/kubeadm-config.yaml \
    /tmp/kubeadm-init.log \
    /tmp/kube-flannel.yml

info "Réactivation du swap..."
sudo sed -i '/\bswap\b/s/^#//' /etc/fstab 2>/dev/null || true
sudo systemctl unmask swap.target 2>/dev/null || true
sudo swapon -a 2>/dev/null || true

info "Restauration des sysctl par défaut..."
sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=0 2>/dev/null || true

success "Fichiers système nettoyés."

# ─── 8. Nettoyage de ~/.bashrc ───────────────────────────────────────────────
section "8 · Nettoyage de ~/.bashrc"

info "Suppression des alias et exports ajoutés par l'installation..."

# Supprimer les blocs ajoutés par le script d'installation
sed -i '/# kubectl alias/d'                          "$HOME/.bashrc" 2>/dev/null || true
sed -i '/alias k=kubectl/d'                          "$HOME/.bashrc" 2>/dev/null || true
sed -i '/# Complétion kubectl/d'                     "$HOME/.bashrc" 2>/dev/null || true
sed -i '/source <(kubectl completion bash)/d'        "$HOME/.bashrc" 2>/dev/null || true
sed -i '/complete -o default -F __start_kubectl k/d' "$HOME/.bashrc" 2>/dev/null || true
sed -i '/export KUBECONFIG/d'                        "$HOME/.bashrc" 2>/dev/null || true
sed -i '/\.local\/bin/d'                             "$HOME/.bashrc" 2>/dev/null || true

success "~/.bashrc nettoyé."

# ─── 9. apt autoremove final ─────────────────────────────────────────────────
section "9 · Nettoyage apt final"

sudo apt-get autoremove -y 2>/dev/null || true
sudo apt-get autoclean  -y 2>/dev/null || true
success "Cache apt nettoyé."

# ─── Vérification finale ─────────────────────────────────────────────────────
section "Vérification finale"

chk_absent() {
    if ! command -v "$2" &>/dev/null 2>&1; then
        printf "${GREEN}[SUPPRIMÉ]${NC}  %s\n" "$1"
    else
        printf "${YELLOW}[PRÉSENT]${NC}   %s — suppression manuelle peut être nécessaire\n" "$1"
    fi
}

chk_absent "kubectl"     "kubectl"
chk_absent "kubeadm"     "kubeadm"
chk_absent "kubelet"     "kubelet"
chk_absent "containerd"  "containerd"
chk_absent "helm"        "helm"
chk_absent "docker"      "docker"
chk_absent "node"        "node"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Nettoyage terminé.                                 ║${NC}"
echo -e "${GREEN}║                                                      ║${NC}"
echo -e "${GREEN}║   Un redémarrage est recommandé pour s'assurer       ║${NC}"
echo -e "${GREEN}║   que tous les modules kernel sont déchargés :       ║${NC}"
echo -e "${GREEN}║     sudo reboot                                      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
