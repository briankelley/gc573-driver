// SPDX-License-Identifier: GPL-2.0
/*
 * GC573 I2C masters (spec/i2c.md).
 *
 * Bus 1 is a register-addressed transaction engine that carries all HDMI
 * chip traffic: one command reads or writes up to a FIFO's worth of bytes
 * at one device register and raises INT bit 11 when it ends. It is an
 * i2c_adapter whose transfers sleep on a completion that the IRQ thread
 * signals; a mutex serialises transfers and no spinlock is held across one.
 */

#include <linux/completion.h>
#include <linux/device.h>
#include <linux/i2c.h>
#include <linux/jiffies.h>
#include <linux/mutex.h>
#include <linux/pci.h>

#include "gc573.h"

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

int gc573_i2c_init(struct gc573 *gc)
{
	int ret;

	ret = gc573_i2c_add(gc, &gc->i2c1, 1, &gc573_i2c1_algo,
			    &gc573_i2c1_quirks, gc);
	if (ret)
		return ret;

	dev_info(&gc->pdev->dev, "I2C bus 1: %s\n", dev_name(&gc->i2c1.dev));
	return 0;
}
