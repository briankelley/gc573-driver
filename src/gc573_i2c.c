// SPDX-License-Identifier: GPL-2.0
/*
 * GC573 I2C masters (spec/i2c.md).
 *
 * Bus 1 is a register-addressed transaction engine that carries all HDMI
 * chip traffic: one command reads or writes up to a FIFO's worth of bytes
 * at one device register and raises INT bit 11 when it ends. It is an
 * i2c_adapter whose transfers sleep on a completion that the IRQ thread
 * signals; a mutex serialises transfers and no spinlock is held across one.
 *
 * Buses 0 and 2 are OpenCores-compatible byte masters, driven by polling.
 * Nothing is known about the devices on them (an EEPROM or authentication
 * chip may be there; spec/open-questions.md #12), so their adapters refuse
 * every transfer unless the i2c_bus02 parameter is set at load time.
 */

#include <linux/completion.h>
#include <linux/device.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/iopoll.h>
#include <linux/jiffies.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/string.h>

#include "gc573.h"

static bool i2c_bus02;
module_param(i2c_bus02, bool, 0444);
MODULE_PARM_DESC(i2c_bus02,
		 "Allow transfers on I2C buses 0 and 2, whose devices are not identified yet (default: off)");

/* spec/i2c.md: RD's transfer timeout is 20 ms, with one retry */
#define GC573_I2C1_TIMEOUT_MS		20
#define GC573_I2C1_TRIES		2

/*
 * Longest transfers seen in the traces (spec/i2c.md): 32-byte reads and
 * 18-byte writes. The engine's FIFO limits are unknown, so go no further.
 */
#define GC573_I2C1_MAX_READ		32
#define GC573_I2C1_MAX_WRITE		18

/* IRQ thread, INT bit 11: latch the engine status, wake the transfer. */
void gc573_i2c1_irq(struct gc573 *gc)
{
	WRITE_ONCE(gc->i2c1_status, ioread8(gc->mmio + GC573_I2C1_STATUS));
	complete(&gc->i2c1_done);
}

static int gc573_i2c1_wait(struct gc573 *gc, u8 ok)
{
	unsigned long t = msecs_to_jiffies(GC573_I2C1_TIMEOUT_MS);

	if (!wait_for_completion_timeout(&gc->i2c1_done, t))
		return -ETIMEDOUT;
	return (READ_ONCE(gc->i2c1_status) & ok) ? 0 : -EIO;
}

/* spec/i2c.md "Read (LEN bytes)" */
static int gc573_i2c1_read(struct gc573 *gc, u8 addr8, u8 reg, u8 *buf,
			   u16 len)
{
	int ret;
	u16 i;

	reinit_completion(&gc->i2c1_done);
	gc573_wr(gc, GC573_I2C1_ADDR, addr8 | 1);
	gc573_wr(gc, GC573_I2C1_ZERO_188, 0);
	gc573_wr(gc, GC573_I2C1_SUBADDR, reg);
	gc573_wr(gc, GC573_I2C1_ZERO_18C, 0);
	gc573_wr(gc, GC573_I2C1_LEN, len);
	gc573_wr(gc, GC573_I2C1_CMD, GC573_I2C1_CMD_CLEAR);
	gc573_wr(gc, GC573_I2C1_CMD, GC573_I2C1_CMD_READ);

	ret = gc573_i2c1_wait(gc, GC573_I2C1_STATUS_RD_OK);
	if (ret)
		return ret;

	gc573_wr(gc, GC573_I2C1_CMD, GC573_I2C1_CMD_CLEAR);
	for (i = 0; i < len; i++)
		buf[i] = gc573_rd(gc, GC573_I2C1_RXFIFO) & 0xff;
	return 0;
}

/* spec/i2c.md "Write (LEN bytes)" */
static int gc573_i2c1_write(struct gc573 *gc, u8 addr8, u8 reg,
			    const u8 *buf, u16 len)
{
	u16 i;

	reinit_completion(&gc->i2c1_done);
	gc573_wr(gc, GC573_I2C1_ADDR, addr8 & 0xfe);
	gc573_wr(gc, GC573_I2C1_ZERO_188, 0);
	gc573_wr(gc, GC573_I2C1_SUBADDR, reg);
	gc573_wr(gc, GC573_I2C1_CMD, GC573_I2C1_CMD_CLEAR);
	gc573_wr(gc, GC573_I2C1_ZERO_18C, 0);
	gc573_wr(gc, GC573_I2C1_LEN, len);
	for (i = 0; i < len; i++)
		gc573_wr(gc, GC573_I2C1_TXFIFO, buf[i]);
	gc573_wr(gc, GC573_I2C1_CMD, GC573_I2C1_CMD_WRITE);

	return gc573_i2c1_wait(gc, GC573_I2C1_STATUS_WR_OK);
}

