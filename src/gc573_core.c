// SPDX-License-Identifier: GPL-2.0
/*
 * AVerMedia Live Gamer 4K (GC573) PCIe HDMI capture card driver: PCI core.
 *
 * Probe brings the FPGA up per spec/init.md steps 1-11; remove quiesces it
 * per spec/init.md "Remove / quiesce". The card has no function-level reset
 * and keeps its register state across driver reloads (spec/pci.md), so
 * probe runs the full sequence every time and never assumes reset values.
 *
 * Teardown is entirely devres-managed. Release order is the reverse of
 * probe: quiesce (interrupts off, reset domains), free IRQ, free vectors,
 * unmap BAR0, disable the device.
 */

#include <linux/delay.h>
#include <linux/device.h>
#include <linux/dma-mapping.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/pci.h>

#include "compat.h"
#include "gc573.h"

/* spec/pci.md */
#define GC573_PCI_VENDOR		0x1461		/* AVerMedia */
#define GC573_PCI_DEVICE		0x0054
#define GC573_PCI_SUBDEVICE		0x5730

/* spec/init.md step 2: poll every 1 ms, at most 11 tries, then 30 ms */
#define GC573_RESET_POLL_US		1000
#define GC573_RESET_TRIES		11
#define GC573_RESET_SETTLE_MS		30

/* spec/init.md step 3: at most 3 recoveries, 2 s each */
#define GC573_DDR_RECOVER_TRIES		3
#define GC573_DDR_RECOVER_MS		2000

/* spec/init.md step 8: set, wait 5 ms, check; at most 21 tries */
#define GC573_GPIO_EN_WAIT_US		5000
#define GC573_GPIO_EN_TRIES		21

/*
 * spec/init.md step 11: at least 50 ms from the last chip-reset release to
 * the first bus-1 transfer (RD: 52.3-52.5 ms; the minimum is unverified)
 */
#define GC573_CHIP_RESET_SETTLE_MS	50

static void gc573_gpio_update(struct gc573 *gc, u32 mask, u32 val)
{
	u32 v;

	spin_lock(&gc->gpio_lock);
	v = gc573_rd(gc, GC573_GPIO);
	gc573_wr(gc, GC573_GPIO, (v & ~mask) | (val & mask));
	spin_unlock(&gc->gpio_lock);
}

/*
 * spec/init.md step 2, also the last quiesce step: reset each domain in
 * turn. A domain's bit reads back 1 once its reset is done.
 */
static int gc573_reset_domains(struct gc573 *gc)
{
	static const u32 domains[] = {
		GC573_RESET_DOMAIN_0, GC573_RESET_DOMAIN_8, GC573_RESET_DOMAIN_9,
	};
	struct device *dev = &gc->pdev->dev;
	unsigned int i, tries;
	int ret = 0;
	u32 v = 0;

	for (i = 0; i < ARRAY_SIZE(domains); i++) {
		gc573_wr(gc, GC573_RESET, domains[i]);
		for (tries = 1; tries <= GC573_RESET_TRIES; tries++) {
			fsleep(GC573_RESET_POLL_US);
			v = gc573_rd(gc, GC573_RESET);
			if (v & domains[i])
				break;
		}
		if (v & domains[i]) {
			dev_dbg(dev, "reset domain %#x done, %u poll(s), RESET=%#010x\n",
				domains[i], tries, v);
		} else {
			dev_err(dev, "reset domain %#x timeout, RESET=%#010x\n",
				domains[i], v);
			if (!ret)
				ret = -ETIMEDOUT;
		}
		msleep(GC573_RESET_SETTLE_MS);
	}
	return ret;
}

