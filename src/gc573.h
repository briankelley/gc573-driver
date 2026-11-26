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
#include <linux/dma-mapping.h>
#include <linux/i2c.h>
#include <linux/io.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/sizes.h>
#include <linux/spinlock.h>
#include <linux/types.h>
#include <linux/workqueue.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-dev.h>
#include <media/v4l2-device.h>
#include <media/videobuf2-v4l2.h>

#include "gc573_chip.h"

struct dentry;
struct pci_dev;
struct sg_table;
struct snd_card;
struct snd_pcm_substream;

/* spec/pci.md */
#define GC573_BAR0_SIZE			0x80000		/* 512 KiB */

/* Core block, spec/regmap.md */
#define GC573_VERSION			0x000		/* FPGA build date, BCD YYYYMMDD */
#define GC573_TLP_ALIGN			0x004		/* read only (debugfs) */
#define GC573_DMA_RUN			0x008		/* read-modify-write only */
#define GC573_DMA_RUN_AUDIO		BIT(1)		/* audio DMA runs */
#define GC573_RESET			0x00c
#define GC573_INT_STATUS		0x010		/* write 1 to clear */
#define GC573_AUDIO_DONE		0x014		/* [1:0] buffer completed */
#define GC573_AUDIO_DONE_MASK		GENMASK(1, 0)
#define GC573_AUDIO_DONE_BUF0		1
#define GC573_AUDIO_DONE_BUF1		2
#define GC573_INT_ENABLE		0x01c
#define GC573_GPIO			0x040

/* Reset domains, spec/init.md step 2 */
#define GC573_RESET_DOMAIN_0		BIT(0)
#define GC573_RESET_DOMAIN_8		BIT(8)
#define GC573_RESET_DOMAIN_9		BIT(9)
#define GC573_RESET_DOMAINS		(GC573_RESET_DOMAIN_0 | GC573_RESET_DOMAIN_8 | \
					 GC573_RESET_DOMAIN_9)

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
#define GC573_GPIO_HPD			BIT(2)		/* splitter TX port 1 HPD, 1 = high */
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

/*
 * Audio DMA, spec/regmap.md "Audio DMA" and spec/audio.md: two buffers
 * the FPGA fills in turn, one period each. The meaning of CFG0, CFG1 and
 * the slot map is unknown; the driver writes RD's values.
 */
#define GC573_AUD_CFG0			0x200
#define GC573_AUD_PERIOD_A		0x204		/* period length, dwords */
#define GC573_AUD_BUF0_LO		0x208
#define GC573_AUD_BUF0_HI		0x20c
#define GC573_AUD_BUF1_LO		0x210
#define GC573_AUD_BUF1_HI		0x214
#define GC573_AUD_CFG1			0x218
#define GC573_AUD_PERIOD_B		0x21c		/* same value as PERIOD_A */
#define GC573_AUD_SLOT(n)		(0x2b4 + 4 * (n))	/* n = 0..3 */
#define GC573_AUD_SLOTS			4

/*
 * Video DMA channels, spec/regmap.md and spec/video-dma.md. One channel
 * per image plane, four buffer slots per channel. ch1/ch2 CH_CTRL read
 * back 0xeeeeeeee: software keeps what it last wrote.
 */
#define GC573_VCH_NUM			3
#define GC573_VCH_SLOTS			4
#define GC573_VCH0_BASE			0x300
#define GC573_VCH1_BASE			0x500
#define GC573_VCH2_BASE			0x600
#define GC573_VCH_STATUS		0x00		/* ch0: [2:0] = done slot + 1 */
#define GC573_VCH_STATUS_SLOT		GENMASK(2, 0)
#define GC573_VCH_CTRL			0x04
#define GC573_VCH_CTRL_RUN		BIT(0)
#define GC573_VCH_CTRL_SLOT(n)		BIT((n) + 1)	/* slot n valid */
#define GC573_VCH_CTRL_SLOTS		GENMASK(4, 1)
#define GC573_VCH_LIST_LO(n)		(0x08 + 12 * (n))
#define GC573_VCH_LIST_HI(n)		(0x0c + 12 * (n))
#define GC573_VCH_COUNT(n)		(0x10 + 12 * (n))

