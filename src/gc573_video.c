// SPDX-License-Identifier: GPL-2.0
/*
 * GC573 video capture: V4L2 device, vb2 queue and video DMA.
 * spec/video-dma.md, spec/video-pipeline.md, spec/init.md, and the FPGA
 * hand-off of spec/hdmi-chips.md.
 *
 * The output size is the active size of the current DV timings (no
 * scaling). With a locked input whose timings match, a stream starts in
 * the input's configuration: bus mode, colour path and CSCs from the AVI
 * InfoFrame. With no locked input the FPGA free-runs at 60 Hz
 * (spec/video-dma.md "Free-running with no input"), as in M2.
 *
 * Input changes (gc573_video_input_changed(), from the HDMI poll worker):
 * every lock, loss and mode change raises V4L2_EVENT_SOURCE_CHANGE, and
 * the application should stop streaming, query and set the timings and
 * start again. A stream also follows the input by itself wherever its
 * buffers still fit, for applications that ignore the event (OBS):
 * - input lost: the stream restarts free-running (black at 60 Hz);
 * - input locked in the stream's timings: the stream restarts from it;
 * - input locked in other timings: the stream is held. The hardware
 *   stops and the buffers wait in the queue; no frames arrive. If within
 *   GC573_VID_HOLD_MS of the hold's start the input is lost or locks in
 *   the stream's timings, the stream restarts as above. If the other
 *   timings last that long, the stream stops: its buffers are returned
 *   with an error and the queue is marked failed (vb2_queue_error()).
 *   A source that changes its mode can lock briefly in another one first:
 *   after a hot-plug a GPU shows its preferred mode until the desktop
 *   sets its own (spec/hdmi-chips.md "Stream policy on input changes").
 *   The hold does not free-run: free-running is documented with no input
 *   (spec/video-dma.md), not with a locked input in other timings.
 * A restart is the hardware stop and start of STREAMOFF and STREAMON on
 * the same buffers: those in flight are queued again, the sequence counts
 * on, and the first frame after it is dropped as after STREAMON.
 *
 * Colorimetry (spec/hdmi-chips.md "Stream policy on input changes"): what
 * G_FMT, TRY_FMT and S_FMT report for each format, and the RGB->YUV CSC,
 * follow the last input that locked since load, from its AVI InfoFrame
 * (gc573_vid_col_input()). They follow it through a loss and a hold, so
 * that an application which sets its format again at the event
 * (GStreamer) gets the colorimetry it had; the free-run frames are black
 * in any of them. A lock in another colorimetry switches them at that
 * lock, with its event. Before the first lock since load: the M2 setup
 * (BT.709, limited-range YUV, full-range RGB).
 *
 * When the queue is not busy the device adopts the new input's timings; a
 * change while it was busy is adopted once it is free (REQBUFS 0, close).
 * STREAMON with a locked input whose timings differ fails with -EPIPE.
 *
 * Buffers: single-planar API, one contiguous buffer per frame. Each plane
 * goes to its own DMA channel through its own descriptor list, and a
 * buffer occupies the same slot on every channel it uses. Slots are armed
 * round-robin, and the hardware completes them in the order armed. Every
 * stop and start first disarms all three channels (CH_CTRL 0) and points
 * every slot at the driver's dummy list, so no channel register is left
 * with a list that has gone (gc573_video_disarm()).
 *
 * Locking: vid.lock serialises the ioctls, the vb2 queue and stream
 * start/stop. vid.slock protects the slot state shared with the IRQ
 * thread, and the channel registers written under it.
 */

#include <linux/bitfield.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/error-injection.h>
#include <linux/fs.h>
#include <linux/gcd.h>
#include <linux/jiffies.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/math64.h>
#include <linux/moduleparam.h>
#include <linux/pci.h>
#include <linux/scatterlist.h>
#include <linux/seq_file.h>
#include <linux/string.h>
#include <linux/v4l2-dv-timings.h>
#include <linux/workqueue.h>
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
/*
 * The dummy list (gc573_video_alloc()): one descriptor at the start of a
 * coherent page, for the page's second half (256-byte aligned, a multiple
 * of 32 bytes: the descriptor rules of spec/video-dma.md)
 */
#define GC573_DUMMY_OFF			2048
#define GC573_DUMMY_LEN			2048
/* descriptor chunk cap: the DMA max segment size (gc573.h) */
#define GC573_DESC_MAX			GC573_DMA_SEG_MAX
/*
 * spec/video-dma.md "Card frame store": the first frame after a start can
 * carry stale lines from an earlier session. It is never delivered.
 */
#define GC573_VID_SKIP			1
/*
 * How long a stream is held while the input is locked in other timings
 * (policy: header comment). The driver locked in a passing mode 1.1-1.7 s
 * after the source set it, before the delivery settle
 * (GC573_HDMI_SETTLE_MS) added about 1 s, so the hold rides out a second
 * mode set that comes up to 2.1-2.7 s after the first, or later; measured
 * blips lasted 138 and 224 ms. Applications that ignore SOURCE_CHANGE see
 * a lasting change (the failed queue) that much later.
 */
#define GC573_VID_HOLD_MS		1000
/*
 * The largest image any format can have: the timings cap's largest frame
 * (1920x1080) in the widest format (XBGR32, 4 bytes per pixel). A buffer
 * that CREATE_BUFS asks for beyond it could never be used.
 */
#define GC573_SIZEIMAGE_MAX		(1920 * 1080 * 4)

static int exp_slot_mode;
module_param(exp_slot_mode, int, 0644);
MODULE_PARM_DESC(exp_slot_mode,
		 "Experiment, spec/open-questions.md #8; read at stream start. 0: normal, 1: slot-valid bits on ch0 only, 2: ch1/ch2 CH_CTRL written at start only, 3: slot-valid bits on ch1/ch2 only, 4: ch1/ch2 CH_CTRL never written, 5: ch1/ch2 CH_CTRL = 0 at start, never set (every stop and start writes 0 to all three first, in every mode)");

/*
 * Experiment, spec/open-questions.md #33 (delivery below 59.94 Hz): RATE_CTRL
 * as the plan there lists it. RATE_CTRL keeps its value across resets and
 * the driver keeps bit 3, so bits 0 and 3 are set or cleared explicitly.
 */
static unsigned int exp_rate_fps;
module_param(exp_rate_fps, uint, 0644);
MODULE_PARM_DESC(exp_rate_fps,
		 "Experiment, spec/open-questions.md #33; read at stream start. RATE_CTRL[31:16] = 1..60 (0: the driver's value)");

static int exp_rate_bits = -1;
module_param(exp_rate_bits, int, 0644);
MODULE_PARM_DESC(exp_rate_bits,
		 "Experiment, spec/open-questions.md #33; read at stream start. RATE_CTRL bits 0 and 3 := this value's bits 0 and 3 (-1: keep them)");

/*
 * Experiment, spec/open-questions.md #13 (reset domain contents; which one
 * stops the audio DMA): the domains a video stop resets, and a debugfs
 * trigger (exp_reset) that resets domains while video is idle.
 */
static int exp_stop_domains = -1;
module_param_unsafe(exp_stop_domains, int, 0644);
MODULE_PARM_DESC(exp_stop_domains,
		 "Experiment, spec/open-questions.md #13, can corrupt memory; setting it taints the kernel. Read at stream stop. Domains to reset: mask of 0x001, 0x100, 0x200 (0: none; -1: the driver's choice, all three with 0x100 left out while audio runs)");

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
 * (c0, c1, c2, offset), unsigned magnitudes, plus a sign mask. Computed
 * per input (gc573_csc_r2y(), gc573_csc_y2r()); for BT.709 they equal the
 * worked examples there.
 */
