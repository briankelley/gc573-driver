/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Kernel-version compatibility for the GC573 driver.
 *
 * Supported kernels: every regression-matrix VM kernel (AGENTS.md). All
 * kernel-version differences live in this file; no version checks elsewhere.
 *
 * Built and tested on 6.8 only. Against the upstream headers of v5.14,
 * v7.0 and v7.3 (the matrix ends), pcim_iomap_regions()/pcim_iomap_table()
 * and i2c_algorithm.master_xfer exist in all, so they need no wrapper.
 * Other matrix kernels: not built yet.
 */
#ifndef GC573_COMPAT_H
#define GC573_COMPAT_H

#include <linux/pci.h>

/* v6.8 renamed PCI_IRQ_LEGACY to PCI_IRQ_INTX; v6.10 dropped the old name. */
#ifndef PCI_IRQ_INTX
#define PCI_IRQ_INTX	PCI_IRQ_LEGACY
#endif

#endif /* GC573_COMPAT_H */
