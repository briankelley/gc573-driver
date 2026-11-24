# SPDX-License-Identifier: GPL-2.0
#
# Out-of-tree Kbuild for the GC573 driver.
#   make [KDIR=<kernel build dir>]   build gc573.ko (default: running kernel)
#   make clean
# Kbuild options pass through, e.g. make W=1, make C=2.

ifneq ($(KERNELRELEASE),)

obj-m := gc573.o
gc573-y := src/gc573_core.o src/gc573_i2c.o

else

KDIR ?= /lib/modules/$(shell uname -r)/build

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: modules clean

endif
