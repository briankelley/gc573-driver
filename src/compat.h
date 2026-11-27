/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Kernel-version compatibility for the GC573 driver.
 *
 * Supported kernels: every regression-matrix VM kernel (AGENTS.md). All
 * kernel-version differences live in this file; no version checks elsewhere.
 * Where backports make a version test unreliable, Kbuild probes the
 * kernel's headers for the feature and defines GC573_HAVE_*; only this file
 * reads those.
 *
 * Checked against the installed headers of every matrix kernel: EL9.9
 * 5.14, Ubuntu 6.8, EL10.3 6.12, Mint 6.14, Ubuntu 7.0, Fedora 7.3.
 * The RHEL kernels carry upstream backports, so a RHEL_RELEASE_CODE test
 * comes with each LINUX_VERSION_CODE test. Fedora headers also define
 * RHEL_RELEASE_CODE (10.99), but Fedora kernels pass the version test.
 *
 * Same on every matrix kernel, so no wrapper: the vb2_mem_ops callbacks
 * with a struct vb2_buffer argument (upstream v5.16; EL9.9 has them),
 * vb2_queue.min_queued_buffers, vb2_video_unregister_device(),
 * v4l2_calc_timeperframe(), PCI_IRQ_INTX (6.8 and later; EL9.9 has it),
 * i2c_algorithm.master_xfer.
 */
#ifndef GC573_COMPAT_H
#define GC573_COMPAT_H

#include <linux/io.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/version.h>
#include <linux/workqueue.h>

#define GC573_RHEL(major, minor)	(((major) << 8) + (minor))

#if defined(RHEL_RELEASE_CODE)
#define GC573_RHEL_CODE			RHEL_RELEASE_CODE
#else
#define GC573_RHEL_CODE			0
#endif

/* v6.8 renamed PCI_IRQ_LEGACY to PCI_IRQ_INTX; v6.10 dropped the old name. */
#ifndef PCI_IRQ_INTX
#define PCI_IRQ_INTX	PCI_IRQ_LEGACY
#endif

/*
 * pcim_iomap_region(): public since v6.12 (EL9.9 has it), replacing the
 * deprecated pcim_iomap_regions() + pcim_iomap_table() pair. Returns the
 * mapping or an IOMEM_ERR_PTR().
 */
#if KERNEL_VERSION(6, 12, 0) <= LINUX_VERSION_CODE || \
	GC573_RHEL(9, 9) <= GC573_RHEL_CODE
static inline void __iomem *
gc573_pcim_iomap_region(struct pci_dev *pdev, int bar, const char *name)
{
	return pcim_iomap_region(pdev, bar, name);
}
#else
static inline void __iomem *
gc573_pcim_iomap_region(struct pci_dev *pdev, int bar, const char *name)
{
	int ret = pcim_iomap_regions(pdev, BIT(bar), name);

	if (ret)
		return IOMEM_ERR_PTR(ret);
	return pcim_iomap_table(pdev)[bar];
}
#endif

/*
 * struct vb2_ops .wait_prepare/.wait_finish: up to v6.12, vb2 drops the
 * queue lock while a blocking DQBUF waits only through these callbacks;
 * v6.13 does it itself when they are NULL; v7.0 removed them (EL9.9 and
 * EL10.3 have the removal). Used inside the vb2_ops initializer.
 */
#if KERNEL_VERSION(7, 0, 0) > LINUX_VERSION_CODE && !GC573_RHEL_CODE
#define GC573_VB2_WAIT_OPS \
	.wait_prepare	= vb2_ops_wait_prepare, \
	.wait_finish	= vb2_ops_wait_finish,
#else
#define GC573_VB2_WAIT_OPS
#endif

/*
 * gc573_block_drivers(): no driver may take a card whose DMA may still run
 * (gc573_card_dead()); vfio-pci's release would turn its bus mastering off.
 * Process context. Distro and stable kernels backport the changes below
 * across versions, so the way is picked by what the kernel's headers have
 * (Kbuild's probes, GC573_HAVE_*), not by version, and then checked: the
 * PCI bus must no longer match gc573 itself to the card
 * (gc573_block_check()), or the driver says it cannot block other drivers.
 *
 * pci_dev.match_driver (up to v6.15, EL9; GC573_HAVE_PCI_MATCH_DRIVER),
 * set false: pci_bus_match() then refuses every driver, whatever binds
 * it: a sysfs bind, a driver_override, driverctl, libvirt's managed
 * hostdev. The flag is the PCI core's own, and upstream objects to
 * drivers using it: 3be5fa236649 reverted the one in-tree use (iommu/amd)
 * for that reason, and v6.16 hid the flag in the core's priv_flags
 * (ce45dc4bb22e). An upstream submission would drop this and ask for an
 * API.
 *
 * Without it there is no such API. A driver_override naming no driver
 * refuses a plain bind and new_id, but driverctl and libvirt write their
 * own over it (README, Known limitations). In order:
 * - the override in struct device (cb3d1049f4ea, v7.0; 6.18.y and
 *   Ubuntu's 6.8 and 7.0 have it backported), device_set_driver_override(),
 *   under a spinlock of its own, where the bus says it matches with it
 *   (bus_type.driver_override: PCI from v7.1, and Ubuntu's 7.0);
 * - pci_dev.driver_override (v6.16 to v7.0, RHEL 10), through
 *   driver_set_override(), which takes the device lock that probe, remove
 *   and shutdown hold where a stop fails: from a work item, which waits
 *   for that lock, so a bind queued behind the same remove can come first.
 *   gc573_card_dead() keeps the module for good, and with it the work's
 *   code; while the module unloads only remove gets here, with the device
 *   lock held, and the override is written in place.
 */
