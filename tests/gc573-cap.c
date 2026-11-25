// SPDX-License-Identifier: GPL-2.0
/*
 * gc573-cap: V4L2 capture test tool for the GC573 driver (tests/cases).
 *
 * gc573-cap -d /dev/videoN [-f FMT[,FMT..]|all] [-b BUFS] [-n FRAMES]
 *           [-p] [-T IDX|all|@FILE] [-t FILE] [-L SECS] [-o FILE]
 *           [-c CYCLES] [-u] [-w MS] [-X SECS [-r]] [-D DEBUGFS_FILE]
 *
 *   default  capture -n frames per format (requeue each buffer at once);
 *            formats ENUM_FMT does not offer at the timings are skipped
 *   -T IDX   first S_DV_TIMINGS to ENUM_DV_TIMINGS entry IDX; "all": run
 *            the format list once per enumerated timing (capture mode);
 *            "@FILE": the same over the timings -t saved in FILE
 *   -t FILE  save every enumerated timing to FILE (struct v4l2_dv_timings
 *            records) and exit. ENUM_DV_TIMINGS follows the EDID, so a
 *            sweep with the EDID cleared (no input) needs a list saved
 *            before
 *   -L SECS  first wait up to SECS for QUERY_DV_TIMINGS to succeed, then
 *            S_DV_TIMINGS to the detected timings (live input)
 *   -o FILE  capture mode: write the last frame (sizeimage bytes) to
 *            FILE.FMT (FMT: the format name)
 *   -p       pattern check: before every QBUF the whole buffer is filled
 *            with a pattern unique to that queueing; after DQBUF every
 *            32-byte block (the DMA length unit) of every plane must differ
 *            from it, i.e. have been written by DMA
 *   -c N     stop/start stress: N cycles of S_FMT (formats in turn),
 *            REQBUFS, STREAMON, -n frames, STREAMOFF, REQBUFS 0
 *   -u       underrun experiment: dequeue all buffers without requeueing,
 *            wait, then requeue 1 and later 2 buffers, then stream again
 *   -w MS    stream MS ms without dequeueing, STREAMOFF, then check every
 *            buffer's planes (for runs where no frame completes)
 *   -R N     returned-buffer test, N QBUFs: after each DQBUF the whole
 *            buffer is filled with a fresh pattern, held 0-20 ms (random),
 *            then checked; any change means DMA wrote into a buffer that
 *            userspace owned. QBUFs thus come at random times
 *   -X SECS  input-change test: stream with one buffer held back (pattern
 *            filled), every buffer's tail beyond sizeimage pattern-filled,
 *            until DQBUF fails or SECS pass, with V4L2_EVENT_SOURCE_CHANGE
 *            subscribed; then check the held buffer and every tail (no DMA
 *            outside the queued buffers' images) and report the event
 *   -r       with -X: afterwards wait for a lock (-L, default 15 s), set
 *            the new timings and capture -n frames (restart)
 *   -F       capture mode: print one line per frame (sequence, timestamp,
 *            signature over every word), for frame-repeat analysis
 *   -M FILE  with -F: after each DQBUF, before hashing, read the ch0 DMA
 *            block (0x300-0x3fc, CH_STATUS first) and the VIP block
 *            (0x1000-0x10fc) from BAR0 through FILE (the device's sysfs
 *            resource0, mapped read-only) and print them (REGS line;
 *            spec/open-questions.md #33)
 *   -D FILE  the driver's debugfs "video" file, printed at key points
 *
 * Output: "RESULT ..." lines with key=value pairs; "FAIL ..." lines for
 * failed checks. Exit status: 0 = all checks passed, 1 = a check failed,
 * 2 = usage or system error.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define MAX_BUFS	32
#define MAX_FRAMES	100000
#define DQ_TIMEOUT_MS	2000
#define CAP		V4L2_BUF_TYPE_VIDEO_CAPTURE

struct fmtname {
	const char *name;
	uint32_t fourcc;
};

static const struct fmtname fmts[] = {
	{ "YUYV", V4L2_PIX_FMT_YUYV },
	{ "UYVY", V4L2_PIX_FMT_UYVY },
	{ "NV12", V4L2_PIX_FMT_NV12 },
	{ "YV12", V4L2_PIX_FMT_YVU420 },
	{ "BGR3", V4L2_PIX_FMT_BGR24 },
	{ "XR24", V4L2_PIX_FMT_XBGR32 },
};

#define NFMTS	(sizeof(fmts) / sizeof(fmts[0]))

struct buf {
	uint32_t *p;
	size_t len;
	uint32_t seed;		/* pattern of the last queueing, 0 = none */
};

static int fd = -1;
static struct buf bufs[MAX_BUFS];
static unsigned int nbufs;
static struct v4l2_pix_format pix;
static const char *dbgfile;
static int failed;
static uint32_t seed_ctr;

static void die(const char *what)
{
	fprintf(stderr, "gc573-cap: %s: %s\n", what, strerror(errno));
	exit(2);
}

static int xioctl(unsigned long req, void *arg)
{
	int r;

	do {
		r = ioctl(fd, req, arg);
	} while (r < 0 && errno == EINTR);
	return r;
}