/*
 * Longest contiguous chunk one descriptor describes, and the DMA max
 * segment size the driver declares. RD's traced lists used chunks of 4 MB
 * and more (T3/S22: 2 descriptors for an 8294400-byte plane); the hardware
 * limit is unknown.
 */
#define GC573_DMA_SEG_MAX		SZ_2M

/* Video DMA descriptor, 4 little-endian words, spec/video-dma.md */
#define GC573_DESC_WORDS		4
#define GC573_DESC_SIZE			16
#define GC573_DESC_CTRL			0x80008000	/* on every descriptor RD used */
#define GC573_DESC_LEN_ALIGN		32		/* chunk length granularity */
#define GC573_DESC_ADDR_ALIGN		256		/* chunk start alignment */

/* Video input processing block, spec/regmap.md, spec/video-pipeline.md */
#define GC573_VIP_CTRL			0x1000
#define GC573_VIP_CTRL_OUT_EN		BIT(0)		/* gates frames into DMA */
#define GC573_VIP_CTRL_SCALER		BIT(7)		/* 1 = scalers in path */
#define GC573_VIP_CTRL_FMT		GENMASK(15, 8)	/* pixel format code */
#define GC573_IN_STATUS			0x1004		/* [1:0] timing stable */
#define GC573_IN_WIDTH			0x1008		/* bus clocks per line */
#define GC573_IN_HEIGHT			0x100c		/* active lines */
#define GC573_IN_FRAME_PERIOD		0x1010		/* 100 MHz ticks, ~0 = none */
#define GC573_IN_FRAME_PERIOD_HZ	100000000U	/* its tick rate */
#define GC573_AUDIO_SAMPLE_PERIOD	0x10a0		/* ticks per sample, ~0 = none */
#define GC573_AUDIO_SAMPLE_PERIOD_HZ	100000000U
#define GC573_CLIP_LEFT			0x1020
#define GC573_CLIP_WIDTH		0x1024
#define GC573_CLIP_TOP			0x1028
#define GC573_CLIP_HEIGHT		0x102c
#define GC573_COLOR_CTRL		0x1040
#define GC573_COLOR_CTRL_IN422		BIT(0)		/* input YCbCr 4:2:2 */
#define GC573_COLOR_CTRL_R2Y		BIT(1)		/* RGB->YUV CSC */
#define GC573_COLOR_CTRL_ADJUST		BIT(2)		/* brightness etc. */
#define GC573_COLOR_CTRL_Y2R		BIT(3)		/* YUV->RGB CSC */
#define GC573_COLOR_CTRL_DUAL		BIT(5)		/* dual-pixel input bus */
#define GC573_COLOR_CTRL_IN420		BIT(19)		/* input YCbCr 4:2:0 */
#define GC573_CONTRAST			0x105c
#define GC573_BRIGHTNESS		0x1060
#define GC573_HUE			0x1064
#define GC573_SATURATION		0x1068
#define GC573_CONTRAST_DEF		0x100
#define GC573_BRIGHTNESS_DEF		0x200
#define GC573_HUE_DEF			0
#define GC573_SATURATION_DEF		0x80
#define GC573_DDR_STATUS		0x107c
#define GC573_DDR_READY			BIT(0)
#define GC573_DDR_RECOVER_1		0x8		/* recovery writes: 8, then 1 */
#define GC573_DDR_RECOVER_2		0x1
#define GC573_RATE_CTRL			0x1080
#define GC573_RATE_CTRL_FPS		GENMASK(31, 16)	/* rate limit, fps */
#define GC573_RATE_CTRL_CSC		GENMASK(2, 1)
#define GC573_RATE_CTRL_IN_YUV		BIT(1)		/* input is YUV */
#define GC573_RATE_CTRL_OUT_RGB		BIT(2)		/* output is RGB */
#define GC573_RATE_CTRL_EXP		(BIT(0) | BIT(3))	/* unknown; OQ 33 */
#define GC573_RATE_FPS_NO_INPUT		5		/* RD's value with no input */
#define GC573_PIX_MODE			0x1088
#define GC573_PIX_MODE_DUAL		BIT(0)		/* dual-pixel input bus */
#define GC573_PIX_MODE_DDR		BIT(1)		/* both clock edges */
#define GC573_PIX_MODE_NO_INPUT		0x2		/* RD's value with no input */
#define GC573_CSC_R2Y			0x10c0		/* 7 words */
#define GC573_CSC_Y2R			0x10e0		/* 7 words */
#define GC573_CSC_WORDS			7

