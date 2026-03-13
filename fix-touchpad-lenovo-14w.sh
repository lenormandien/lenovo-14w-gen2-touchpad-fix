#!/bin/bash
# =============================================================================
# Correctif complet pour touchpad ELAN0643 — Lenovo 14w Gen 2 (82N9)
# Applique les corrections _DSM et _CRS, puis installe les tables ACPI.
# =============================================================================

set -euo pipefail

# --- Couleurs ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warning() { echo -e "${YELLOW}[ATTENTION]${NC} $1"; }
error()   { echo -e "${RED}[ERREUR]${NC} $1"; exit 1; }

# --- Vérifications préliminaires ---
if [ "$EUID" -ne 0 ]; then
    error "Exécute ce script en root : sudo bash $0"
fi

WORKDIR=$(mktemp -d /tmp/acpi-fix-XXXXXX)
info "Répertoire de travail : $WORKDIR"
cd "$WORKDIR"

# --- Extraction des tables ACPI ---
info "Extraction des tables ACPI..."
mkdir -p acpi/dat acpi/dsl
cd acpi/dat
acpidump -b || error "Échec de l'extraction ACPI."
iasl -d *.dat || error "Échec de la décompilation."
mv *.dsl ../dsl
cd "$WORKDIR"
success "Tables ACPI extraites."

DSDT="$WORKDIR/acpi/dsl/dsdt.dsl"
[ -f "$DSDT" ] || error "Fichier DSDT introuvable."

# --- Sauvegarde du DSDT original ---
cp "$DSDT" "${DSDT}.bak"
info "Sauvegarde créée : ${DSDT}.bak"

# --- Application des corrections ---
info "Application des corrections..."

# Correction 1 : _DSM (Case 0x01)
# Correction 2 : _CRS (If -> Else)
python3 - "$DSDT" << 'PYEOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# --- Correction 1 : _DSM (Case 0x01) ---
old_dsm = (
    'Return (0x01)\n'
    '                            }\n'
    '\n'
    '                            If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))\n'
    '                            {\n'
    '                                Return (0x20)\n'
    '                            }'
)
new_dsm = (
    'Return (0x01)\n'
    '                            }\n'
    '                            Else\n'
    '                            // If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))\n'
    '                            {\n'
    '                                Return (0x20)\n'
    '                            }'
)
if old_dsm in content:
    content = content.replace(old_dsm, new_dsm, 1)
    print("  [OK] Correction _DSM appliquée.")
else:
    print("  [ATTENTION] Correction _DSM : motif non trouvé.")

# --- Correction 2 : _CRS (If -> Else) ---
old_crs = (
    'Return (ConcatenateResTemplate (SBFB, SBFG))\n'
    '                }\n'
    '                If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))\n'
    '                {\n'
    '                    Name (SBFC'
)
new_crs = (
    'Return (ConcatenateResTemplate (SBFB, SBFG))\n'
    '                }\n'
    '                Else\n'
    '                // If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))\n'
    '                {\n'
    '                    Name (SBFC'
)
if old_crs in content:
    content = content.replace(old_crs, new_crs, 1)
    print("  [OK] Correction _CRS appliquée.")
else:
    # Si le motif n'est pas trouvé, applique la correction manuellement pour ton cas spécifique
    crs_pattern = re.compile(
        r'If \(\(.*TPTY.*== 0x01\)\)\n'
        r'\s*\{\n'
        r'.*?Return \(ConcatenateResTemplate \(SBFB, SBFG\)\)\n'
        r'\s*\}\n'
        r'\s*If \(\(.*TPTY.*== 0x02\)\)\n'
        r'\s*\{'
    )
    crs_replacement = (
        'If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))\n'
        '                {\n'
        '                    Name (SBFB, ResourceTemplate ()\n'
        '                    {\n'
        '                        I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,\n'
        '                            AddressingMode7Bit, "\\_SB.I2CD",\n'
        '                            0x00, ResourceConsumer, , Exclusive,\n'
        '                            )\n'
        '                    })\n'
        '                    Return (ConcatenateResTemplate (SBFB, SBFG))\n'
        '                }\n'
        '                Else\n'
        '                // If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))\n'
        '                {\n'
        '                    Name (SBFC, ResourceTemplate ()\n'
        '                    {\n'
        '                        I2cSerialBusV2 (0x002C, ControllerInitiated, 0x00061A80,\n'
        '                            AddressingMode7Bit, "\\_SB.I2CD",\n'
        '                            0x00, ResourceConsumer, , Exclusive,\n'
        '                            )\n'
        '                    })\n'
        '                    Return (ConcatenateResTemplate (SBFC, SBFG))\n'
        '                }'
    )
    if crs_pattern.search(content):
        content = crs_pattern.sub(crs_replacement, content, 1)
        print("  [OK] Correction _CRS appliquée (version adaptée).")
    else:
        print("  [ATTENTION] Correction _CRS : motif non trouvé. Vérifie manuellement.")

with open(sys.argv[1], 'w') as f:
    f.write(content)
PYEOF

success "Correctifs appliqués."

# --- Recompilation ---
info "Recompilation du DSDT..."
cp "$DSDT" "$WORKDIR/dsdt.dsl"
cd "$WORKDIR"
iasl -sa dsdt.dsl || error "Erreur de recompilation."
success "DSDT recompilé."

# --- Installation ---
info "Installation des tables ACPI..."
mkdir -p kernel/firmware/acpi
cp dsdt.aml kernel/firmware/acpi/
find kernel | cpio -H newc --create > /boot/initrd_acpi_patched
echo 'GRUB_EARLY_INITRD_LINUX_CUSTOM="initrd_acpi_patched"' > /etc/default/grub.d/acpi-tables.cfg
update-grub || error "Erreur de mise à jour GRUB."
success "Tables ACPI installées."

# --- Nettoyage ---
cd /
rm -rf "$WORKDIR"
success "Nettoyage terminé."

# --- Instructions finales ---
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   Correctif appliqué avec succès !${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  👉 Redémarre ton laptop pour activer le correctif :"
echo -e "     ${YELLOW}reboot${NC}"
echo ""
echo -e "  Après redémarrage, vérifie le touchpad avec :"
echo -e "     ${YELLOW}dmesg | grep -i elan${NC}"
echo -e "     ${YELLOW}libinput list-devices${NC}"
echo ""