static double now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static void dump_debugfs(const char *when)
{
	char line[512];
	FILE *f;

	if (!dbgfile)
		return;
	f = fopen(dbgfile, "r");
	if (!f) {
		printf("debugfs (%s): %s: %s\n", when, dbgfile, strerror(errno));
		return;
	}
	printf("debugfs (%s):\n", when);
	while (fgets(line, sizeof(line), f))
		printf("  | %s", line);
	fclose(f);
}

/* ---- pattern ---- */

static inline uint32_t pat(uint32_t seed, size_t i)
{
	uint32_t x = ((uint32_t)i ^ seed) * 0x9e3779b1u;

	return x ^ (x >> 15);
}

static void fill(struct buf *b)
{
	size_t i, n = pix.sizeimage / 4;

	seed_ctr++;
	b->seed = seed_ctr * 0x6b43a9b5u | 1;
	for (i = 0; i < n; i++)
		b->p[i] = pat(b->seed, i);
}

/* 32-byte blocks of [off, off + len) still holding the pattern */
static size_t untouched(const struct buf *b, size_t off, size_t len)
{
	size_t blk, k, w, nb = len / 32, n = 0;

	for (blk = 0; blk < nb; blk++) {
		w = off / 4 + blk * 8;
		for (k = 0; k < 8; k++)
			if (b->p[w + k] != pat(b->seed, w + k))
				break;
		n += k == 8;
	}
	return n;
}

static unsigned int planes(size_t off[3], size_t len[3])
{
	size_t y = (size_t)pix.width * pix.height;

	switch (pix.pixelformat) {
	case V4L2_PIX_FMT_NV12:
		off[0] = 0; len[0] = y;
		off[1] = y; len[1] = y / 2;
		return 2;
	case V4L2_PIX_FMT_YVU420:
		off[0] = 0; len[0] = y;
		off[1] = y; len[1] = y / 4;
		off[2] = y + y / 4; len[2] = y / 4;
		return 3;
	default:
		off[0] = 0; len[0] = pix.sizeimage;
		return 1;
	}
}

/* ---- what the hardware wrote: most common word, frame signature ---- */

struct pstat {
	size_t untouched_max;	/* worst frame */
	unsigned long frames_bad;
	uint32_t top_word;
	double top_share;	/* of the sampled words, last frame */
};

static uint64_t plane_sig(const struct buf *b, size_t off, size_t len,
			  uint32_t *top, double *share)
{
	uint32_t val[8] = { 0 }, cnt[8] = { 0 };
	size_t i, n = 0, w0 = off / 4, nw = len / 4;
	uint64_t h = 0xcbf29ce484222325ull;
	unsigned int k, best = 0;

	/* the signature covers every word; the census samples every 61st */
	for (i = 0; i < nw; i++)
		h = (h ^ b->p[w0 + i]) * 0x100000001b3ull;
	for (i = 0; i < nw; i += 61) {
		uint32_t x = b->p[w0 + i];

		n++;
		for (k = 0; k < 8 && cnt[k] && val[k] != x; k++)
			;
		if (k < 8) {
			val[k] = x;
			cnt[k]++;
		}
	}
	for (k = 1; k < 8; k++)
		if (cnt[k] > cnt[best])
			best = k;
	*top = val[best];
	*share = n ? 100.0 * cnt[best] / n : 0;
	return h;
}

/* ---- buffers ---- */

/* -T @FILE: the saved timings, in place of ENUM_DV_TIMINGS */
static struct v4l2_dv_timings *saved;
static unsigned int nsaved;

/* -t FILE: write every enumerated timing to FILE */
static int save_timings(const char *path)
{
	struct v4l2_enum_dv_timings et;
	FILE *f = fopen(path, "wb");

	if (!f)
		die(path);
	memset(&et, 0, sizeof(et));
	for (; !xioctl(VIDIOC_ENUM_DV_TIMINGS, &et); et.index++)
		if (fwrite(&et.timings, sizeof(et.timings), 1, f) != 1)
			die(path);
	if (errno != EINVAL)
		die("ENUM_DV_TIMINGS");
	if (fclose(f))
		die(path);
	printf("SAVED timings=%u file=%s\n", et.index, path);
	return 0;
}

static void load_timings(const char *path)
{
	struct v4l2_dv_timings t;
	FILE *f = fopen(path, "rb");

	if (!f)
		die(path);
	while (fread(&t, sizeof(t), 1, f) == 1) {
		saved = realloc(saved, (nsaved + 1) * sizeof(*saved));
		if (!saved)
			die("realloc");
		saved[nsaved++] = t;
	}
	fclose(f);
}

/*
 * S_DV_TIMINGS to entry idx (enumerated, or of the -T @FILE list); -1 if
 * there is no such entry
 */
