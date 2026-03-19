# Lenovo 14w Gen 2 — Touchpad Fix (ELAN0643 / I2C)

> Correctif DSDT + service systemd pour faire fonctionner le touchpad ELAN0643 sous Linux (testé sur **Linux Mint**).

---

## Le problème

Sur le **Lenovo 14w Gen 2**, le touchpad ELAN0643 est connecté au système via le bus **I2C** et géré par le driver kernel `elan_i2c`. Sous Linux, il ne fonctionne pas avec le DSDT d'origine livré par Lenovo.

### Qu'est-ce que le DSDT ?

Le **DSDT** (Differentiated System Description Table) est une table ACPI stockée dans le firmware BIOS. Elle décrit au système d'exploitation comment interagir avec le matériel : quelles ressources (IRQ, adresses mémoire, bus I2C…) sont assignées à chaque périphérique, comment les mettre sous tension, les suspendre, etc. Linux lit cette table au démarrage pour initialiser les périphériques.

### Pourquoi le touchpad ne fonctionne pas ?

Le DSDT contient une méthode `_CRS` (Current Resource Settings) pour le périphérique touchpad `ELAN0643`. Cette méthode est appelée par le kernel pour savoir sur quel bus I2C et à quelle adresse se trouve le touchpad.

Dans le DSDT d'origine, cette méthode lit une variable `TPTY` (Touchpad Type) depuis l'Embedded Controller (EC — le microcontrôleur qui gère le matériel bas niveau du laptop) :

- Si `TPTY == 0x01` → adresse I2C `0x0015`
- Si `TPTY == 0x02` → adresse I2C `0x002C`
- **Sinon → rien du tout** ❌

Sous Linux, au moment où l'ACPI évalue cette méthode, `TPTY` n'est pas encore initialisée à `0x01` ou `0x02` par l'EC. La méthode `_CRS` termine donc sans retourner aucune ressource. Le kernel ne sait pas où trouver le touchpad → `elan_i2c` n'est jamais chargé → le touchpad est muet.

### Résumé

| Valeur de `TPTY` au boot | DSDT original | DSDT corrigé |
|:---:|:---:|:---:|
| `0x01` | I2C `0x0015` ✅ | I2C `0x0015` ✅ |
| `0x02` | I2C `0x002C` ✅ | I2C `0x002C` ✅ |
| autre (cas Linux) | **Rien** ❌ | I2C `0x002C` ✅ |

---

## Correctifs appliqués

Quatre modifications sont apportées au fichier `dsdt.dsl`.

---

### Correctif 1 — `ELAN0643._DSM` (~ligne 7734)

La méthode `_DSM` communique au kernel le type de périphérique HID utilisé. Elle souffre du même problème que `_CRS` : si `TPTY` ne vaut ni `0x01` ni `0x02`, elle ne retourne rien.

**Avant :**
```asl
If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))
{
    Return (0x01)
}
If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))
{
    Return (0x20)
}
// ← si TPTY vaut autre chose : pas de Return → undefined ❌
```

**Après :**
```asl
If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))
{
    Return (0x01)
}
Else
{
    Return (0x20)   // fallback garanti dans tous les cas ✅
}
```

**Explication :** Le second `If (TPTY == 0x02)` est remplacé par un simple `Else`. Ainsi, si `TPTY` ne vaut pas `0x01` (ce qui est le cas sous Linux), la méthode retourne quand même `0x20` (code HID I2C générique), ce qui permet au kernel de reconnaître le périphérique.

---

### Correctif 2 — `ELAN0643._CRS` (~ligne 7778) ← **le plus critique**

La méthode `_CRS` retourne les ressources matérielles du touchpad (bus I2C + interruption GPIO). C'est elle que le kernel consulte pour savoir où le touchpad est branché. Sans ressources → pas d'initialisation.

**Avant :**
```asl
If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))
{
    Name (SBFB, ResourceTemplate ()
    {
        I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,
            AddressingMode7Bit, "\\_SB.I2CD",
            0x00, ResourceConsumer, , Exclusive,
            )
    })
    Return (ConcatenateResTemplate (SBFB, SBFG))
}
If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))
{
    Name (SBFC, ResourceTemplate ()
    {
        I2cSerialBusV2 (0x002C, ControllerInitiated, 0x00061A80,
            AddressingMode7Bit, "\\_SB.I2CD",
            0x00, ResourceConsumer, , Exclusive,
            )
    })
    Return (ConcatenateResTemplate (SBFC, SBFG))
}
// ← si TPTY vaut autre chose : _CRS retourne rien → touchpad ignoré ❌
```

**Après :**
```asl
If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x01))
{
    Name (SBFB, ResourceTemplate ()
    {
        I2cSerialBusV2 (0x0015, ControllerInitiated, 0x00061A80,
            AddressingMode7Bit, "\\_SB.I2CD",
            0x00, ResourceConsumer, , Exclusive,
            )
    })
    Return (ConcatenateResTemplate (SBFB, SBFG))
}
Else
{
    Name (SBFC, ResourceTemplate ()
    {
        I2cSerialBusV2 (0x002C, ControllerInitiated, 0x00061A80,
            AddressingMode7Bit, "\\_SB.I2CD",
            0x00, ResourceConsumer, , Exclusive,
            )
    })
    Return (ConcatenateResTemplate (SBFC, SBFG))  // fallback garanti ✅
}
```

