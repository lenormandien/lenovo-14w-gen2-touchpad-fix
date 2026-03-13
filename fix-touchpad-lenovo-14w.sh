#!/bin/bash
# =============================================================================
# Installation du DSDT corrigé pour ELAN0643 — Lenovo 14w Gen 2
#
# Correctifs appliqués dans dsdt.dsl :
#   1. _DSM ELAN0643 : If (TPTY==0x02) → Else (fix adresse I2C)
#   2. _CRS ELAN0643 : If (TPTY==0x02) → Else (fix adresse I2C)
#   3. I2CD _S0W     : Return(0x04) → Return(0x00) (interdit D3hot en S0)
#   4. I2CD _PS3     : neutralisé (empêche la mise en veille du contrôleur)
#
# Utilise le fichier dsdt.dsl déjà présent dans le répertoire courant.
# Usage : sudo bash install-dsdt-elan0643.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[ATTENTION]${NC} $1"; }
error()   { echo -e "${RED}[ERREUR]${NC} $1"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}>>> $1${NC}"; }
detail()  { echo -e "    $1"; }

echo ""
echo -e "${BOLD}${BLUE}============================================================${NC}"
echo -e "${BOLD}${BLUE}   Installation DSDT — Touchpad ELAN0643 Lenovo 14w Gen 2${NC}"
echo -e "${BOLD}${BLUE}============================================================${NC}"
echo -e "  Script    : $0"
echo -e "  Répertoire: $(pwd)"
echo -e "  Date      : $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  Kernel    : $(uname -r)"
echo -e "${BLUE}------------------------------------------------------------${NC}"

# =============================================================================
step "Étape 0 — Vérifications préliminaires"
# =============================================================================

info "Vérification des privilèges root..."
if [ "$EUID" -ne 0 ]; then
    error "Ce script doit être exécuté en root.\n    Relance avec : sudo bash $0"
fi
success "Privilèges root confirmés (UID=0)."

info "Recherche des outils nécessaires : iasl, cpio, update-grub..."
MISSING=()
for tool in iasl cpio update-grub; do
    if command -v "$tool" &> /dev/null; then
        detail "✔ $tool → $(command -v "$tool")"
    else
        detail "✘ $tool → introuvable"
        MISSING+=("$tool")
    fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
    warning "Outils manquants : ${MISSING[*]}"
    info "Installation via apt-get..."
    apt-get update -qq
    apt-get install -y acpica-tools cpio || error "Échec de l'installation des outils."
    success "Outils installés."
else
    success "Tous les outils sont disponibles."
fi

info "Recherche du fichier dsdt.dsl dans le répertoire courant..."
if [ ! -f "dsdt.dsl" ]; then
    error "Fichier 'dsdt.dsl' introuvable dans $(pwd).\n    Place ce script au même endroit que dsdt.dsl et relance."
fi
detail "Fichier trouvé : $(pwd)/dsdt.dsl"
detail "Taille         : $(wc -l < dsdt.dsl) lignes, $(du -h dsdt.dsl | cut -f1)"
success "dsdt.dsl présent."

info "Vérification des correctifs dans dsdt.dsl..."
PATCH_OK=0

if grep -q "//If.*TPTY.*0x02\|// If.*TPTY.*0x02" dsdt.dsl; then
    detail "✔ Patch ELAN0643 _DSM/_CRS (TPTY→Else) : présent"
    PATCH_OK=$((PATCH_OK + 1))
else
    warning "✘ Patch ELAN0643 _DSM/_CRS : NON TROUVÉ"
fi

if grep -q "Fix ELAN0643: forcer D0" dsdt.dsl; then
    detail "✔ Patch I2CD _S0W (Return 0x00) : présent"
    PATCH_OK=$((PATCH_OK + 1))
else
    warning "✘ Patch I2CD _S0W : NON TROUVÉ — le contrôleur risque de rester en D3hot"
fi

if grep -q "Fix ELAN0643: neutralisé" dsdt.dsl; then
    detail "✔ Patch I2CD _PS3 (neutralisé) : présent"
    PATCH_OK=$((PATCH_OK + 1))
else
    warning "✘ Patch I2CD _PS3 : NON TROUVÉ"
fi

if [ "$PATCH_OK" -lt 2 ]; then
    warning "Seulement $PATCH_OK/3 groupes de correctifs détectés."
    read -rp "    Continuer quand même ? (o/N) : " CONFIRM
    [[ "$CONFIRM" =~ ^[oO]$ ]] || exit 0
else
    success "$PATCH_OK/3 groupes de correctifs confirmés dans dsdt.dsl."
fi

# =============================================================================
step "Étape 1 — Recompilation du DSDT"
# =============================================================================

