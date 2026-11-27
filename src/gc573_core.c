// SPDX-License-Identifier: GPL-2.0
/*
 * AVerMedia Live Gamer 4K (GC573) PCIe HDMI capture card driver: PCI core.
 *
 * Probe brings the FPGA up per spec/init.md steps 1-11; remove quiesces it
 * per spec/init.md "Remove / quiesce". The card has no function-level reset
 * and keeps its register state across driver reloads (spec/pci.md), so
 * probe runs the full sequence every time and never assumes reset values,
 * and it stops the engines before it turns bus mastering on.
 *
 * Teardown is entirely devres-managed. Release order is the reverse of
 * probe: debugfs, HDMI polling (stopped), every DMA engine stopped and the
 * stop checked (gc573_dma_stop(), at the head of the ALSA card's release),
 * the ALSA card (disconnected; it goes with its last file), the video
 * device and its buffers, the HDMI workqueue, source HPD low, I2C
 * adapters, quiesce (interrupts off, reset domains), free IRQ, free
 * vectors, bus mastering off, the DMA memory the card itself uses (audio
 * buffers, the dummy list), unmap BAR0, disable the device, a dead card's
 * INTx off, and last the v4l2_device reference. No DMA memory goes back and bus mastering never
 * goes off before the engines were stopped (spec/pci.md). After a stop
 * that cannot be confirmed none of the memory the card was given goes
 * back at all: it is kept, mapped, until reboot, and the card keeps bus
 * mastering (gc573_dma_dead()). struct gc573 is freed when the last
 * reference goes, which can be after remove while a video or PCM file is
 * still open.
 */

#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/dma-mapping.h>
#include <linux/interrupt.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/notifier.h>
#include <linux/pci.h>
#include <linux/pm_runtime.h>
#include <linux/slab.h>
#include <linux/suspend.h>

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

/* Tests only (tests/cases/22-stop-fault.sh): see GC573_STOP_FAULT_* */
unsigned int gc573_exp_stop_fault;
module_param_named_unsafe(exp_stop_fault, gc573_exp_stop_fault, uint, 0644);
MODULE_PARM_DESC(exp_stop_fault,
		 "Test only; setting it taints the kernel. A DMA stop the card confirmed then counts as failed, and the driver handles it as a real failure: the card is unusable until reboot. Read at each stop. Bit 0: a video stop's INT bit 0 counts as missing, bit 1: its reset of domain 0 counts as failed (with both, the video stop fails), bit 2: the teardown counts the audio DMA as still on, bit 3: the probe's stop counts the audio DMA as still on, bit 4: a video stop counted as failed by bits 0 and 1 is so only 2 s later, its lock held, bit 5: an audio stop counts as without INT bit 4 and the audio DMA still on (0: off)");

/* Tests only (tests/cases/26-no-answer.sh): see GC573_MMIO_ONES_* */
static unsigned int exp_mmio_ones;
module_param_unsafe(exp_mmio_ones, uint, 0644);
MODULE_PARM_DESC(exp_mmio_ones,
		 "Test only; setting it taints the kernel. Register reads return all-ones, as from a card that does not answer; read at each probe. 1: from the start of the probe, 2: for 1.5 s once bus mastering is on, 3: for 25 s once it is on, 4: from the probe's check after that on, for good (0: off)");

/* Tests only (tests/cases/30-probe-entry.sh): see gc573_hw_stop_engines() */
static bool exp_probe_armed;
module_param_unsafe(exp_probe_armed, bool, 0644);
MODULE_PARM_DESC(exp_probe_armed,
		 "Test only; setting it taints the kernel. The probe's read of DMA_RUN before it stops the engines shows the audio DMA on, as a previous owner could leave it; the card itself is idle. Read at each probe (0: off)");

/*
 * Tests only (tests/cases/29-intx.sh, bare metal): the card's INTx is
 * untested, and under VFIO its line storms (spec/open-questions.md #43),
 * so by default the probe takes MSI or nothing
 */
static unsigned int exp_intx;
module_param_unsafe(exp_intx, uint, 0644);
MODULE_PARM_DESC(exp_intx,
		 "Test only; setting it taints the kernel. 0: MSI only, a probe without MSI fails (default); 1: MSI, else the shared legacy interrupt (INTx); 2: INTx even with MSI there; other values as 0. INTx is untested on this card. Read at each probe");

/* The interrupt types the probe may take (exp_intx) */
static unsigned int gc573_irq_types(void)
{
	switch (READ_ONCE(exp_intx)) {
	case 1:
		return PCI_IRQ_MSI | PCI_IRQ_INTX;
	case 2:
		return PCI_IRQ_INTX;
	default:
		return PCI_IRQ_MSI;
	}
}

/* gc573_rd(), with exp_mmio_ones on: all-ones now? */
bool gc573_mmio_ones_now(struct gc573 *gc)
{
	if (READ_ONCE(gc->mmio_ones_timed) &&
	    time_after_eq(jiffies, READ_ONCE(gc->mmio_ones_until))) {
		WRITE_ONCE(gc->mmio_ones, false);
		return false;
	}
	return true;
}

/* exp_mmio_ones: its reads start here if @mode is the one set */
static void gc573_mmio_ones_start(struct gc573 *gc, unsigned int mode)
{
	unsigned int ms = 0;

	if (READ_ONCE(exp_mmio_ones) != mode)
		return;
	if (mode == GC573_MMIO_ONES_BRIEF)
		ms = 1500;
	else if (mode == GC573_MMIO_ONES_LONG)
		ms = 25000;
	gc->mmio_ones_until = jiffies + msecs_to_jiffies(ms);
	gc->mmio_ones_timed = ms != 0;
	WRITE_ONCE(gc->mmio_ones, true);
	if (ms)
		dev_info(&gc->pdev->dev, "exp_mmio_ones %u: register reads return all-ones for %u ms\n",
			 mode, ms);
	else
		dev_info(&gc->pdev->dev, "exp_mmio_ones %u: register reads return all-ones from now on\n",
			 mode);
}