/* Scalers, spec/regmap.md */
#define GC573_SCALER_RESET		0x50000
#define GC573_SCALER_RUN		0x3		/* both scaler cores out of reset */

/* OpenCores-compatible byte master (I2C bus 0 or bus 2) */
struct gc573_ocbus {
	struct gc573 *gc;
	struct i2c_adapter adap;
	u32 base;			/* GC573_I2C0_BASE or GC573_I2C2_BASE */
};

/* Output pixel format, spec/video-pipeline.md "Pixel format code" */
struct gc573_fmt {
	u32 fourcc;
	u8 code;			/* VIP_CTRL[15:8] */
	u8 bpp;				/* bytes per pixel, packed or luma plane */
	u8 nch;				/* DMA channels = planes */
	bool rgb;			/* RGB output (CSC setup differs) */
};

/* Descriptor list of one buffer on one channel (coherent memory) */
struct gc573_dlist {
	__le32 *desc;
	dma_addr_t dma;
	size_t size;			/* bytes allocated */
	u32 count;			/* descriptors: SLOTn_COUNT */
};

struct gc573_vbuf {
	struct vb2_v4l2_buffer vb;	/* first: vb2 allocates this struct */
	struct list_head list;		/* on gc573_video.queued */
	struct sg_table *sgt;		/* pages, DMA-mapped from buf_init on */
	struct gc573_dlist dl[GC573_VCH_NUM];
	u64 armed;			/* gc573_video.arm_seq when armed */
};

/* Last few slot completions, for debugfs (experiments, bring-up) */
#define GC573_VEV_NUM			32
struct gc573_vev {
	u64 ns;				/* INT bit 1 time (hard handler) */
	u32 status;			/* ch0 CH_STATUS */
	u32 ctrl;			/* ch0 CH_CTRL when serviced */
	u8 done;			/* buffers completed by this event */
	u8 armed;			/* slots armed afterwards */
};

/* Statistics since the last stream start, for debugfs */
struct gc573_vstats {
	u32 irqs;			/* INT bit 1 serviced while running */
	u32 frames;			/* buffers delivered */
	u32 skipped;			/* frames dropped after the start */
	u32 multi;			/* INT bit 1 that completed > 1 slot */
	u32 unarmed;			/* INT bit 1 for a slot not armed */
	u32 order;			/* earlier-armed slot still valid */
	u32 bad_status;			/* CH_STATUS slot field not 1..4 */
	u32 stale;			/* INT bit 1 while not running */
	u32 terms;			/* INT bit 0 */
	u32 term_missing;		/* stop without INT bit 0 */
	u32 underruns;			/* no slot armed after a frame */
	struct gc573_vev ev[GC573_VEV_NUM];
	unsigned int ev_head;
};

