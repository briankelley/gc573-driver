// SPDX-License-Identifier: GPL-2.0
/*
 * GC573 video capture: V4L2 device, vb2 queue and video DMA.
 * spec/video-dma.md, spec/video-pipeline.md, spec/init.md.
 *
 * M2 scope: the HDMI chips stay in reset, so the FPGA sees no input and
 * free-runs at 60 Hz (spec/video-dma.md "Free-running with no input");
 * the DMA path runs in full. The output size is the active size of the
 * current DV timings: no input detection, scaling or controls yet.
 *
 * Buffers: single-planar API, one contiguous buffer per frame. Each plane
 * goes to its own DMA channel through its own descriptor list, and a
 * buffer occupies the same slot on every channel it uses. Slots are armed
 * round-robin, and the hardware completes them in the order armed.
 *
 * Locking: vid.lock serialises the ioctls, the vb2 queue and stream
 * start/stop. vid.slock protects the slot state shared with the IRQ
 * thread, and the channel registers written under it.
 */

#include <linux/bitfield.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/jiffies.h>
#include <linux/ktime.h>
#include <linux/moduleparam.h>
#include <linux/pci.h>
#include <linux/scatterlist.h>
#include <linux/seq_file.h>
#include <linux/string.h>
#include <linux/v4l2-dv-timings.h>
#include <media/v4l2-dv-timings.h>
#include <media/v4l2-event.h>
#include <media/v4l2-fh.h>
#include <media/v4l2-ioctl.h>
#include <media/videobuf2-v4l2.h>

#include "compat.h"
#include "gc573.h"

/* spec/video-pipeline.md "Clip": RD waits 50 ms after writing the clip */
#define GC573_CLIP_SETTLE_MS		50
/* spec/video-pipeline.md "Scalers" step 1 */
#define GC573_SCALER_RESET_US		5000
/* spec/init.md "Stream stop (video)": INT bit 0 within 2 s */
#define GC573_VID_TERM_MS		2000
/* spec/video-dma.md: RD's lists hold up to 2048 descriptors */
#define GC573_DL_MAX			2048
/* descriptor chunk cap: the DMA max segment size (gc573.h) */
#define GC573_DESC_MAX			GC573_DMA_SEG_MAX
/*
 * spec/video-dma.md "Card frame store": the first frame after a start can
 * carry stale lines from an earlier session. It is never delivered.
 */
#define GC573_VID_SKIP			1

static int exp_slot_mode;
module_param(exp_slot_mode, int, 0644);
MODULE_PARM_DESC(exp_slot_mode,
		 "Experiment, spec/open-questions.md #8; read at stream start. 0: normal, 1: slot-valid bits on ch0 only, 2: ch1/ch2 CH_CTRL written at start only, 3: slot-valid bits on ch1/ch2 only, 4: ch1/ch2 CH_CTRL never written, 5: ch1/ch2 CH_CTRL = 0 at start, never set");

static const u32 gc573_vch_base[GC573_VCH_NUM] = {
	GC573_VCH0_BASE, GC573_VCH1_BASE, GC573_VCH2_BASE,
};

/* spec/video-pipeline.md "Pixel format code"; the first is the default */
static const struct gc573_fmt gc573_fmts[] = {
	{ .fourcc = V4L2_PIX_FMT_YUYV,   .code = 0x00, .bpp = 2, .nch = 1 },
	{ .fourcc = V4L2_PIX_FMT_UYVY,   .code = 0x09, .bpp = 2, .nch = 1 },
	{ .fourcc = V4L2_PIX_FMT_NV12,   .code = 0x0f, .bpp = 1, .nch = 2 },
	{ .fourcc = V4L2_PIX_FMT_YVU420, .code = 0x10, .bpp = 1, .nch = 3 },
	{ .fourcc = V4L2_PIX_FMT_BGR24,  .code = 0x02, .bpp = 3, .nch = 1,
	  .rgb = true },
	{ .fourcc = V4L2_PIX_FMT_XBGR32, .code = 0x06, .bpp = 4, .nch = 1,
	  .rgb = true },
};

/*
 * spec/video-pipeline.md "CSC coefficient banks": 12 entries, rows of
 * (c0, c1, c2, offset), unsigned magnitudes, plus a sign mask. Values:
 * the BT.709 limited-range worked example there.
 */
struct gc573_csc {
	u16 neg;			/* bit i set: entry i is negative */
	u16 e[12];
};

static const struct gc573_csc gc573_csc_709_r2y = {
	.neg = 0x350,
	.e = {
		0x2750, 0x03f8, 0x0baf, 0x0100,		/* Y:  G, B, R, +16 */
		0x15ab, 0x1c1c, 0x0671, 0x0800,		/* Cb: G, B, R, +128 */
		0x1988, 0x0294, 0x1c1c, 0x0800,		/* Cr: G, B, R, +128 */
	},
};

static const struct gc573_csc gc573_csc_709_y2r = {
	.neg = 0x886,
	.e = {
		0x4a85, 0x0da6, 0x221b, 0x04ce,		/* G: Y, Cb, Cr, offset */
		0x4a85, 0x8732, 0x0000, 0x1210,		/* B */
		0x4a85, 0x0000, 0x72bc, 0x0f82,		/* R */
	},
};

/*
 * DV timings: CEA-861 progressive up to 1080p60 (single-pixel input bus).
 * 4K needs the dual-pixel modes; interlaced input is untraced.
 */
static const struct v4l2_dv_timings_cap gc573_timings_cap = {
	.type = V4L2_DV_BT_656_1120,
	/* keep this initialization for compatibility with GCC < 4.4.6 */
	.reserved = { 0 },
	V4L2_INIT_BT_TIMINGS(640, 1920, 480, 1080, 25000000, 148500000,
			     V4L2_DV_BT_STD_CEA861, V4L2_DV_BT_CAP_PROGRESSIVE)
};

static const struct v4l2_dv_timings gc573_timings_def =
	V4L2_DV_BT_CEA_1920X1080P60;

static inline struct gc573_vbuf *to_gc573_vbuf(struct vb2_buffer *vb)
{
	return container_of(to_vb2_v4l2_buffer(vb), struct gc573_vbuf, vb);
}

