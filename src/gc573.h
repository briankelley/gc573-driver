/* SPDX-License-Identifier: GPL-2.0 */
/*
 * AVerMedia Live Gamer 4K (GC573) driver: shared definitions.
 *
 * Every register and value here is taken from spec/ in this repository;
 * the comment on each group names the spec file. Offsets are bytes into
 * BAR0, registers are 32-bit little-endian unless stated otherwise.
 */
#ifndef GC573_H
#define GC573_H

#include <linux/atomic.h>
#include <linux/bits.h>
#include <linux/completion.h>
#include <linux/i2c.h>
#include <linux/io.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/types.h>

struct pci_dev;

/* spec/pci.md */
#define GC573_BAR0_SIZE			0x80000		/* 512 KiB */

/* Core block, spec/regmap.md */
#define GC573_VERSION			0x000		/* FPGA build date, BCD YYYYMMDD */
#define GC573_RESET			0x00c
#define GC573_INT_STATUS		0x010		/* write 1 to clear */
#define GC573_INT_ENABLE		0x01c
#define GC573_GPIO			0x040

/* Reset domains, spec/init.md step 2 */
#define GC573_RESET_DOMAIN_0		BIT(0)
#define GC573_RESET_DOMAIN_8		BIT(8)
#define GC573_RESET_DOMAIN_9		BIT(9)

/* Interrupt bits, spec/interrupts.md */
#define GC573_INT_VID_TERM		BIT(0)		/* video stream terminated */
#define GC573_INT_VID_DONE		BIT(1)		/* video list done (ch0) */
#define GC573_INT_AUD_STOP		BIT(4)		/* audio DMA stopped */
#define GC573_INT_AUD_DONE		BIT(5)		/* audio period done */
#define GC573_INT_UNK8			BIT(8)		/* enabled, meaning unknown */
#define GC573_INT_UNK9			BIT(9)		/* enabled, meaning unknown */
#define GC573_INT_I2C1			BIT(11)		/* I2C bus-1 transfer complete */
#define GC573_INT_ENABLE_MASK		0xb33		/* bits 0, 1, 4, 5, 8, 9, 11 */
#define GC573_INT_STALE_MASK		0xbff		/* stale bits cleared at enable */

/* GPIO (0x040) bits, spec/regmap.md "GPIO"; write by read-modify-write */
#define GC573_GPIO_BIT1			BIT(1)		/* cleared at init, role unknown */
#define GC573_GPIO_EN4			BIT(4)		/* enable, reads back 1 when on */
#define GC573_GPIO_RST5_N		BIT(5)		/* active-low reset, chip unknown */
#define GC573_GPIO_EN6			BIT(6)		/* enable, reads back 1 when on */
#define GC573_GPIO_RST8_N		BIT(8)		/* active-low reset, chip unknown */

/* I2C clock setup registers, spec/init.md step 5 and spec/i2c.md */
#define GC573_I2C2_BASE			0x100		/* bus 2 byte master */
#define GC573_I2C0_BASE			0x120		/* bus 0 byte master */
#define GC573_OC_PRERLO			0x00		/* OpenCores prescale low */
#define GC573_OC_PRERHI			0x04		/* OpenCores prescale high */
#define GC573_OC_CTR			0x08		/* OpenCores control */
#define GC573_OC_CTR_EN			BIT(7)		/* core enable */
#define GC573_OC_TXR			0x0c		/* write: byte to send */
#define GC573_OC_RXR			0x0c		/* read: byte received */
#define GC573_OC_CR			0x10		/* write: command */
#define GC573_OC_SR			0x10		/* read: status */
#define GC573_OC_CR_STA			BIT(7)		/* (repeated) START */
#define GC573_OC_CR_STO			BIT(6)		/* STOP */
#define GC573_OC_CR_RD			BIT(5)		/* read a byte */
#define GC573_OC_CR_WR			BIT(4)		/* write a byte */
#define GC573_OC_CR_ACK			BIT(3)		/* 1 = answer NACK */
#define GC573_OC_SR_RXACK		BIT(7)		/* 1 = no ACK received */
#define GC573_OC_SR_AL			BIT(5)		/* arbitration lost */
#define GC573_OC_SR_TIP			BIT(1)		/* transfer in progress */
#define GC573_I2C0_PRESCALE		0x3d
#define GC573_I2C2_PRESCALE		0xf9
#define GC573_I2C1_PRESCALE		0x180		/* bus 1 engine prescale */
#define GC573_I2C1_PRESCALE_VAL		0x138