/*
 * GPIO (0x040) read-modify-write. Nothing is written when the read gives
 * all-ones: the card does not answer, and its every bit set is no state to
 * write back
 */
void gc573_gpio_update(struct gc573 *gc, u32 mask, u32 val)
{
	u32 v;

	spin_lock(&gc->gpio_lock);
	v = gc573_rd(gc, GC573_GPIO);
	if (v != U32_MAX)
		gc573_wr(gc, GC573_GPIO, (v & ~mask) | (val & mask));
	else
		dev_warn_once(&gc->pdev->dev, "GPIO update: the card does not answer (reads all-ones): not written\n");
	spin_unlock(&gc->gpio_lock);
}

/*
 * DMA_RUN (0x008): bit 1 runs the audio DMA, the other bits are unknown;
 * RD wrote the whole register only with video idle. Every change is a
 * read-modify-write under this lock (spec/audio.md "Driver notes"). An
 * all-ones read writes nothing: every run bit set is no state to write
 * back to a card that does not answer.
 */
void gc573_dma_run_update(struct gc573 *gc, u32 mask, u32 val)
{
	unsigned long flags;
	u32 v;

	spin_lock_irqsave(&gc->dma_run_lock, flags);
	v = gc573_rd(gc, GC573_DMA_RUN);
	if (v != U32_MAX)
		gc573_wr(gc, GC573_DMA_RUN, (v & ~mask) | (val & mask));
	else
		dev_warn_once(&gc->pdev->dev, "DMA_RUN update: the card does not answer (reads all-ones): not written\n");
	spin_unlock_irqrestore(&gc->dma_run_lock, flags);
}

/*
 * spec/init.md step 2, also the last step of a video stop and of the
 * quiesce: reset each domain in @mask in turn, in the spec's order (the
 * spec's sequence resets all three: gc573_reset_domains()). A domain's
 * bit reads back 1 once its reset is done. All-ones is no answer, not
 * done: -ENODEV at once.
 */
