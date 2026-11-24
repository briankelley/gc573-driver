# SPDX-License-Identifier: GPL-2.0
#
# Out-of-tree build wrapper for the GC573 driver; the objects are in Kbuild.
#   make [KDIR=<kernel build dir>]   build gc573.ko (default: running kernel)
#   make clean
# Kbuild options pass through, e.g. make W=1, make C=2.
# Kbuild, not this file, holds obj-m: DKMS sets KERNELRELEASE on the make
# command line, so a KERNELRELEASE test here cannot tell kbuild from DKMS.

KDIR ?= /lib/modules/$(shell uname -r)/build

# Build with the compiler named in the kernel's CONFIG_CC_VERSION_TEXT when
# it is installed under that name: Ubuntu builds kernels with the triplet-
# named gcc (x86_64-linux-gnu-gcc-NN), and kbuild warns when the name differs
# even for the same compiler. CC=... on the command line still wins.
ifeq ($(origin CC),default)
KCC := $(firstword $(shell sed -n 's/^CONFIG_CC_VERSION_TEXT="//p' $(KDIR)/.config 2>/dev/null))
ifneq ($(KCC),)
ifneq ($(shell command -v $(KCC)),)
KCC_ARG := CC=$(KCC)
endif
endif
endif

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(KCC_ARG) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(KCC_ARG) clean

.PHONY: modules clean