static int set_timings(unsigned int idx)
{
	struct v4l2_enum_dv_timings et = { .index = idx };
	const struct v4l2_bt_timings *bt = &et.timings.bt;
	double frame;

	if (saved) {
		if (idx >= nsaved)
			return -1;
		et.timings = saved[idx];
	} else if (xioctl(VIDIOC_ENUM_DV_TIMINGS, &et)) {
		if (errno == EINVAL)
			return -1;
		die("ENUM_DV_TIMINGS");
	}
	if (xioctl(VIDIOC_S_DV_TIMINGS, &et.timings))
		die("S_DV_TIMINGS");
	frame = (double)V4L2_DV_BT_FRAME_WIDTH(bt) *
		V4L2_DV_BT_FRAME_HEIGHT(bt);
	printf("TIMINGS index=%u %ux%u%s %.2f\n", idx, bt->width, bt->height,
	       bt->interlaced ? "i" : "p", frame ? bt->pixelclock / frame : 0);
	return 0;
}

/* Is fourcc offered by ENUM_FMT at the current timings? */
static int fmt_offered(uint32_t fourcc)
{
	struct v4l2_fmtdesc d = { .type = CAP };

	for (d.index = 0; !xioctl(VIDIOC_ENUM_FMT, &d); d.index++)
		if (d.pixelformat == fourcc)
			return 1;
	return 0;
}

static void set_fmt(uint32_t fourcc)
{
	struct v4l2_format f = { .type = CAP };

	if (xioctl(VIDIOC_G_FMT, &f))
		die("G_FMT");
	f.fmt.pix.pixelformat = fourcc;
	if (xioctl(VIDIOC_S_FMT, &f))
		die("S_FMT");
	if (f.fmt.pix.pixelformat != fourcc) {
		fprintf(stderr, "gc573-cap: format %.4s not accepted\n",
			(char *)&fourcc);
		exit(2);
	}
	pix = f.fmt.pix;
}

/* QUERY_DV_TIMINGS until it succeeds (up to secs), then S_DV_TIMINGS */
static int wait_lock(double secs)
{
	struct v4l2_streamparm parm = { .type = CAP };
	struct v4l2_dv_timings t;
	const struct v4l2_bt_timings *bt = &t.bt;
	double t0 = now_ms();
	int e = 0;

	for (;;) {
		memset(&t, 0, sizeof(t));
		if (!xioctl(VIDIOC_QUERY_DV_TIMINGS, &t))
			break;
		e = errno;
		if (now_ms() - t0 > secs * 1e3) {
			printf("NOLOCK after %.1f s: %s\n", secs, strerror(e));
			return -1;
		}
		usleep(50000);
	}
	if (xioctl(VIDIOC_S_DV_TIMINGS, &t))
		die("S_DV_TIMINGS");
	if (xioctl(VIDIOC_G_PARM, &parm))
		die("G_PARM");
	printf("LOCK after_ms=%.0f %ux%u%s pixelclock=%llu flags=%#x vic=%u fps=%.4f tpf=%u/%u h=%u/%u/%u v=%u/%u/%u pol=%#x\n",
	       now_ms() - t0, bt->width, bt->height, bt->interlaced ? "i" : "p",
	       (unsigned long long)bt->pixelclock, bt->flags, bt->cea861_vic,
	       (double)parm.parm.capture.timeperframe.denominator /
	       parm.parm.capture.timeperframe.numerator,
	       parm.parm.capture.timeperframe.numerator,
	       parm.parm.capture.timeperframe.denominator, bt->hfrontporch,
	       bt->hsync, bt->hbackporch, bt->vfrontporch, bt->vsync,
	       bt->vbackporch, bt->polarities);
	return 0;
}

static void alloc_bufs(unsigned int n)
{
	struct v4l2_requestbuffers rb = {
		.count = n, .type = CAP, .memory = V4L2_MEMORY_MMAP,
	};
	unsigned int i;

	if (xioctl(VIDIOC_REQBUFS, &rb))
		die("REQBUFS");
	if (rb.count > MAX_BUFS) {
		fprintf(stderr, "gc573-cap: %u buffers\n", rb.count);
		exit(2);
	}
	nbufs = rb.count;
	for (i = 0; i < nbufs; i++) {
		struct v4l2_buffer b = {
			.index = i, .type = CAP, .memory = V4L2_MEMORY_MMAP,
		};

		if (xioctl(VIDIOC_QUERYBUF, &b))
			die("QUERYBUF");
		bufs[i].p = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
				 MAP_SHARED, fd, b.m.offset);
		if (bufs[i].p == MAP_FAILED)
			die("mmap");
		bufs[i].len = b.length;
		bufs[i].seed = 0;
	}
}

static void free_bufs(void)
{
	struct v4l2_requestbuffers rb = {
		.count = 0, .type = CAP, .memory = V4L2_MEMORY_MMAP,
	};
	unsigned int i;

	for (i = 0; i < nbufs; i++)
		munmap(bufs[i].p, bufs[i].len);
	nbufs = 0;
	if (xioctl(VIDIOC_REQBUFS, &rb))
		die("REQBUFS 0");
}

static void qbuf(unsigned int i, int pattern)
{
	struct v4l2_buffer b = {
		.index = i, .type = CAP, .memory = V4L2_MEMORY_MMAP,
	};

	if (pattern)
		fill(&bufs[i]);
	if (xioctl(VIDIOC_QBUF, &b))
		die("QBUF");
}