struct gc573_csc {
	u16 neg;			/* bit i set: entry i is negative */
	u16 e[12];
};

/* Luma weights Kr, Kb x 10000 (ITU-R BT.709, BT.601, BT.2020) */
static const u16 gc573_kr_kb[][2] = {
	[GC573_ENC_709] = { 2126, 722 },
	[GC573_ENC_601] = { 2990, 1140 },
	[GC573_ENC_2020] = { 2627, 593 },
};

#define GC573_K		10000LL

/*
 * DV timings: progressive up to 1080p60 (single-pixel input bus). 4K
 * needs the dual-pixel modes; interlaced input is untraced.
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

/*
 * TODO(spec): open question 30. At width 720 YV12 never completed a frame
 * (each chroma plane, 360-byte lines, received 2016 bytes less than its
 * size); NV12 and the packed formats work. No YV12 at that width.
 */
static bool gc573_fmt_ok(const struct gc573_fmt *f, u32 width)
{
	return !(f->fourcc == V4L2_PIX_FMT_YVU420 && width == 720);
}

/* The format, or the default if it is unknown or unusable at the width */
static const struct gc573_fmt *gc573_find_fmt(u32 fourcc, u32 width)
{
	const struct gc573_fmt *f = gc573_lookup_fmt(fourcc);

	return f && gc573_fmt_ok(f, width) ? f : &gc573_fmts[0];
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
 * TODO(spec): spec/ has no line-length rule for the pixel packer (open
 * question 30). Widths seen to complete frames: 640, 1280 and 1920 in all
 * six formats, 720 in all but YV12 (tests/cases/10-video-capture.sh).
 * Until spec/ has the rule, offer only these.
 */
static const u32 gc573_widths[] = { 640, 720, 1280, 1920 };

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
		if (gc573_fmt_ok(&gc573_fmts[i], w) &&
		    !gc573_layout_ok(&gc573_fmts[i], w, h))
			return false;
	return true;
}

/* ENUM_DV_TIMINGS: what the device captures and the EDID offers */
static bool gc573_timings_offered(const struct v4l2_dv_timings *t,
				  void *handle)
{
	return gc573_timings_fit(t, NULL) && gc573_hdmi_edid_offers(handle, t);
}

/* Is the stream configured for the locked input? */
static bool gc573_vid_input_matches(const struct gc573_video *v)
{
	return v->in.locked &&
	       v4l2_match_dv_timings(&v->in.timings, &v->timings, 0, false);
}

/*
 * The input whose colorimetry the device reports and the RGB->YUV CSC
 * uses (spec/hdmi-chips.md "Stream policy on input changes"): the last one
 * that locked since load, through a loss and a hold. NULL before the first
 * lock. While an input is locked it is that input.
 */
static const struct gc573_input *
gc573_vid_col_input(const struct gc573_video *v)
{
	return v->col_valid ? &v->col_in : NULL;
}

/* The input as the device sees it now, and the last one locked */
static void gc573_vid_note_input(struct gc573_video *v,
				 const struct gc573_input *in)
{
	v->in = *in;
	if (in->locked) {
		v->col_in = *in;
		v->col_valid = true;
	}
}

/* Y'CbCr encoding of the YUV outputs: the input's, or by size for RGB */
static enum gc573_enc gc573_vid_out_enc(const struct gc573_video *v)
{
	const struct gc573_input *in = gc573_vid_col_input(v);

	if (!in)
		return GC573_ENC_709;
	if (in->colour)
		return in->enc;
	return v->timings.bt.height >= 720 ? GC573_ENC_709 : GC573_ENC_601;
}

/*
 * Colorimetry of the captured data, from gc573_vid_col_input(). Before any
 * lock the M2 setup applies: BT.709, limited-range YUV, full-range RGB.
 * Then that input's colour space; YUV outputs are limited range in the
 * encoding of gc573_vid_out_enc(); RGB outputs are full range, except that
 * RGB input reaches RGB output unconverted and keeps its range. During a
 * loss the frames are the free-run black (video-dma.md), which is black in
 * any of these (RGB outputs: 0, under a limited-range RGB input too).
 */
static void gc573_vid_colorimetry(const struct gc573_video *v,
				  const struct gc573_fmt *f,
				  struct v4l2_pix_format *pix)
{
	static const u8 encs[] = {
		[GC573_ENC_709] = V4L2_YCBCR_ENC_709,
		[GC573_ENC_601] = V4L2_YCBCR_ENC_601,
		[GC573_ENC_2020] = V4L2_YCBCR_ENC_BT2020,
	};
	static const u8 spaces[] = {
		[GC573_ENC_709] = V4L2_COLORSPACE_REC709,
		[GC573_ENC_601] = V4L2_COLORSPACE_SMPTE170M,
		[GC573_ENC_2020] = V4L2_COLORSPACE_BT2020,
	};
	const struct gc573_input *in = gc573_vid_col_input(v);

	pix->colorspace = V4L2_COLORSPACE_REC709;
	pix->xfer_func = V4L2_XFER_FUNC_709;
	pix->ycbcr_enc = encs[gc573_vid_out_enc(v)];
	pix->quantization = f->rgb ? V4L2_QUANTIZATION_FULL_RANGE :
				     V4L2_QUANTIZATION_LIM_RANGE;
	if (!in)
		return;
	if (!in->colour) {
		pix->colorspace = V4L2_COLORSPACE_SRGB;
		pix->xfer_func = V4L2_XFER_FUNC_SRGB;
		if (f->rgb && !in->full_range)
			pix->quantization = V4L2_QUANTIZATION_LIM_RANGE;
	} else {
		pix->colorspace = spaces[in->enc];
	}
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
	gc573_vid_colorimetry(&gc->vid, f, pix);
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
	atomic_inc(&gc573_mem_live.dlists);
	atomic_long_add(dl->size, &gc573_mem_live.dl_bytes);

	memset(&x, 0, sizeof(x));
	x.desc = dl->desc;
	gc573_dl_walk(&x, sgt, off, len);
	dl->count = x.count;
	return 0;
}

/* @keep: never freed, still mapped (after gc573_dma_dead()) */
static void gc573_dl_free(struct gc573 *gc, struct gc573_vbuf *b, bool keep)
{
	unsigned int c;

	for (c = 0; c < GC573_VCH_NUM; c++) {
		struct gc573_dlist *dl = &b->dl[c];

		if (dl->desc) {
			if (keep)
				atomic_long_add(dl->size, &gc573_mem_live.kept);
			else
				dma_free_coherent(&gc->pdev->dev, dl->size,
						  dl->desc, dl->dma);
			atomic_dec(&gc573_mem_live.dlists);
			atomic_long_sub(dl->size, &gc573_mem_live.dl_bytes);
		}
		memset(dl, 0, sizeof(*dl));
	}
}

/* The memory of a buffer the card can write: its pages and its lists */
static long gc573_vbuf_dma_bytes(struct gc573_vbuf *b)
{
	long n = PAGE_ALIGN(vb2_plane_size(&b->vb.vb2_buf, 0));
	unsigned int c;

	for (c = 0; c < GC573_VCH_NUM; c++)
		n += b->dl[c].size;
	return n;
}

/* ---- hardware ---- */

/* round(num / den), den > 0 */
static s64 gc573_div_round(s64 num, s64 den)
{
	return num >= 0 ? div64_s64(num + den / 2, den) :
			  -div64_s64(-num + den / 2, den);
}