**Explication :** Le second `If (TPTY == 0x02)` devient `Else`. Le touchpad reçoit toujours une ressource I2C valide (adresse `0x002C`), quelle que soit la valeur de `TPTY`. Le kernel peut alors lier le driver `elan_i2c`.

---

### Correctif 3 — `I2CD._S0W`

La méthode `_S0W` indique au kernel le niveau de veille le plus profond autorisé pour le contrôleur I2C (`I2CD` = `AMDI0010:01`) quand le système est en S0 (éveillé). La valeur `0x04` signifie **D3cold** — le contrôleur peut être complètement coupé — ce qui provoque sa mise hors tension et empêche le touchpad I2C de fonctionner.

**Avant :**
```asl
Method (_S0W, 0, NotSerialized)
{
    Return (0x04)  // D3cold autorisé → contrôleur peut être éteint ❌
}
```

**Après :**
```asl
Method (_S0W, 0, NotSerialized)
{
    Return (0x00)  // D0 seulement → contrôleur reste actif ✅
}
```

**Explication :** En retournant `0x00` (état D0 = actif), on interdit au runtime PM du kernel de mettre le contrôleur I2C en veille profonde. Le bus reste alimenté et le touchpad reste accessible.

---

### Correctif 4 — `I2CD._PS3`

La méthode `_PS3` est exécutée quand le contrôleur passe en état D3 (veille). L'appel `DSAD(0x08, 0x03)` envoie une commande à l'EC pour couper l'alimentation du contrôleur. On neutralise cet appel pour s'assurer que le contrôleur n'est jamais éteint.

**Avant :**
```asl
Method (_PS3, 0, NotSerialized)
{
    DSAD (0x08, 0x03)  // coupe l'alimentation du contrôleur I2C ❌
}
```

**Après :**
```asl
Method (_PS3, 0, NotSerialized)
{
    // Fix ELAN0643: neutralisé — ne pas couper I2CD
    // DSAD (0x08, 0x03)
}
```

---

### Correctif 5 — Service systemd `elan0643-touchpad`

En plus des correctifs DSDT, un service systemd est installé. Il s'exécute au démarrage et :