/*
 * The engine only does register-addressed transfers, so it takes exactly
 * two message shapes: write [reg] then read n bytes from the same device,
 * or a single write of [reg, data...]. The quirks below let the I2C core
 * reject most other shapes before they get here.
 */
static int gc573_i2c1_xfer(struct i2c_adapter *adap, struct i2c_msg *msgs,
			   int num)
{
	struct gc573 *gc = i2c_get_adapdata(adap);
	struct i2c_msg *m = &msgs[0];
	unsigned int tries;
	bool rd;
	int i, ret = -ETIMEDOUT;

	for (i = 0; i < num; i++) {
		if (msgs[i].flags & ~(I2C_M_RD | I2C_M_DMA_SAFE))
			return -EOPNOTSUPP;
		if (msgs[i].addr > 0x7f)
			return -EINVAL;
	}

	if (num == 2 && !(m->flags & I2C_M_RD) && m->len == 1 &&
	    (msgs[1].flags & I2C_M_RD) && msgs[1].addr == m->addr &&
	    msgs[1].len >= 1 && msgs[1].len <= GC573_I2C1_MAX_READ)
		rd = true;
	else if (num == 1 && !(m->flags & I2C_M_RD) &&
		 m->len >= 2 && m->len <= 1 + GC573_I2C1_MAX_WRITE)
		rd = false;
	else
		return -EOPNOTSUPP;

	mutex_lock(&gc->i2c_lock);
	for (tries = 1; tries <= GC573_I2C1_TRIES; tries++) {
		if (rd)
			ret = gc573_i2c1_read(gc, m->addr << 1, m->buf[0],
					      msgs[1].buf, msgs[1].len);
		else
			ret = gc573_i2c1_write(gc, m->addr << 1, m->buf[0],
					       m->buf + 1, m->len - 1);
		if (ret != -ETIMEDOUT)
			break;
		/* let a late INT bit 11 land before the retry re-arms the wait */
		synchronize_irq(gc->irq);
	}
	mutex_unlock(&gc->i2c_lock);

	if (ret == -ETIMEDOUT)
		dev_warn_ratelimited(&gc->pdev->dev,
				     "I2C bus 1: 0x%02x reg 0x%02x %s timeout\n",
				     m->addr << 1, m->buf[0], rd ? "read" : "write");
	return ret ? ret : num;
}

static u32 gc573_i2c1_func(struct i2c_adapter *adap)
{
	return I2C_FUNC_SMBUS_BYTE_DATA | I2C_FUNC_SMBUS_WORD_DATA |
	       I2C_FUNC_SMBUS_I2C_BLOCK;
}

static const struct i2c_algorithm gc573_i2c1_algo = {
	.master_xfer	= gc573_i2c1_xfer,
	.functionality	= gc573_i2c1_func,
};

static const struct i2c_adapter_quirks gc573_i2c1_quirks = {
	.flags			= I2C_AQ_COMB_WRITE_THEN_READ | I2C_AQ_NO_ZERO_LEN,
	.max_write_len		= 1 + GC573_I2C1_MAX_WRITE,
	.max_read_len		= GC573_I2C1_MAX_READ,
	.max_comb_1st_msg_len	= 1,
	.max_comb_2nd_msg_len	= GC573_I2C1_MAX_READ,
};

/*
 * Byte masters. spec/i2c.md gives RD's sequence (TXR, CR, poll SR.TIP,
 * check SR.RxACK) and command bytes; register semantics per P:OC-I2C.
 * A byte takes about 90 us at 100 kHz; allow 5 ms for clock stretching.
 */
#define GC573_OC_POLL_US		10
#define GC573_OC_TIMEOUT_US		5000

