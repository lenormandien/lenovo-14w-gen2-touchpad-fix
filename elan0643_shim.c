// SPDX-License-Identifier: GPL-2.0
/*
 * elan0643_shim.c — Lenovo 14w Gen 2 touchpad fix
 *
 * Ce module crée un device i2c pour ELAN0643 en associant
 * le firmware_node ACPI (acpi_companion) au device i2c.
 * Cela permet à elan_i2c de résoudre le GPIO IRQ via ACPI.
 *
 * Compilé contre linux-headers-$(uname -r)
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/i2c.h>
#include <linux/acpi.h>
#include <linux/platform_device.h>

#define ELAN_I2C_ADDR   0x15
#define ELAN_ACPI_HID   "ELAN0643"
#define I2CD_ACPI_HID   "AMDI0010"
#define I2CD_ACPI_UID   "3"          /* UID=3 → I2CD */

static struct i2c_client *elan_client = NULL;

static int __init elan0643_shim_init(void)
{
    struct acpi_device *i2cd_adev = NULL;
    struct acpi_device *elan_adev = NULL;
    struct i2c_adapter *adapter   = NULL;
    struct i2c_board_info info    = {};
    acpi_handle handle;
    acpi_status status;
    int ret = 0;

    pr_info("elan0643_shim: init\n");

    /* Trouver le device ACPI I2CD (AMDI0010, UID=3) */
    status = acpi_get_handle(NULL, "\\_SB.I2CD", &handle);
    if (ACPI_FAILURE(status)) {
        pr_err("elan0643_shim: \\SB.I2CD introuvable (status=%d)\n", status);
        return -ENODEV;
    }

    i2cd_adev = acpi_fetch_acpi_dev(handle);
    if (!i2cd_adev) {
        pr_err("elan0643_shim: acpi_device pour I2CD introuvable\n");
        return -ENODEV;
    }
    pr_info("elan0643_shim: I2CD trouvé : %s\n", acpi_device_hid(i2cd_adev));

    /* Trouver le device ACPI ELAN0643 (enfant de I2CD) */
    status = acpi_get_handle(handle, "TPD0", &handle);
    if (ACPI_FAILURE(status)) {
        pr_err("elan0643_shim: TPD0 introuvable sous I2CD\n");
        return -ENODEV;
    }

    elan_adev = acpi_fetch_acpi_dev(handle);
    if (!elan_adev) {
        pr_err("elan0643_shim: acpi_device pour TPD0/ELAN0643 introuvable\n");
        return -ENODEV;
    }
    pr_info("elan0643_shim: ELAN0643 trouvé : %s\n", acpi_device_hid(elan_adev));

    /* Trouver l'adaptateur i2c associé à I2CD */
    adapter = i2c_acpi_find_adapter_by_handle(i2cd_adev->handle);
    if (!adapter) {
        pr_err("elan0643_shim: adaptateur i2c pour I2CD introuvable\n");
        return -ENODEV;
    }
    pr_info("elan0643_shim: adaptateur i2c trouvé : %s (nr=%d)\n",
            adapter->name, adapter->nr);

    /* Construire le board_info avec acpi_companion */
    strscpy(info.type, "elan_i2c", sizeof(info.type));
    info.addr       = ELAN_I2C_ADDR;
    info.fwnode     = acpi_fwnode_handle(elan_adev);
    info.swnode     = NULL;

    /* Créer le device i2c avec le firmware_node ACPI */
    elan_client = i2c_new_client_device(adapter, &info);
    if (IS_ERR(elan_client)) {
        ret = PTR_ERR(elan_client);
        pr_err("elan0643_shim: i2c_new_client_device échoué : %d\n", ret);
        elan_client = NULL;
        put_device(&adapter->dev);
        return ret;
    }

    pr_info("elan0643_shim: device i2c créé : %s à 0x%02x sur i2c-%d\n",
            elan_client->name, elan_client->addr, adapter->nr);

    put_device(&adapter->dev);
    return 0;
}

static void __exit elan0643_shim_exit(void)
{
    if (elan_client) {
        pr_info("elan0643_shim: suppression du device i2c\n");
        i2c_unregister_device(elan_client);
        elan_client = NULL;
    }
    pr_info("elan0643_shim: exit\n");
}

module_init(elan0643_shim_init);
module_exit(elan0643_shim_exit);

MODULE_AUTHOR("Lenovo 14w Gen2 touchpad fix");
MODULE_DESCRIPTION("Shim ACPI→i2c pour ELAN0643 sur Lenovo 14w Gen 2");
MODULE_LICENSE("GPL");
MODULE_ALIAS("acpi:ELAN0643");