static const struct gc573_fmt *gc573_lookup_fmt(u32 fourcc)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(gc573_fmts); i++)
		if (gc573_fmts[i].fourcc == fourcc)
			return &gc573_fmts[i];
	return NULL;
}

static const struct gc573_fmt *gc573_find_fmt(u32 fourcc)
{
	return gc573_lookup_fmt(fourcc) ?: &gc573_fmts[0];
}

/* Bytes of each channel's plane (spec/video-dma.md "Channels and planes") */
static void gc573_planes(const struct gc573_fmt *f, u32 w, u32 h,
			 u32 size[GC573_VCH_NUM])
{
	u32 luma = w * h * f->bpp;

	size[0] = luma;
	size[1] = f->nch == 2 ? luma / 2 : f->nch == 3 ? luma / 4 : 0;
	size[2] = f->nch == 3 ? luma / 4 : 0;
}

/* Plane splits and sizes the descriptor rules allow (spec/video-dma.md) */
static bool gc573_layout_ok(const struct gc573_fmt *f, u32 w, u32 h)
{
	u32 size[GC573_VCH_NUM], off = 0;
	unsigned int c;

	if (w % 2 || h % 2)
		return false;
	gc573_planes(f, w, h, size);
	for (c = 0; c < f->nch; c++) {
		if (off % GC573_DESC_ADDR_ALIGN ||
		    size[c] % GC573_DESC_LEN_ALIGN)
			return false;
		off += size[c];
	}
	return true;
}

/*
 * TODO(spec): spec/ has no line-length rule for the pixel packer. Widths
 * seen to complete frames in all six formats with no input: 640, 1280 and
 * 1920 (tests/cases/10-video-capture.sh). At 720 (720x576p50) YV12 never
 * completed a frame: Y was written in full, but each chroma plane (360-byte
 * lines) received 2016 bytes less than its size, so the slot stayed pending
 * and INT bit 1 never came; NV12 and the packed formats worked. Until spec/
 * has the rule, offer only the widths seen to work.
 */
static const u32 gc573_widths[] = { 640, 1280, 1920 };

/*
 * v4l2_check_dv_timings_fnc: sizes every format can be captured at.
 * TLP_ALIGN (0x004) is never written; RD would leave it 0 only for frames
 * of a multiple of 32 dwords at 16 bpp (spec/regmap.md), so only those.
 */
static bool gc573_timings_fit(const struct v4l2_dv_timings *t, void *handle)
{
	u32 w = t->bt.width, h = t->bt.height;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(gc573_widths); i++)
		if (w == gc573_widths[i])
			break;
	if (i == ARRAY_SIZE(gc573_widths))
		return false;
	if ((w * h * 2 / 4) % 32)
		return false;
	for (i = 0; i < ARRAY_SIZE(gc573_fmts); i++)
		if (!gc573_layout_ok(&gc573_fmts[i], w, h))
			return false;
	return true;
}

static void gc573_fill_pix(struct gc573 *gc, const struct gc573_fmt *f,
			   struct v4l2_pix_format *pix)
{
	const struct v4l2_bt_timings *bt = &gc->vid.timings.bt;
	u32 size[GC573_VCH_NUM];

	gc573_planes(f, bt->width, bt->height, size);
	memset(pix, 0, sizeof(*pix));
	pix->width = bt->width;
	pix->height = bt->height;
	pix->pixelformat = f->fourcc;
	pix->field = V4L2_FIELD_NONE;
	pix->bytesperline = bt->width * f->bpp;
	pix->sizeimage = size[0] + size[1] + size[2];
	/* the CSCs are programmed for BT.709 limited range */
	pix->colorspace = V4L2_COLORSPACE_REC709;
	pix->xfer_func = V4L2_XFER_FUNC_709;
	pix->ycbcr_enc = V4L2_YCBCR_ENC_709;
	pix->quantization = f->rgb ? V4L2_QUANTIZATION_FULL_RANGE :
				     V4L2_QUANTIZATION_LIM_RANGE;
}

/* ---- descriptor lists ---- */

struct gc573_dl_ctx {
	__le32 *desc;			/* NULL: count only */
	u32 count;
	dma_addr_t addr;		/* run being collected */
	u32 len;
	bool bad;			/* a chunk breaks the alignment rules */
};

static void gc573_dl_emit(struct gc573_dl_ctx *x)
{
	if (!x->len)
		return;
	if (x->addr % GC573_DESC_ADDR_ALIGN || x->len % GC573_DESC_LEN_ALIGN)
		x->bad = true;
	if (x->desc) {
		__le32 *d = x->desc + GC573_DESC_WORDS * x->count;

		d[0] = cpu_to_le32(lower_32_bits(x->addr));
		d[1] = cpu_to_le32(upper_32_bits(x->addr));
		d[2] = cpu_to_le32(x->len / 4);		/* in dwords */
		d[3] = cpu_to_le32(GC573_DESC_CTRL);
	}
	x->count++;
	x->len = 0;
}

static void gc573_dl_add(struct gc573_dl_ctx *x, dma_addr_t addr, u32 len)
{
	while (len) {
		u32 n;

		if (!x->len || x->addr + x->len != addr ||
		    x->len == GC573_DESC_MAX) {
			gc573_dl_emit(x);
			x->addr = addr;
		}
		n = min_t(u32, len, GC573_DESC_MAX - x->len);
		x->len += n;
		addr += n;
		len -= n;
	}
}

/* Describe bytes [off, off + len) of the DMA-mapped buffer */
static void gc573_dl_walk(struct gc573_dl_ctx *x, struct sg_table *sgt,
			  u32 off, u32 len)
{
	struct scatterlist *sg;
	u32 pos = 0, end = off + len;
	unsigned int i;

	for_each_sgtable_dma_sg(sgt, sg, i) {
		u32 sl = sg_dma_len(sg);
		u32 a = max(pos, off), b = min(pos + sl, end);

		if (a < b)
			gc573_dl_add(x, sg_dma_address(sg) + (a - pos), b - a);
		pos += sl;
		if (pos >= end)
			break;
	}
	gc573_dl_emit(x);
}