static int gc573_oc_cmd(struct gc573_ocbus *bus, u32 cmd, u32 *sr)
{
	struct gc573 *gc = bus->gc;

	gc573_wr(gc, bus->base + GC573_OC_CR, cmd);
	return read_poll_timeout(ioread32, *sr, !(*sr & GC573_OC_SR_TIP),
				 GC573_OC_POLL_US, GC573_OC_TIMEOUT_US, false,
				 gc->mmio + bus->base + GC573_OC_SR);
}

/* One message: (repeated) START and address byte, then the data bytes. */
static int gc573_oc_msg(struct gc573_ocbus *bus, struct i2c_msg *msg,
			bool last)
{
	struct gc573 *gc = bus->gc;
	bool rd = msg->flags & I2C_M_RD;
	u32 sr, cmd;
	int ret;
	u16 i;

	gc573_wr(gc, bus->base + GC573_OC_TXR, i2c_8bit_addr_from_msg(msg));
	ret = gc573_oc_cmd(bus, GC573_OC_CR_STA | GC573_OC_CR_WR, &sr);
	if (ret)
		goto stop;
	if (sr & GC573_OC_SR_AL)
		return -EAGAIN;
	if (sr & GC573_OC_SR_RXACK) {
		ret = -ENXIO;
		goto stop;
	}

	for (i = 0; i < msg->len; i++) {
		bool final = last && i == msg->len - 1;

		if (rd) {
			cmd = GC573_OC_CR_RD;
			if (i == msg->len - 1)
				cmd |= GC573_OC_CR_ACK;	/* NACK the last byte */
		} else {
			gc573_wr(gc, bus->base + GC573_OC_TXR, msg->buf[i]);
			cmd = GC573_OC_CR_WR;
		}
		if (final)
			cmd |= GC573_OC_CR_STO;

		ret = gc573_oc_cmd(bus, cmd, &sr);
		if (ret)
			goto stop;
		if (sr & GC573_OC_SR_AL)
			return -EAGAIN;
		if (rd) {
			msg->buf[i] = gc573_rd(gc, bus->base + GC573_OC_RXR) & 0xff;
		} else if (sr & GC573_OC_SR_RXACK) {
			if (final)		/* STOP already sent */
				return -EIO;
			ret = -EIO;
			goto stop;
		}
	}
	return 0;

stop:
	gc573_oc_cmd(bus, GC573_OC_CR_STO, &sr);
	return ret;
}

static int gc573_oc_xfer(struct i2c_adapter *adap, struct i2c_msg *msgs,
			 int num)
{
	struct gc573_ocbus *bus = i2c_get_adapdata(adap);
	int i, ret = 0;

	if (!i2c_bus02) {
		dev_notice_ratelimited(&bus->gc->pdev->dev,
				       "%s: transfer refused (i2c_bus02=0)\n",
				       adap->name);
		return -EPERM;
	}

	for (i = 0; i < num; i++) {
		if (msgs[i].flags & ~(I2C_M_RD | I2C_M_DMA_SAFE))
			return -EOPNOTSUPP;
		if (msgs[i].addr > 0x7f)
			return -EINVAL;
	}

	/* bus 0 may share wires with the bus 1 engine (spec/i2c.md) */
	mutex_lock(&bus->gc->i2c_lock);
	for (i = 0; i < num && !ret; i++)
		ret = gc573_oc_msg(bus, &msgs[i], i == num - 1);
	mutex_unlock(&bus->gc->i2c_lock);

	return ret ? ret : num;
}

static u32 gc573_oc_func(struct i2c_adapter *adap)
{
	return I2C_FUNC_I2C | (I2C_FUNC_SMBUS_EMUL & ~I2C_FUNC_SMBUS_QUICK);
}

static const struct i2c_algorithm gc573_oc_algo = {
	.master_xfer	= gc573_oc_xfer,
	.functionality	= gc573_oc_func,
};

/* Zero-length messages are not in spec/i2c.md: no address-only probes. */
static const struct i2c_adapter_quirks gc573_oc_quirks = {
	.flags		= I2C_AQ_NO_ZERO_LEN,
};

