#!/usr/bin/env bash
# =============================================================================
# one-shot-installation.sh — Installation complète DevSecOps Labs
# =============================================================================
#
# OS          : Ubuntu 22.04 LTS ou Ubuntu 24.04 LTS
# Instance EC2: t3.large (2 vCPU, 8 Go RAM), 50 Go
# Utilisateur : ubuntu
#
# UTILISATION
#   chmod +x one-shot-installation.sh
#   ./one-shot-installation.sh
#
# CE QUI EST INSTALLÉ
#   Docker, Node.js 20
#   containerd, kubeadm v1.30, kubelet, kubectl, Flannel, Helm
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() {
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
}

# ─── 0. Vérifications préalables ─────────────────────────────────────────────
section "0 · Vérifications préalables"

[ -f /etc/os-release ] || error "Impossible de détecter l'OS."
. /etc/os-release
info "Système : ${PRETTY_NAME}"
[[ "$ID" == "ubuntu" ]] || warn "Ce script est optimisé pour Ubuntu."

AVAIL_KB=$(df / --output=avail -k | tail -1)
[[ $AVAIL_KB -ge 40000000 ]] || warn "Moins de 40 Go disponibles — 50 Go recommandés."

# Supprimer les warnings QEMU / needrestart
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
sudo mkdir -p /etc/needrestart/conf.d/
echo "\$nrconf{restart} = 'a';" \
    | sudo tee /etc/needrestart/conf.d/autorestart.conf > /dev/null 2>&1 || true

# Détecter l'interface réseau principale (eth0 sur Ubuntu 22.04, ens5 sur 24.04 EC2)
PRIMARY_IFACE=$(ip -o -4 route show to default \
    | awk '{print $5}' | head -1)
info "Interface réseau principale : ${PRIMARY_IFACE}"
[[ -n "$PRIMARY_IFACE" ]] || error "Interface réseau non détectée."

success "Vérifications OK."

# ─── 1. Mise à jour système ───────────────────────────────────────────────────
section "1 · Mise à jour des paquets système"

# Supprimer toute entrée NodeSource résiduelle avant apt-get update
# (évite l'erreur GPG NO_PUBKEY 2F59B5F99B1BE0B4 sur les re-runs)
sudo rm -f \
    /etc/apt/sources.list.d/nodesource.list \
    /etc/apt/sources.list.d/nodistro.list \
    /usr/share/keyrings/nodesource.gpg \
    /usr/share/keyrings/nodesource.asc

sudo apt-get update -qq
sudo apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release git wget unzip \
    apt-transport-https software-properties-common \
    socat conntrack ipset jq python3 python3-pip

success "Système mis à jour."


# ─── 2. Docker ───────────────────────────────────────────────────────────────
section "2 · Docker"

sudo apt-get install -y -qq docker.io docker-compose
sudo systemctl enable docker
sudo systemctl start docker

# Attendre que le daemon Docker soit prêt (max 30s)
info "Attente du daemon Docker..."
for i in $(seq 1 15); do
    sudo docker version &>/dev/null 2>&1 && break
    sleep 2
    [ $i -eq 15 ] && warn "Docker daemon lent à démarrer — poursuite quand même."
done


# Le socket est /run/docker.sock sur Ubuntu 22.04+ (/ var/run est un symlink)
# On chmod les deux pour couvrir toutes les versions
sudo chmod 666 /run/docker.sock 2>/dev/null || true
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
success "Docker installé et opérationnel : $(docker --version)"

# ─── 3. Node.js 20 LTS ───────────────────────────────────────────────────────
section "3 · Node.js 20 LTS"

if command -v node &>/dev/null; then
    success "Node.js déjà installé : $(node --version)"
else
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - 2>/dev/null
    sudo apt-get install -y -qq nodejs
    success "Node.js installé : $(node --version)"
fi

# ─── 4. Swap désactivé ───────────────────────────────────────────────────────
section "4 · Désactivation du swap (Kubernetes)"

sudo swapoff -a
sudo sed -i '/\bswap\b/s/^/#/' /etc/fstab
sudo systemctl mask swap.target 2>/dev/null || true
success "Swap désactivé."

# ─── 5. Modules kernel ──────────────────────────────────────────────────────
section "5 · Modules kernel et sysctl"

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system -q
success "Modules kernel et sysctl configurés."

# ─── 6. containerd ──────────────────────────────────────────────────────────
section "6 · containerd (container runtime)"

if ! systemctl is-active containerd &>/dev/null; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/docker.gpg 2>/dev/null || true
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -sc) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq containerd.io
fi

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo sed -i '/disabled_plugins.*cri/d' /etc/containerd/config.toml
sudo systemctl enable containerd
sudo systemctl restart containerd