int gc573_reset_domain_mask(struct gc573 *gc, u32 mask)
{
	static const u32 domains[] = {
		GC573_RESET_DOMAIN_0, GC573_RESET_DOMAIN_8, GC573_RESET_DOMAIN_9,
	};
	struct device *dev = &gc->pdev->dev;
	unsigned int i, tries;
	int ret = 0;
	u32 v = 0;

	for (i = 0; i < ARRAY_SIZE(domains); i++) {
		if (!(mask & domains[i]))
			continue;
		gc573_wr(gc, GC573_RESET, domains[i]);
		for (tries = 1; tries <= GC573_RESET_TRIES; tries++) {
			fsleep(GC573_RESET_POLL_US);
			v = gc573_rd(gc, GC573_RESET);
			if (v == U32_MAX) {
				dev_err(dev, "reset domain %#x: the card does not answer (RESET reads all-ones)\n",
					domains[i]);
				return -ENODEV;
			}
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

int gc573_reset_domains(struct gc573 *gc)
{
	return gc573_reset_domain_mask(gc, GC573_RESET_DOMAINS);
}

/* spec/init.md step 3 */
static int gc573_ddr_check(struct gc573 *gc)
{
	struct device *dev = &gc->pdev->dev;
	unsigned int recover;
	u32 v;

	for (recover = 0; ; recover++) {
		v = gc573_rd(gc, GC573_DDR_STATUS);
		if (v == U32_MAX) {
			dev_err(dev, "DDR check: the card does not answer (DDR_STATUS reads all-ones)\n");
			return -ENODEV;
		}
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
	u32 v;

	for (tries = 1; tries <= GC573_GPIO_EN_TRIES; tries++) {
		gc573_gpio_update(gc, bit, bit);
		fsleep(GC573_GPIO_EN_WAIT_US);
		v = gc573_rd(gc, GC573_GPIO);
		if (v == U32_MAX) {
			dev_err(&gc->pdev->dev, "GPIO enable %#x: the card does not answer (GPIO reads all-ones)\n",
				bit);
			return -ENODEV;
		}
		if (v & bit)
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

static void gc573_card_dead(struct gc573 *gc, const char *why, bool locked);
static struct pci_driver gc573_pci_driver;

/*
 * Probe, with MMIO only, before bus mastering goes on (spec/init.md step
 * 2, and what comes before it). The card keeps its registers from one
 * owner to the next (spec/pci.md), and RD leaves its DMA running when it
 * unloads (spec/init.md "Remove / quiesce"): an engine a previous owner
 * left armed (a driver, a virtual machine through VFIO, a crashed kernel)
 * would write to that owner's memory as soon as bus mastering is on. So
 * first interrupts off with their status cleared, the audio DMA and the
 * video output off as the spec's stops do, every video channel disarmed,
 * then step 2's domain resets.
 *
 * A card that does not answer reads all-ones (VERSION too): it may as
 * well be running DMA, and the probe ends there, bus mastering left as it
 * is (gc573_master_guard() keeps it on if it was). VERSION is read again
 * after the resets, for gc573_answer_check(), and DMA_RUN and VIP_CTRL
 * must read the engines stopped, as at the teardown (gc573_dma_stop()).
 * If the stop cannot be completed or confirmed once the slots point at
 * the dummy list, that list and the audio buffers are kept
 * (gc573_dma_dead()).
 *
 * Bus mastering off when the probe started, and the card not idle (an
 * engine on, or all-ones): a previous owner may have turned it off under
 * running DMA (an older driver's failed stop, a virtual machine ended
 * without a working reset, a kexec), and a card whose bus mastering went
 * on again after that read all-ones for some 15 s and stalled a CPU
 * (spec/pci.md). Nothing is written to the card then, bus mastering
 * never goes on, and the card is dead until reboot (gc573_card_dead()):
 * it was given none of the driver's memory.
 */
static int gc573_hw_stop_engines(struct gc573 *gc)
{
	unsigned int fault = READ_ONCE(gc573_exp_stop_fault);
	struct device *dev = &gc->pdev->dev;
	u32 ver, run, vip;
	int ret;

	ver = gc573_rd(gc, GC573_VERSION);
	run = gc573_rd(gc, GC573_DMA_RUN);
	vip = gc573_rd(gc, GC573_VIP_CTRL);
	dev_dbg(dev, "state at probe: VERSION=%08x RESET=%#010x INT_ENABLE=%#010x INT_STATUS=%#010x GPIO=%#010x DMA_RUN=%#010x VIP_CTRL=%#010x\n",
		ver, gc573_rd(gc, GC573_RESET), gc573_rd(gc, GC573_INT_ENABLE),
		gc573_rd(gc, GC573_INT_STATUS), gc573_rd(gc, GC573_GPIO),
		run, vip);
	/* tests only: an idle card, read as one a previous owner left busy */
	if (READ_ONCE(exp_probe_armed) && run != U32_MAX) {
		u32 armed = run | GC573_DMA_RUN_AUDIO;

		dev_warn(dev, "exp_probe_armed: DMA_RUN %#010x read as %#010x (the audio DMA on)\n",
			 run, armed);
		run = armed;
	}
	if (gc->master_was_off &&
	    (ver == U32_MAX || run == U32_MAX || vip == U32_MAX ||
	     (run & GC573_DMA_RUN_AUDIO) || (vip & GC573_VIP_CTRL_OUT_EN))) {
		dev_err(dev, "bus mastering was off when the probe started, and the card does not read idle (VERSION %08x DMA_RUN %#010x VIP_CTRL %#010x): a previous owner may have turned it off under running DMA, and on again it can stall the machine (spec/pci.md); nothing is written to the card\n",
			ver, run, vip);
		gc573_card_dead(gc, "not idle at the probe's start with bus mastering off",
				true);
		return -ENODEV;
	}
	if (ver == U32_MAX || run == U32_MAX || vip == U32_MAX) {
		dev_err(dev, "the card does not answer (VERSION %08x DMA_RUN %#010x VIP_CTRL %#010x): not used\n",
			ver, run, vip);
		return -ENODEV;
	}

	gc573_irq_hw_disable(gc);
	if (run & GC573_DMA_RUN_AUDIO)
		gc573_dma_run_update(gc, GC573_DMA_RUN_AUDIO, 0);
	if (vip & GC573_VIP_CTRL_OUT_EN)
		gc573_wr(gc, GC573_VIP_CTRL, vip & ~GC573_VIP_CTRL_OUT_EN);
	gc573_video_disarm(gc);		/* every slot on the dummy list too */
	if ((run & GC573_DMA_RUN_AUDIO) || (vip & GC573_VIP_CTRL_OUT_EN))
		dev_info(dev, "DMA running at probe (DMA_RUN %#010x, VIP_CTRL %#010x): stopped before bus mastering\n",
			 run, vip);

	/* 2: reset domains */
	ret = gc573_reset_domains(gc);
	gc->fw_version = gc573_rd(gc, GC573_VERSION);
	if (!ret && gc->fw_version != ver) {
		dev_err(dev, "the card stopped answering during the resets (VERSION %08x, %08x before)\n",
			gc->fw_version, ver);
		ret = -ENODEV;
	}
	if (!ret) {
		/* the stop read back, as gc573_dma_stop() reads it */
		run = gc573_rd(gc, GC573_DMA_RUN);
		vip = gc573_rd(gc, GC573_VIP_CTRL);
		/* tests only: a stop confirmed, counted as failed */
		if ((fault & GC573_STOP_FAULT_PROBE) && run != U32_MAX &&
		    vip != U32_MAX && !(run & GC573_DMA_RUN_AUDIO) &&
		    !(vip & GC573_VIP_CTRL_OUT_EN)) {
			dev_warn(dev, "exp_stop_fault %#x: the probe stop was confirmed (DMA_RUN %#010x VIP_CTRL %#010x), counted as the audio DMA still on\n",
				 fault, run, vip);
			run |= GC573_DMA_RUN_AUDIO;
		}
		if (run == U32_MAX || vip == U32_MAX ||
		    (run & GC573_DMA_RUN_AUDIO) || (vip & GC573_VIP_CTRL_OUT_EN)) {
			dev_err(dev, "the stop of the engines at probe is not confirmed: %s, DMA_RUN %#010x VIP_CTRL %#010x\n",
				run == U32_MAX || vip == U32_MAX ?
				"the card does not answer" : "DMA still on", run, vip);
			ret = -ENODEV;
		}
	}
	if (ret)
		gc573_dma_dead(gc, "the stop of the engines at probe failed", true);
	else
		gc->master_unchecked = false;
	return ret;
}

/*
 * Before the PCI enable: bus mastering as the card's last owner left it
 * (firmware leaves it on, too). Off: noted for gc573_hw_stop_engines(),
 * which then turns it on only for a card that reads idle. On, with the
 * card not reading idle (an engine on, all-ones, or BAR0 not readable): a
 * previous owner may have left DMA running, and gc573_master_guard() must
 * keep any unwind from turning bus mastering off. Read through a mapping
 * of its own, so that nothing of the probe's can fail before the guard is
 * in place.
 */
static bool gc573_master_unchecked(struct gc573 *gc)
{
	struct pci_dev *pdev = gc->pdev;
	void __iomem *m;
	u32 run, vip;
	u16 cmd;

	pci_read_config_word(pdev, PCI_COMMAND, &cmd);
	gc->master_was_off = cmd != (u16)~0 && !(cmd & PCI_COMMAND_MASTER);
	if (gc->master_was_off)
		return false;
	/* tests only: exp_mmio_ones 1 has the card read all-ones from here */
	if (cmd == (u16)~0 || !(cmd & PCI_COMMAND_MEMORY) ||
	    READ_ONCE(exp_mmio_ones) == GC573_MMIO_ONES_PROBE)
		return true;
	m = pci_iomap_range(pdev, 0, 0, GC573_BAR0_SIZE);
	if (!m)
		return true;
	run = readl(m + GC573_DMA_RUN);
	vip = readl(m + GC573_VIP_CTRL);
	pci_iounmap(pdev, m);
	return run == U32_MAX || vip == U32_MAX ||
	       (run & GC573_DMA_RUN_AUDIO) || (vip & GC573_VIP_CTRL_OUT_EN);
}

/* After bus mastering goes on: up to this long for the card to answer */
#define GC573_ANSWER_WAIT_MS		20000
#define GC573_ANSWER_POLL_MS		100

/*
 * After bus mastering and the IRQ vectors: VERSION must read what it read
 * just before (gc573_hw_stop_engines()). A card whose bus mastering had
 * been turned off mid-transfer read all-ones for some 15 s once the next
 * probe turned it on again, and stalled a CPU meanwhile (spec/pci.md). So
 * wait for it, bounded, and say how long it took; a card that does not
 * answer again is left as one whose stop failed, and keeps the memory it
 * may target (gc573_dma_dead()).
 */
static int gc573_answer_check(struct gc573 *gc, unsigned long t_master)
{
	struct device *dev = &gc->pdev->dev;
	unsigned long end = t_master + msecs_to_jiffies(GC573_ANSWER_WAIT_MS);
	u32 v = gc573_rd(gc, GC573_VERSION);

	if (v == gc->fw_version)
		return 0;
	dev_warn(dev, "VERSION reads %08x since bus mastering went on (%08x before): the card is not ready; waiting up to %u s\n",
		 v, gc->fw_version, GC573_ANSWER_WAIT_MS / 1000);
	while (time_before(jiffies, end)) {
		msleep(GC573_ANSWER_POLL_MS);
		v = gc573_rd(gc, GC573_VERSION);
		if (v == gc->fw_version) {
			dev_warn(dev, "the card answers again, %u ms after bus mastering went on\n",
				 jiffies_to_msecs(jiffies - t_master));
			return 0;
		}
	}
	gc573_dma_dead(gc, "the card stopped answering after bus mastering was enabled",
		       true);
	return -ENODEV;
}

/*
 * spec/init.md steps 3-11. Step 1 (PCI) is done by the caller, step 2
 * before bus mastering (gc573_hw_stop_engines()).
 */
static int gc573_hw_init(struct gc573 *gc)
{
	struct device *dev = &gc->pdev->dev;
	int ret;

	/* 3: on-board DDR ready */
	ret = gc573_ddr_check(gc);
	if (ret)
		return ret;

	/* 4: version, read before bus mastering and checked after it */
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
 * The cards whose DMA stop could not be confirmed in this boot
 * (gc573_card_dead()), by PCI domain, bus and function: never probed
 * again, also not as a new pci_dev after a remove and rescan. Once one is
 * here the module stays loaded, and with it this record.
 */
#define GC573_DEAD_MAX			8
static struct {
	int domain;
	unsigned int bus, devfn;
} gc573_dead[GC573_DEAD_MAX];
static unsigned int gc573_ndead;
static DEFINE_MUTEX(gc573_dead_lock);

static bool gc573_dead_has(struct pci_dev *pdev)
{
	bool found = false;
	unsigned int i;

	mutex_lock(&gc573_dead_lock);
	for (i = 0; i < gc573_ndead; i++)
		if (gc573_dead[i].domain == pci_domain_nr(pdev->bus) &&
		    gc573_dead[i].bus == pdev->bus->number &&
		    gc573_dead[i].devfn == pdev->devfn)
			found = true;
	mutex_unlock(&gc573_dead_lock);
	return found;
}

static void gc573_dead_add(struct pci_dev *pdev)
{
	mutex_lock(&gc573_dead_lock);
	if (gc573_ndead < GC573_DEAD_MAX) {
		gc573_dead[gc573_ndead].domain = pci_domain_nr(pdev->bus);
		gc573_dead[gc573_ndead].bus = pdev->bus->number;
		gc573_dead[gc573_ndead].devfn = pdev->devfn;
		gc573_ndead++;
	} else {
		dev_err(&pdev->dev, "more than %d cards whose stop failed: this one is not recorded, and after a remove and rescan it could be probed again\n",
			GC573_DEAD_MAX);
	}
	mutex_unlock(&gc573_dead_lock);
}

static int gc573_dead_cards_get(char *buf, const struct kernel_param *kp)
{
	unsigned int i;
	int n = 0;

	mutex_lock(&gc573_dead_lock);
	for (i = 0; i < gc573_ndead; i++)
		n += scnprintf(buf + n, PAGE_SIZE - n, "%04x:%02x:%02x.%u\n",
			       gc573_dead[i].domain, gc573_dead[i].bus,
			       PCI_SLOT(gc573_dead[i].devfn),
			       PCI_FUNC(gc573_dead[i].devfn));
	mutex_unlock(&gc573_dead_lock);
	return n;
}

static int gc573_dead_cards_set(const char *val, const struct kernel_param *kp)
{
	return -EPERM;
}

static const struct kernel_param_ops gc573_dead_cards_ops = {
	.set = gc573_dead_cards_set,
	.get = gc573_dead_cards_get,
};
module_param_cb(dead_cards, &gc573_dead_cards_ops, NULL, 0444);
MODULE_PARM_DESC(dead_cards,
		 "Read only: the cards (PCI addresses) whose DMA stop could not be confirmed in this boot. Each keeps bus mastering and the memory it was given, and gets no driver, until reboot");

/*
 * The card's DMA may still run (spec/pci.md): leave the card as it is
 * until reboot, and never turn its bus mastering off; if it was off when
 * the probe started, it stays off (gc573_hw_stop_engines()). Without
 * MMIO, so that gc573_master_guard() can use it too.
 * - An enable that is never undone: pcim's disable at the teardown then
 *   leaves the device enabled and bus mastering on (pci_disable_device()
 *   turns it off only with the last enable gone).
 * - A runtime PM usage count that is never put: with no driver and
 *   power/control at auto, the PCI core would count the card suspended
 *   while it stays in D0 (pci_pm_runtime_suspend()), and the port above
 *   it could then suspend under its DMA.
 * - No driver takes the card again: not this one, and not vfio-pci, whose
 *   release (a VM's end) turns bus mastering off (gc573_block_drivers(),
 *   compat.h: complete where the kernel has pci_dev.match_driver, up to
 *   v6.15, weaker without it; modinfo's dead_block says which).
 *   A new pci_dev of it, after a remove and rescan, gets refused by this
 *   driver's record, but nothing keeps other drivers from that one
 *   (README).
 * - The module stays loaded, and with it the record. A stop that fails
 *   while the module unloads cannot hold it: then only
 *   gc573_block_drivers() does.
 * No stream starts again; bus 1 and the HDMI poll stop too.
 * Process context. @locked: the caller holds the device lock, or runs
 * for a task that holds it and waits (probe, devres, shutdown); not an
 * ioctl, a worker or an ALSA callback (compat.h, gc573_block_drivers()).
 */
static void gc573_card_dead(struct gc573 *gc, const char *why, bool locked)
{
	struct pci_dev *pdev = gc->pdev;
	u16 cmd;

	WRITE_ONCE(gc->dma_dead, true);
	WRITE_ONCE(gc->vid.dead, true);
	WRITE_ONCE(gc->hdmi.polling, false);
	if (pci_enable_device(pdev))
		dev_err(&pdev->dev, "cannot keep the device enabled: its teardown will turn bus mastering off\n");
	/* never put: no runtime suspend, of it or of the port above it */
	pm_runtime_get_noresume(&pdev->dev);
	gc573_block_drivers(pdev, &gc573_pci_driver, locked);
	gc573_dead_add(pdev);
	__module_get(THIS_MODULE);
	pci_read_config_word(pdev, PCI_COMMAND, &cmd);
	if (cmd != (u16)~0 && !(cmd & PCI_COMMAND_MASTER))
		dev_err(&pdev->dev, "%s: bus mastering stays off, and the card gets no driver until reboot; reboot before using the card again\n",
			why);
	else
		dev_err(&pdev->dev, "%s: the card keeps bus mastering and gets no driver until reboot; reboot before using the card again\n",
			why);
}

/*
 * A DMA stop could not be confirmed (no INT bit 0 and no domain reset, an
 * engine still on after the teardown's stop, or a card that does not
 * answer): the audio DMA stopped as the quiesce does, then
 * gc573_card_dead(). The memory the card was given may still be written,
 * so it is kept for good, DMA-mapped, from here on: the buffers the card
 * was given (gc573_buf_cleanup()), their lists, the dummy list and the
 * audio buffers. A reboot gives it back. Called in process context;
 * @locked as for gc573_card_dead().
 */
void gc573_dma_dead(struct gc573 *gc, const char *why, bool locked)
{
	struct device *dev = &gc->pdev->dev;
	u32 run, vip;
	long kept;

	if (READ_ONCE(gc->dma_dead))
		return;
	gc573_audio_quiesce(gc);
	run = gc573_rd(gc, GC573_DMA_RUN);
	vip = gc573_rd(gc, GC573_VIP_CTRL);
	gc573_card_dead(gc, why, locked);
	kept = atomic_long_read(&gc->vid.exposed_bytes) + PAGE_SIZE +
	       GC573_AUD_BUF_BYTES;
	dev_warn(dev, "%ld KiB of DMA memory kept until reboot: the card did not confirm its DMA stopped (after the stop DMA_RUN %#010x VIP_CTRL %#010x)\n",
		 kept >> 10, run, vip);
}

/*
 * Devres, added right after pcim_enable_device() if bus mastering was on
 * when the probe started and the card did not read idle
 * (gc573_master_unchecked()): it runs after every other teardown action
 * and just before pcim's disable, which turns bus mastering off. A
 * previous owner may have left DMA running, so a probe that ends before
 * gc573_hw_stop_engines() confirmed the engines stopped leaves the card as
 * one whose stop failed. The card was given none of the driver's memory
 * before that point.
 */
static void gc573_master_guard(void *data)
{
	struct gc573 *gc = data;

	if (!gc->master_unchecked || READ_ONCE(gc->dma_dead))
		return;
	dev_warn(&gc->pdev->dev, "bus mastering was on when the probe started, and the card did not read idle: a previous owner may have left its DMA running\n");
	gc573_card_dead(gc, "the probe failed before the engines were stopped",
			true);
}

/*
 * Before any of the driver's DMA memory goes back (remove, a probe that
 * fails once the video device or the ALSA card exists): every engine
 * stopped for good, the domains reset (spec/init.md "Remove / quiesce"
 * steps 1 and 3), and the stop checked by what DMA_RUN and VIP_CTRL read
 * back. Interrupts stay on: the HDMI teardown still uses bus 1. Runs once,
 * from the first teardown action that frees DMA memory, under the device
 * lock (devres, shutdown). A card that died under an ioctl or a worker
 * gets its block again here, in place, before the unbind ends
 * (gc573_block_drivers()).
 */
void gc573_dma_stop(struct gc573 *gc)
{
	unsigned int fault = READ_ONCE(gc573_exp_stop_fault);
	struct device *dev = &gc->pdev->dev;
	u32 run, vip;

	if (gc->dma_stopped)
		return;
	gc->dma_stopped = true;
	if (READ_ONCE(gc->dma_dead))
		gc573_block_drivers(gc->pdev, &gc573_pci_driver, true);

	mutex_lock(&gc->vid.lock);
	gc->vid.dead = true;
	if (gc573_rd(gc, GC573_VIP_CTRL) & GC573_VIP_CTRL_OUT_EN)
		gc573_video_hw_stop(gc, true);
	mutex_unlock(&gc->vid.lock);
	/* a held stream's deadline: nothing queues it once dead is set */
	cancel_delayed_work_sync(&gc->vid.hold_work);
	gc573_audio_quiesce(gc);

	gc573_reset_domains(gc);
	run = gc573_rd(gc, GC573_DMA_RUN);
	vip = gc573_rd(gc, GC573_VIP_CTRL);
	/* tests only: a confirmed stop, counted as failed */
	if ((fault & GC573_STOP_FAULT_AUDIO) && run != U32_MAX &&
	    vip != U32_MAX && !(run & GC573_DMA_RUN_AUDIO) &&
	    !(vip & GC573_VIP_CTRL_OUT_EN)) {
		dev_warn(dev, "exp_stop_fault %#x: the teardown stop was confirmed (DMA_RUN %#010x VIP_CTRL %#010x), counted as the audio DMA still on\n",
			 fault, run, vip);
		run |= GC573_DMA_RUN_AUDIO;
	}
	if ((run & GC573_DMA_RUN_AUDIO) || (vip & GC573_VIP_CTRL_OUT_EN)) {
		dev_err(dev, "teardown stop failed: %s, DMA_RUN %#010x VIP_CTRL %#010x\n",
			run == U32_MAX || vip == U32_MAX ?
			"the card does not answer" : "DMA still on", run, vip);
		gc573_dma_dead(gc, "teardown stop failed", true);
	}
}

/*
 * spec/init.md "Remove / quiesce". Runs from devres on remove and on probe
 * failure, after the child devices are gone and before the IRQ is freed.
 */
static void gc573_quiesce(void *data)
{
	struct gc573 *gc = data;

	/* 1: stop video and audio, and never start them again */
	gc573_dma_stop(gc);

	/* 2: interrupts off, status cleared */
	gc573_irq_hw_disable(gc);

	/* 3: reset domains */
	gc573_reset_domains(gc);

	dev_dbg(&gc->pdev->dev, "quiesced: INT_ENABLE=%#010x INT_STATUS=%#010x RESET=%#010x\n",
		gc573_rd(gc, GC573_INT_ENABLE), gc573_rd(gc, GC573_INT_STATUS),
		gc573_rd(gc, GC573_RESET));

	/* 4: IRQ, then the card's own DMA memory, go after this (devres) */
}

/*
 * Hard handler: claim and ack the enabled bits that are set. Audio is
 * serviced here: a period has to leave its DMA buffer within 10 ms, and
 * its timestamp is the interrupt's. The rest is deferred to the thread.
 * Acking here keeps a shared INTx line from staying asserted while the
 * thread runs. spec/interrupts.md.
 */
static irqreturn_t gc573_irq(int irq, void *data)
{
	struct gc573 *gc = data;
	u32 status, pending, audio, done = 0;
	u64 ns = 0;

	status = gc573_rd(gc, GC573_INT_STATUS);
	if (status == U32_MAX)		/* device not responding */
		return IRQ_NONE;
	atomic_or(status, &gc->irq_seen);

	pending = status & GC573_INT_ENABLE_MASK;
	if (!pending)
		return IRQ_NONE;

	/* frame and period timestamps as close to the event as they get */
	if (pending & (GC573_INT_VID_DONE | GC573_INT_AUD_DONE))
		ns = ktime_get_ns();
	if (pending & GC573_INT_VID_DONE)
		WRITE_ONCE(gc->vid.irq_ns, ns);
	/* RD reads AUDIO_DONE before the ack (spec/audio.md "Running") */
	if (pending & GC573_INT_AUD_DONE)
		done = gc573_rd(gc, GC573_AUDIO_DONE);

	/* write 1 to clear exactly the bits taken for service */
	gc573_wr(gc, GC573_INT_STATUS, pending);

	audio = pending & (GC573_INT_AUD_STOP | GC573_INT_AUD_DONE);
	if (audio)
		gc573_audio_irq(gc, audio, done, ns);
	pending &= ~audio;
	if (!pending)
		return IRQ_HANDLED;
	atomic_or(pending, &gc->irq_pending);
	return IRQ_WAKE_THREAD;
}

static irqreturn_t gc573_irq_thread(int irq, void *data)
{
	struct gc573 *gc = data;
	u32 pending = atomic_xchg(&gc->irq_pending, 0);

	/* bits 8, 9: enabled by the spec's sequence, meaning unknown: ack only */
	if (pending & (GC573_INT_UNK8 | GC573_INT_UNK9))
		dev_dbg_ratelimited(&gc->pdev->dev, "interrupt %#x (bits 8/9)\n",
				    pending);

	if (pending & GC573_INT_I2C1)
		gc573_i2c1_irq(gc);

	if (pending & GC573_INT_VID_DONE)
		gc573_video_irq_done(gc);
	if (pending & GC573_INT_VID_TERM)
		gc573_video_irq_term(gc);

	return IRQ_HANDLED;
}

static void gc573_release(struct v4l2_device *v4l2_dev)
{
	struct gc573 *gc = container_of(v4l2_dev, struct gc573, v4l2_dev);

	gc573_video_release(gc);
	kfree(gc);
}

static void gc573_v4l2_put(void *data)
{
	struct gc573 *gc = data;

	v4l2_device_unregister(&gc->v4l2_dev);
	v4l2_device_put(&gc->v4l2_dev);
}

/*
 * Devres, added before pcim_enable_device(), so after pcim's disable: a
 * dead card's INTx stays disabled. The MSI teardown enables it again
 * (pci_msi_shutdown()), and a wedged card that asserts it would hold a
 * line another driver may share until the kernel turns the line off for
 * all of them; the card may not honour INTx Disable at all
 * (spec/open-questions.md #43). Not written if config space reads
 * all-ones.
 */
static void gc573_dead_intx(void *data)
{
	struct gc573 *gc = data;
	u16 cmd;

	if (!READ_ONCE(gc->dma_dead))
		return;
	pci_read_config_word(gc->pdev, PCI_COMMAND, &cmd);
	if (cmd != (u16)~0)
		pci_intx(gc->pdev, 0);
}

/*
 * Devres: bus mastering off in every teardown and probe unwind once it was
 * on, after the quiesce and free_irq and before the DMA memory goes back.
 * pcim's disable, which turns it off too, comes only after those frees.
 * Never after a stop the card did not confirm (spec/pci.md).
 */
static void gc573_clear_master(void *data)
{
	struct gc573 *gc = data;

	if (!READ_ONCE(gc->dma_dead))
		pci_clear_master(gc->pdev);
}

/*
 * System sleep. With no PM callbacks of the driver's, the PCI core turns
 * bus mastering off for suspend, hibernation and the restore of an image
 * (pci_pm_default_suspend()), whatever the card does; spec/pci.md forbids
 * that while its DMA may run. So no sleep while a stream is on, and from
 * the notice of one to its end no stream starts. An idle card sleeps as
 * the core has it (and needs a rebind or a reboot after a sleep that cut
 * its power). Cards whose stop failed: gc573_pm_dead_notify(), and here
 * too, for one whose stop fails while that notifier runs.
 */
static int gc573_pm_notify(struct notifier_block *nb, unsigned long action,
			   void *data)
{
	struct gc573 *gc = container_of(nb, struct gc573, pm_nb);
	const char *busy = NULL;
	bool sleeping;

	switch (action) {
	case PM_SUSPEND_PREPARE:
	case PM_HIBERNATION_PREPARE:
	case PM_RESTORE_PREPARE:
		sleeping = true;
		break;
	case PM_POST_SUSPEND:
	case PM_POST_HIBERNATION:
	case PM_POST_RESTORE:
		sleeping = false;
		break;
	default:
		return NOTIFY_DONE;
	}
	mutex_lock(&gc->vid.lock);
	spin_lock_irq(&gc->aud.lock);
	/*
	 * A stop that failed under vid.lock while gc573_pm_dead_notify(),
	 * which runs first, found no card dead yet: the stream is off by now
	 */
	if (sleeping && READ_ONCE(gc->dma_dead))
		busy = "the card did not confirm its DMA stopped";
	else if (sleeping && vb2_is_streaming(&gc->vid.queue))
		busy = "a video stream is on";
	else if (sleeping && gc->aud.running)
		busy = "an audio stream is on";
	else if (sleeping && gc573_audio_stop_unconfirmed(gc))
		busy = "an audio stop is not confirmed (no INT bit 4, the audio DMA still on)";
	else
		gc->sleeping = sleeping;
	spin_unlock_irq(&gc->aud.lock);
	mutex_unlock(&gc->vid.lock);
	if (!busy)
		return NOTIFY_DONE;
	dev_warn(&gc->pdev->dev, "system sleep refused: %s, and the PCI core would turn bus mastering off under its DMA\n",
		 busy);
	return notifier_from_errno(-EBUSY);
}

static int gc573_pm_dead_notify(struct notifier_block *nb,
				unsigned long action, void *data)
{
	unsigned int n;

	if (action != PM_SUSPEND_PREPARE && action != PM_HIBERNATION_PREPARE &&
	    action != PM_RESTORE_PREPARE)
		return NOTIFY_DONE;
	mutex_lock(&gc573_dead_lock);
	n = gc573_ndead;
	mutex_unlock(&gc573_dead_lock);
	if (!n)
		return NOTIFY_DONE;
	pr_warn("%s: system sleep refused: %u card(s) did not confirm their DMA stopped (dead_cards), and the PCI core would turn bus mastering off; reboot first\n",
		KBUILD_MODNAME, n);
	return notifier_from_errno(-EBUSY);
}

static struct notifier_block gc573_pm_dead_nb = {
	.notifier_call = gc573_pm_dead_notify,
};

static void gc573_pm_unregister(void *data)
{
	struct gc573 *gc = data;

	unregister_pm_notifier(&gc->pm_nb);
}

static void gc573_debugfs_remove(void *data)
{
	struct gc573 *gc = data;

	debugfs_remove_recursive(gc->debugfs);
}

/* Bring-up and experiment state; removed before anything it reads */
static int gc573_debugfs_init(struct gc573 *gc)
{
	char name[32];

	snprintf(name, sizeof(name), "%s-%s", KBUILD_MODNAME,
		 pci_name(gc->pdev));
	gc->debugfs = debugfs_create_dir(name, NULL);
	gc573_video_debugfs(gc);
	gc573_hdmi_debugfs(gc);
	gc573_audio_debugfs(gc);
	return devm_add_action_or_reset(&gc->pdev->dev, gc573_debugfs_remove,
					gc);
}

static int gc573_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct device *dev = &pdev->dev;
	unsigned long t_master;
	unsigned int types;
	struct gc573 *gc;
	int ret;

	if (gc573_dead_has(pdev)) {
		dev_err(dev, "this card did not confirm its DMA stopped earlier in this boot: not used; reboot before using the card again\n");
		return -ENODEV;
	}

	/* refcounted through v4l2_dev: open file handles can outlive remove */
	gc = kzalloc(sizeof(*gc), GFP_KERNEL);
	if (!gc)
		return -ENOMEM;
	gc->pdev = pdev;
	spin_lock_init(&gc->gpio_lock);
	spin_lock_init(&gc->dma_run_lock);
	mutex_init(&gc->i2c_lock);
	init_completion(&gc->i2c1_done);
	gc573_video_early_init(gc);
	gc573_audio_early_init(gc);
	pci_set_drvdata(pdev, gc);

	gc->v4l2_dev.release = gc573_release;
	ret = v4l2_device_register(dev, &gc->v4l2_dev);
	if (ret) {
		kfree(gc);
		return dev_err_probe(dev, ret, "cannot register v4l2 device\n");
	}
	ret = devm_add_action_or_reset(dev, gc573_v4l2_put, gc);
	if (ret)
		return ret;

	if (pci_resource_len(pdev, 0) < GC573_BAR0_SIZE)
		return dev_err_probe(dev, -ENODEV, "BAR0 too small: %pR\n",
				     &pdev->resource[0]);

	/*
	 * 1: PCI enable, bus master, BAR0, MSI (spec/pci.md). With bus
	 * mastering on and the card not idle, no unwind may turn it off
	 * before the engines were stopped (gc573_master_guard()); with it off
	 * and the card not idle, it never goes on (gc573_hw_stop_engines()).
	 */
	gc->master_unchecked = gc573_master_unchecked(gc);
	ret = devm_add_action_or_reset(dev, gc573_dead_intx, gc);
	if (ret)
		return ret;
	ret = pcim_enable_device(pdev);
	if (ret)
		return dev_err_probe(dev, ret, "cannot enable device\n");
	if (gc->master_unchecked) {
		ret = devm_add_action(dev, gc573_master_guard, gc);
		if (ret) {
			gc573_master_guard(gc);
			return ret;
		}
	}

	gc->mmio = gc573_pcim_iomap_region(pdev, 0, KBUILD_MODNAME);
	if (IS_ERR(gc->mmio))
		return dev_err_probe(dev, PTR_ERR(gc->mmio), "cannot map BAR0\n");

	/* 64-bit DMA is untested (spec/pci.md) */
	ret = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
	if (ret)
		return dev_err_probe(dev, ret, "no 32-bit DMA\n");
	/* one descriptor per segment: tell the DMA layer how long they get */
	dma_set_max_seg_size(dev, GC573_DMA_SEG_MAX);

	/* before the quiesce's action: devres frees these after it ran */
	ret = gc573_audio_alloc(gc);
	if (!ret)
		ret = gc573_video_alloc(gc);
	if (ret)
		return ret;

	/* no engine a previous owner left armed may write once this is on */
	gc573_mmio_ones_start(gc, GC573_MMIO_ONES_PROBE);
	ret = gc573_hw_stop_engines(gc);
	if (ret)
		return ret;
	pci_set_master(pdev);
	t_master = jiffies;
	/* off again after the quiesce and free_irq, before any DMA memory goes */
	ret = devm_add_action_or_reset(dev, gc573_clear_master, gc);
	if (ret)
		return ret;
	gc573_mmio_ones_start(gc, GC573_MMIO_ONES_BRIEF);
	gc573_mmio_ones_start(gc, GC573_MMIO_ONES_LONG);

	types = gc573_irq_types();
	ret = pci_alloc_irq_vectors(pdev, 1, 1, types);
	/*
	 * -EINVAL: MSI is off (pci=nomsi, the device's msi_bus) or the device
	 * cannot use it. -ENOMEM, -ENOSPC, -ENODEV: an allocation failed
	 * (drivers/pci/msi in 6.8), which INTx would not cure
	 */
	if (ret == -EINVAL && types == PCI_IRQ_MSI)
		return dev_err_probe(dev, ret,
				     "MSI unavailable: INTx is untested on this card (exp_intx=1 allows it)\n");
	if (ret < 0)
		return dev_err_probe(dev, ret, "cannot allocate the interrupt vector\n");
	gc->irq = pci_irq_vector(pdev, 0);
	if (gc->irq < 0)
		return dev_err_probe(dev, gc->irq, "no IRQ number\n");

	/* the card answers as it did before bus mastering went on */
	ret = gc573_answer_check(gc, t_master);
	if (ret)
		return ret;
	gc573_mmio_ones_start(gc, GC573_MMIO_ONES_INIT);

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

	/* HDMI chips: IDs, init, default EDID (spec/hdmi-chips.md) */
	ret = gc573_hdmi_init(gc);
	if (ret)
		return dev_err_probe(dev, ret, "HDMI front-end bring-up failed\n");

	ret = gc573_video_init(gc);
	if (ret)
		return dev_err_probe(dev, ret, "cannot register video device\n");

	ret = gc573_audio_init(gc);
	if (ret)
		return dev_err_probe(dev, ret, "cannot register sound card\n");

	/* no system sleep while a stream runs: gc573_pm_notify() */
	gc->pm_nb.notifier_call = gc573_pm_notify;
	ret = register_pm_notifier(&gc->pm_nb);
	if (ret)
		return dev_err_probe(dev, ret, "cannot register the PM notifier\n");
	ret = devm_add_action_or_reset(dev, gc573_pm_unregister, gc);
	if (ret)
		return ret;

	/* polling stops before the video device goes (devres order) */
	ret = gc573_hdmi_start(gc);
	if (ret)
		return ret;

	return gc573_debugfs_init(gc);
}

/*
 * Reboot, kexec: no DMA or interrupts may outlive this kernel. After a
 * stop the card did not confirm, bus mastering stays on (spec/pci.md):
 * a reboot's platform reset stops the card. A kexec does not wait for
 * that: the PCI core turns bus mastering off on every PCI device in D0 to
 * D3hot, bound to a driver or not, after its driver's shutdown
 * (pci_device_shutdown(), the bus's shutdown, which device_shutdown()
 * calls for every device), so a dead card's is turned off too (README).
 */
static void gc573_shutdown(struct pci_dev *pdev)
{
	struct gc573 *gc = pci_get_drvdata(pdev);

	gc573_hdmi_shutdown(gc);
	gc573_quiesce(gc);
	if (!READ_ONCE(gc->dma_dead))
		pci_clear_master(pdev);
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
	.shutdown	= gc573_shutdown,
};

static int __init gc573_init(void)
{
	int ret;

	ret = register_pm_notifier(&gc573_pm_dead_nb);
	if (ret)
		return ret;
	ret = pci_register_driver(&gc573_pci_driver);
	if (ret)
		unregister_pm_notifier(&gc573_pm_dead_nb);
	return ret;
}
module_init(gc573_init);

static void __exit gc573_exit(void)
{
	pci_unregister_driver(&gc573_pci_driver);
	unregister_pm_notifier(&gc573_pm_dead_nb);
}
module_exit(gc573_exit);

MODULE_DESCRIPTION("AVerMedia Live Gamer 4K (GC573) HDMI capture driver");
MODULE_LICENSE("GPL");
/* how a dead card is kept from other drivers here (compat.h) */
MODULE_INFO(dead_block, GC573_DEAD_BLOCK);