/* Entry i = num / den in units of 'unit' (Q2.14: 16384; offsets: 16) */
static void gc573_csc_set(struct gc573_csc *m, unsigned int i, s64 num,
			  s64 den, s64 unit)
{
	s64 v = gc573_div_round(num * unit, den);

	if (v < 0) {
		m->neg |= BIT(i);
		v = -v;
	}
	m->e[i] = min_t(s64, v, U16_MAX);
}

/*
 * RGB (full or limited range) to limited-range Y'CbCr: rows Y, Cb, Cr;
 * columns G, B, R; offsets in 8-bit code values.
 */
static void gc573_csc_r2y(struct gc573_csc *m, enum gc573_enc enc, bool full)
{
	const s64 kr = gc573_kr_kb[enc][0], kb = gc573_kr_kb[enc][1];
	const s64 kg = GC573_K - kr - kb, s = full ? 255 : 219;
	const s64 o = full ? 0 : 16, cb = 2 * (GC573_K - kb) * s;
	const s64 cr = 2 * (GC573_K - kr) * s;

	memset(m, 0, sizeof(*m));
	gc573_csc_set(m, 0, 219 * kg, s * GC573_K, 16384);
	gc573_csc_set(m, 1, 219 * kb, s * GC573_K, 16384);
	gc573_csc_set(m, 2, 219 * kr, s * GC573_K, 16384);
	gc573_csc_set(m, 3, 16 * s - 219 * o, s, 16);
	gc573_csc_set(m, 4, -224 * kg, cb, 16384);
	gc573_csc_set(m, 5, 224 * (GC573_K - kb), cb, 16384);
	gc573_csc_set(m, 6, -224 * kr, cb, 16384);
	gc573_csc_set(m, 7, 128, 1, 16);
	gc573_csc_set(m, 8, -224 * kg, cr, 16384);
	gc573_csc_set(m, 9, -224 * kb, cr, 16384);
	gc573_csc_set(m, 10, 224 * (GC573_K - kr), cr, 16384);
	gc573_csc_set(m, 11, 128, 1, 16);
}

/*
 * Y'CbCr (limited or full range) to full-range RGB: rows G, B, R; columns
 * Y, Cb, Cr; the offsets fold in the input offsets.
 */