/* 0, or -ETIMEDOUT / -errno */
static int dqbuf(struct v4l2_buffer *b, int timeout_ms)
{
	struct pollfd pfd = { .fd = fd, .events = POLLIN };
	int r;

	r = poll(&pfd, 1, timeout_ms);
	if (r < 0)
		die("poll");
	if (!r)
		return -ETIMEDOUT;
	memset(b, 0, sizeof(*b));
	b->type = CAP;
	b->memory = V4L2_MEMORY_MMAP;
	if (xioctl(VIDIOC_DQBUF, b))
		return -errno;
	return 0;
}

static void stream(int on)
{
	int type = CAP;

	if (xioctl(on ? VIDIOC_STREAMON : VIDIOC_STREAMOFF, &type))
		die(on ? "STREAMON" : "STREAMOFF");
}

static double ts_ms(const struct v4l2_buffer *b)
{
	return b->timestamp.tv_sec * 1e3 + b->timestamp.tv_usec / 1e3;
}

/* ---- per-frame checks ---- */

struct run {
	unsigned long frames, gaps, bad_frames, errflag;
	double ivl_sum, ivl_min, ivl_max, prev_ts;
	uint32_t prev_seq;
	struct pstat ps[3];
	uint64_t *sigs;
	unsigned long nsigs;
};

static void run_init(struct run *r)
{
	memset(r, 0, sizeof(*r));
	r->ivl_min = 1e9;
	r->sigs = calloc(MAX_FRAMES, sizeof(*r->sigs));
	if (!r->sigs)
		die("calloc");
}

static int frame_log;
static volatile uint32_t *bar;	/* -M */

static void bar_open(const char *path)
{
	int fd = open(path, O_RDWR | O_SYNC);
	void *m;

	if (fd < 0)
		die(path);
	m = mmap(NULL, 0x2000, PROT_READ, MAP_SHARED, fd, 0);
	if (m == MAP_FAILED)
		die("mmap BAR0");
	bar = m;
}

/* REGS seq=N <0x300> ... <0x3fc> <0x1000> ... <0x10fc> */
static void bar_log(unsigned int seq)
{
	uint32_t v[128];
	unsigned int i;

	for (i = 0; i < 64; i++)
		v[i] = bar[0x300 / 4 + i];
	for (i = 0; i < 64; i++)
		v[64 + i] = bar[0x1000 / 4 + i];
	printf("REGS seq=%u", seq);
	for (i = 0; i < 128; i++)
		printf(" %08x", v[i]);
	printf("\n");
}

static void check_frame(struct run *r, const struct v4l2_buffer *b,
			int pattern)
{
	size_t off[3], len[3];
	unsigned int np = planes(off, len), c;
	uint64_t sig = 0;
	int bad = 0;

	if (bar && frame_log)
		bar_log(b->sequence);
	if (b->flags & V4L2_BUF_FLAG_ERROR)
		r->errflag++;
	if (r->frames) {
		double d = ts_ms(b) - r->prev_ts;

		if (b->sequence != r->prev_seq + 1)
			r->gaps++;
		r->ivl_sum += d;
		if (d < r->ivl_min)
			r->ivl_min = d;
		if (d > r->ivl_max)
			r->ivl_max = d;
	}
	r->prev_ts = ts_ms(b);
	r->prev_seq = b->sequence;

	for (c = 0; c < np; c++) {
		struct pstat *ps = &r->ps[c];

		if (pattern) {
			size_t u = untouched(&bufs[b->index], off[c], len[c]);

			if (u > ps->untouched_max)
				ps->untouched_max = u;
			if (u) {
				ps->frames_bad++;
				bad = 1;
			}
		}
		sig = sig * 31 + plane_sig(&bufs[b->index], off[c], len[c],
					   &ps->top_word, &ps->top_share);
	}
	r->bad_frames += bad;
	if (r->nsigs < MAX_FRAMES)
		r->sigs[r->nsigs++] = sig;
	r->frames++;
	if (frame_log)
		printf("FRAME seq=%u ts_ms=%.3f sig=%016llx\n", b->sequence,
		       ts_ms(b), (unsigned long long)sig);
}

static unsigned long distinct(uint64_t *v, unsigned long n)
{
	unsigned long i, j, d = 0;

	for (i = 0; i < n; i++) {
		for (j = 0; j < i && v[j] != v[i]; j++)
			;
		d += j == i;
		if (i > 2000)	/* enough to tell constant from changing */
			break;
	}
	return d;
}

static void print_run(const char *tag, struct run *r, int pattern)
{
	size_t off[3], len[3];
	unsigned int np = planes(off, len), c;

	printf("RESULT %s fmt=%.4s %ux%u frames=%lu seq_gaps=%lu err_flags=%lu",
	       tag, (char *)&pix.pixelformat, pix.width, pix.height,
	       r->frames, r->gaps, r->errflag);
	if (r->frames > 1)
		printf(" ivl_ms_mean=%.3f min=%.3f max=%.3f",
		       r->ivl_sum / (r->frames - 1), r->ivl_min, r->ivl_max);
	if (pattern)
		printf(" frames_not_overwritten=%lu", r->bad_frames);
	for (c = 0; c < np; c++) {
		printf(" ch%u_bytes=%zu", c, len[c]);
		if (pattern)
			printf(" ch%u_untouched_blocks_max=%zu", c,
			       r->ps[c].untouched_max);
		printf(" ch%u_top_word=%08x(%.1f%%)", c, r->ps[c].top_word,
		       r->ps[c].top_share);
	}
	printf(" distinct_frames=%lu\n", distinct(r->sigs, r->nsigs));
	free(r->sigs);
}