for i in $(seq 1 10); do
    systemctl is-active containerd &>/dev/null && break || sleep 2
done
success "containerd installé et configuré."

# ─── 7. kubeadm / kubelet / kubectl v1.30 ───────────────────────────────────
section "7 · kubeadm / kubelet / kubectl v1.30"

if ! command -v kubectl &>/dev/null; then
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
        | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
        | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
fi

# Fix iptables-legacy pour AWS EC2 (nftables → iptables)
if command -v update-alternatives &>/dev/null; then
    sudo update-alternatives --set iptables  /usr/sbin/iptables-legacy  2>/dev/null || true
    sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
fi

# Configurer kubelet avec l'IP privée EC2
EC2_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
LOCAL_IP=$(curl -sf -H "X-aws-ec2-metadata-token: ${EC2_TOKEN}" \
    http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null \
    || hostname -I | awk '{print $1}')
echo "KUBELET_EXTRA_ARGS=--node-ip=${LOCAL_IP}" \
    | sudo tee /etc/default/kubelet > /dev/null

sudo systemctl enable kubelet
success "kubeadm, kubelet, kubectl v1.30 installés."

# ─── 8. Initialisation du cluster single-node ───────────────────────────────
section "8 · Initialisation du cluster Kubernetes"

if [ -f "$HOME/.kube/config" ] && kubectl cluster-info &>/dev/null 2>&1; then
    success "Cluster déjà initialisé et opérationnel."
else
    EC2_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
    LOCAL_IP=$(curl -sf -H "X-aws-ec2-metadata-token: ${EC2_TOKEN}" \
        http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null \
        || hostname -I | awk '{print $1}')
    info "IP locale : ${LOCAL_IP} | Interface : ${PRIMARY_IFACE}"

    # Reset si installation partielle
    if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
        warn "Installation partielle détectée — reset..."
        sudo kubeadm reset -f 2>/dev/null || true
        sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d
        sudo systemctl restart containerd
        sleep 5
    fi

    # ── Config kubeadm ──
    cat > /tmp/kubeadm-config.yaml << KUBEADMEOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.30.0
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${LOCAL_IP}
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    node-ip: ${LOCAL_IP}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
KUBEADMEOF

    sudo kubeadm init \
        --config /tmp/kubeadm-config.yaml \
        --ignore-preflight-errors=NumCPU,Swap \
        2>&1 | tee /tmp/kubeadm-init.log

    grep -q "initialized successfully" /tmp/kubeadm-init.log \
        || error "kubeadm init a échoué — voir /tmp/kubeadm-init.log"

    # ── Configurer kubectl automatiquement ──
    mkdir -p "$HOME/.kube"
    sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
    sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
    chmod 600 "$HOME/.kube/config"
    export KUBECONFIG="$HOME/.kube/config"

    # Attendre l'API server
    info "Attente de l'API server..."
    for i in $(seq 1 30); do
        kubectl cluster-info &>/dev/null 2>&1 && break
        sleep 3
        [ $i -eq 30 ] && error "API server ne répond pas après 90s."
    done
    success "Cluster initialisé — API server opérationnel."
fi

# ─── 9. KUBECONFIG permanent ────────────────────────────────────────────────
section "9 · Configuration permanente kubectl"

grep -q 'KUBECONFIG' "$HOME/.bashrc" 2>/dev/null || \
    echo 'export KUBECONFIG="$HOME/.kube/config"' >> "$HOME/.bashrc"

export KUBECONFIG="$HOME/.kube/config"

success "KUBECONFIG configuré de façon permanente"

# ─── 10. Suppression du taint control-plane ─────────────────────────────────
section "10 · Suppression du taint control-plane"

kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true
success "Nœud schedulable comme worker."

# ─── 11. Flannel (CNI réseau) ───────────────────────────────────────────────
section "11 · Flannel (CNI réseau)"

if kubectl get ds -n kube-flannel kube-flannel-ds &>/dev/null 2>&1; then
    CURRENT_IFACE=$(kubectl get ds kube-flannel-ds -n kube-flannel \
        -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
        | grep -o 'iface=[^ "]*' | cut -d= -f2 || echo "")
    if [ "$CURRENT_IFACE" = "$PRIMARY_IFACE" ]; then
        success "Flannel déjà installé avec l'interface ${PRIMARY_IFACE}."
    else
        warn "Flannel sur interface '${CURRENT_IFACE}' ≠ '${PRIMARY_IFACE}'. Réinstallation..."
        kubectl delete -f https://github.com/flannel-io/flannel/releases/download/v0.26.1/kube-flannel.yml \
            --ignore-not-found 2>/dev/null || true
        sleep 5
    fi