/* I2C bus 1 transaction engine, spec/i2c.md */
#define GC573_I2C1_ADDR			0x184		/* 8-bit address, bit 0 = read */
#define GC573_I2C1_ZERO_188		0x188		/* role unknown, 0 each transfer */
#define GC573_I2C1_ZERO_18C		0x18c		/* role unknown, 0 each transfer */
#define GC573_I2C1_SUBADDR		0x190		/* device register address */
#define GC573_I2C1_LEN			0x194		/* byte count */
#define GC573_I2C1_TXFIFO		0x198		/* write pushes one byte */
#define GC573_I2C1_RXFIFO		0x19c		/* read pops one byte, bits 7:0 */
#define GC573_I2C1_CMD			0x1a0
#define GC573_I2C1_CMD_CLEAR		0x10		/* clear/flush */
#define GC573_I2C1_CMD_WRITE		0x04		/* start write */
#define GC573_I2C1_CMD_READ		0x08		/* start read */
#define GC573_I2C1_STATUS		0x1a4		/* 8-bit read */
#define GC573_I2C1_STATUS_WR_OK		BIT(0)
#define GC573_I2C1_STATUS_RD_OK		BIT(2)

/* Video input processing block, spec/regmap.md */
#define GC573_DDR_STATUS		0x107c
#define GC573_DDR_READY			BIT(0)
#define GC573_DDR_RECOVER_1		0x8		/* recovery writes: 8, then 1 */
#define GC573_DDR_RECOVER_2		0x1

/* Scalers, spec/regmap.md */
#define GC573_SCALER_RESET		0x50000
#define GC573_SCALER_RUN		0x3		/* both scaler cores out of reset */

/* OpenCores-compatible byte master (I2C bus 0 or bus 2) */
struct gc573_ocbus {
	struct gc573 *gc;
	struct i2c_adapter adap;
	u32 base;			/* GC573_I2C0_BASE or GC573_I2C2_BASE */
};

struct gc573 {
	struct pci_dev *pdev;
	void __iomem *mmio;
	int irq;
	u32 fw_version;

	/* INT_STATUS bits acked by the hard handler, serviced by the thread */
	atomic_t irq_pending;

	/* serialises read-modify-write of GPIO (0x040) */
	spinlock_t gpio_lock;

	/* serialises the I2C masters: one transfer on the card at a time */
	struct mutex i2c_lock;
	struct i2c_adapter i2c1;	/* bus 1 engine: HDMI chips */
	struct completion i2c1_done;	/* bus 1 transfer ended (INT bit 11) */
	u8 i2c1_status;			/* GC573_I2C1_STATUS latched at INT bit 11 */
	struct gc573_ocbus i2c0;	/* byte master, devices unknown */
	struct gc573_ocbus i2c2;	/* byte master, devices unknown */
};

int gc573_i2c_init(struct gc573 *gc);
void gc573_i2c1_irq(struct gc573 *gc);
void gc573_i2c_check_ids(struct gc573 *gc);

static inline u32 gc573_rd(struct gc573 *gc, u32 off)
{
	return ioread32(gc->mmio + off);
}

static inline void gc573_wr(struct gc573 *gc, u32 off, u32 val)
{
	iowrite32(val, gc->mmio + off);
}

#endif /* GC573_H */
