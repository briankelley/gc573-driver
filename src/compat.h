/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Kernel-version compatibility for the GC573 driver.
 *
 * Supported kernels: every regression-matrix VM kernel (AGENTS.md). All
 * kernel-version differences live in this file; no version checks elsewhere.
 *
 * APIs used by the driver and checked against upstream v5.14 and v7.0:
 * pcim_iomap_regions()/pcim_iomap_table() and i2c_algorithm.master_xfer
 * exist in both, so they need no wrapper.
 */
#ifndef GC573_COMPAT_H
#define GC573_COMPAT_H

#include <linux/pci.h>

/* v6.8 renamed PCI_IRQ_LEGACY to PCI_IRQ_INTX; v6.10 dropped the old name. */
#ifndef PCI_IRQ_INTX
#define PCI_IRQ_INTX	PCI_IRQ_LEGACY
#endif

#endif /* GC573_COMPAT_H */