struct gc573_video {
	struct video_device vdev;
	struct vb2_queue queue;
	struct mutex lock;		/* ioctls, vb2 queue, hardware start/stop */
	struct v4l2_ctrl_handler ctrls;
	struct v4l2_ctrl *power_ctrl;	/* V4L2_CID_DV_RX_POWER_PRESENT */
	struct v4l2_dv_timings timings;
	struct v4l2_pix_format pix;
	const struct gc573_fmt *fmt;
	struct gc573_input in;		/* input as last seen by the device */
	struct gc573_input col_in;	/* last input locked since load */
	bool col_valid;			/* col_in is set */
	bool adopt_pending;		/* input changed while the queue was busy */
	bool start_pending;		/* restart waits for a queued buffer */
	bool failed;			/* queue marked failed (vb2_queue_error) */
	bool held;			/* stream held: input in other timings */
	unsigned long hold_until;	/* jiffies: a hold lasting to here fails */
	struct delayed_work hold_work;	/* fails a hold that lasts */
	u32 input_restarts;		/* streams restarted by an input change */
	u32 input_holds;		/* streams held by an input change */
	bool dead;			/* quiesced: never start again */
	struct completion term;		/* INT bit 0: stream terminated */
	u64 irq_ns;			/* time of the last INT bit 1 */

	/* stream state shared with the IRQ thread */
	spinlock_t slock;
	bool running;			/* frames are being serviced */
	struct list_head queued;	/* buffers waiting for a slot */
	struct gc573_vbuf *slot[GC573_VCH_SLOTS];
	unsigned int next_arm;		/* slots are armed round-robin */
	u64 arm_seq;
	u32 ch_ctrl[GC573_VCH_NUM];	/* CH_CTRL values written (ch1, ch2) */
	u32 vip_ctrl;			/* VIP_CTRL while streaming, w/o OUT_EN */
	bool live;			/* streaming from a locked input */
	u32 input_stops;		/* streams failed by an input change */
	u32 sequence;
	unsigned int skip;		/* completions still to drop */
	int exp_mode;			/* exp_slot_mode for this stream */
	struct gc573_vstats st;
};

/* Audio statistics since the module was loaded, for debugfs */
struct gc573_astats {
	u64 periods;			/* periods delivered */
	u64 silent;			/* of these, delivered as silence */
	u64 filled;			/* silent frames for resets and pauses */
	u32 starts;			/* streams started */
	u32 restarts;			/* DMA started again after a reset */
	u32 pauses;			/* the FPGA's pacing paused (filled) */
	u32 stops;			/* INT bit 4 */
	u32 stop_missing;		/* stop without INT bit 4 */
	u32 order;			/* AUDIO_DONE not the buffer expected */
	u32 bad_done;			/* AUDIO_DONE neither 1 nor 2 */
	u32 stale;			/* INT bit 5 while not running */
	u32 late;			/* interrupt over 5 ms late, no pause */
	u32 interval_max_us;		/* longest interval, this stream */
	u32 interval_min_us;		/* shortest interval, this stream */
};

/* Audio capture, src/gc573_audio.c */
struct gc573_audio {
	struct snd_card *card;
	void *buf;			/* the two DMA buffers (coherent) */
	dma_addr_t buf_dma;
	struct completion stopped;	/* INT bit 4 */

	/* stream state shared with the hard IRQ handler */
	spinlock_t lock;
	struct snd_pcm_substream *ss;	/* the stream started last */
	u8 *area;			/* ALSA ring buffer */
	unsigned int buffer_bytes;
	unsigned int period_bytes;	/* ALSA period, a multiple of 10 ms */
	unsigned int pos;		/* ring write offset, bytes */
	unsigned int part;		/* bytes into the current ALSA period */
	unsigned int rate;
	bool running;			/* periods are being delivered */
	bool stopping;			/* stopped, INT bit 4 not waited for */
	bool dead;			/* quiesced: never start again */
	bool resync;			/* restarted: fill the gap first */
	unsigned int pause_us;		/* a late period: pause or latency? */
	bool good;			/* the last period carried samples */
	u8 next;			/* AUDIO_DONE value expected next */
	u32 sample_period;		/* AUDIO_SAMPLE_PERIOD, last period */
	u64 last_ns;			/* INT bit 5 time, last period */
	struct gc573_astats st;
};

struct gc573 {
	struct pci_dev *pdev;
	void __iomem *mmio;
	int irq;
	u32 fw_version;
	struct v4l2_device v4l2_dev;	/* refcount owner of this struct */
	struct dentry *debugfs;

	/* INT_STATUS bits acked by the hard handler, serviced by the thread */
	atomic_t irq_pending;
	atomic_t irq_seen;		/* OR of every INT_STATUS read, debugfs */