static int gc573_dl_build(struct gc573 *gc, struct sg_table *sgt, u32 off,
			  u32 len, struct gc573_dlist *dl)
{
	struct device *dev = &gc->pdev->dev;
	struct gc573_dl_ctx x = { };

	gc573_dl_walk(&x, sgt, off, len);
	if (!x.count || x.count > GC573_DL_MAX || x.bad) {
		dev_err(dev, "cannot build DMA list: %u descriptor(s)%s\n",
			x.count, x.bad ? ", misaligned chunk" : "");
		return -EINVAL;
	}

	dl->size = PAGE_ALIGN(x.count * GC573_DESC_SIZE);
	dl->desc = dma_alloc_coherent(dev, dl->size, &dl->dma, GFP_KERNEL);
	if (!dl->desc)
		return -ENOMEM;

	memset(&x, 0, sizeof(x));
	x.desc = dl->desc;
	gc573_dl_walk(&x, sgt, off, len);
	dl->count = x.count;
	return 0;
}

static void gc573_dl_free(struct gc573 *gc, struct gc573_vbuf *b)
{
	unsigned int c;

	for (c = 0; c < GC573_VCH_NUM; c++) {
		struct gc573_dlist *dl = &b->dl[c];

		if (dl->desc)
			dma_free_coherent(&gc->pdev->dev, dl->size, dl->desc,
					  dl->dma);
		memset(dl, 0, sizeof(*dl));
	}
}

/* ---- hardware ---- */

static void gc573_csc_write(struct gc573 *gc, u32 base,
			    const struct gc573_csc *m)
{
	unsigned int k;

	gc573_wr(gc, base, m->neg);
	for (k = 1; k < GC573_CSC_WORDS; k++)
		gc573_wr(gc, base + 4 * k,
			 m->e[2 * k - 2] | (u32)m->e[2 * k - 1] << 16);
}

/*
 * Pipeline for the current format with no input, in RD's order
 * (spec/video-pipeline.md, spec/video-dma.md "Start" step 1). Output stays
 * disabled. Scalers: reset and bypassed (output size = input size).
 */
static void gc573_vid_setup(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	const struct gc573_fmt *f = v->fmt;
	u32 rate;

	gc573_wr(gc, GC573_COLOR_CTRL, 0);
	gc573_wr(gc, GC573_BRIGHTNESS, GC573_BRIGHTNESS_DEF);
	gc573_wr(gc, GC573_CONTRAST, GC573_CONTRAST_DEF);
	gc573_wr(gc, GC573_HUE, GC573_HUE_DEF);
	gc573_wr(gc, GC573_SATURATION, GC573_SATURATION_DEF);

	v->vip_ctrl = FIELD_PREP(GC573_VIP_CTRL_FMT, f->code);
	gc573_wr(gc, GC573_VIP_CTRL, v->vip_ctrl);

	gc573_wr(gc, GC573_CLIP_LEFT, 0);
	gc573_wr(gc, GC573_CLIP_WIDTH, v->pix.width);
	gc573_wr(gc, GC573_CLIP_TOP, 0);
	gc573_wr(gc, GC573_CLIP_HEIGHT, v->pix.height);
	msleep(GC573_CLIP_SETTLE_MS);

	gc573_wr(gc, GC573_SCALER_RESET, 0);
	fsleep(GC573_SCALER_RESET_US);
	gc573_wr(gc, GC573_SCALER_RESET, GC573_SCALER_RUN);
	fsleep(GC573_SCALER_RESET_US);

	/* rate limit and CSC select; the other bits are preserved */
	rate = gc573_rd(gc, GC573_RATE_CTRL);
	rate &= ~(GC573_RATE_CTRL_FPS | GC573_RATE_CTRL_CSC);
	rate |= FIELD_PREP(GC573_RATE_CTRL_FPS, GC573_RATE_FPS_NO_INPUT) |
		FIELD_PREP(GC573_RATE_CTRL_CSC, f->rgb ?
			   GC573_RATE_CTRL_CSC_RGB : GC573_RATE_CTRL_CSC_YUV);
	gc573_wr(gc, GC573_RATE_CTRL, rate);

	/* both CSCs programmed; YUV outputs go YUV->RGB->YUV (both on) */
	gc573_csc_write(gc, GC573_CSC_R2Y, &gc573_csc_709_r2y);
	gc573_csc_write(gc, GC573_CSC_Y2R, &gc573_csc_709_y2r);
	gc573_wr(gc, GC573_COLOR_CTRL, GC573_COLOR_CTRL_ADJUST |
		 GC573_COLOR_CTRL_Y2R | (f->rgb ? 0 : GC573_COLOR_CTRL_R2Y));

	gc573_wr(gc, GC573_PIX_MODE, GC573_PIX_MODE_NO_INPUT);
}

/* exp_slot_mode: may this stream write channel c's slot-valid bits now? */
static bool gc573_vid_slots_writable(struct gc573_video *v, unsigned int c,
				     bool at_start)
{
	switch (v->exp_mode) {
	case 1:
		return c == 0;
	case 2:
		return c == 0 || at_start;
	case 3:
		return c != 0;
	case 4:
	case 5:
		return c == 0;
	default:
		return true;
	}
}

/*
 * Set and clear CH_CTRL bits of channel c. ch0 is read-modify-written:
 * hardware clears its slot bits as slots complete. ch1/ch2 cannot be read
 * back, so they get the exact value software intends. slock held.
 */
static void gc573_vid_ctrl(struct gc573 *gc, unsigned int c, u32 set, u32 clr)
{
	struct gc573_video *v = &gc->vid;
	u32 reg = gc573_vch_base[c] + GC573_VCH_CTRL;

	if (!c) {
		gc573_wr(gc, reg, (gc573_rd(gc, reg) & ~clr) | set);
	} else {
		v->ch_ctrl[c] = (v->ch_ctrl[c] & ~clr) | set;
		gc573_wr(gc, reg, v->ch_ctrl[c]);
	}
}

