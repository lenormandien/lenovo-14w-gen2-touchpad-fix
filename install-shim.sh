#!/bin/bash
# =============================================================================
# Installation du module kernel elan0643_shim
# Lenovo 14w Gen 2 — Fix touchpad ELAN0643
#
# Ce module crée le lien ACPI→i2c manquant entre ELAN0643 et le bus i2c
# en passant le firmware_node ACPI à i2c_new_client_device, ce qui permet
# à elan_i2c de résoudre le GPIO IRQ correctement.
#
# Usage : sudo bash install-shim.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
error()   { echo -e "${RED}[ERREUR]${NC} $1"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}>>> $1${NC}"; }

[ "$EUID" -eq 0 ] || error "Relance avec : sudo bash $0"

echo ""
echo -e "${BOLD}${BLUE}============================================================${NC}"
echo -e "${BOLD}${BLUE}   Installation module elan0643_shim — Lenovo 14w Gen 2${NC}"
echo -e "${BOLD}${BLUE}============================================================${NC}"
echo -e "  Kernel : $(uname -r)"
echo ""

# =============================================================================
step "Étape 1 — Vérifications"
# =============================================================================

[ -f "elan0643_shim.c" ] || error "elan0643_shim.c introuvable dans $(pwd)"
[ -f "Makefile" ] || error "Makefile introuvable dans $(pwd)"
[ -d "/lib/modules/$(uname -r)/build" ] || error "linux-headers-$(uname -r) non installé"

for tool in make gcc modprobe depmod; do
    command -v "$tool" &>/dev/null || /sbin/$tool --version &>/dev/null || \
        error "$tool introuvable"
done
success "Prérequis OK"

# =============================================================================
step "Étape 2 — Compilation"
# =============================================================================

info "Compilation du module..."
make clean 2>/dev/null || true
make KVER=$(uname -r) || error "Compilation échouée"
[ -f "elan0643_shim.ko" ] || error "elan0643_shim.ko non généré"
success "Module compilé : elan0643_shim.ko"

# =============================================================================
step "Étape 3 — Installation"
# =============================================================================

info "Installation dans /lib/modules/$(uname -r)/extra/..."
make install KVER=$(uname -r) || error "Installation échouée"
success "Module installé"

# =============================================================================
step "Étape 4 — Configuration chargement automatique"
# =============================================================================

info "Suppression de l'ancienne config new_device si présente..."
# Le shim remplace la création manuelle via new_device dans le service
SERVICE_SCRIPT="/usr/local/lib/elan0643-touchpad-init.sh"
if [ -f "$SERVICE_SCRIPT" ]; then
    # Désactiver le service systemd existant qui faisait new_device manuel
    systemctl disable elan0643-touchpad.service 2>/dev/null || true
    info "Service elan0643-touchpad.service désactivé (remplacé par le module)"
fi

info "Configuration du chargement automatique..."
cat > /etc/modules-load.d/elan0643.conf << 'EOF'
# Modules pour touchpad ELAN0643 — Lenovo 14w Gen 2
elan_i2c
elan0643_shim
EOF
success "Modules configurés dans /etc/modules-load.d/elan0643.conf"

# =============================================================================
step "Étape 5 — Test immédiat"
# =============================================================================

info "Chargement du module en live..."
/sbin/modprobe elan_i2c 2>/dev/null || true
/sbin/rmmod elan0643_shim 2>/dev/null || true
/sbin/modprobe elan0643_shim

sleep 2
dmesg | grep -i "elan0643_shim\|elan_i2c.*1-0015\|Touchpad\|irq" | tail -15

info "Vérification device i2c..."
ls /sys/bus/i2c/devices/ | grep "1-" && \
    success "Device i2c créé !" || \
    error "Device i2c non créé — voir dmesg"

PHYS=$(readlink -f /sys/bus/acpi/devices/ELAN0643:00/physical_node 2>/dev/null || echo "")
if echo "$PHYS" | grep -q "i2c"; then
    success "ELAN0643 lié au bus i2c : $PHYS"
    DRV=$(readlink "$PHYS/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "aucun")
    info "Driver : $DRV"
    [ "$DRV" = "elan_i2c" ] && success "Touchpad actif !" || \
        error "Driver incorrect : $DRV"
else
    dmesg | grep -i "elan\|irq\|1-0015" | tail -10
    error "ELAN0643 non lié au bus i2c"
fi

echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}   Module installé avec succès !${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "  👉 Vérifie le touchpad :"
echo -e "     ${YELLOW}libinput list-devices | grep -A10 Touchpad${NC}"
echo ""
echo -e "  Le module sera chargé automatiquement au prochain reboot."
echo -e "  Vérifie après reboot avec :"
echo -e "     ${YELLOW}dmesg | grep -i elan${NC}"
echo ""