/* spec/init.md step 3 */
static int gc573_ddr_check(struct gc573 *gc)
{
	struct device *dev = &gc->pdev->dev;
	unsigned int recover;
	u32 v;

	for (recover = 0; ; recover++) {
		v = gc573_rd(gc, GC573_DDR_STATUS);
		if (v & GC573_DDR_READY)
			break;
		if (recover == GC573_DDR_RECOVER_TRIES) {
			dev_err(dev, "DDR not ready, DDR_STATUS=%#x\n", v);
			return -EIO;
		}
		dev_warn(dev, "DDR not ready, DDR_STATUS=%#x, recovery %u/%u\n",
			 v, recover + 1, GC573_DDR_RECOVER_TRIES);
		gc573_wr(gc, GC573_DDR_STATUS, GC573_DDR_RECOVER_1);
		gc573_wr(gc, GC573_DDR_STATUS, GC573_DDR_RECOVER_2);
		msleep(GC573_DDR_RECOVER_MS);
	}
	dev_dbg(dev, "DDR_STATUS=%#x\n", v);
	return 0;
}

/* spec/init.md step 8: set an enable bit until it reads back 1 */
static int gc573_gpio_enable(struct gc573 *gc, u32 bit)
{
	unsigned int tries;

	for (tries = 1; tries <= GC573_GPIO_EN_TRIES; tries++) {
		gc573_gpio_update(gc, bit, bit);
		fsleep(GC573_GPIO_EN_WAIT_US);
		if (gc573_rd(gc, GC573_GPIO) & bit)
			return 0;
	}
	dev_err(&gc->pdev->dev, "GPIO enable %#x timeout, GPIO=%#010x\n",
		bit, gc573_rd(gc, GC573_GPIO));
	return -ETIMEDOUT;
}

/* spec/init.md steps 10, 11: active-low reset pulse 1, 0, 1 */
static void gc573_gpio_reset_pulse(struct gc573 *gc, u32 bit,
				   unsigned long high_us, unsigned long low_us,
				   unsigned long settle_us)
{
	gc573_gpio_update(gc, bit, bit);
	fsleep(high_us);
	gc573_gpio_update(gc, bit, 0);
	fsleep(low_us);
	gc573_gpio_update(gc, bit, bit);
	fsleep(settle_us);
}

/* spec/interrupts.md "Enable / disable" */
static void gc573_irq_hw_enable(struct gc573 *gc)
{
	u32 status = gc573_rd(gc, GC573_INT_STATUS);

	gc573_wr(gc, GC573_INT_STATUS, status & GC573_INT_STALE_MASK);
	gc573_wr(gc, GC573_INT_ENABLE, GC573_INT_ENABLE_MASK);
}

static void gc573_irq_hw_disable(struct gc573 *gc)
{
	gc573_wr(gc, GC573_INT_ENABLE, 0);
	gc573_wr(gc, GC573_INT_STATUS, gc573_rd(gc, GC573_INT_STATUS));
}