/* ---- modes ---- */

static const char *outfile;

static void save_frame(const struct buf *b)
{
	char name[512];
	FILE *f;

	snprintf(name, sizeof(name), "%s.%.4s", outfile,
		 (char *)&pix.pixelformat);
	f = fopen(name, "wb");
	if (!f || fwrite(b->p, 1, pix.sizeimage, f) != pix.sizeimage)
		die(name);
	fclose(f);
	printf("INFO saved %s (%u bytes)\n", name, pix.sizeimage);
}

static int capture(uint32_t fourcc, unsigned int nb, unsigned long n,
		   int pattern)
{
	struct v4l2_buffer b;
	struct run r;
	unsigned int i, last = 0;
	double t0, first = 0;
	int ret = 0, e;

	if (!fmt_offered(fourcc)) {
		struct v4l2_format f = { .type = CAP };

		if (xioctl(VIDIOC_G_FMT, &f))
			die("G_FMT");
		printf("SKIP capture fmt=%.4s: not offered at %ux%u\n",
		       (char *)&fourcc, f.fmt.pix.width, f.fmt.pix.height);
		return 0;
	}
	set_fmt(fourcc);
	alloc_bufs(nb);
	run_init(&r);
	for (i = 0; i < nbufs; i++)
		qbuf(i, pattern);
	t0 = now_ms();
	stream(1);
	while (r.frames < n) {
		e = dqbuf(&b, DQ_TIMEOUT_MS);
		if (e) {
			printf("FAIL capture fmt=%.4s: no frame after %lu: %s\n",
			       (char *)&fourcc, r.frames, strerror(-e));
			ret = 1;
			break;
		}
		if (!r.frames)
			first = now_ms() - t0;
		check_frame(&r, &b, pattern);
		last = b.index;
		if (outfile && r.frames == n)
			break;
		qbuf(b.index, pattern);
	}
	dump_debugfs("streaming");
	if (outfile && r.frames == n)
		save_frame(&bufs[last]);
	stream(0);
	printf("INFO start_to_first_frame_ms=%.1f\n", first);
	if (pattern && r.bad_frames) {
		printf("FAIL pattern fmt=%.4s: %lu of %lu frames not fully overwritten\n",
		       (char *)&fourcc, r.bad_frames, r.frames);
		ret = 1;
	}
	if (r.gaps || r.errflag) {
		printf("FAIL sequence fmt=%.4s: gaps=%lu error_flags=%lu\n",
		       (char *)&fourcc, r.gaps, r.errflag);
		ret = 1;
	}
	print_run("capture", &r, pattern);
	free_bufs();
	return ret;
}

static int cycles(const uint32_t *list, unsigned int nl, unsigned int nc,
		  unsigned int nb, unsigned long n)
{
	double on_max = 0, on_sum = 0, off_max = 0, off_sum = 0, t;
	unsigned long frames = 0;
	struct v4l2_buffer b;
	unsigned int c, i;
	unsigned long k;
	int e;

	for (c = 0; c < nc; c++) {
		set_fmt(list[c % nl]);
		alloc_bufs(nb);
		for (i = 0; i < nbufs; i++)
			qbuf(i, 0);
		t = now_ms();
		stream(1);
		for (k = 0; k < n; k++) {
			e = dqbuf(&b, DQ_TIMEOUT_MS);
			if (e) {
				printf("FAIL cycle %u fmt=%.4s: no frame %lu: %s\n",
				       c, (char *)&pix.pixelformat, k,
				       strerror(-e));
				dump_debugfs("cycle failure");
				stream(0);
				free_bufs();
				return 1;
			}
			if (!k) {
				t = now_ms() - t;
				on_sum += t;
				if (t > on_max)
					on_max = t;
			}
			frames++;
			qbuf(b.index, 0);
		}
		t = now_ms();
		stream(0);
		t = now_ms() - t;
		off_sum += t;
		if (t > off_max)
			off_max = t;
		free_bufs();
	}
	printf("RESULT cycles=%u frames=%lu start_to_first_frame_ms_mean=%.1f max=%.1f streamoff_ms_mean=%.1f max=%.1f\n",
	       nc, frames, on_sum / nc, on_max, off_sum / nc, off_max);
	return 0;
}