static void gc573_csc_y2r(struct gc573_csc *m, enum gc573_enc enc, bool full)
{
	const s64 kr = gc573_kr_kb[enc][0], kb = gc573_kr_kb[enc][1];
	const s64 kg = GC573_K - kr - kb, k = GC573_K;
	const s64 sy = full ? 255 : 219, sc = full ? 255 : 224;
	const s64 oy = full ? 0 : 16;
	const s64 gb = 2 * kb * (k - kb), gr = 2 * kr * (k - kr);

	memset(m, 0, sizeof(*m));
	gc573_csc_set(m, 0, 255, sy, 16384);
	gc573_csc_set(m, 1, -255 * gb, kg * k * sc, 16384);
	gc573_csc_set(m, 2, -255 * gr, kg * k * sc, 16384);
	gc573_csc_set(m, 3, -255 * oy * kg * k * sc + 128 * 255 * (gb + gr) * sy,
		      sy * kg * k * sc, 16);
	gc573_csc_set(m, 4, 255, sy, 16384);
	gc573_csc_set(m, 5, 255 * 2 * (k - kb), k * sc, 16384);
	gc573_csc_set(m, 7, -255 * oy * k * sc - 128 * 255 * 2 * (k - kb) * sy,
		      sy * k * sc, 16);
	gc573_csc_set(m, 8, 255, sy, 16384);
	gc573_csc_set(m, 10, 255 * 2 * (k - kr), k * sc, 16384);
	gc573_csc_set(m, 11, -255 * oy * k * sc - 128 * 255 * 2 * (k - kr) * sy,
		      sy * k * sc, 16);
}

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
 * Pipeline for the current format, in RD's order (spec/video-pipeline.md,
 * spec/video-dma.md "Start" step 1). Output stays disabled. Scalers:
 * reset and bypassed (output size = input size).
 *
 * No matching input: RD's no-input setup (PIX_MODE 2, input taken as YUV,
 * rate limit 5, YUV->RGB CSC limited-range BT.709). The RGB->YUV CSC is in
 * the encoding the device reports (gc573_vid_out_enc(), the last locked
 * input's): it maps the free-run black to black in any encoding.
 * Locked input (spec/hdmi-chips.md "FPGA hand-off",
 * hdmi-it6805.md 10.4): PIX_MODE and COLOR_CTRL bits 0/5/19 mirror the
 * IT6805 bus and the AVI colour format. CSCs: YUV input goes through the
 * YUV->RGB CSC (to full-range RGB), YUV outputs through the RGB->YUV CSC;
 * RGB input to RGB output passes with both off (traced, T4/S42).
 */
static void gc573_vid_setup(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	const struct gc573_fmt *f = v->fmt;
	const struct gc573_input *in = &v->in;
	u32 color = GC573_COLOR_CTRL_ADJUST, pix = GC573_PIX_MODE_NO_INPUT;
	u32 fps = GC573_RATE_FPS_NO_INPUT, rate;
	enum gc573_enc in_enc = GC573_ENC_709;
	bool yuv_in = true, full_in = false;
	struct gc573_csc m;

	if (v->live) {
		yuv_in = in->colour != 0;
		full_in = in->full_range;
		in_enc = in->enc;
		pix = (in->dual ? GC573_PIX_MODE_DUAL : 0) |
		      (in->ddr ? GC573_PIX_MODE_DDR : 0);
		if (in->dual)
			color |= GC573_COLOR_CTRL_DUAL;
		if (in->colour == 1)
			color |= GC573_COLOR_CTRL_IN422;
		if (in->colour == 3)
			color |= GC573_COLOR_CTRL_IN420;
		/* RD clamps the rate limit to 5..60 (video-pipeline.md) */
		if (in->period)
			fps = clamp(DIV_ROUND_CLOSEST(GC573_IN_FRAME_PERIOD_HZ,
						      in->period), 5U, 60U);
		else
			fps = 60;
	}
	if (yuv_in)
		color |= GC573_COLOR_CTRL_Y2R;
	if (!f->rgb)
		color |= GC573_COLOR_CTRL_R2Y;

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

	/* rate limit and colour-path flags; bit 3 and above 31:16 kept */
	if (exp_rate_fps >= 1 && exp_rate_fps <= 60)
		fps = exp_rate_fps;
	rate = gc573_rd(gc, GC573_RATE_CTRL);
	rate &= ~(GC573_RATE_CTRL_FPS | GC573_RATE_CTRL_IN_YUV |
		  GC573_RATE_CTRL_OUT_RGB);
	rate |= FIELD_PREP(GC573_RATE_CTRL_FPS, fps) |
		(yuv_in ? GC573_RATE_CTRL_IN_YUV : 0) |
		(f->rgb ? GC573_RATE_CTRL_OUT_RGB : 0);
	if (exp_rate_bits >= 0)
		rate = (rate & ~GC573_RATE_CTRL_EXP) |
		       (exp_rate_bits & GC573_RATE_CTRL_EXP);
	gc573_wr(gc, GC573_RATE_CTRL, rate);

	/* R2Y: from Y2R's full-range RGB, or from the RGB input as it is */
	gc573_csc_r2y(&m, gc573_vid_out_enc(v), yuv_in || full_in);
	gc573_csc_write(gc, GC573_CSC_R2Y, &m);
	gc573_csc_y2r(&m, in_enc, yuv_in && v->live && full_in);
	gc573_csc_write(gc, GC573_CSC_Y2R, &m);
	gc573_wr(gc, GC573_COLOR_CTRL, color);

	gc573_wr(gc, GC573_PIX_MODE, pix);
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
 * hardware clears its slot bits as slots complete (an all-ones read, a
 * card that does not answer, is not written back: every slot and the run
 * bit set). ch1/ch2 cannot be read back, so they get the exact value
 * software intends. slock held.
 */
static void gc573_vid_ctrl(struct gc573 *gc, unsigned int c, u32 set, u32 clr)
{
	struct gc573_video *v = &gc->vid;
	u32 reg = gc573_vch_base[c] + GC573_VCH_CTRL;
	u32 val;

	if (!c) {
		val = gc573_rd(gc, reg);
		if (val != U32_MAX)
			gc573_wr(gc, reg, (val & ~clr) | set);
		else
			dev_warn_once(&gc->pdev->dev, "ch0 CH_CTRL update: the card does not answer (reads all-ones): not written\n");
	} else {
		v->ch_ctrl[c] = (v->ch_ctrl[c] & ~clr) | set;
		gc573_wr(gc, reg, v->ch_ctrl[c]);
	}
}

/*
 * Every channel disarmed: CH_CTRL 0, no run bit and no slot valid (ch0's
 * gates every channel, spec/video-dma.md "Slots"), and every slot of
 * every channel pointing at the dummy list, memory the driver keeps until
 * after the quiesce. Probe (before bus mastering), and every stream stop
 * and start, slock held there. A slot a format does not use thus never
 * keeps a list an earlier stream freed.
 */
void gc573_video_disarm(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	unsigned int c, n;

	for (c = 0; c < GC573_VCH_NUM; c++) {
		u32 base = gc573_vch_base[c];

		gc573_wr(gc, base + GC573_VCH_CTRL, 0);
		v->ch_ctrl[c] = 0;
		for (n = 0; n < GC573_VCH_SLOTS; n++) {
			gc573_wr(gc, base + GC573_VCH_LIST_LO(n),
				 lower_32_bits(v->dummy_dma));
			gc573_wr(gc, base + GC573_VCH_LIST_HI(n),
				 upper_32_bits(v->dummy_dma));
			gc573_wr(gc, base + GC573_VCH_COUNT(n), 1);
		}
	}
}

/*
 * Point slot n of every channel in use at b's lists, from when on the card
 * can write b (kept if a stop is not confirmed, gc573_buf_cleanup()).
 * slock held.
 */
static void gc573_vid_program_slot(struct gc573 *gc, unsigned int n,
				   struct gc573_vbuf *b)
{
	unsigned int c;

	if (!b->exposed) {
		b->exposed = true;
		atomic_long_add(gc573_vbuf_dma_bytes(b), &gc->vid.exposed_bytes);
	}
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
 * bit 0, reset the domains. Domain 8 holds the audio DMA and nothing the
 * video path reads back (open question 13, driver M5: domain 0 resets the
 * video DMA, COLOR_CTRL, CLIP and the CSC banks, the same as all three):
 * while an audio stream runs it is left out, and audio carries on through
 * the stop. Either the terminate or the reset of domain 0 stops the video
 * DMA; with neither, the buffers about to go back may still be written:
 * the card is left as it is, with that memory, until reboot
 * (gc573_dma_dead()), and -EIO is returned. vid.lock held. Safe to call
 * when not running.
 */
int gc573_video_hw_stop(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	struct device *dev = &gc->pdev->dev;
	unsigned int fault = READ_ONCE(gc573_exp_stop_fault);
	unsigned long t0 = jiffies;
	int domains = READ_ONCE(exp_stop_domains);
	bool term = true, reset, counted = false;
	u32 vip;

	spin_lock(&v->slock);
	v->running = false;
	spin_unlock(&v->slock);

	vip = gc573_rd(gc, GC573_VIP_CTRL);
	if (vip == U32_MAX) {
		/* no answer: no terminate to ask for or wait on */
		term = false;
		dev_warn(dev, "video stop: the card does not answer (VIP_CTRL reads all-ones)\n");
	} else if (vip & GC573_VIP_CTRL_OUT_EN) {
		reinit_completion(&v->term);
		gc573_wr(gc, GC573_VIP_CTRL, vip & ~GC573_VIP_CTRL_OUT_EN);
		if (!wait_for_completion_timeout(&v->term,
						 msecs_to_jiffies(GC573_VID_TERM_MS))) {
			v->st.term_missing++;
			term = false;
			dev_warn(dev, "video stop: timeout waiting for INT bit 0\n");
		}
	}
	if (domains < 0) {
		domains = GC573_RESET_DOMAINS;
		if (gc573_audio_running(gc))
			domains &= ~GC573_RESET_DOMAIN_8;
	}
	reset = !gc573_reset_domain_mask(gc, domains) &&
		(domains & GC573_RESET_DOMAIN_0);
	spin_lock(&v->slock);
	gc573_video_disarm(gc);
	spin_unlock(&v->slock);
	/* tests only: a stop confirmed with the output off, counted as failed */
	vip = gc573_rd(gc, GC573_VIP_CTRL);
	if ((fault & (GC573_STOP_FAULT_TERM | GC573_STOP_FAULT_RESET)) &&
	    (term || reset) && vip != U32_MAX && !(vip & GC573_VIP_CTRL_OUT_EN)) {
		dev_warn(dev, "exp_stop_fault %#x: the video stop was confirmed (INT bit 0 %s, domain 0 reset %s, VIP_CTRL %#010x), counted as%s%s\n",
			 fault, term ? "came" : "missing",
			 reset ? "done" : "not done", vip,
			 fault & GC573_STOP_FAULT_TERM ? " no INT bit 0" : "",
			 fault & GC573_STOP_FAULT_RESET ? " no domain 0 reset" : "");
		if (fault & GC573_STOP_FAULT_TERM)
			term = false;
		if (fault & GC573_STOP_FAULT_RESET)
			reset = false;
		counted = true;
	}
	if (!term && !reset) {
		/* tests only: a system sleep started now meets the stop */
		if (counted && (fault & GC573_STOP_FAULT_SLOW)) {
			dev_warn(dev, "exp_stop_fault %#x: the video stop counts as failed in %u ms, vid.lock held\n",
				 fault, GC573_STOP_FAULT_SLOW_MS);
			msleep(GC573_STOP_FAULT_SLOW_MS);
		}
		gc573_dma_dead(gc, "video stop (no INT bit 0, no reset of domain 0) failed");
		return -EIO;
	}
	/* a reset of domain 8 stops the audio DMA: start it again */
	gc573_audio_reset_done(gc);
	dev_dbg(dev, "video stopped in %u ms\n",
		jiffies_to_msecs(jiffies - t0));
	return 0;
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

	/*
	 * CREATE_BUFS: the caller's sizeimage, at least the current one and
	 * at most what a later format could use (all of it is allocated)
	 */
	if (*nplanes)
		return *nplanes != 1 || sizes[0] < size ||
		       sizes[0] > PAGE_ALIGN(GC573_SIZEIMAGE_MAX) ? -EINVAL : 0;
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
	gc573_dl_free(gc, b, false);
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

/*
 * A buffer the card was given, after a stop the card did not confirm
 * (gc573_dma_dead()), is kept: its lists and pages are never freed and
 * stay DMA-mapped, so that a transfer the card still holds cannot land in
 * memory someone else has, or at an IOVA a new buffer was given.
 */
static void gc573_buf_cleanup(struct vb2_buffer *vb)
{
	struct gc573 *gc = vb2_get_drv_priv(vb->vb2_queue);
	struct gc573_vbuf *b = to_gc573_vbuf(vb);
	bool keep = READ_ONCE(gc->dma_dead) && b->exposed;

	if (b->exposed && !keep)
		atomic_long_sub(gc573_vbuf_dma_bytes(b), &gc->vid.exposed_bytes);
	gc573_dl_free(gc, b, keep);
	if (keep)
		gc573_mem_keep(b->sgt);
	else
		dma_unmap_sgtable(&gc->pdev->dev, b->sgt, DMA_FROM_DEVICE, 0);
}

static void gc573_vid_hw_start(struct gc573 *gc, bool restart);

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
	/* a restart after an input change waited for this buffer */
	if (v->start_pending && !v->dead) {
		v->start_pending = false;
		gc573_vid_hw_start(gc, true);
	}
}

/*
 * spec/video-dma.md "Start", from the input as it is: live from a locked
 * input in the stream's timings, free-running without one. At least one
 * buffer is queued. A restart keeps the sequence and the statistics.
 * vid.lock held.
 */
static void gc573_vid_hw_start(struct gc573 *gc, bool restart)
{
	struct gc573_video *v = &gc->vid;
	struct gc573_vbuf *first;
	unsigned int c, n;

	v->live = v->in.locked;

	gc573_vid_setup(gc);

	spin_lock(&v->slock);
	v->exp_mode = READ_ONCE(exp_slot_mode);
	if (v->exp_mode < 0 || v->exp_mode > 5)
		v->exp_mode = 0;
	v->next_arm = 0;
	v->arm_seq = 0;
	v->skip = GC573_VID_SKIP;
	gc573_video_disarm(gc);
	if (!restart) {
		v->sequence = 0;
		memset(&v->st, 0, sizeof(v->st));
	}

	/* every slot of every channel in use points at a queued buffer */
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
		"video %s: %p4cc %ux%u %s, %u slot(s) armed, exp_slot_mode %d, IN 1004 %#x 1008 %#x 100c %#x 1010 %#x\n",
		restart ? "restart" : "start", &v->pix.pixelformat,
		v->pix.width, v->pix.height, v->live ? "live" : "no input",
		gc573_vid_armed(v), v->exp_mode,
		gc573_rd(gc, GC573_IN_STATUS), gc573_rd(gc, GC573_IN_WIDTH),
		gc573_rd(gc, GC573_IN_HEIGHT),
		gc573_rd(gc, GC573_IN_FRAME_PERIOD));
}

static int gc573_start_streaming(struct vb2_queue *q, unsigned int count)
{
	struct gc573 *gc = vb2_get_drv_priv(q);
	struct gc573_video *v = &gc->vid;

	v->failed = false;
	v->held = false;
	v->start_pending = false;
	if (v->dead) {
		gc573_vid_return_all(gc, VB2_BUF_STATE_QUEUED);
		return -ENODEV;
	}
	/* a system sleep is under way (gc573_pm_notify()) */
	if (gc->sleeping) {
		gc573_vid_return_all(gc, VB2_BUF_STATE_QUEUED);
		return -EBUSY;
	}
	/* a locked input in other timings: query and set them first */
	if (v->in.locked && !gc573_vid_input_matches(v)) {
		gc573_vid_return_all(gc, VB2_BUF_STATE_QUEUED);
		return -EPIPE;
	}
	gc573_vid_hw_start(gc, false);
	return 0;
}

static void gc573_stop_streaming(struct vb2_queue *q)
{
	struct gc573 *gc = vb2_get_drv_priv(q);
	struct gc573_video *v = &gc->vid;

	/* after the quiesce the engines are reset and the IRQ is off */
	if (!v->dead)
		gc573_video_hw_stop(gc);
	v->start_pending = false;
	v->held = false;
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

/* The formats usable at the current width (gc573_fmt_ok()) */
static int gc573_enum_fmt(struct file *file, void *priv,
			  struct v4l2_fmtdesc *f)
{
	struct gc573 *gc = video_drvdata(file);
	u32 w = gc->vid.timings.bt.width;
	unsigned int i, n = 0;

	for (i = 0; i < ARRAY_SIZE(gc573_fmts); i++) {
		if (!gc573_fmt_ok(&gc573_fmts[i], w))
			continue;
		if (n++ == f->index) {
			f->pixelformat = gc573_fmts[i].fourcc;
			return 0;
		}
	}
	return -EINVAL;
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

	gc573_fill_pix(gc, gc573_find_fmt(f->fmt.pix.pixelformat,
					  gc->vid.timings.bt.width),
		       &f->fmt.pix);
	return 0;
}

static int gc573_s_fmt(struct file *file, void *priv, struct v4l2_format *f)
{
	struct gc573 *gc = video_drvdata(file);
	struct gc573_video *v = &gc->vid;
	const struct gc573_fmt *fmt = gc573_find_fmt(f->fmt.pix.pixelformat,
						     v->timings.bt.width);

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
	const struct gc573_fmt *f = gc573_lookup_fmt(fs->pixel_format);

	if (fs->index || !f || !gc573_fmt_ok(f, gc->vid.timings.bt.width))
		return -EINVAL;
	fs->type = V4L2_FRMSIZE_TYPE_DISCRETE;
	fs->discrete.width = gc->vid.timings.bt.width;
	fs->discrete.height = gc->vid.timings.bt.height;
	return 0;
}

/*
 * The DV timings' nominal frame interval as an exact fraction: frame size
 * over pixel clock, times 1001/1000 with REDUCED_FPS, so 1/60 and
 * 1001/60000 as applications expect (v4l2_calc_timeperframe() rounds the
 * rate to 1/100 fps first: 50/2997 for 59.94 Hz). {0, 0} if it does not
 * fit a v4l2_fract.
 */
static struct v4l2_fract gc573_vid_nominal(const struct v4l2_bt_timings *bt)
{
	u64 n = (u64)V4L2_DV_BT_FRAME_WIDTH(bt) * V4L2_DV_BT_FRAME_HEIGHT(bt);
	u64 d = bt->pixelclock;
	struct v4l2_fract f = { 0, 0 };
	u64 g;

	if ((bt->flags & V4L2_DV_FL_CAN_REDUCE_FPS) &&
	    (bt->flags & V4L2_DV_FL_REDUCED_FPS)) {
		n *= 1001;
		d *= 1000;
	}
	if (!n || !d)
		return f;
	g = gcd(n, d);
	n = div64_u64(n, g);
	d = div64_u64(d, g);
	if (n <= U32_MAX && d <= U32_MAX) {
		f.numerator = n;
		f.denominator = d;
	}
	return f;
}

/*
 * Frame interval: with a matching locked input the period the FPGA
 * measured (0x1010, spec/hdmi-it6805.md 8.3), reported as the nominal
 * interval when within 0.1 % of it; else the DV timings' nominal one.
 *
 * Delivery (spec/video-pipeline.md "Delivery rate", open question 33):
 * inputs at 50 Hz and below complete every 16.667 ms, an input frame being
 * repeated, and no register marks the repeats; 59.93-60 Hz inputs complete
 * at their own rate. Every completion reaches the application, so below
 * GC573_VID_LOCK_MIN_DHZ the interval reported is the delivered 1/60. The
 * boundary between the two regimes is not known; 59.5 Hz keeps every
 * observed mode right.
 */
#define GC573_VID_LOCK_MIN_DHZ		595	/* 59.5 Hz, in 0.1 Hz */

static struct v4l2_fract gc573_vid_interval(struct gc573_video *v)
{
	struct v4l2_fract nom = gc573_vid_nominal(&v->timings.bt), f;
	unsigned long g;
	u64 a, b;

	if (!nom.denominator)
		nom = v4l2_calc_timeperframe(&v->timings);
	if (!gc573_vid_input_matches(v) || !v->in.period)
		return nom;
	if ((u64)v->in.period * GC573_VID_LOCK_MIN_DHZ >
	    (u64)GC573_IN_FRAME_PERIOD_HZ * 10)
		return (struct v4l2_fract){ 1, 60 };
	a = (u64)v->in.period * nom.denominator;
	b = (u64)nom.numerator * GC573_IN_FRAME_PERIOD_HZ;
	if (abs_diff(a, b) <= div_u64(b, 1000))
		return nom;
	g = gcd(v->in.period, GC573_IN_FRAME_PERIOD_HZ);
	f.numerator = v->in.period / g;
	f.denominator = GC573_IN_FRAME_PERIOD_HZ / g;
	return f;
}

static int gc573_enum_frameintervals(struct file *file, void *priv,
				     struct v4l2_frmivalenum *fi)
{
	struct gc573 *gc = video_drvdata(file);
	const struct v4l2_bt_timings *bt = &gc->vid.timings.bt;
	const struct gc573_fmt *f = gc573_lookup_fmt(fi->pixel_format);

	if (fi->index || !f || !gc573_fmt_ok(f, bt->width) ||
	    fi->width != bt->width || fi->height != bt->height)
		return -EINVAL;
	fi->type = V4L2_FRMIVAL_TYPE_DISCRETE;
	fi->discrete = gc573_vid_interval(&gc->vid);
	return 0;
}

/* G_PARM and S_PARM: the frame interval follows the input */
static int gc573_g_parm(struct file *file, void *priv,
			struct v4l2_streamparm *a)
{
	struct gc573 *gc = video_drvdata(file);

	if (a->type != V4L2_BUF_TYPE_VIDEO_CAPTURE)
		return -EINVAL;
	memset(&a->parm.capture, 0, sizeof(a->parm.capture));
	a->parm.capture.capability = V4L2_CAP_TIMEPERFRAME;
	a->parm.capture.timeperframe = gc573_vid_interval(&gc->vid);
	return 0;
}

static int gc573_enum_input(struct file *file, void *priv,
			    struct v4l2_input *inp)
{
	struct gc573 *gc = video_drvdata(file);
	struct gc573_input in;

	if (inp->index)
		return -EINVAL;
	strscpy(inp->name, "HDMI", sizeof(inp->name));
	inp->type = V4L2_INPUT_TYPE_CAMERA;
	inp->capabilities = V4L2_IN_CAP_DV_TIMINGS;
	gc573_hdmi_input(gc, &in);
	if (!in.power)
		inp->status = V4L2_IN_ST_NO_POWER | V4L2_IN_ST_NO_SIGNAL;
	else if (!in.signal)
		inp->status = V4L2_IN_ST_NO_SIGNAL;
	else if (!in.locked)
		inp->status = V4L2_IN_ST_NO_SYNC;
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
	/* the device tells 1000/1001 rates apart (measured frame period) */
	if (t->bt.flags & V4L2_DV_FL_CAN_REDUCE_FPS)
		t->bt.flags |= V4L2_DV_FL_CAN_DETECT_REDUCED_FPS;
	if (v4l2_match_dv_timings(t, &v->timings, 0, true))
		return 0;
	if (vb2_is_busy(&v->queue))
		return -EBUSY;
	v->timings = *t;
	v->fmt = gc573_find_fmt(v->fmt->fourcc, t->bt.width);
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

/*
 * The HDMI front-end's detected timings (spec/hdmi-it6805.md 8.1, 8.3):
 * ENOLINK without signal, ENOLCK while not stable, ERANGE for timings the
 * device cannot capture.
 */
static int gc573_query_dv_timings(struct file *file, void *priv,
				  struct v4l2_dv_timings *t)
{
	struct gc573 *gc = video_drvdata(file);
	struct gc573_input in;

	gc573_hdmi_input(gc, &in);
	if (!in.signal)
		return -ENOLINK;
	if (!in.locked)
		return -ENOLCK;
	if (!v4l2_valid_dv_timings(&in.timings, &gc573_timings_cap,
				   gc573_timings_fit, NULL))
		return -ERANGE;
	*t = in.timings;
	return 0;
}

/* The capturable timings the EDID offers */
static int gc573_enum_dv_timings(struct file *file, void *priv,
				 struct v4l2_enum_dv_timings *t)
{
	struct gc573 *gc = video_drvdata(file);

	return v4l2_enum_dv_timings_cap(t, &gc573_timings_cap,
					gc573_timings_offered, gc);
}

/*
 * The ioctls that reach the card (S_EDID: bus 1 and GPIO; LOG_STATUS:
 * registers), and G_EDID with them: -ENODEV once the card is dead or its
 * teardown has begun. The teardown sets vid.dead under vid.lock
 * (gc573_dma_stop()), which the V4L2 core holds around every ioctl, so
 * none of them reaches the card after that.
 */
static int gc573_g_edid(struct file *file, void *priv, struct v4l2_edid *e)
{
	struct gc573 *gc = video_drvdata(file);

	memset(e->reserved, 0, sizeof(e->reserved));
	if (READ_ONCE(gc->vid.dead))
		return -ENODEV;
	if (e->pad)
		return -EINVAL;
	return gc573_hdmi_get_edid(gc, e);
}

static int gc573_s_edid(struct file *file, void *priv, struct v4l2_edid *e)
{
	struct gc573 *gc = video_drvdata(file);

	memset(e->reserved, 0, sizeof(e->reserved));
	if (READ_ONCE(gc->vid.dead))
		return -ENODEV;
	if (e->pad)
		return -EINVAL;
	return gc573_hdmi_set_edid(gc, e);
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

	if (READ_ONCE(v->dead))
		return -ENODEV;
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
	v4l2_info(&gc->v4l2_dev, "stream: %s%s, frames %u, skipped %u; input changes: %u restarts, %u holds, %u stops\n",
		  vb2_is_streaming(&v->queue) ? "on" : "off",
		  v->held ? " (held)" : v->live ? " (live)" : "",
		  v->st.frames, v->st.skipped, v->input_restarts,
		  v->input_holds, v->input_stops);
	v4l2_info(&gc->v4l2_dev, "input: power %d signal %d locked %d period %#x\n",
		  v->in.power, v->in.signal, v->in.locked, v->in.period);
	if (v->in.locked)
		v4l2_print_dv_timings(gc->v4l2_dev.name, "input timings: ",
				      &v->in.timings, true);
	v4l2_ctrl_handler_log_status(&v->ctrls, gc->v4l2_dev.name);
	return 0;
}

/*
 * The device takes the input's timings while the queue is free (policy:
 * header comment). vid.lock held.
 */
static void gc573_vid_adopt_input(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;

	v->adopt_pending = false;
	if (v->in.locked &&
	    v4l2_valid_dv_timings(&v->in.timings, &gc573_timings_cap,
				  gc573_timings_fit, NULL)) {
		v->timings = v->in.timings;
		v->fmt = gc573_find_fmt(v->fmt->fourcc, v->in.timings.bt.width);
	}
	gc573_fill_pix(gc, v->fmt, &v->pix);
}

/* REQBUFS and the last close can free the queue. vid.lock held. */
static void gc573_vid_queue_freed(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;

	if (v->adopt_pending && !v->dead && !vb2_is_busy(&v->queue))
		gc573_vid_adopt_input(gc);
}

static int gc573_reqbufs(struct file *file, void *priv,
			 struct v4l2_requestbuffers *p)
{
	struct gc573 *gc = video_drvdata(file);
	int ret = vb2_ioctl_reqbufs(file, priv, p);

	gc573_vid_queue_freed(gc);
	return ret;
}

/* the video device, and with it struct gc573, outlives this call */
static int gc573_vid_release_file(struct file *file)
{
	struct gc573 *gc = video_drvdata(file);
	int ret = vb2_fop_release(file);

	mutex_lock(&gc->vid.lock);
	gc573_vid_queue_freed(gc);
	mutex_unlock(&gc->vid.lock);
	return ret;
}

static int gc573_subscribe_event(struct v4l2_fh *fh,
				 const struct v4l2_event_subscription *sub)
{
	switch (sub->type) {
	case V4L2_EVENT_SOURCE_CHANGE:
		/*
		 * The id is the input index, and there is one input. Every
		 * other id would be one more subscription of its own (memory
		 * no one accounts for, walked at each event with interrupts
		 * off), never raised.
		 */
		if (sub->id)
			return -EINVAL;
		return v4l2_src_change_event_subscribe(fh, sub);
	case V4L2_EVENT_CTRL:
		return v4l2_ctrl_subscribe_event(fh, sub);
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
	.vidioc_g_edid			= gc573_g_edid,
	.vidioc_s_edid			= gc573_s_edid,
	.vidioc_reqbufs			= gc573_reqbufs,
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
	.release	= gc573_vid_release_file,
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

	seq_printf(m, "core: INT_STATUS %#010x INT_ENABLE %#010x RESET %#010x TLP_ALIGN %#010x INT seen %#010x dma_dead %d\n",
		   gc573_rd(gc, GC573_INT_STATUS),
		   gc573_rd(gc, GC573_INT_ENABLE), gc573_rd(gc, GC573_RESET),
		   gc573_rd(gc, GC573_TLP_ALIGN),
		   (u32)atomic_read(&gc->irq_seen), READ_ONCE(gc->dma_dead));
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
	seq_printf(m, "mem (live, all cards): bufs %d pages %ld vmaps %d dlists %d dl_bytes %ld\n",
		   atomic_read(&gc573_mem_live.bufs),
		   atomic_long_read(&gc573_mem_live.pages),
		   atomic_read(&gc573_mem_live.vmaps),
		   atomic_read(&gc573_mem_live.dlists),
		   atomic_long_read(&gc573_mem_live.dl_bytes));
	seq_printf(m, "mem kept (since load, all cards; until reboot): bytes %ld; this card: exposed %ld\n",
		   atomic_long_read(&gc573_mem_live.kept),
		   atomic_long_read(&v->exposed_bytes));

	/* seq_printf() does not sleep: print the shared state under slock */
	spin_lock(&v->slock);
	seq_printf(m, "stream: running %d live %d input_restarts %u input_stops %u input_holds %u held %d start_pending %d fmt %p4cc %ux%u sizeimage %u exp_slot_mode %d next_arm %u ch_ctrl written: ch1 %#x ch2 %#x\n",
		   v->running, v->live, v->input_restarts, v->input_stops,
		   v->input_holds, v->held, v->start_pending, &v->pix.pixelformat,
		   v->pix.width, v->pix.height, v->pix.sizeimage, v->exp_mode,
		   v->next_arm, v->ch_ctrl[1], v->ch_ctrl[2]);
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

/*
 * Experiment, open question 13: write a mask of 0x001, 0x100 and 0x200 to
 * reset those domains (spec/init.md step 2 per domain) while video is
 * idle; audio may run. DMA_RUN before and after goes to the kernel log;
 * then a running audio stream is started again if the reset stopped it,
 * as after a video stop.
 */
static ssize_t gc573_exp_reset_write(struct file *file, const char __user *ubuf,
				     size_t len, loff_t *ppos)
{
	struct gc573 *gc = file->private_data;
	struct gc573_video *v = &gc->vid;
	u32 mask, run0, run1, rst;
	int ret;

	ret = kstrtou32_from_user(ubuf, len, 0, &mask);
	if (ret)
		return ret;
	if (!mask || (mask & ~GC573_RESET_DOMAINS))
		return -EINVAL;
	mutex_lock(&v->lock);
	if (v->dead || vb2_is_streaming(&v->queue)) {
		ret = -EBUSY;
		goto out;
	}
	run0 = gc573_rd(gc, GC573_DMA_RUN);
	ret = gc573_reset_domain_mask(gc, mask);
	run1 = gc573_rd(gc, GC573_DMA_RUN);
	rst = gc573_rd(gc, GC573_RESET);
	dev_info(&gc->pdev->dev,
		 "exp_reset %#x: %d, RESET=%#010x, DMA_RUN %#010x -> %#010x\n",
		 mask, ret, rst, run0, run1);
	gc573_audio_reset_done(gc);
out:
	mutex_unlock(&v->lock);
	return ret ? ret : len;
}

static const struct file_operations gc573_exp_reset_fops = {
	.owner = THIS_MODULE,
	.open = simple_open,
	.write = gc573_exp_reset_write,
	.llseek = noop_llseek,
};

void gc573_video_debugfs(struct gc573 *gc)
{
	debugfs_create_file("video", 0444, gc->debugfs, gc,
			    &gc573_vid_debugfs_fops);
	debugfs_create_file("exp_reset", 0200, gc->debugfs, gc,
			    &gc573_exp_reset_fops);
}

/* ---- input changes ---- */

/* Same signal as far as capture is concerned? */
static bool gc573_input_same(const struct gc573_input *a,
			     const struct gc573_input *b)
{
	if (a->locked != b->locked)
		return false;
	return !a->locked ||
	       (v4l2_match_dv_timings(&a->timings, &b->timings, 0, true) &&
		a->colour == b->colour && a->full_range == b->full_range &&
		a->enc == b->enc && a->dvi == b->dvi && a->dual == b->dual &&
		a->ddr == b->ddr);
}

/*
 * After a stop: the buffers in the slots go back to the head of the
 * queue, in arming order. slock held.
 */
static void gc573_vid_unarm(struct gc573_video *v)
{
	struct gc573_vbuf *b[GC573_VCH_SLOTS];
	unsigned int n, i, k = 0;

	for (n = 0; n < GC573_VCH_SLOTS; n++) {
		struct gc573_vbuf *s = v->slot[n];

		if (!s)
			continue;
		for (i = k; i && b[i - 1]->armed > s->armed; i--)
			b[i] = b[i - 1];
		b[i] = s;
		k++;
		v->slot[n] = NULL;
	}
	while (k--)
		list_add(&b[k]->list, &v->queued);
}

/*
 * The stream stops for good: its buffers return with an error and the
 * queue is marked failed. vid.lock held.
 */
static void gc573_vid_fail(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;

	if (v->running)
		gc573_video_hw_stop(gc);
	v->start_pending = false;
	v->held = false;
	gc573_vid_return_all(gc, VB2_BUF_STATE_ERROR);
	vb2_queue_error(&v->queue);
	v->failed = true;
	v->input_stops++;
}

/* The end of a hold: the input still in other timings fails the stream */
static void gc573_vid_hold_expired(struct work_struct *work)
{
	struct gc573_video *v = container_of(to_delayed_work(work),
					     struct gc573_video, hold_work);
	struct gc573 *gc = container_of(v, struct gc573, vid);

	mutex_lock(&v->lock);
	/* a newer hold has its own deadline, and work queued for it */
	if (v->held && !v->dead && !time_before(jiffies, v->hold_until)) {
		gc573_vid_fail(gc);
		dev_dbg(&gc->pdev->dev,
			"video: input in other timings for %u ms, stream stopped\n",
			GC573_VID_HOLD_MS);
	}
	mutex_unlock(&v->lock);
}

/*
 * A streaming queue follows a change of the input (policy: header
 * comment). vid.lock held; v->in is the new input.
 */
static void gc573_vid_follow_input(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	struct device *dev = &gc->pdev->dev;

	if (v->failed)
		return;
	if (v->in.locked && !gc573_vid_input_matches(v)) {
		/* held already: the hold counts from its start */
		if (v->held)
			return;
		if (gc573_video_hw_stop(gc)) {
			gc573_vid_fail(gc);
			return;
		}
		spin_lock(&v->slock);
		gc573_vid_unarm(v);
		spin_unlock(&v->slock);
		v->start_pending = false;
		v->held = true;
		v->hold_until = jiffies + msecs_to_jiffies(GC573_VID_HOLD_MS);
		mod_delayed_work(system_wq, &v->hold_work,
				 msecs_to_jiffies(GC573_VID_HOLD_MS));
		v->input_holds++;
		dev_dbg(dev, "video: input in other timings, stream held\n");
		return;
	}
	v->held = false;
	/* free-running already, and still no input */
	if (!v->in.locked && !v->live && (v->running || v->start_pending))
		return;
	if (gc573_video_hw_stop(gc)) {
		gc573_vid_fail(gc);
		return;
	}
	spin_lock(&v->slock);
	gc573_vid_unarm(v);
	v->start_pending = list_empty(&v->queued);
	spin_unlock(&v->slock);
	/* same timings, so the same buffer layout; new colorimetry */
	gc573_fill_pix(gc, v->fmt, &v->pix);
	v->input_restarts++;
	if (!v->start_pending)
		gc573_vid_hw_start(gc, true);
	dev_dbg(dev, "video: input changed, stream restarted %s%s\n",
		v->in.locked ? "live" : "free-running",
		v->start_pending ? " at the next QBUF" : "");
}

/*
 * From the HDMI poll worker on lock, loss, mode or power change (policy:
 * header comment). Never called with the HDMI lock held.
 */
void gc573_video_input_changed(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	const struct v4l2_event ev = {
		.type = V4L2_EVENT_SOURCE_CHANGE,
		.u.src_change.changes = V4L2_EVENT_SRC_CH_RESOLUTION,
	};
	struct gc573_input in;
	bool same;

	mutex_lock(&v->lock);
	if (v->dead)
		goto unlock;
	gc573_hdmi_input(gc, &in);
	same = gc573_input_same(&in, &v->in);
	gc573_vid_note_input(v, &in);
	v4l2_ctrl_s_ctrl(v->power_ctrl, in.power);
	if (same)
		goto unlock;
	v4l2_event_queue(&v->vdev, &ev);
	if (vb2_is_streaming(&v->queue))
		gc573_vid_follow_input(gc);
	if (!vb2_is_busy(&v->queue))
		gc573_vid_adopt_input(gc);
	else
		v->adopt_pending = true;
unlock:
	mutex_unlock(&v->lock);
}

/* ---- setup ---- */

/* Devres, with bus mastering off; kept after gc573_dma_dead() */
static void gc573_video_free_dummy(void *data)
{
	struct gc573 *gc = data;
	struct gc573_video *v = &gc->vid;

	if (READ_ONCE(gc->dma_dead))
		atomic_long_add(PAGE_SIZE, &gc573_mem_live.kept);
	else
		dma_free_coherent(&gc->pdev->dev, PAGE_SIZE, v->dummy,
				  v->dummy_dma);
}

/*
 * The dummy list, before bus mastering and the quiesce's devres actions
 * are added (gc573_probe()): devres frees it after both ran, unless a
 * stop was not confirmed. Its one descriptor describes the page's second
 * half.
 */
int gc573_video_alloc(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	int ret;

	v->dummy = dma_alloc_coherent(&gc->pdev->dev, PAGE_SIZE, &v->dummy_dma,
				      GFP_KERNEL);
	if (!v->dummy)
		return -ENOMEM;
	ret = devm_add_action_or_reset(&gc->pdev->dev, gc573_video_free_dummy,
				       gc);
	if (ret)
		return ret;
	v->dummy[0] = cpu_to_le32(lower_32_bits(v->dummy_dma + GC573_DUMMY_OFF));
	v->dummy[1] = cpu_to_le32(upper_32_bits(v->dummy_dma + GC573_DUMMY_OFF));
	v->dummy[2] = cpu_to_le32(GC573_DUMMY_LEN / 4);	/* in dwords */
	v->dummy[3] = cpu_to_le32(GC573_DESC_CTRL);
	return 0;
}

/* Software state the quiesce and the IRQ thread may use: before probe */
void gc573_video_early_init(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;

	mutex_init(&v->lock);
	spin_lock_init(&v->slock);
	INIT_LIST_HEAD(&v->queued);
	init_completion(&v->term);
	INIT_DELAYED_WORK(&v->hold_work, gc573_vid_hold_expired);
	v->timings = gc573_timings_def;
	v->fmt = &gc573_fmts[0];
	gc573_fill_pix(gc, v->fmt, &v->pix);
}

/*
 * The buffers go here: every engine stopped first (gc573_dma_stop()).
 * Then vid.lock once, so that an ioctl that got past the core's
 * registered check before the unregister has ended before anything it
 * may touch goes, whatever locking vb2_video_unregister_device() does on
 * a given kernel.
 */
static void gc573_video_unregister(void *data)
{
	struct gc573 *gc = data;

	gc573_dma_stop(gc);
	vb2_video_unregister_device(&gc->vid.vdev);
	mutex_lock(&gc->vid.lock);
	mutex_unlock(&gc->vid.lock);
}

/* From the v4l2_device release: no file handle is left */
void gc573_video_release(struct gc573 *gc)
{
	v4l2_ctrl_handler_free(&gc->vid.ctrls);
}

int gc573_video_init(struct gc573 *gc)
{
	struct gc573_video *v = &gc->vid;
	struct video_device *vdev = &v->vdev;
	struct vb2_queue *q = &v->queue;
	struct gc573_input in;
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

	/* freed with struct gc573 (gc573_video_release()) */
	v4l2_ctrl_handler_init(&v->ctrls, 1);
	v->power_ctrl = v4l2_ctrl_new_std(&v->ctrls, NULL,
					  V4L2_CID_DV_RX_POWER_PRESENT, 0, 1,
					  0, 0);
	if (v->ctrls.error)
		return v->ctrls.error;
	gc573_hdmi_input(gc, &in);
	gc573_vid_note_input(v, &in);
	v4l2_ctrl_s_ctrl(v->power_ctrl, v->in.power);

	strscpy(vdev->name, "GC573 HDMI capture", sizeof(vdev->name));
	vdev->fops = &gc573_fops;
	vdev->ioctl_ops = &gc573_ioctl_ops;
	vdev->release = video_device_release_empty;
	vdev->v4l2_dev = &gc->v4l2_dev;
	vdev->queue = q;
	vdev->lock = &v->lock;
	vdev->ctrl_handler = &v->ctrls;
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

/* tests/cases/16-probe-fail-hpd.sh fails it (bpftrace override) */
ALLOW_ERROR_INJECTION(gc573_video_init, ERRNO);