/* spec/init.md steps 2-11. Step 1 (PCI) is done by the caller. */
static int gc573_hw_init(struct gc573 *gc)
{
	struct device *dev = &gc->pdev->dev;
	int ret;

	dev_dbg(dev, "state at probe: RESET=%#010x INT_ENABLE=%#010x INT_STATUS=%#010x GPIO=%#010x\n",
		gc573_rd(gc, GC573_RESET), gc573_rd(gc, GC573_INT_ENABLE),
		gc573_rd(gc, GC573_INT_STATUS), gc573_rd(gc, GC573_GPIO));

	/* 2: reset domains */
	ret = gc573_reset_domains(gc);
	if (ret)
		return ret;

	/* 3: on-board DDR ready */
	ret = gc573_ddr_check(gc);
	if (ret)
		return ret;

	/* 4: version */
	gc->fw_version = gc573_rd(gc, GC573_VERSION);
	dev_info(dev, "FPGA version %08x\n", gc->fw_version);

	/* 5: I2C clocks: bus 0, bus 1, bus 2 */
	gc573_wr(gc, GC573_I2C0_BASE + GC573_OC_PRERLO, GC573_I2C0_PRESCALE);
	gc573_wr(gc, GC573_I2C0_BASE + GC573_OC_PRERHI, 0);
	gc573_wr(gc, GC573_I2C0_BASE + GC573_OC_CTR, GC573_OC_CTR_EN);
	gc573_wr(gc, GC573_I2C1_PRESCALE, GC573_I2C1_PRESCALE_VAL);
	gc573_wr(gc, GC573_I2C2_BASE + GC573_OC_PRERLO, GC573_I2C2_PRESCALE);
	gc573_wr(gc, GC573_I2C2_BASE + GC573_OC_PRERHI, 0);
	gc573_wr(gc, GC573_I2C2_BASE + GC573_OC_CTR, GC573_OC_CTR_EN);

	/* 6: clear stale interrupt status, enable interrupts */
	gc573_irq_hw_enable(gc);

	/* 7: scalers out of reset */
	gc573_wr(gc, GC573_SCALER_RESET, GC573_SCALER_RUN);

	/* 8: GPIO enables */
	ret = gc573_gpio_enable(gc, GC573_GPIO_EN4);
	if (!ret)
		ret = gc573_gpio_enable(gc, GC573_GPIO_EN6);
	if (ret)
		return ret;

	/* 9: clear GPIO bit 1 */
	fsleep(2000);
	gc573_gpio_update(gc, GC573_GPIO_BIT1, 0);
	fsleep(2000);

	/* 10, 11: on-board chip resets */
	gc573_gpio_reset_pulse(gc, GC573_GPIO_RST5_N, 5000, 10000, 5000);
	gc573_gpio_reset_pulse(gc, GC573_GPIO_RST8_N, 2000, 2000, 2000);
	msleep(GC573_CHIP_RESET_SETTLE_MS);

	dev_dbg(dev, "init done: GPIO=%#010x\n", gc573_rd(gc, GC573_GPIO));
	return 0;
}

/*
 * spec/init.md "Remove / quiesce". Runs from devres on remove and on probe
 * failure, after the child devices are gone and before the IRQ is freed.
 */
static void gc573_quiesce(void *data)
{
	struct gc573 *gc = data;

	/* 1: stop video and audio: nothing starts them before M2/M4 */

	/* 2: interrupts off, status cleared */
	gc573_irq_hw_disable(gc);

	/* 3: reset domains */
	gc573_reset_domains(gc);

	dev_dbg(&gc->pdev->dev, "quiesced: INT_ENABLE=%#010x INT_STATUS=%#010x RESET=%#010x\n",
		gc573_rd(gc, GC573_INT_ENABLE), gc573_rd(gc, GC573_INT_STATUS),
		gc573_rd(gc, GC573_RESET));

	/* 4: IRQ, then DMA memory, are released by devres after this */
}

/*
 * Hard handler: claim and ack the enabled bits that are set, then defer
 * their servicing to the thread. Acking here keeps a shared INTx line
 * from staying asserted while the thread runs. spec/interrupts.md.
 */
static irqreturn_t gc573_irq(int irq, void *data)
{
	struct gc573 *gc = data;
	u32 status, pending;

	status = gc573_rd(gc, GC573_INT_STATUS);
	if (status == U32_MAX)		/* device not responding */
		return IRQ_NONE;

	pending = status & GC573_INT_ENABLE_MASK;
	if (!pending)
		return IRQ_NONE;

	/* write 1 to clear exactly the bits taken for service */
	gc573_wr(gc, GC573_INT_STATUS, pending);
	atomic_or(pending, &gc->irq_pending);
	return IRQ_WAKE_THREAD;
}