/* Point slot n of every channel in use at b's lists. slock held. */
static void gc573_vid_program_slot(struct gc573 *gc, unsigned int n,
				   struct gc573_vbuf *b)
{
	unsigned int c;

	for (c = 0; c < gc->vid.fmt->nch; c++) {
		u32 base = gc573_vch_base[c];

		gc573_wr(gc, base + GC573_VCH_LIST_LO(n),
			 lower_32_bits(b->dl[c].dma));
		gc573_wr(gc, base + GC573_VCH_LIST_HI(n),
			 upper_32_bits(b->dl[c].dma));
		gc573_wr(gc, base + GC573_VCH_COUNT(n), b->dl[c].count);
	}
}

/* Arm free slots, round-robin, with queued buffers. slock held. */
static unsigned int gc573_vid_fill(struct gc573 *gc, bool at_start)
{
	struct gc573_video *v = &gc->vid;
	unsigned int armed = 0, c, n;
	struct gc573_vbuf *b;

	while (!v->slot[v->next_arm] && !list_empty(&v->queued)) {
		n = v->next_arm;
		b = list_first_entry(&v->queued, struct gc573_vbuf, list);
		list_del(&b->list);
		gc573_vid_program_slot(gc, n, b);
		for (c = 0; c < v->fmt->nch; c++)
			if (gc573_vid_slots_writable(v, c, at_start))
				gc573_vid_ctrl(gc, c, GC573_VCH_CTRL_SLOT(n), 0);
		b->armed = ++v->arm_seq;
		v->slot[n] = b;
		v->next_arm = (n + 1) % GC573_VCH_SLOTS;
		armed++;
	}
	return armed;
}

static unsigned int gc573_vid_armed(struct gc573_video *v)
{
	unsigned int n, armed = 0;

	for (n = 0; n < GC573_VCH_SLOTS; n++)
		armed += !!v->slot[n];
	return armed;
}

static void gc573_vid_return_all(struct gc573 *gc, enum vb2_buffer_state st)
{
	struct gc573_video *v = &gc->vid;
	struct gc573_vbuf *b, *tmp;
	LIST_HEAD(bufs);
	unsigned int n;

	spin_lock(&v->slock);
	for (n = 0; n < GC573_VCH_SLOTS; n++) {
		if (v->slot[n])
			list_add_tail(&v->slot[n]->list, &bufs);
		v->slot[n] = NULL;
	}
	list_splice_tail_init(&v->queued, &bufs);
	spin_unlock(&v->slock);

	list_for_each_entry_safe(b, tmp, &bufs, list) {
		list_del(&b->list);
		vb2_buffer_done(&b->vb.vb2_buf, st);
	}
}

/*
 * spec/init.md "Stream stop (video)" steps 1-3: output off, wait for INT
 * bit 0, reset the domains. vid.lock held. Safe to call when not running.
 */
void gc573_video_hw_stop(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	struct device *dev = &gc->pdev->dev;
	unsigned long t0 = jiffies;
	u32 vip;

	spin_lock(&v->slock);
	v->running = false;
	spin_unlock(&v->slock);

	vip = gc573_rd(gc, GC573_VIP_CTRL);
	if (vip & GC573_VIP_CTRL_OUT_EN) {
		reinit_completion(&v->term);
		gc573_wr(gc, GC573_VIP_CTRL, vip & ~GC573_VIP_CTRL_OUT_EN);
		if (!wait_for_completion_timeout(&v->term,
						 msecs_to_jiffies(GC573_VID_TERM_MS))) {
			v->st.term_missing++;
			dev_warn(dev, "video stop: timeout waiting for INT bit 0\n");
		}
	}
	gc573_reset_domains(gc);
	dev_dbg(dev, "video stopped in %u ms\n",
		jiffies_to_msecs(jiffies - t0));
}

/* ---- IRQ thread ---- */

static void gc573_vid_complete(struct gc573 *gc, struct gc573_vbuf *b, u64 ns)
{
	struct gc573_video *v = &gc->vid;

	if (v->skip) {
		/* stale frame-store content possible: back into the queue */
		v->skip--;
		v->st.skipped++;
		list_add(&b->list, &v->queued);
		return;
	}
	b->vb.vb2_buf.timestamp = ns;
	b->vb.sequence = v->sequence++;
	b->vb.field = V4L2_FIELD_NONE;
	vb2_set_plane_payload(&b->vb.vb2_buf, 0, v->pix.sizeimage);
	vb2_buffer_done(&b->vb.vb2_buf, VB2_BUF_STATE_DONE);
	v->st.frames++;
}

/*
 * INT bit 1 (spec/video-dma.md "Per frame"): ch0 STATUS names the slot
 * that completed. Slots armed before it whose ch0 valid bit hardware has
 * cleared completed too (interrupts coalesce); one still valid is counted
 * as out of order and left alone. Then refill the free slots.
 */
void gc573_video_irq_done(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	u64 ns = READ_ONCE(v->irq_ns);
	struct gc573_vbuf *done[GC573_VCH_SLOTS];
	unsigned int ndone = 0, i, j, n, s, c;
	struct gc573_vev *ev;
	u32 status, ctrl, clr = 0;

	spin_lock(&v->slock);
	if (!v->running) {
		v->st.stale++;
		goto unlock;
	}
	v->st.irqs++;
	status = gc573_rd(gc, GC573_VCH0_BASE + GC573_VCH_STATUS);
	ctrl = gc573_rd(gc, GC573_VCH0_BASE + GC573_VCH_CTRL);
	s = FIELD_GET(GC573_VCH_STATUS_SLOT, status);

	if (s < 1 || s > GC573_VCH_SLOTS) {
		v->st.bad_status++;
	} else if (!v->slot[--s]) {
		v->st.unarmed++;
	} else {
		u64 s_armed = v->slot[s]->armed;

		for (n = 0; n < GC573_VCH_SLOTS; n++) {
			struct gc573_vbuf *b = v->slot[n];

			if (!b || (n != s && b->armed > s_armed))
				continue;
			if (n != s && (ctrl & GC573_VCH_CTRL_SLOT(n))) {
				v->st.order++;
				continue;
			}
			/* keep done[] in arming order */
			for (i = ndone; i && done[i - 1]->armed > b->armed; i--)
				done[i] = done[i - 1];
			done[i] = b;
			ndone++;
			clr |= GC573_VCH_CTRL_SLOT(n);
			v->slot[n] = NULL;
		}
		if (ndone > 1)
			v->st.multi++;
		/* spec: clear the slot bit in ch0 CTRL if still set */
		if (ctrl & clr)
			gc573_vid_ctrl(gc, 0, 0, ctrl & clr);
		for (c = 1; c < v->fmt->nch; c++)
			if (gc573_vid_slots_writable(v, c, false))
				gc573_vid_ctrl(gc, c, 0, clr);
		for (j = 0; j < ndone; j++)
			gc573_vid_complete(gc, done[j], ns);
	}

	gc573_vid_fill(gc, false);
	if (!gc573_vid_armed(v))
		v->st.underruns++;

	ev = &v->st.ev[v->st.ev_head++ % GC573_VEV_NUM];
	ev->ns = ns;
	ev->status = status;
	ev->ctrl = ctrl;
	ev->done = ndone;
	ev->armed = gc573_vid_armed(v);
unlock:
	spin_unlock(&v->slock);
}