	/* serialises read-modify-write of GPIO (0x040) */
	spinlock_t gpio_lock;
	/* serialises read-modify-write of DMA_RUN (0x008), IRQ-safe */
	spinlock_t dma_run_lock;

	/* serialises the I2C masters: one transfer on the card at a time */
	struct mutex i2c_lock;
	struct i2c_adapter i2c1;	/* bus 1 engine: HDMI chips */
	struct completion i2c1_done;	/* bus 1 transfer ended (INT bit 11) */
	u8 i2c1_status;			/* GC573_I2C1_STATUS latched at INT bit 11 */
	struct gc573_ocbus i2c0;	/* byte master, devices unknown */
	struct gc573_ocbus i2c2;	/* byte master, devices unknown */

	struct gc573_video vid;
	struct gc573_hdmi hdmi;
	struct gc573_audio aud;
};

int gc573_reset_domain_mask(struct gc573 *gc, u32 mask);
int gc573_reset_domains(struct gc573 *gc);
void gc573_gpio_update(struct gc573 *gc, u32 mask, u32 val);
void gc573_dma_run_update(struct gc573 *gc, u32 mask, u32 val);

int gc573_i2c_init(struct gc573 *gc);
int gc573_i2c1_transfer(struct gc573 *gc, u8 addr8, u8 reg, u8 *buf, u16 len,
			bool rd, bool *retried);
void gc573_i2c1_irq(struct gc573 *gc);

int gc573_hdmi_init(struct gc573 *gc);
int gc573_hdmi_start(struct gc573 *gc);
void gc573_hdmi_shutdown(struct gc573 *gc);
void gc573_hdmi_input(struct gc573 *gc, struct gc573_input *in);
bool gc573_hdmi_edid_offers(struct gc573 *gc, const struct v4l2_dv_timings *t);
int gc573_hdmi_get_edid(struct gc573 *gc, struct v4l2_edid *e);
int gc573_hdmi_set_edid(struct gc573 *gc, struct v4l2_edid *e);
void gc573_hdmi_debugfs(struct gc573 *gc);

extern const struct vb2_mem_ops gc573_vb2_mem_ops;

/*
 * The driver's own video buffer memory live now, over all cards: vb2
 * buffers (gc573_vb2.c) with their pages and kernel mappings, and the DMA
 * descriptor lists (gc573_video.c). debugfs "video" prints them ("mem:").
 * With no buffers requested they are all 0: a leak check that other
 * programs' memory cannot move (tests/live.sh obssoak).
 */
struct gc573_mem_live {
	atomic_t bufs;
	atomic_long_t pages;
	atomic_t vmaps;
	atomic_t dlists;
	atomic_long_t dl_bytes;
};

extern struct gc573_mem_live gc573_mem_live;

void gc573_video_early_init(struct gc573 *gc);
int gc573_video_init(struct gc573 *gc);
void gc573_video_hw_stop(struct gc573 *gc);
void gc573_video_irq_done(struct gc573 *gc);
void gc573_video_irq_term(struct gc573 *gc);
void gc573_video_debugfs(struct gc573 *gc);
void gc573_video_input_changed(struct gc573 *gc);
void gc573_video_release(struct gc573 *gc);

void gc573_audio_early_init(struct gc573 *gc);
int gc573_audio_init(struct gc573 *gc);
void gc573_audio_quiesce(struct gc573 *gc);
bool gc573_audio_running(struct gc573 *gc);
void gc573_audio_reset_done(struct gc573 *gc);
void gc573_audio_irq(struct gc573 *gc, u32 pending, u32 done, u64 ns);
void gc573_audio_debugfs(struct gc573 *gc);

static inline u32 gc573_rd(struct gc573 *gc, u32 off)
{
	return ioread32(gc->mmio + off);
}

static inline void gc573_wr(struct gc573 *gc, u32 off, u32 val)
{
	iowrite32(val, gc->mmio + off);
}

#endif /* GC573_H */
