// SPDX-License-Identifier: GPL-2.0
/*
 * kmemleak canary for the GC573 test suite. Leaks CANARY_OBJS allocations
 * filled with 0xa5 at load, on purpose, so tests/cases/00-kmemleak-selftest.sh
 * can prove that the suite's kmemleak check reports a real leak. Test use
 * only: never shipped, never loaded together with the driver.
 */

#include <linux/compiler.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/string.h>

#define CANARY_OBJS	8
#define CANARY_SIZE	128

static void *canary[CANARY_OBJS];

static int __init canary_init(void)
{
	int i;

	for (i = 0; i < CANARY_OBJS; i++) {
		canary[i] = kmalloc(CANARY_SIZE, GFP_KERNEL);
		if (canary[i])
			memset(canary[i], 0xa5, CANARY_SIZE);
	}
	/* drop every reference: the allocations are now leaked */
	for (i = 0; i < CANARY_OBJS; i++)
		WRITE_ONCE(canary[i], NULL);
	return 0;
}

static void __exit canary_exit(void)
{
}

module_init(canary_init);
module_exit(canary_exit);

MODULE_DESCRIPTION("kmemleak canary for the gc573 test suite (leaks on purpose)");
MODULE_LICENSE("GPL");