static int underrun(uint32_t fourcc, unsigned int nb)
{
	struct v4l2_buffer b;
	unsigned int i, idx[MAX_BUFS];
	double t, last = 0;
	struct run r;
	int e, ret = 0;
	size_t off[3], len[3];
	unsigned int np, c;

	set_fmt(fourcc);
	alloc_bufs(nb);
	np = planes(off, len);
	for (i = 0; i < nbufs; i++)
		qbuf(i, 1);
	stream(1);
	for (i = 0; i < nbufs; i++) {
		e = dqbuf(&b, DQ_TIMEOUT_MS);
		if (e) {
			printf("FAIL underrun: initial frame %u: %s\n", i,
			       strerror(-e));
			stream(0);
			free_bufs();
			return 1;
		}
		idx[i] = b.index;
		last = ts_ms(&b);
		printf("INFO underrun: frame seq=%u buf=%u t=%.3f\n",
		       b.sequence, b.index, last);
	}
	/* every buffer is with the application now */
	usleep(500 * 1000);
	dump_debugfs("all buffers dequeued, 500 ms later");

	/* one buffer back */
	qbuf(idx[0], 1);
	t = now_ms();
	e = dqbuf(&b, DQ_TIMEOUT_MS);
	if (e) {
		printf("RESULT underrun_requeue1 completed=0 (%s)\n",
		       strerror(-e));
		ret = 1;
	} else {
		size_t u = 0;

		for (c = 0; c < np; c++)
			u += untouched(&bufs[b.index], off[c], len[c]);
		printf("RESULT underrun_requeue1 completed=1 latency_ms=%.1f seq=%u untouched_blocks=%zu gap_since_last_frame_ms=%.1f\n",
		       now_ms() - t, b.sequence, u, ts_ms(&b) - last);
		last = ts_ms(&b);
	}
	dump_debugfs("after requeue of 1");

	/* two more */
	qbuf(idx[1], 1);
	qbuf(idx[2 % nbufs], 1);
	for (i = 0; i < 2; i++) {
		t = now_ms();
		e = dqbuf(&b, DQ_TIMEOUT_MS);
		if (e) {
			printf("RESULT underrun_requeue2 frame=%u completed=0 (%s)\n",
			       i, strerror(-e));
			ret = 1;
			break;
		}
		printf("RESULT underrun_requeue2 frame=%u buf=%u seq=%u latency_ms=%.1f ivl_ms=%.3f\n",
		       i, b.index, b.sequence, now_ms() - t,
		       ts_ms(&b) - last);
		last = ts_ms(&b);
	}

	/* everything back: does the stream run normally again? */
	for (i = 0; i < nbufs; i++) {
		struct v4l2_buffer q = {
			.index = i, .type = CAP, .memory = V4L2_MEMORY_MMAP,
		};

		if (xioctl(VIDIOC_QUERYBUF, &q))
			die("QUERYBUF");
		if (!(q.flags & V4L2_BUF_FLAG_QUEUED))
			qbuf(i, 1);
	}
	run_init(&r);
	while (r.frames < 120) {
		e = dqbuf(&b, DQ_TIMEOUT_MS);
		if (e) {
			printf("FAIL underrun: after recovery, frame %lu: %s\n",
			       r.frames, strerror(-e));
			ret = 1;
			break;
		}
		check_frame(&r, &b, 1);
		qbuf(b.index, 1);
	}
	dump_debugfs("recovered");
	stream(0);
	print_run("underrun_recovery", &r, 1);
	free_bufs();
	return ret;
}

static int waitcheck(uint32_t fourcc, unsigned int nb, unsigned int ms)
{
	size_t off[3], len[3];
	unsigned int np, i, c;

	set_fmt(fourcc);
	alloc_bufs(nb);
	np = planes(off, len);
	for (i = 0; i < nbufs; i++)
		qbuf(i, 1);
	stream(1);
	usleep(ms * 1000);
	dump_debugfs("before STREAMOFF");
	stream(0);
	printf("RESULT wait fmt=%.4s ms=%u", (char *)&fourcc, ms);
	for (i = 0; i < nbufs; i++)
		for (c = 0; c < np; c++)
			printf(" b%u_ch%u_untouched=%zu/%zu", i, c,
			       untouched(&bufs[i], off[c], len[c]),
			       len[c] / 32);
	printf("\n");
	free_bufs();
	return 0;
}

static int rbtest(uint32_t fourcc, unsigned int nb, unsigned long n)
{
	unsigned long q = 0, bad = 0, blocks = 0, hold_us = 0;
	unsigned int seed = (unsigned int)time(NULL), i;
	struct v4l2_buffer b;
	size_t nblk, k;
	double t0;
	int ret = 0, e;

	set_fmt(fourcc);
	alloc_bufs(nb);
	nblk = pix.sizeimage / 32;
	for (i = 0; i < nbufs; i++)
		qbuf(i, 0);
	printf("INFO rbtest fmt=%.4s %ux%u buffers=%u qbufs=%lu seed=%u\n",
	       (char *)&fourcc, pix.width, pix.height, nbufs, n, seed);
	t0 = now_ms();
	stream(1);
	while (q < n) {
		unsigned int us = rand_r(&seed) % 20001;

		e = dqbuf(&b, DQ_TIMEOUT_MS);
		if (e) {
			printf("FAIL rbtest: no frame after %lu QBUFs: %s\n", q,
			       strerror(-e));
			ret = 1;
			break;
		}
		fill(&bufs[b.index]);
		usleep(us);
		hold_us += us;
		k = untouched(&bufs[b.index], 0, pix.sizeimage);
		if (k != nblk) {
			if (bad < 10)
				printf("FAIL rbtest: buffer %u (sequence %u) changed while dequeued: %zu of %zu blocks, held %u us\n",
				       b.index, b.sequence, nblk - k, nblk, us);
			bad++;
			blocks += nblk - k;
		}
		qbuf(b.index, 0);
		if (!(++q % 20000))
			printf("INFO rbtest progress qbufs=%lu changed=%lu t=%.0fs\n",
			       q, bad, (now_ms() - t0) / 1e3);
	}
	dump_debugfs("end of rbtest");
	stream(0);
	printf("RESULT rbtest fmt=%.4s buffers=%u qbufs=%lu buffers_changed=%lu blocks_changed=%lu mean_hold_ms=%.2f seconds=%.0f\n",
	       (char *)&fourcc, nbufs, q, bad, blocks,
	       q ? hold_us / 1e3 / q : 0, (now_ms() - t0) / 1e3);
	free_bufs();
	return ret || bad;
}

