# SPDX-License-Identifier: GPL-2.0
#
# Out-of-tree build wrapper for the GC573 driver; the objects are in Kbuild.
#   make [KDIR=<kernel build dir>]   build gc573.ko (default: running kernel)
#   make clean
# Kbuild options pass through, e.g. make W=1, make C=2.
# Kbuild, not this file, holds obj-m: DKMS sets KERNELRELEASE on the make
# command line, so a KERNELRELEASE test here cannot tell kbuild from DKMS.

KDIR ?= /lib/modules/$(shell uname -r)/build

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: modules clean
