/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Kernel-version compatibility for the GC573 driver.
 *
 * Supported kernels: every regression-matrix VM kernel (AGENTS.md). All
 * kernel-version differences live in this file; no version checks elsewhere.
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
#include <linux/pci.h>
#include <linux/version.h>

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

#endif /* GC573_COMPAT_H */