/* INT bit 0: the stream has terminated after output was disabled */
void gc573_video_irq_term(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;

	spin_lock(&v->slock);
	v->st.terms++;
	spin_unlock(&v->slock);
	complete(&v->term);
}

/* ---- vb2 ---- */

static int gc573_queue_setup(struct vb2_queue *q, unsigned int *nbufs,
			     unsigned int *nplanes, unsigned int sizes[],
			     struct device *alloc_devs[])
{
	struct gc573 *gc = vb2_get_drv_priv(q);
	u32 size = gc->vid.pix.sizeimage;

	if (*nplanes)
		return *nplanes != 1 || sizes[0] < size ? -EINVAL : 0;
	*nplanes = 1;
	sizes[0] = size;
	return 0;
}

/* After allocation: DMA-map the pages and build the descriptor lists */
static int gc573_buf_init(struct vb2_buffer *vb)
{
	struct gc573 *gc = vb2_get_drv_priv(vb->vb2_queue);
	struct gc573_video *v = &gc->vid;
	struct gc573_vbuf *b = to_gc573_vbuf(vb);
	struct device *dev = &gc->pdev->dev;
	u32 size[GC573_VCH_NUM], off = 0;
	unsigned int c;
	int ret;

	b->sgt = vb2_plane_cookie(vb, 0);
	ret = dma_map_sgtable(dev, b->sgt, DMA_FROM_DEVICE, 0);
	if (ret)
		return ret;

	gc573_planes(v->fmt, v->pix.width, v->pix.height, size);
	for (c = 0; c < v->fmt->nch; c++) {
		ret = gc573_dl_build(gc, b->sgt, off, size[c], &b->dl[c]);
		if (ret)
			goto err;
		off += size[c];
	}
	return 0;

err:
	gc573_dl_free(gc, b);
	dma_unmap_sgtable(dev, b->sgt, DMA_FROM_DEVICE, 0);
	return ret;
}

static int gc573_buf_prepare(struct vb2_buffer *vb)
{
	struct gc573 *gc = vb2_get_drv_priv(vb->vb2_queue);
	u32 size = gc->vid.pix.sizeimage;

	if (vb2_plane_size(vb, 0) < size)
		return -EINVAL;
	vb2_set_plane_payload(vb, 0, size);
	dma_sync_sgtable_for_device(&gc->pdev->dev, to_gc573_vbuf(vb)->sgt,
				    DMA_FROM_DEVICE);
	return 0;
}

static void gc573_buf_finish(struct vb2_buffer *vb)
{
	struct gc573 *gc = vb2_get_drv_priv(vb->vb2_queue);

	dma_sync_sgtable_for_cpu(&gc->pdev->dev, to_gc573_vbuf(vb)->sgt,
				 DMA_FROM_DEVICE);
}

static void gc573_buf_cleanup(struct vb2_buffer *vb)
{
	struct gc573 *gc = vb2_get_drv_priv(vb->vb2_queue);
	struct gc573_vbuf *b = to_gc573_vbuf(vb);

	gc573_dl_free(gc, b);
	dma_unmap_sgtable(&gc->pdev->dev, b->sgt, DMA_FROM_DEVICE, 0);
}

static void gc573_buf_queue(struct vb2_buffer *vb)
{
	struct gc573 *gc = vb2_get_drv_priv(vb->vb2_queue);
	struct gc573_video *v = &gc->vid;

	spin_lock(&v->slock);
	list_add_tail(&to_gc573_vbuf(vb)->list, &v->queued);
	/*
	 * Hardware clears a slot's ch0 valid bit when the slot completes, so
	 * a read-modify-write of ch0 CH_CTRL that straddles a completion sets
	 * that bit again. While a slot is armed only the IRQ thread arms
	 * more, right after it has handled a completion. With none armed the
	 * DMA is stalled and nothing can complete (spec/video-dma.md): arm now.
	 */
	if (v->running && !gc573_vid_armed(v))
		gc573_vid_fill(gc, false);
	spin_unlock(&v->slock);
}