/* ---- input change ---- */

/* Fill the buffer's tail, sizeimage to the mapped length, with its pattern */
static void fill_tail(struct buf *b)
{
	size_t i;

	for (i = pix.sizeimage / 4; i < b->len / 4; i++)
		b->p[i] = pat(b->seed, i);
}

/* Tail words that no longer hold the pattern */
static size_t tail_changed(const struct buf *b)
{
	size_t i, n = 0;

	for (i = pix.sizeimage / 4; i < b->len / 4; i++)
		n += b->p[i] != pat(b->seed, i);
	return n;
}

static int changetest(uint32_t fourcc, unsigned int nb, double secs,
		      int restart, double lock_secs, unsigned long n)
{
	struct v4l2_event_subscription sub = {
		.type = V4L2_EVENT_SOURCE_CHANGE,
	};
	unsigned long frames = 0, tails = 0, held_bad, held_tail;
	double t0, t_event = -1, t_err = -1, t_last = -1;
	struct v4l2_event ev;
	struct v4l2_buffer b;
	unsigned int i, held;
	int ret = 0, errored = 0;

	if (nb < 3) {
		fprintf(stderr, "gc573-cap: -X needs -b 3 or more\n");
		exit(2);
	}
	if (xioctl(VIDIOC_SUBSCRIBE_EVENT, &sub))
		die("SUBSCRIBE_EVENT");
	set_fmt(fourcc);
	alloc_bufs(nb);
	for (i = 0; i < nbufs; i++) {
		fill(&bufs[i]);
		fill_tail(&bufs[i]);
	}
	held = nbufs - 1;
	for (i = 0; i < held; i++)
		qbuf(i, 0);
	t0 = now_ms();
	stream(1);
	printf("INFO change: streaming %.4s %ux%u, buffer %u held back, tails %zu bytes\n",
	       (char *)&fourcc, pix.width, pix.height, held,
	       bufs[0].len - pix.sizeimage);
	while (now_ms() - t0 < secs * 1e3 && !(errored && t_event >= 0)) {
		struct pollfd pfd = {
			.fd = fd, .events = errored ? POLLPRI : POLLIN | POLLPRI,
		};

		if (poll(&pfd, 1, 100) < 0)
			die("poll");
		if (pfd.revents & POLLPRI) {
			memset(&ev, 0, sizeof(ev));
			if (xioctl(VIDIOC_DQEVENT, &ev))
				die("DQEVENT");
			if (ev.type == V4L2_EVENT_SOURCE_CHANGE && t_event < 0) {
				t_event = now_ms() - t0;
				printf("INFO change: SOURCE_CHANGE (changes %#x) at %.0f ms, %lu frames\n",
				       ev.u.src_change.changes, t_event, frames);
			}
		}
		if (errored || !(pfd.revents & (POLLIN | POLLERR)))
			continue;
		memset(&b, 0, sizeof(b));
		b.type = CAP;
		b.memory = V4L2_MEMORY_MMAP;
		if (xioctl(VIDIOC_DQBUF, &b)) {
			if (errno == EAGAIN)
				continue;
			errored = 1;
			t_err = now_ms() - t0;
			printf("INFO change: DQBUF %s at %.0f ms, %lu frames, last frame at %.0f ms\n",
			       strerror(errno), t_err, frames, t_last);
			continue;
		}
		frames++;
		t_last = now_ms() - t0;
		if (tail_changed(&bufs[b.index]))
			tails++;
		fill(&bufs[b.index]);
		fill_tail(&bufs[b.index]);
		qbuf(b.index, 0);
	}
	held_bad = pix.sizeimage / 32 - untouched(&bufs[held], 0, pix.sizeimage);
	held_tail = tail_changed(&bufs[held]);
	dump_debugfs("input change");
	stream(0);
	/* every buffer is back: no tail may have been written */
	for (i = 0; i < nbufs; i++)
		if (tail_changed(&bufs[i]))
			tails++;
	printf("RESULT change fmt=%.4s %ux%u frames=%lu event_ms=%.0f dqbuf_error_ms=%.0f held_blocks_changed=%lu held_tail_words_changed=%lu tails_changed=%lu\n",
	       (char *)&fourcc, pix.width, pix.height, frames, t_event, t_err,
	       held_bad, held_tail, tails);
	free_bufs();
	sub.type = V4L2_EVENT_ALL;
	xioctl(VIDIOC_UNSUBSCRIBE_EVENT, &sub);
	if (t_event < 0) {
		printf("FAIL change: no SOURCE_CHANGE within %.0f s\n", secs);
		ret = 1;
	}
	if (held_bad || held_tail || tails) {
		printf("FAIL change: DMA outside the queued images\n");
		ret = 1;
	}
	if (!restart)
		return ret;
	if (wait_lock(lock_secs)) {
		printf("FAIL change: no lock for the restart\n");
		return 1;
	}
	return ret | capture(fourcc, nb, n, 1);
}