static irqreturn_t gc573_irq_thread(int irq, void *data)
{
	struct gc573 *gc = data;
	u32 pending = atomic_xchg(&gc->irq_pending, 0);
	u32 unexpected;

	/* bits 8, 9: enabled by the spec's sequence, meaning unknown: ack only */
	if (pending & (GC573_INT_UNK8 | GC573_INT_UNK9))
		dev_dbg_ratelimited(&gc->pdev->dev, "interrupt %#x (bits 8/9)\n",
				    pending);

	if (pending & GC573_INT_I2C1)
		gc573_i2c1_irq(gc);

	/* nothing starts video or audio yet */
	unexpected = pending & (GC573_INT_VID_TERM | GC573_INT_VID_DONE |
				GC573_INT_AUD_STOP | GC573_INT_AUD_DONE);
	if (unexpected)
		dev_warn_ratelimited(&gc->pdev->dev, "unexpected interrupt %#x\n",
				     unexpected);

	return IRQ_HANDLED;
}

static int gc573_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct device *dev = &pdev->dev;
	struct gc573 *gc;
	int ret;

	gc = devm_kzalloc(dev, sizeof(*gc), GFP_KERNEL);
	if (!gc)
		return -ENOMEM;
	gc->pdev = pdev;
	spin_lock_init(&gc->gpio_lock);
	mutex_init(&gc->i2c_lock);
	init_completion(&gc->i2c1_done);
	pci_set_drvdata(pdev, gc);

	/* 1: PCI enable, bus master, BAR0, MSI (spec/pci.md) */
	ret = pcim_enable_device(pdev);
	if (ret)
		return dev_err_probe(dev, ret, "cannot enable device\n");

	if (pci_resource_len(pdev, 0) < GC573_BAR0_SIZE)
		return dev_err_probe(dev, -ENODEV, "BAR0 too small: %pR\n",
				     &pdev->resource[0]);

	gc->mmio = gc573_pcim_iomap_region(pdev, 0, KBUILD_MODNAME);
	if (IS_ERR(gc->mmio))
		return dev_err_probe(dev, PTR_ERR(gc->mmio), "cannot map BAR0\n");

	/* 64-bit DMA is untested (spec/pci.md) */
	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret)
		return dev_err_probe(dev, ret, "no 32-bit DMA\n");

	pci_set_master(pdev);

	ret = pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI | PCI_IRQ_INTX);
	if (ret < 0)
		return dev_err_probe(dev, ret, "no IRQ vector\n");
	gc->irq = pci_irq_vector(pdev, 0);
	if (gc->irq < 0)
		return dev_err_probe(dev, gc->irq, "no IRQ number\n");

	ret = devm_request_threaded_irq(dev, gc->irq, gc573_irq, gc573_irq_thread,
					pci_dev_msi_enabled(pdev) ? 0 : IRQF_SHARED,
					KBUILD_MODNAME, gc);
	if (ret)
		return dev_err_probe(dev, ret, "cannot request IRQ %d\n", gc->irq);
	dev_info(dev, "using %s, irq %d\n",
		 pci_dev_msi_enabled(pdev) ? "MSI" : "INTx", gc->irq);

	ret = devm_add_action_or_reset(dev, gc573_quiesce, gc);
	if (ret)
		return ret;

	ret = gc573_hw_init(gc);
	if (ret)
		return ret;

	/* I2C adapters: devres removes them before the quiesce above runs */
	ret = gc573_i2c_init(gc);
	if (ret)
		return ret;

	gc573_i2c_check_ids(gc);
	return 0;
}

static const struct pci_device_id gc573_pci_ids[] = {
	{ PCI_DEVICE_SUB(GC573_PCI_VENDOR, GC573_PCI_DEVICE,
			 GC573_PCI_VENDOR, GC573_PCI_SUBDEVICE) },
	{ }
};
MODULE_DEVICE_TABLE(pci, gc573_pci_ids);

static struct pci_driver gc573_pci_driver = {
	.name		= KBUILD_MODNAME,
	.id_table	= gc573_pci_ids,
	.probe		= gc573_probe,
};
module_pci_driver(gc573_pci_driver);

MODULE_DESCRIPTION("AVerMedia Live Gamer 4K (GC573) HDMI capture driver");
MODULE_LICENSE("GPL");
