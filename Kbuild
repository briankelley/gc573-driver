# SPDX-License-Identifier: GPL-2.0
obj-m := gc573.o
gc573-y := src/gc573_core.o src/gc573_i2c.o src/gc573_vb2.o src/gc573_video.o \
	   src/gc573_chip.o src/gc573_seq.o src/gc573_it6805.o \
	   src/gc573_splitter.o src/gc573_hdmi.o src/gc573_audio.o

# Features of the kernel's headers where stable and distro backports make a
# version test unreliable, for src/compat.h alone (AGENTS.md): how
# gc573_block_drivers() keeps other drivers off a dead card.
gc573-pci-h := $(srctree)/include/linux/pci.h
gc573-dev-h := $(srctree)/include/linux/device.h
gc573-bus-h := $(srctree)/include/linux/device/bus.h
# "(" for grep -E: make would count a bare one in the call below, and ERE
# takes it for a group
gc573-lp := [(]
ccflags-y += $(if $(shell grep -Eqs '^[[:space:]]+bool[[:space:]]+match_driver;' \
	$(gc573-pci-h) && echo y),-DGC573_HAVE_PCI_MATCH_DRIVER)
ccflags-y += $(if $(shell grep -Eqs '^[[:space:]]+(const[[:space:]]+)?char[[:space:]]*\*[[:space:]]*driver_override_BROKEN;' \
	$(gc573-pci-h) && echo y),-DGC573_HAVE_PCI_DRIVER_OVERRIDE)
ccflags-y += $(if $(shell grep -Eqs 'int[[:space:]]+device_set_driver_override$(gc573-lp)' \
	$(gc573-dev-h) && echo y),-DGC573_HAVE_DEVICE_SET_DRIVER_OVERRIDE)
ccflags-y += $(if $(shell grep -Eqs '^[[:space:]]+bool[[:space:]]+driver_override;' \
	$(gc573-bus-h) && echo y),-DGC573_HAVE_BUS_DRIVER_OVERRIDE)