/* spec/video-dma.md "Start"; at least one buffer is queued */
static int gc573_start_streaming(struct vb2_queue *q, unsigned int count)
{
	struct gc573 *gc = vb2_get_drv_priv(q);
	struct gc573_video *v = &gc->vid;
	struct gc573_vbuf *first;
	unsigned int c, n;

	if (v->dead) {
		gc573_vid_return_all(gc, VB2_BUF_STATE_QUEUED);
		return -ENODEV;
	}

	gc573_vid_setup(gc);

	spin_lock(&v->slock);
	v->exp_mode = READ_ONCE(exp_slot_mode);
	if (v->exp_mode < 0 || v->exp_mode > 5)
		v->exp_mode = 0;
	v->next_arm = 0;
	v->arm_seq = 0;
	v->sequence = 0;
	v->skip = GC573_VID_SKIP;
	memset(v->ch_ctrl, 0, sizeof(v->ch_ctrl));
	memset(&v->st, 0, sizeof(v->st));

	/* every slot of every channel in use points at memory we own */
	first = list_first_entry(&v->queued, struct gc573_vbuf, list);
	for (n = 0; n < GC573_VCH_SLOTS; n++)
		gc573_vid_program_slot(gc, n, first);
	gc573_vid_fill(gc, true);
	for (c = 0; c < v->fmt->nch; c++)
		if (c == 0 || v->exp_mode < 4)
			gc573_vid_ctrl(gc, c, GC573_VCH_CTRL_RUN, 0);
		else if (v->exp_mode == 5)
			gc573_vid_ctrl(gc, c, 0, ~0U);

	v->running = true;
	gc573_wr(gc, GC573_VIP_CTRL, v->vip_ctrl | GC573_VIP_CTRL_OUT_EN);
	spin_unlock(&v->slock);

	dev_dbg(&gc->pdev->dev,
		"video start: %p4cc %ux%u, %u slot(s) armed, exp_slot_mode %d, IN 1004 %#x 1008 %#x 100c %#x 1010 %#x\n",
		&v->pix.pixelformat, v->pix.width, v->pix.height,
		gc573_vid_armed(v), v->exp_mode,
		gc573_rd(gc, GC573_IN_STATUS), gc573_rd(gc, GC573_IN_WIDTH),
		gc573_rd(gc, GC573_IN_HEIGHT),
		gc573_rd(gc, GC573_IN_FRAME_PERIOD));
	return 0;
}

static void gc573_stop_streaming(struct vb2_queue *q)
{
	struct gc573 *gc = vb2_get_drv_priv(q);
	struct gc573_video *v = &gc->vid;

	/* after the quiesce the engines are reset and the IRQ is off */
	if (!v->dead)
		gc573_video_hw_stop(gc);
	gc573_vid_return_all(gc, VB2_BUF_STATE_ERROR);

	dev_dbg(&gc->pdev->dev,
		"video stats: irqs %u frames %u skipped %u multi %u unarmed %u order %u bad_status %u stale %u terms %u underruns %u\n",
		v->st.irqs, v->st.frames, v->st.skipped, v->st.multi,
		v->st.unarmed, v->st.order, v->st.bad_status, v->st.stale,
		v->st.terms, v->st.underruns);
}

static const struct vb2_ops gc573_vb2_ops = {
	.queue_setup		= gc573_queue_setup,
	.buf_init		= gc573_buf_init,
	.buf_prepare		= gc573_buf_prepare,
	.buf_finish		= gc573_buf_finish,
	.buf_cleanup		= gc573_buf_cleanup,
	.buf_queue		= gc573_buf_queue,
	.start_streaming	= gc573_start_streaming,
	.stop_streaming		= gc573_stop_streaming,
	GC573_VB2_WAIT_OPS
};

/* ---- V4L2 ioctls ---- */

static int gc573_querycap(struct file *file, void *priv,
			  struct v4l2_capability *cap)
{
	struct gc573 *gc = video_drvdata(file);

	strscpy(cap->driver, KBUILD_MODNAME, sizeof(cap->driver));
	strscpy(cap->card, "AVerMedia Live Gamer 4K (GC573)",
		sizeof(cap->card));
	snprintf(cap->bus_info, sizeof(cap->bus_info), "PCI:%s",
		 pci_name(gc->pdev));
	return 0;
}

static int gc573_enum_fmt(struct file *file, void *priv,
			  struct v4l2_fmtdesc *f)
{
	if (f->index >= ARRAY_SIZE(gc573_fmts))
		return -EINVAL;
	f->pixelformat = gc573_fmts[f->index].fourcc;
	return 0;
}

static int gc573_g_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct gc573 *gc = video_drvdata(file);

	f->fmt.pix = gc->vid.pix;
	return 0;
}

static int gc573_try_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct gc573 *gc = video_drvdata(file);

	gc573_fill_pix(gc, gc573_find_fmt(f->fmt.pix.pixelformat),
		       &f->fmt.pix);
	return 0;
}

static int gc573_s_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct gc573 *gc = video_drvdata(file);
	struct gc573_video *v = &gc->vid;
	const struct gc573_fmt *fmt = gc573_find_fmt(f->fmt.pix.pixelformat);

	if (vb2_is_busy(&v->queue))
		return -EBUSY;
	gc573_fill_pix(gc, fmt, &f->fmt.pix);
	v->fmt = fmt;
	v->pix = f->fmt.pix;
	return 0;
}

static int gc573_enum_framesizes(struct file *file, void *priv,
				 struct v4l2_frmsizeenum *fs)
{
	struct gc573 *gc = video_drvdata(file);

	if (fs->index || !gc573_lookup_fmt(fs->pixel_format))
		return -EINVAL;
	fs->type = V4L2_FRMSIZE_TYPE_DISCRETE;
	fs->discrete.width = gc->vid.timings.bt.width;
	fs->discrete.height = gc->vid.timings.bt.height;
	return 0;
}

static int gc573_enum_frameintervals(struct file *file, void *priv,
				     struct v4l2_frmivalenum *fi)
{
	struct gc573 *gc = video_drvdata(file);
	const struct v4l2_bt_timings *bt = &gc->vid.timings.bt;

	if (fi->index || !gc573_lookup_fmt(fi->pixel_format) ||
	    fi->width != bt->width || fi->height != bt->height)
		return -EINVAL;
	fi->type = V4L2_FRMIVAL_TYPE_DISCRETE;
	fi->discrete = v4l2_calc_timeperframe(&gc->vid.timings);
	return 0;
}

/* G_PARM and S_PARM: the frame interval follows the DV timings */
static int gc573_g_parm(struct file *file, void *priv,
			struct v4l2_streamparm *a)
{
	struct gc573 *gc = video_drvdata(file);