info "Lancement de iasl -sa dsdt.dsl..."
echo -e "${CYAN}-------- sortie iasl --------${NC}"
if ! iasl -sa dsdt.dsl; then
    echo -e "${CYAN}-----------------------------${NC}"
    error "iasl a signalé une erreur. Vérifie la syntaxe de dsdt.dsl."
fi
echo -e "${CYAN}-----------------------------${NC}"

info "Vérification de la génération de dsdt.aml..."
if [ ! -f "dsdt.aml" ]; then
    error "dsdt.aml non généré malgré un exit code 0."
fi
detail "Fichier généré : $(pwd)/dsdt.aml"
detail "Taille         : $(du -h dsdt.aml | cut -f1)"
success "DSDT recompilé avec succès."

# =============================================================================
step "Étape 2 — Construction de l'archive initrd ACPI"
# =============================================================================

WORKDIR=$(mktemp -d /tmp/acpi-fix-XXXXXX)
info "Répertoire de travail temporaire : $WORKDIR"

info "Création de la structure kernel/firmware/acpi/..."
mkdir -p "$WORKDIR/kernel/firmware/acpi"
detail "Structure : $WORKDIR/kernel/firmware/acpi/"

info "Copie de dsdt.aml dans l'arborescence..."
cp dsdt.aml "$WORKDIR/kernel/firmware/acpi/"
detail "Copié     : $WORKDIR/kernel/firmware/acpi/dsdt.aml"
success "Arborescence prête."

info "Génération de l'archive cpio /boot/initrd_acpi_patched..."
CPIO_FILES=$(cd "$WORKDIR" && find kernel | wc -l)
detail "Fichiers à archiver : $CPIO_FILES"
(cd "$WORKDIR" && find kernel | cpio -H newc --create) > /boot/initrd_acpi_patched
detail "Archive produite  : /boot/initrd_acpi_patched"
detail "Taille            : $(du -h /boot/initrd_acpi_patched | cut -f1)"
success "Archive /boot/initrd_acpi_patched créée."

# =============================================================================
step "Étape 3 — Configuration de GRUB"
# =============================================================================

GRUB_CONF="/etc/default/grub.d/acpi-tables.cfg"
info "Création du fichier de configuration GRUB : $GRUB_CONF"
mkdir -p /etc/default/grub.d
echo 'GRUB_EARLY_INITRD_LINUX_CUSTOM="initrd_acpi_patched"' > "$GRUB_CONF"
detail "Contenu : $(cat "$GRUB_CONF")"
success "Fichier $GRUB_CONF écrit."

info "Mise à jour de la configuration GRUB (update-grub)..."
echo -e "${CYAN}-------- sortie update-grub --------${NC}"
if ! update-grub; then
    echo -e "${CYAN}-----------------------------------${NC}"
    error "update-grub a échoué."
fi
echo -e "${CYAN}-----------------------------------${NC}"
success "GRUB mis à jour avec succès."

# =============================================================================
step "Étape 4 — Nettoyage"
# =============================================================================

info "Suppression du répertoire de travail temporaire : $WORKDIR"
rm -rf "$WORKDIR"
success "Nettoyage terminé."

# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo -e "${BOLD}${GREEN}   DSDT corrigé installé avec succès !${NC}"
echo -e "${BOLD}${GREEN}============================================================${NC}"
echo ""
echo -e "  Correctifs appliqués :"
echo -e "    ${CYAN}[1/4]${NC} ELAN0643 _DSM  : If (TPTY==0x02) → Else"
echo -e "    ${CYAN}[2/4]${NC} ELAN0643 _CRS  : If (TPTY==0x02) → Else"
echo -e "    ${CYAN}[3/4]${NC} I2CD _S0W      : Return(0x04)    → Return(0x00)"
echo -e "    ${CYAN}[4/4]${NC} I2CD _PS3      : DSAD(0x08,0x03) → neutralisé"
echo ""
echo -e "  Fichiers installés :"
echo -e "    ${CYAN}/boot/initrd_acpi_patched${NC}  ($(du -h /boot/initrd_acpi_patched | cut -f1))"
echo -e "    ${CYAN}$GRUB_CONF${NC}"
echo ""
echo -e "  👉 Redémarre pour activer le correctif :"
echo -e "     ${YELLOW}reboot${NC}"
echo ""
echo -e "  Après redémarrage, vérifie que le touchpad est reconnu :"
echo -e "     ${YELLOW}dmesg | grep -i elan${NC}"
echo -e "     ${YELLOW}libinput list-devices | grep -A 10 Touchpad${NC}"
echo ""
echo -e "  En cas de problème :"
echo -e "     ${YELLOW}rm $GRUB_CONF && update-grub${NC}"
echo ""