/* Register an adapter; devres deletes it before the quiesce runs. */
static int gc573_i2c_add(struct gc573 *gc, struct i2c_adapter *adap, int bus,
			 const struct i2c_algorithm *algo,
			 const struct i2c_adapter_quirks *quirks, void *data)
{
	struct device *dev = &gc->pdev->dev;
	int ret;

	adap->owner = THIS_MODULE;
	adap->algo = algo;
	adap->quirks = quirks;
	adap->dev.parent = dev;
	snprintf(adap->name, sizeof(adap->name), "gc573 %s bus %d",
		 pci_name(gc->pdev), bus);
	i2c_set_adapdata(adap, data);

	ret = devm_i2c_add_adapter(dev, adap);
	if (ret)
		return dev_err_probe(dev, ret, "cannot add I2C bus %d\n", bus);
	return 0;
}

/* Clocks and core enables are set by the FPGA init (spec/init.md step 5). */
int gc573_i2c_init(struct gc573 *gc)
{
	int ret;

	gc->i2c0.gc = gc;
	gc->i2c0.base = GC573_I2C0_BASE;
	gc->i2c2.gc = gc;
	gc->i2c2.base = GC573_I2C2_BASE;

	ret = gc573_i2c_add(gc, &gc->i2c0.adap, 0, &gc573_oc_algo,
			    &gc573_oc_quirks, &gc->i2c0);
	if (!ret)
		ret = gc573_i2c_add(gc, &gc->i2c1, 1, &gc573_i2c1_algo,
				    &gc573_i2c1_quirks, gc);
	if (!ret)
		ret = gc573_i2c_add(gc, &gc->i2c2.adap, 2, &gc573_oc_algo,
				    &gc573_oc_quirks, &gc->i2c2);
	if (ret)
		return ret;

	dev_info(&gc->pdev->dev,
		 "I2C bus 0: %s, bus 1: %s, bus 2: %s (bus 0/2 transfers %s)\n",
		 dev_name(&gc->i2c0.adap.dev), dev_name(&gc->i2c1.dev),
		 dev_name(&gc->i2c2.adap.dev), i2c_bus02 ? "on" : "off");
	return 0;
}

/*
 * HDMI chip IDs, registers 0x00-0x03 on bus 1 (spec/i2c.md "Device
 * inventory"). Read with the transfers RD uses at load (T1/S01): IT6805
 * one byte per transfer, splitter two. Read-only: RD's bank-select write
 * (0x0f = 0) before the splitter reads is left out.
 */
struct gc573_chip_id {
	const char *name;
	u16 addr;		/* 7-bit */
	u8 step;		/* bytes per read transfer */
	u8 id[4];
};

static const struct gc573_chip_id gc573_chip_ids[] = {
	{ "IT6805", 0x48, 1, { 0x54, 0x49, 0x05, 0x68 } },
	{ "splitter", 0x2c, 2, { 0x54, 0x49, 0x63, 0x66 } },
};

static int gc573_i2c_read_id(struct gc573 *gc,
			     const struct gc573_chip_id *chip, u8 *id)
{
	u8 reg;
	int ret;

	for (reg = 0; reg < sizeof(chip->id); reg += chip->step) {
		struct i2c_msg msgs[] = {
			{ .addr = chip->addr, .len = 1, .buf = &reg },
			{ .addr = chip->addr, .flags = I2C_M_RD,
			  .len = chip->step, .buf = id + reg },
		};

		ret = i2c_transfer(&gc->i2c1, msgs, 2);
		if (ret != 2)
			return ret < 0 ? ret : -EIO;
	}
	return 0;
}

/* M1 gate: read and log both chip IDs. A mismatch is logged, not fatal. */
void gc573_i2c_check_ids(struct gc573 *gc)
{
	struct device *dev = &gc->pdev->dev;
	u8 id[sizeof(gc573_chip_ids[0].id)];
	unsigned int i;
	int ret;

	/* the chip-reset settle time (spec/init.md step 11) is in hw init */
	for (i = 0; i < ARRAY_SIZE(gc573_chip_ids); i++) {
		const struct gc573_chip_id *chip = &gc573_chip_ids[i];

		ret = gc573_i2c_read_id(gc, chip, id);
		if (ret)
			dev_err(dev, "I2C bus 1 0x%02x (%s): id read failed: %d\n",
				chip->addr << 1, chip->name, ret);
		else
			dev_info(dev, "I2C bus 1 0x%02x (%s): id %*ph %s\n",
				 chip->addr << 1, chip->name, (int)sizeof(id), id,
				 memcmp(id, chip->id, sizeof(id)) ? "MISMATCH" : "OK");
	}
}