fi

if ! kubectl get ds -n kube-flannel kube-flannel-ds &>/dev/null 2>&1; then
    curl -fsSL \
        "https://github.com/flannel-io/flannel/releases/download/v0.26.1/kube-flannel.yml" \
        -o /tmp/kube-flannel.yml

    if grep -q "iface=eth0" /tmp/kube-flannel.yml; then
        sed -i "s/--iface=eth0/--iface=${PRIMARY_IFACE}/g" /tmp/kube-flannel.yml
    elif grep -q "\-\-kube-subnet-mgr" /tmp/kube-flannel.yml; then
        sed -i "/--kube-subnet-mgr/a\\        - --iface=${PRIMARY_IFACE}" /tmp/kube-flannel.yml
    fi

    info "Flannel configuré avec l'interface : ${PRIMARY_IFACE}"
    kubectl apply -f /tmp/kube-flannel.yml
    rm -f /tmp/kube-flannel.yml
    success "Flannel installé."
fi

# ─── 12. Helm ───────────────────────────────────────────────────────────────
section "12 · Helm v3"

if command -v helm &>/dev/null; then
    success "Helm déjà installé : $(helm version --short)"
else
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
        | DESIRED_VERSION="v3.16.4" bash
    success "Helm installé : $(helm version --short)"
fi

# ─── 13. Attente que le cluster soit Ready ───────────────────────────────────
section "13 · Attente que le cluster soit opérationnel"

info "Attente nœud Ready (max 5 min)..."
for i in $(seq 1 60); do
    STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
    [ "$STATUS" = "Ready" ] && { success "Nœud Ready après $((i*5))s."; break; }
    [ $((i % 12)) -eq 0 ] && info "En attente... $((i*5))s"
    sleep 5
    [ $i -eq 60 ] && warn "Nœud pas encore Ready — vérifier : kubectl get pods -A"
done

info "Attente de Flannel et CoreDNS..."
kubectl wait --for=condition=Ready pod \
    -l app=flannel -n kube-flannel \
    --timeout=120s 2>/dev/null && \
    success "Flannel Ready." || \
    warn "Flannel pas encore Ready — vérifier : kubectl logs -n kube-flannel -l app=flannel"

kubectl wait --for=condition=Ready pod \
    -l k8s-app=kube-dns -n kube-system \
    --timeout=120s 2>/dev/null && \
    success "CoreDNS Ready." || \
    warn "CoreDNS pas encore Ready."

# ─── Vérification finale ─────────────────────────────────────────────────────
section "Vérification finale"

export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

chk() {
    if eval "$2" &>/dev/null 2>&1; then
        printf "${GREEN}[OK]${NC}    %s\n" "$1"
    else
        printf "${RED}[ECHEC]${NC} %s\n" "$1"
    fi
}

chk "Docker engine"      "sudo docker version"
chk "Node.js"            "node --version"
chk "containerd"         "systemctl is-active containerd"
chk "kubelet"            "systemctl is-active kubelet"
chk "kubectl"            "kubectl get nodes"
chk "kubeconfig"         "test -f $HOME/.kube/config"
chk "Flannel Running"    "kubectl get pods -n kube-flannel -l app=flannel --field-selector=status.phase=Running | grep flannel"
chk "Helm"               "helm version"

echo ""
kubectl get nodes -o wide 2>/dev/null || true
echo ""
kubectl get pods -A 2>/dev/null | grep -v "Completed" | head -20 || true

EC2_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)
IP=$(curl -sf -H "X-aws-ec2-metadata-token: ${EC2_TOKEN}" \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null \
    || curl -sf -H "X-aws-ec2-metadata-token: ${EC2_TOKEN}" \
    http://169.254.169.254/latest/meta-data/local-ipv4 2>/dev/null \
    || hostname -I | awk '{print $1}')

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  INFORMATIONS DU CLUSTER                            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  IP publique      : ${GREEN}${IP}${NC}"
echo -e "  API Kubernetes   : https://${IP}:6443"
echo ""
echo -e "  ${BLUE}NodePort Kubernetes (port forwarding SSH) :${NC}"
echo    "    ssh -i <cle.pem> -L 30000:localhost:30000 ubuntu@${IP} -N"
echo    "    Port 30000-32767 → Services NodePort"
echo ""

echo "╔══════════════════════════════════════════════════════╗"
echo "║   Installation terminée avec succès !                ║"
echo "║                                                      ║"
echo "║   Recharger le shell dans cette session :            ║"
echo "║     source ~/.bashrc                                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