#define GC573_NO_DRIVER		"gc573-dead-card"

/* After a block: the PCI bus must not match @drv (gc573) to the card */
static inline void gc573_block_check(struct pci_dev *pdev,
				     struct pci_driver *drv)
{
	if (pdev->dev.bus->match(&pdev->dev, &drv->driver) > 0)
		dev_err(&pdev->dev, "cannot block other drivers: the PCI bus still matches drivers to the card\n");
}

#if defined(GC573_HAVE_PCI_MATCH_DRIVER)
#define GC573_DEAD_BLOCK	"match_driver"

static inline void gc573_block_drivers(struct pci_dev *pdev,
				       struct pci_driver *drv)
{
	pdev->match_driver = false;
	gc573_block_check(pdev, drv);
}
#else

#if defined(GC573_HAVE_DEVICE_SET_DRIVER_OVERRIDE) && \
	defined(GC573_HAVE_BUS_DRIVER_OVERRIDE)
#define GC573_BLOCK_GENERIC	"generic,"
#define GC573_BLOCK_ONLY	"generic"

/* The override in struct device, if the PCI bus matches with it */
static inline bool gc573_block_generic(struct pci_dev *pdev,
				       struct pci_driver *drv)
{
	int ret;

	if (!pdev->dev.bus->driver_override)
		return false;
	ret = device_set_driver_override(&pdev->dev, GC573_NO_DRIVER);
	if (ret)
		dev_err(&pdev->dev, "cannot block other drivers: driver_override: %d\n",
			ret);
	else
		gc573_block_check(pdev, drv);
	return true;
}
#else
#define GC573_BLOCK_GENERIC	""
#define GC573_BLOCK_ONLY	"none"

static inline bool gc573_block_generic(struct pci_dev *pdev,
				       struct pci_driver *drv)
{
	return false;
}
#endif

#if defined(GC573_HAVE_PCI_DRIVER_OVERRIDE)
#define GC573_DEAD_BLOCK	GC573_BLOCK_GENERIC "pci_dev"

struct gc573_block_work {
	struct work_struct work;
	struct pci_dev *pdev;
	struct pci_driver *drv;
};

static inline void gc573_block_drivers_work(struct work_struct *work)
{
	struct gc573_block_work *bw = container_of(work, struct gc573_block_work, work);
	struct pci_dev *pdev = bw->pdev;
	int ret = driver_set_override(&pdev->dev, &pdev->driver_override,
				      GC573_NO_DRIVER, strlen(GC573_NO_DRIVER));

	if (ret) {
		dev_err(&pdev->dev, "cannot block other drivers: driver_override: %d\n",
			ret);
	} else {
		device_lock(&pdev->dev);
		gc573_block_check(pdev, bw->drv);
		device_unlock(&pdev->dev);
	}
	pci_dev_put(pdev);
	kfree(bw);
}

static inline void gc573_block_drivers(struct pci_dev *pdev,
				       struct pci_driver *drv)
{
	struct gc573_block_work *bw;
	const char *old, *name;

	if (gc573_block_generic(pdev, drv))
		return;
	if (!try_module_get(THIS_MODULE)) {
		/* unloading: remove, under the device lock */
		name = kstrdup(GC573_NO_DRIVER, GFP_KERNEL);
		if (!name)
			return;
		old = pdev->driver_override;
		pdev->driver_override = name;
		kfree(old);
		gc573_block_check(pdev, drv);
		return;
	}
	module_put(THIS_MODULE);
	bw = kzalloc(sizeof(*bw), GFP_KERNEL);
	if (!bw)
		return;
	INIT_WORK(&bw->work, gc573_block_drivers_work);
	bw->pdev = pci_dev_get(pdev);
	bw->drv = drv;
	schedule_work(&bw->work);
}
#else
#define GC573_DEAD_BLOCK	GC573_BLOCK_ONLY

static inline void gc573_block_drivers(struct pci_dev *pdev,
				       struct pci_driver *drv)
{
	if (!gc573_block_generic(pdev, drv))
		dev_err(&pdev->dev, "cannot block other drivers: this kernel's PCI bus keeps no driver_override a driver can set\n");
}
#endif
#endif

#endif /* GC573_COMPAT_H */