static unsigned int parse_fmts(const char *s, uint32_t *list)
{
	char tmp[256], *tok, *save = NULL;
	unsigned int n = 0, i;

	if (!strcmp(s, "all")) {
		for (i = 0; i < NFMTS; i++)
			list[i] = fmts[i].fourcc;
		return NFMTS;
	}
	snprintf(tmp, sizeof(tmp), "%s", s);
	for (tok = strtok_r(tmp, ",", &save); tok;
	     tok = strtok_r(NULL, ",", &save)) {
		for (i = 0; i < NFMTS && strcmp(tok, fmts[i].name); i++)
			;
		if (i == NFMTS || n == NFMTS) {
			fprintf(stderr, "gc573-cap: format %s?\n", tok);
			exit(2);
		}
		list[n++] = fmts[i].fourcc;
	}
	return n;
}

int main(int argc, char **argv)
{
	const char *dev = NULL, *fl = "YUYV";
	const char *tl = NULL, *tsave = NULL;
	unsigned int nb = 4, nc = 0, wait_ms = 0, nl, i, t, t_end;
	unsigned long n = 60, rb = 0;
	double lock_secs = 0, xsecs = 0;
	uint32_t list[NFMTS];
	int opt, pattern = 0, under = 0, restart = 0;

	while ((opt = getopt(argc, argv, "d:f:b:n:pT:t:L:o:c:uw:R:X:rFD:M:")) != -1) {
		switch (opt) {
		case 'd': dev = optarg; break;
		case 'f': fl = optarg; break;
		case 'T': tl = optarg; break;
		case 't': tsave = optarg; break;
		case 'b': nb = atoi(optarg); break;
		case 'n': n = strtoul(optarg, NULL, 0); break;
		case 'p': pattern = 1; break;
		case 'c': nc = atoi(optarg); break;
		case 'u': under = 1; break;
		case 'w': wait_ms = atoi(optarg); break;
		case 'R': rb = strtoul(optarg, NULL, 0); break;
		case 'L': lock_secs = atof(optarg); break;
		case 'o': outfile = optarg; break;
		case 'X': xsecs = atof(optarg); break;
		case 'r': restart = 1; break;
		case 'F': frame_log = 1; break;
		case 'D': dbgfile = optarg; break;
		case 'M': bar_open(optarg); break;
		default:
			fprintf(stderr, "usage: see the comment in %s\n",
				__FILE__);
			return 2;
		}
	}
	if (!dev || !nb || nb > MAX_BUFS || n > MAX_FRAMES) {
		fprintf(stderr, "gc573-cap: -d DEV required; 1 <= -b <= %d\n",
			MAX_BUFS);
		return 2;
	}
	nl = parse_fmts(fl, list);
	fd = open(dev, O_RDWR);
	if (fd < 0)
		die(dev);
	setvbuf(stdout, NULL, _IOLBF, 0);

	if (tsave)
		return save_timings(tsave);
	if (tl && tl[0] == '@') {
		load_timings(tl + 1);
		tl = "all";
	}
	if (lock_secs && wait_lock(lock_secs))
		return 3;
	if (xsecs) {
		failed = changetest(list[0], nb, xsecs, restart,
				    lock_secs ? lock_secs : 15, n);
		close(fd);
		return failed ? 1 : 0;
	}

	/* one pass with the current timings unless -T is given */
	t = tl && strcmp(tl, "all") ? strtoul(tl, NULL, 0) : 0;
	t_end = tl && !strcmp(tl, "all") ? ~0U : t + 1;
	for (; t < t_end; t++) {
		if (tl && set_timings(t)) {
			if (t_end == t + 1) {
				fprintf(stderr, "gc573-cap: no timings %u\n",
					t);
				return 2;
			}
			break;
		}
		if (rb)
			failed |= rbtest(list[0], nb, rb);
		else if (nc)
			failed |= cycles(list, nl, nc, nb, n);
		else if (under)
			failed |= underrun(list[0], nb);
		else if (wait_ms)
			failed |= waitcheck(list[0], nb, wait_ms);
		else
			for (i = 0; i < nl; i++)
				failed |= capture(list[i], nb, n, pattern);
	}

	close(fd);
	return failed ? 1 : 0;
}