	if (a->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;
	memset(&a->parm.capture, 0, sizeof(a->parm.capture));
	a->parm.capture.capability = V4L2_CAP_TIMEPERFRAME;
	a->parm.capture.timeperframe = v4l2_calc_timeperframe(&gc->vid.timings);
	return 0;
}

static int gc573_enum_input(struct file *file, void *priv,
			    struct v4l2_input *inp)
{
	if (inp->index)
		return -EINVAL;
	strscpy(inp->name, "HDMI", sizeof(inp->name));
	inp->type = V4L2_INPUT_TYPE_CAMERA;
	inp->capabilities = V4L2_IN_CAP_DV_TIMINGS;
	/* the HDMI receiver is not brought up yet */
	inp->status = V4L2_IN_ST_NO_SIGNAL;
	return 0;
}

static int gc573_g_input(struct file *file, void *priv, unsigned int *i)
{
	*i = 0;
	return 0;
}

static int gc573_s_input(struct file *file, void *priv, unsigned int i)
{
	return i ? -EINVAL : 0;
}

static int gc573_s_dv_timings(struct file *file, void *priv,
			      struct v4l2_dv_timings *t)
{
	struct gc573 *gc = video_drvdata(file);
	struct gc573_video *v = &gc->vid;

	if (!v4l2_find_dv_timings_cap(t, &gc573_timings_cap, 0,
				      gc573_timings_fit, NULL))
		return -EINVAL;
	if (v4l2_match_dv_timings(t, &v->timings, 0, false))
		return 0;
	if (vb2_is_busy(&v->queue))
		return -EBUSY;
	v->timings = *t;
	gc573_fill_pix(gc, v->fmt, &v->pix);
	return 0;
}

static int gc573_g_dv_timings(struct file *file, void *priv,
			      struct v4l2_dv_timings *t)
{
	struct gc573 *gc = video_drvdata(file);