1. Attend que `AMDI0010:01` soit présent dans `/sys/bus/platform/devices/`
2. Force le runtime PM du contrôleur I2C en mode `on` (bloque l'autosuspend)
3. Effectue un **unbind/rebind** du driver `i2c_designware` sur `AMDI0010:01` pour recréer le bus I2C avec le contrôleur en D0
4. Vérifie que `elan_i2c` s'est bien lié aux adresses `0x0015` ou `0x002C`

Ce service est un filet de sécurité : le DSDT corrigé devrait suffire, mais il garantit que le contrôleur I2C est bien actif même si le runtime PM a tenté de le suspendre entre le boot ACPI et l'initialisation du driver.

---

## Prérequis

- Linux Mint (ou toute distro Debian/Ubuntu avec GRUB2)
- Accès root (`sudo`)
- `dsdt.dsl` **patché** présent dans le répertoire courant

Les outils suivants sont installés automatiquement si absents :

| Outil | Paquet | Rôle |
|---|---|---|
| `iasl` | `acpica-tools` | Compile/décompile les tables ACPI |
| `cpio` | `cpio` | Crée l'archive initrd |
| `update-grub` | `grub-common` | Régénère la config GRUB |

---

## Installation pas à pas

### Étape 1 — Extraire le DSDT du firmware

```bash
# Extraire la table DSDT brute depuis le firmware actif
sudo cat /sys/firmware/acpi/tables/DSDT > dsdt.dat

# Installer iasl si nécessaire
sudo apt install acpica-tools

# Décompiler en ASL lisible
iasl -d dsdt.dat
# → génère dsdt.dsl dans le répertoire courant
```

### Étape 2 — Appliquer les correctifs dans `dsdt.dsl`

Ouvre `dsdt.dsl` avec un éditeur de texte. Il faut modifier **4 endroits** dans le fichier.

#### Correctif 1 — `_DSM` (~ligne 7734)

Chercher ce bloc :
```asl
                            If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))
                            {
                                Return (0x20)
                            }
```

Remplacer **uniquement la ligne du `If`** par `Else` :
```asl
                            Else
                            {
                                Return (0x20)
                            }
```

#### Correctif 2 — `_CRS` (~ligne 7778)

Chercher ce bloc :
```asl
                If ((^^^PCI0.LPC0.H_EC.ECRD (RefOf (^^^PCI0.LPC0.H_EC.TPTY)) == 0x02))
                {
                    Name (SBFC, ResourceTemplate ()
```

Remplacer **uniquement la ligne du `If`** par `Else` :
```asl
                Else
                {
                    Name (SBFC, ResourceTemplate ()
```

#### Correctif 3 — `_S0W` (dans le scope `I2CD`)

Chercher dans la méthode `_S0W` du périphérique `I2CD` :
```asl
                    Return (0x04)
```

Remplacer par :
```asl
                    Return (0x00)
```

#### Correctif 4 — `_PS3` (dans le scope `I2CD`)

Chercher dans la méthode `_PS3` :
```asl
                    DSAD (0x08, 0x03)
```

Commenter la ligne :
```asl
                    // Fix ELAN0643: neutralisé
                    // DSAD (0x08, 0x03)
```

### Étape 3 — Lancer le script d'installation

```bash
# Cloner le repo
git clone https://github.com/TON_PSEUDO/lenovo-14w-gen2-touchpad-fix
cd lenovo-14w-gen2-touchpad-fix

# Copier le dsdt.dsl patché ici
cp /chemin/vers/dsdt.dsl .

# Lancer l'installation
sudo bash install-dsdt-elan0643.sh
```

Le script effectue automatiquement :

1. **Vérification** des correctifs dans `dsdt.dsl`
2. **Recompilation** : `iasl -sa dsdt.dsl` → `dsdt.aml`
3. **Archive initrd** : `cpio` emballe `dsdt.aml` dans `/boot/initrd_acpi_patched`
4. **GRUB** : crée `/etc/default/grub.d/acpi-tables.cfg` et relance `update-grub` pour que le DSDT patché soit chargé avant le DSDT du firmware
5. **Service systemd** : installe et active `elan0643-touchpad.service`

### Étape 4 — Redémarrer

```bash
sudo reboot
```

---

## Vérification après reboot

```bash
# Le service s'est-il exécuté sans erreur ?
systemctl status elan0643-touchpad.service

# Le driver elan_i2c s'est-il initialisé ?
dmesg | grep -i elan

# Le touchpad est-il détecté par libinput ?
libinput list-devices | grep -A 10 Touchpad
```

**Sortie attendue dans `dmesg` :**
```
elan_i2c i2c-X-0015: Elan Touchpad ... initialized
```

---

## Rollback complet

```bash
# 1. Désactiver le service
sudo systemctl disable elan0643-touchpad.service
sudo systemctl stop elan0643-touchpad.service

# 2. Supprimer la config GRUB et régénérer
sudo rm /etc/default/grub.d/acpi-tables.cfg
sudo update-grub

# 3. Supprimer les fichiers installés
sudo rm /boot/initrd_acpi_patched
sudo rm /usr/local/lib/elan0643-touchpad-init.sh
sudo rm /etc/systemd/system/elan0643-touchpad.service
sudo systemctl daemon-reload

# 4. Redémarrer
sudo reboot
```

Après reboot, le DSDT d'origine du firmware est à nouveau utilisé.

---

## Fichiers du projet

```
.
├── README.md                        # cette documentation
├── install-dsdt-elan0643.sh         # script d'installation principal
├── dsdt.dsl                         # DSDT patché (généré + modifié manuellement)
└── dsdt_original.dsl                # DSDT original extrait du firmware (référence)
```

> **Note :** `dsdt.dsl` est extrait du firmware de **ta** machine. Si le BIOS a été mis à jour depuis, il faudra recommencer l'extraction et réappliquer les correctifs.

---

## Pourquoi ce n'est pas corrigé dans le kernel upstream ?

Le bug est dans le **firmware BIOS Lenovo**, pas dans le kernel Linux. Le kernel lit le DSDT tel quel et se comporte correctement vis-à-vis des spécifications ACPI : si `_CRS` ne retourne rien, il n'initialise pas le périphérique.

La correction idéale serait une mise à jour BIOS de Lenovo. En attendant, l'override ACPI via initrd est la méthode officielle recommandée par la documentation kernel :
[https://www.kernel.org/doc/html/latest/admin-guide/acpi/initrd_table_override.html](https://www.kernel.org/doc/html/latest/admin-guide/acpi/initrd_table_override.html)

---

## Matériel testé

| Champ | Valeur |
|---|---|
| Machine | Lenovo 14w Gen 2 |
| Touchpad | ELAN0643 (`ELAN238E` HID) |
| Contrôleur I2C | `AMDI0010:01` (driver `i2c_designware`) |
| Driver touchpad | `elan_i2c` |
| Adresse I2C | `0x0015` (TPTY=1) ou `0x002C` (fallback) |
| OS testé | Linux Mint |
| GRUB | GRUB2 |

---

## Contribuer

Les PR sont les bienvenues pour :
- Tester sur d'autres distributions (Debian, Ubuntu, Fedora, Arch…)
- Vérifier la compatibilité avec d'autres révisions BIOS Lenovo 14w Gen 2
- Adapter à d'autres modèles Lenovo avec le même bug `TPTY`
- Automatiser l'extraction et le patch du DSDT

---

## Licence

MIT