	*t = gc->vid.timings;
	return 0;
}

/* no input detection yet: there is never a link */
static int gc573_query_dv_timings(struct file *file, void *priv,
				  struct v4l2_dv_timings *t)
{
	return -ENOLINK;
}

static int gc573_enum_dv_timings(struct file *file, void *priv,
				 struct v4l2_enum_dv_timings *t)
{
	return v4l2_enum_dv_timings_cap(t, &gc573_timings_cap,
					gc573_timings_fit, NULL);
}

static int gc573_dv_timings_cap(struct file *file, void *priv,
				struct v4l2_dv_timings_cap *cap)
{
	*cap = gc573_timings_cap;
	return 0;
}

static int gc573_log_status(struct file *file, void *priv)
{
	struct gc573 *gc = video_drvdata(file);
	struct gc573_video *v = &gc->vid;

	v4l2_print_dv_timings(gc->v4l2_dev.name, "timings: ", &v->timings,
			      true);
	v4l2_info(&gc->v4l2_dev, "format: %p4cc %ux%u, %u bytes\n",
		  &v->pix.pixelformat, v->pix.width, v->pix.height,
		  v->pix.sizeimage);
	v4l2_info(&gc->v4l2_dev,
		  "input registers: 1004 %#x 1008 %#x 100c %#x 1010 %#x\n",
		  gc573_rd(gc, GC573_IN_STATUS), gc573_rd(gc, GC573_IN_WIDTH),
		  gc573_rd(gc, GC573_IN_HEIGHT),
		  gc573_rd(gc, GC573_IN_FRAME_PERIOD));
	v4l2_info(&gc->v4l2_dev, "stream: %s, frames %u, skipped %u\n",
		  vb2_is_streaming(&v->queue) ? "on" : "off", v->st.frames,
		  v->st.skipped);
	return 0;
}

static int gc573_subscribe_event(struct v4l2_fh *fh,
				 const struct v4l2_event_subscription *sub)
{
	switch (sub->type) {
	case V4L2_EVENT_SOURCE_CHANGE:
		return v4l2_src_change_event_subscribe(fh, sub);
	default:
		return -EINVAL;
	}
}

static const struct v4l2_ioctl_ops gc573_ioctl_ops = {
	.vidioc_querycap		= gc573_querycap,
	.vidioc_enum_fmt_vid_cap	= gc573_enum_fmt,
	.vidioc_g_fmt_vid_cap		= gc573_g_fmt,
	.vidioc_try_fmt_vid_cap		= gc573_try_fmt,
	.vidioc_s_fmt_vid_cap		= gc573_s_fmt,
	.vidioc_enum_framesizes		= gc573_enum_framesizes,
	.vidioc_enum_frameintervals	= gc573_enum_frameintervals,
	.vidioc_g_parm			= gc573_g_parm,
	.vidioc_s_parm			= gc573_g_parm,
	.vidioc_enum_input		= gc573_enum_input,
	.vidioc_g_input			= gc573_g_input,
	.vidioc_s_input			= gc573_s_input,
	.vidioc_s_dv_timings		= gc573_s_dv_timings,
	.vidioc_g_dv_timings		= gc573_g_dv_timings,
	.vidioc_query_dv_timings	= gc573_query_dv_timings,
	.vidioc_enum_dv_timings		= gc573_enum_dv_timings,
	.vidioc_dv_timings_cap		= gc573_dv_timings_cap,
	.vidioc_reqbufs			= vb2_ioctl_reqbufs,
	.vidioc_create_bufs		= vb2_ioctl_create_bufs,
	.vidioc_prepare_buf		= vb2_ioctl_prepare_buf,
	.vidioc_querybuf		= vb2_ioctl_querybuf,
	.vidioc_qbuf			= vb2_ioctl_qbuf,
	.vidioc_dqbuf			= vb2_ioctl_dqbuf,
	.vidioc_streamon		= vb2_ioctl_streamon,
	.vidioc_streamoff		= vb2_ioctl_streamoff,
	.vidioc_log_status		= gc573_log_status,
	.vidioc_subscribe_event		= gc573_subscribe_event,
	.vidioc_unsubscribe_event	= v4l2_event_unsubscribe,
};

static const struct v4l2_file_operations gc573_fops = {
	.owner		= THIS_MODULE,
	.open		= v4l2_fh_open,
	.release	= vb2_fop_release,
	.unlocked_ioctl	= video_ioctl2,
	.mmap		= vb2_fop_mmap,
	.poll		= vb2_fop_poll,
};

/* ---- debugfs ---- */

static int gc573_vid_debugfs_show(struct seq_file *m, void *unused)
{
	struct gc573 *gc = m->private;
	struct gc573_video *v = &gc->vid;
	struct gc573_vstats *st = &v->st;
	unsigned int i, n;

	seq_printf(m, "core: INT_STATUS %#010x INT_ENABLE %#010x RESET %#010x TLP_ALIGN %#010x INT seen %#010x\n",
		   gc573_rd(gc, GC573_INT_STATUS),
		   gc573_rd(gc, GC573_INT_ENABLE), gc573_rd(gc, GC573_RESET),
		   gc573_rd(gc, GC573_TLP_ALIGN),
		   (u32)atomic_read(&gc->irq_seen));
	seq_printf(m, "input: 1004 %#010x 1008 %#010x 100c %#010x 1010 %#010x\n",
		   gc573_rd(gc, GC573_IN_STATUS), gc573_rd(gc, GC573_IN_WIDTH),
		   gc573_rd(gc, GC573_IN_HEIGHT),
		   gc573_rd(gc, GC573_IN_FRAME_PERIOD));
	seq_printf(m, "vip: VIP_CTRL %#010x COLOR_CTRL %#010x RATE_CTRL %#010x PIX_MODE %#010x CLIP %u,%u %ux%u\n",
		   gc573_rd(gc, GC573_VIP_CTRL), gc573_rd(gc, GC573_COLOR_CTRL),
		   gc573_rd(gc, GC573_RATE_CTRL), gc573_rd(gc, GC573_PIX_MODE),
		   gc573_rd(gc, GC573_CLIP_LEFT), gc573_rd(gc, GC573_CLIP_TOP),
		   gc573_rd(gc, GC573_CLIP_WIDTH),
		   gc573_rd(gc, GC573_CLIP_HEIGHT));
	seq_printf(m, "ch0: STATUS %#010x CTRL %#010x\n",
		   gc573_rd(gc, GC573_VCH0_BASE + GC573_VCH_STATUS),
		   gc573_rd(gc, GC573_VCH0_BASE + GC573_VCH_CTRL));

	/* seq_printf() does not sleep: print the shared state under slock */
	spin_lock(&v->slock);
	seq_printf(m, "stream: running %d fmt %p4cc %ux%u sizeimage %u exp_slot_mode %d next_arm %u ch_ctrl written: ch1 %#x ch2 %#x\n",
		   v->running, &v->pix.pixelformat, v->pix.width, v->pix.height,
		   v->pix.sizeimage, v->exp_mode, v->next_arm, v->ch_ctrl[1],
		   v->ch_ctrl[2]);
	seq_puts(m, "slots (buffer index):");
	for (n = 0; n < GC573_VCH_SLOTS; n++)
		seq_printf(m, " %d",
			   v->slot[n] ? (int)v->slot[n]->vb.vb2_buf.index : -1);
	seq_printf(m, "\nstats: irqs %u frames %u skipped %u multi %u unarmed %u order %u bad_status %u stale %u terms %u term_missing %u underruns %u\n",
		   st->irqs, st->frames, st->skipped, st->multi, st->unarmed,
		   st->order, st->bad_status, st->stale, st->terms,
		   st->term_missing, st->underruns);
	seq_puts(m, "events (oldest first): t_ns status ctrl done armed\n");
	i = st->ev_head > GC573_VEV_NUM ? st->ev_head - GC573_VEV_NUM : 0;
	for (; i < st->ev_head; i++) {
		struct gc573_vev *e = &st->ev[i % GC573_VEV_NUM];

		seq_printf(m, "  %llu %#010x %#010x %u %u\n", e->ns, e->status,
			   e->ctrl, e->done, e->armed);
	}
	spin_unlock(&v->slock);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(gc573_vid_debugfs);

void gc573_video_debugfs(struct gc573 *gc)
{
	debugfs_create_file("video", 0444, gc->debugfs, gc,
			    &gc573_vid_debugfs_fops);
}

/* ---- setup ---- */

/* Software state the quiesce and the IRQ thread may use: before probe */
void gc573_video_early_init(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;

	mutex_init(&v->lock);
	spin_lock_init(&v->slock);
	INIT_LIST_HEAD(&v->queued);
	init_completion(&v->term);
	v->timings = gc573_timings_def;
	v->fmt = &gc573_fmts[0];
	gc573_fill_pix(gc, v->fmt, &v->pix);
}

static void gc573_video_unregister(void *data)
{
	struct gc573 *gc = data;

	vb2_video_unregister_device(&gc->vid.vdev);
}

int gc573_video_init(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	struct video_device *vdev = &v->vdev;
	struct vb2_queue *q = &v->queue;
	int ret;

	q->type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	q->io_modes = VB2_MMAP;
	q->drv_priv = gc;
	q->buf_struct_size = sizeof(struct gc573_vbuf);
	q->ops = &gc573_vb2_ops;
	q->mem_ops = &gc573_vb2_mem_ops;
	q->timestamp_flags = V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC |
			     V4L2_BUF_FLAG_TSTAMP_SRC_EOF;
	q->min_queued_buffers = 1;
	q->lock = &v->lock;
	q->dev = &gc->pdev->dev;
	ret = vb2_queue_init(q);
	if (ret)
		return ret;

	strscpy(vdev->name, "GC573 HDMI capture", sizeof(vdev->name));
	vdev->fops = &gc573_fops;
	vdev->ioctl_ops = &gc573_ioctl_ops;
	vdev->release = video_device_release_empty;
	vdev->v4l2_dev = &gc->v4l2_dev;
	vdev->queue = q;
	vdev->lock = &v->lock;
	vdev->vfl_dir = VFL_DIR_RX;
	vdev->device_caps = V4L2_CAP_VIDEO_CAPTURE | V4L2_CAP_STREAMING;
	video_set_drvdata(vdev, gc);

	ret = video_register_device(vdev, VFL_TYPE_VIDEO, -1);
	if (ret) {
		vb2_queue_release(q);
		return ret;
	}
	dev_info(&gc->pdev->dev, "video device %s\n",
		 video_device_node_name(vdev));

	return devm_add_action_or_reset(&gc->pdev->dev, gc573_video_unregister,
					gc);
}
