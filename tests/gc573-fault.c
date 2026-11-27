// SPDX-License-Identifier: GPL-2.0
/*
 * gc573-fault: systematic fault injection for the GC573 driver
 * (tests/cases/18-fault-inject.sh), through the kernel's fail-nth
 * (Documentation/fault-injection/fault-injection.rst). Writing N to
 * /proc/self/task/<tid>/fail-nth makes the N-th fault-injection point this
 * thread passes fail: slab and page allocations here, as the case sets up
 * /sys/kernel/debug/failslab and fail_page_alloc (with a stacktrace filter
 * only points with a gc573 function on the stack count). Reading it back
 * gives 0 once the fault was injected.
 *
 * gc573-fault load -n N KO [PARAMS]   finit_module(KO, PARAMS) with the
 *                                     N-th point failed
 * gc573-fault bind -n N BDF           BDF written to the gc573 driver's
 *                                     bind file with the N-th point failed
 * gc573-fault sweep OP -d VDEV [-D PCM] [-e EDID] [-m DEBUGFS]
 *                  [-F FULL] [-S STRIDE] [-v]
 *     OP: vopen, reqbufs, s_fmt, streamon, s_edid, pcm_open, hw_params.
 *     For n = 1, 2 ... FULL, then every STRIDE-th: OP with the n-th point
 *     failed, then the recovery check: the same step again without a fault
 *     and a short stream (5 video frames or 5 audio periods), and with -m
 *     the driver's buffer memory (debugfs "mem") back to 0. The sweep ends
 *     at the first n past OP's last point (the fault not injected).
 *     -e: the EDID (raw, 128-byte blocks) for s_edid, which also clears
 *     the EDID after each step (0 blocks: HPD low, the input off). The
 *     video steps stream free-running: the case keeps the input off.
 *
 * Output: an "FI load" or "FI bind" line; per sweep an "FI OP n=..." line
 * for each injected fault whose recovery failed (each one with -v) and a
 * summary "FI OP points=... injected=... op_failed=... errnos=...
 * recover_fail=...". Exit status: 0 = the fault was injected (load, bind)
 * or every recovery passed (sweep), 1 = a recovery failed, 2 = usage or
 * setup error, 3 = (load, bind) the N-th point was not reached.
 */
#define _GNU_SOURCE
#include <alsa/asoundlib.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define CAP		V4L2_BUF_TYPE_VIDEO_CAPTURE
#define MAX_BUFS	8
#define DQ_TIMEOUT_MS	2000
#define WHY		512

static int fnth = -1;
static int vfd = -1;
static const char *vdev, *pcmname, *edidfile, *memfile;
static int verbose;

struct vbuf {
	void *p;
	size_t len;
};

static struct vbuf vb[MAX_BUFS];
static unsigned int nvb;

static void die(const char *what)
{
	fprintf(stderr, "gc573-fault: %s: %s\n", what, strerror(errno));
	exit(2);
}

static const char *ename(int e)
{
	const char *s = e ? strerrorname_np(e) : "0";

	return s ? s : "E?";
}

/* ---- fail-nth ---- */

static void nth_open(void)
{
	char p[64];

	snprintf(p, sizeof(p), "/proc/self/task/%ld/fail-nth",
		 (long)syscall(SYS_gettid));
	fnth = open(p, O_RDWR | O_CLOEXEC);
	if (fnth < 0)
		die(p);
}

static void nth_set(unsigned int n)
{
	char b[16];
	int l = snprintf(b, sizeof(b), "%u", n);

	if (pwrite(fnth, b, l, 0) != l)
		die("fail-nth write");
}

/* 1 if the fault nth_set() set up was injected; then fail-nth is cleared */
static int nth_done(void)
{
	char b[16] = "";
	int inj;

	if (pread(fnth, b, sizeof(b) - 1, 0) < 0)
		die("fail-nth read");
	inj = atoi(b) == 0;
	nth_set(0);
	return inj;
}

/* ---- load, bind ---- */

static int cmd_load(unsigned int n, const char *ko, const char *params)
{
	int kfd, r, e, inj;

	kfd = open(ko, O_RDONLY | O_CLOEXEC);
	if (kfd < 0)
		die(ko);
	nth_open();
	nth_set(n);
	r = syscall(SYS_finit_module, kfd, params, 0);
	e = errno;
	inj = nth_done();
	close(kfd);
	printf("FI load n=%u injected=%d rc=%d errno=%s\n", n, inj, r,
	       ename(r ? e : 0));
	return inj ? 0 : 3;
}

static int cmd_bind(unsigned int n, const char *bdf)
{
	int bfd, e, inj;
	ssize_t r;

	bfd = open("/sys/bus/pci/drivers/gc573/bind", O_WRONLY | O_CLOEXEC);
	if (bfd < 0)
		die("gc573 bind file");
	nth_open();
	nth_set(n);
	r = write(bfd, bdf, strlen(bdf));
	e = errno;
	inj = nth_done();
	close(bfd);
	printf("FI bind n=%u injected=%d rc=%zd errno=%s\n", n, inj, r,
	       ename(r < 0 ? e : 0));
	return inj ? 0 : 3;
}

/* ---- video ---- */

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do {
		r = ioctl(fd, req, arg);
	} while (r < 0 && errno == EINTR);
	return r;
}

/* REQBUFS count (MMAP): the count granted, or -1 */
static int vreqbufs(unsigned int count)
{
	struct v4l2_requestbuffers rb = {
		.count = count, .type = CAP, .memory = V4L2_MEMORY_MMAP,
	};

	if (xioctl(vfd, VIDIOC_REQBUFS, &rb))
		return -1;
	return rb.count;
}

static void vunmap_all(void)
{
	unsigned int i;

	for (i = 0; i < nvb; i++)
		munmap(vb[i].p, vb[i].len);
	nvb = 0;
}

/* QUERYBUF and mmap buffers 0 .. count-1 */
static int vmap_all(unsigned int count, char *why)
{
	struct v4l2_buffer b;
	unsigned int i;

	if (count > MAX_BUFS) {
		snprintf(why, WHY, "%u buffers granted, at most %d expected",
			 count, MAX_BUFS);
		return -1;
	}
	for (i = 0; i < count; i++) {
		memset(&b, 0, sizeof(b));
		b.type = CAP;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		if (xioctl(vfd, VIDIOC_QUERYBUF, &b)) {
			snprintf(why, WHY, "QUERYBUF %u: %s", i, ename(errno));
			vunmap_all();
			return -1;
		}
		vb[i].len = b.length;
		vb[i].p = mmap(NULL, b.length, PROT_READ | PROT_WRITE,
			       MAP_SHARED, vfd, b.m.offset);
		if (vb[i].p == MAP_FAILED) {
			snprintf(why, WHY, "mmap %u: %s", i, ename(errno));
			vunmap_all();
			return -1;
		}
		nvb = i + 1;
	}
	return 0;
}

static int vqbuf(unsigned int i, char *why)
{
	struct v4l2_buffer b = {
		.type = CAP, .memory = V4L2_MEMORY_MMAP, .index = i,
	};

	if (xioctl(vfd, VIDIOC_QBUF, &b)) {
		snprintf(why, WHY, "QBUF %u: %s", i, ename(errno));
		return -1;
	}
	return 0;
}

static int vqbuf_all(char *why)
{
	unsigned int i;

	for (i = 0; i < nvb; i++)
		if (vqbuf(i, why))
			return -1;
	return 0;
}

static int vstreamoff(char *why)
{
	int t = CAP;

	if (xioctl(vfd, VIDIOC_STREAMOFF, &t)) {
		snprintf(why, WHY, "STREAMOFF: %s", ename(errno));
		return -1;
	}
	return 0;
}

/* nf frames on a stream already on: DQBUF, then QBUF again */
static int vframes(unsigned int nf, char *why)
{
	struct pollfd pf = { .fd = vfd, .events = POLLIN };
	struct v4l2_buffer b;
	unsigned int k;
	int r;

	for (k = 0; k < nf; k++) {
		r = poll(&pf, 1, DQ_TIMEOUT_MS);
		if (r <= 0) {
			snprintf(why, WHY, "frame %u: %s", k,
				 r ? ename(errno) : "no frame within 2 s");
			return -1;
		}
		memset(&b, 0, sizeof(b));
		b.type = CAP;
		b.memory = V4L2_MEMORY_MMAP;
		if (xioctl(vfd, VIDIOC_DQBUF, &b)) {
			snprintf(why, WHY, "DQBUF %u: %s", k, ename(errno));
			return -1;
		}
		if (vqbuf(b.index, why))
			return -1;
	}
	return 0;
}

/* buffers mapped: QBUF all, STREAMON, nf frames, STREAMOFF */
static int vstream(unsigned int nf, char *why)
{
	int t = CAP;

	if (vqbuf_all(why))
		return -1;
	if (xioctl(vfd, VIDIOC_STREAMON, &t)) {
		snprintf(why, WHY, "STREAMON: %s", ename(errno));
		vstreamoff(why + strlen(why) / 2);
		return -1;
	}
	if (vframes(nf, why)) {
		vstreamoff(why + strlen(why) / 2);
		return -1;
	}
	return vstreamoff(why);
}

/* a whole clean cycle: REQBUFS nb, nf frames, REQBUFS 0 */
static int vcycle(unsigned int nb, unsigned int nf, char *why)
{
	int c = vreqbufs(nb), r;

	if (c <= 0) {
		snprintf(why, WHY, "clean REQBUFS %u: %s", nb,
			 c < 0 ? ename(errno) : "0 buffers");
		return -1;
	}
	r = vmap_all(c, why);
	if (!r)
		r = vstream(nf, why);
	vunmap_all();
	if (vreqbufs(0) < 0 && !r) {
		snprintf(why, WHY, "clean REQBUFS 0: %s", ename(errno));
		r = -1;
	}
	return r;
}

/* the driver's buffer memory (debugfs "mem" line): 0 with nothing allocated */
static int mem_zero(char *why)
{
	long a, b, c, d, e;
	char line[256];
	int r = -1;
	FILE *f;

	if (!memfile)
		return 0;
	f = fopen(memfile, "r");
	if (!f) {
		snprintf(why, WHY, "%s: %s", memfile, ename(errno));
		return -1;
	}
	snprintf(why, WHY, "no mem line in %s", memfile);
	while (fgets(line, sizeof(line), f)) {
		if (sscanf(line, "mem (live, all cards): bufs %ld pages %ld vmaps %ld dlists %ld dl_bytes %ld",
			   &a, &b, &c, &d, &e) != 5)
			continue;
		line[strcspn(line, "\n")] = 0;
		if (a || b || c || d || e) {
			snprintf(why, WHY, "driver memory not back to 0: %s", line);
		} else {
			why[0] = 0;
			r = 0;
		}
		break;
	}
	fclose(f);
	return r;
}

static int vopen_check(char *why)
{
	struct v4l2_capability cap;
	int fd = open(vdev, O_RDWR | O_NONBLOCK | O_CLOEXEC), r = 0;

	if (fd < 0) {
		snprintf(why, WHY, "clean open: %s", ename(errno));
		return -1;
	}
	if (xioctl(fd, VIDIOC_QUERYCAP, &cap)) {
		snprintf(why, WHY, "QUERYCAP: %s", ename(errno));
		r = -1;
	}
	close(fd);
	return r;
}

static int g_fmt(struct v4l2_format *f)
{
	memset(f, 0, sizeof(*f));
	f->type = CAP;
	return xioctl(vfd, VIDIOC_G_FMT, f);
}

/* ---- the EDID (s_edid) ---- */

static uint8_t edid[512];
static unsigned int edid_blocks;

static int s_edid(unsigned int blocks)
{
	struct v4l2_edid e = { .blocks = blocks, .edid = edid };

	return xioctl(vfd, VIDIOC_S_EDID, &e);
}

/* G_EDID equals the file */
static int edid_check(char *why)
{
	uint8_t got[512];
	struct v4l2_edid e = { .blocks = edid_blocks, .edid = got };

	if (xioctl(vfd, VIDIOC_G_EDID, &e)) {
		snprintf(why, WHY, "G_EDID: %s", ename(errno));
		return -1;
	}
	if (e.blocks != edid_blocks || memcmp(got, edid, edid_blocks * 128)) {
		snprintf(why, WHY, "G_EDID: %u blocks, not the %u set", e.blocks,
			 edid_blocks);
		return -1;
	}
	return 0;
}

/* ---- audio ---- */

#define PERIOD	480
#define BUFFER	9600

static snd_pcm_hw_params_t *hw_setup(snd_pcm_t *p)
{
	snd_pcm_hw_params_t *hw;

	if (snd_pcm_hw_params_malloc(&hw) < 0)
		return NULL;
	if (snd_pcm_hw_params_any(p, hw) < 0 ||
	    snd_pcm_hw_params_set_access(p, hw, SND_PCM_ACCESS_RW_INTERLEAVED) < 0 ||
	    snd_pcm_hw_params_set_format(p, hw, SND_PCM_FORMAT_S16_LE) < 0 ||
	    snd_pcm_hw_params_set_channels(p, hw, 2) < 0 ||
	    snd_pcm_hw_params_set_rate(p, hw, 48000, 0) < 0 ||
	    snd_pcm_hw_params_set_period_size(p, hw, PERIOD, 0) < 0 ||
	    snd_pcm_hw_params_set_buffer_size(p, hw, BUFFER) < 0) {
		snd_pcm_hw_params_free(hw);
		return NULL;
	}
	return hw;
}

/* np periods from a prepared PCM, then drop */
static int aread(snd_pcm_t *p, unsigned int np, char *why)
{
	int16_t buf[PERIOD * 2];
	snd_pcm_sframes_t r;
	unsigned int k;
	int e;

	e = snd_pcm_start(p);
	if (e < 0) {
		snprintf(why, WHY, "snd_pcm_start: %s", snd_strerror(e));
		return -1;
	}
	for (k = 0; k < np; k++) {
		e = snd_pcm_wait(p, DQ_TIMEOUT_MS);
		if (e <= 0) {
			snprintf(why, WHY, "period %u: %s", k,
				 e ? snd_strerror(e) : "none within 2 s");
			snd_pcm_drop(p);
			return -1;
		}
		r = snd_pcm_readi(p, buf, PERIOD);
		if (r < 0) {
			snprintf(why, WHY, "period %u: readi %s", k,
				 snd_strerror(r));
			snd_pcm_drop(p);
			return -1;
		}
	}
	snd_pcm_drop(p);
	return 0;
}

/* a clean capture: open, hw params, 5 periods, close */
static int acycle(char *why)
{
	snd_pcm_hw_params_t *hw;
	snd_pcm_t *p;
	int e, r;

	e = snd_pcm_open(&p, pcmname, SND_PCM_STREAM_CAPTURE, 0);
	if (e < 0) {
		snprintf(why, WHY, "clean snd_pcm_open: %s", snd_strerror(e));
		return -1;
	}
	hw = hw_setup(p);
	if (!hw) {
		snprintf(why, WHY, "clean hw params refine failed");
		snd_pcm_close(p);
		return -1;
	}
	e = snd_pcm_hw_params(p, hw);
	snd_pcm_hw_params_free(hw);
	if (e < 0) {
		snprintf(why, WHY, "clean snd_pcm_hw_params: %s", snd_strerror(e));
		snd_pcm_close(p);
		return -1;
	}
	r = aread(p, 5, why);
	snd_pcm_close(p);
	return r;
}

/* ---- the sweep ---- */

enum op { VOPEN, REQBUFS, S_FMT, STREAMON, S_EDID, PCM_OPEN, HW_PARAMS };

static const char *const opnames[] = {
	"vopen", "reqbufs", "s_fmt", "streamon", "s_edid", "pcm_open",
	"hw_params",
};

/*
 * One step with the n-th point failed: *inj = whether it was, *err = the
 * operation's error (0 = it succeeded), then the recovery check. Returns 0
 * if the recovery passed, -1 with why set if not.
 */
static int step(enum op op, unsigned int n, int *inj, int *err, char *why)
{
	struct v4l2_format f0, f, g, t;
	struct v4l2_requestbuffers rb;
	snd_pcm_hw_params_t *hw;
	snd_pcm_t *p;
	int r, e = 0, fd, c, type = CAP;

	why[0] = 0;
	switch (op) {
	case VOPEN:
		nth_set(n);
		fd = open(vdev, O_RDWR | O_NONBLOCK | O_CLOEXEC);
		e = fd < 0 ? errno : 0;
		*inj = nth_done();
		if (fd >= 0)
			close(fd);
		*err = e;
		return vopen_check(why);

	case REQBUFS:
		if (vreqbufs(0) < 0) {
			snprintf(why, WHY, "REQBUFS 0 before: %s", ename(errno));
			return -1;
		}
		memset(&rb, 0, sizeof(rb));
		rb.count = 4;
		rb.type = CAP;
		rb.memory = V4L2_MEMORY_MMAP;
		nth_set(n);
		r = xioctl(vfd, VIDIOC_REQBUFS, &rb);
		e = r ? errno : 0;
		*inj = nth_done();
		*err = e;
		r = 0;
		if (!e && rb.count) {
			/* the buffers granted under the fault must stream */
			r = vmap_all(rb.count, why);
			if (!r)
				r = vstream(5, why);
			vunmap_all();
		}
		if (vreqbufs(0) < 0 && !r) {
			snprintf(why, WHY, "REQBUFS 0 after: %s", ename(errno));
			r = -1;
		}
		if (!r && e)
			r = vcycle(4, 5, why);
		if (!r)
			r = mem_zero(why);
		return r;

	case S_FMT:
		if (g_fmt(&f0)) {
			snprintf(why, WHY, "G_FMT before: %s", ename(errno));
			return -1;
		}
		f = f0;
		f.fmt.pix.pixelformat = f0.fmt.pix.pixelformat == V4L2_PIX_FMT_YUYV ?
					V4L2_PIX_FMT_NV12 : V4L2_PIX_FMT_YUYV;
		f.fmt.pix.bytesperline = 0;
		f.fmt.pix.sizeimage = 0;
		nth_set(n);
		r = xioctl(vfd, VIDIOC_S_FMT, &f);
		e = r ? errno : 0;
		*inj = nth_done();
		*err = e;
		/* the format is the old one or the new one, whole */
		if (g_fmt(&g)) {
			snprintf(why, WHY, "G_FMT after: %s", ename(errno));
			return -1;
		}
		t = g;
		if (xioctl(vfd, VIDIOC_TRY_FMT, &t)) {
			snprintf(why, WHY, "TRY_FMT after: %s", ename(errno));
			return -1;
		}
		if ((!e && g.fmt.pix.pixelformat != f.fmt.pix.pixelformat) ||
		    (g.fmt.pix.pixelformat != f0.fmt.pix.pixelformat &&
		     g.fmt.pix.pixelformat != f.fmt.pix.pixelformat) ||
		    g.fmt.pix.width != t.fmt.pix.width ||
		    g.fmt.pix.height != t.fmt.pix.height ||
		    g.fmt.pix.bytesperline != t.fmt.pix.bytesperline ||
		    g.fmt.pix.sizeimage != t.fmt.pix.sizeimage) {
			snprintf(why, WHY, "G_FMT after S_FMT (%s): %.4s %ux%u bpl %u size %u; TRY_FMT gives %ux%u bpl %u size %u",
				 ename(e), (char *)&g.fmt.pix.pixelformat,
				 g.fmt.pix.width, g.fmt.pix.height,
				 g.fmt.pix.bytesperline, g.fmt.pix.sizeimage,
				 t.fmt.pix.width, t.fmt.pix.height,
				 t.fmt.pix.bytesperline, t.fmt.pix.sizeimage);
			return -1;
		}
		r = vcycle(2, 3, why);
		if (!r)
			r = mem_zero(why);
		return r;

	case STREAMON:
		c = vreqbufs(4);
		if (c <= 0) {
			snprintf(why, WHY, "REQBUFS 4 before: %s",
				 c < 0 ? ename(errno) : "0 buffers");
			return -1;
		}
		r = vmap_all(c, why);
		if (!r)
			r = vqbuf_all(why);
		if (r) {
			vunmap_all();
			vreqbufs(0);
			return -1;
		}
		nth_set(n);
		r = xioctl(vfd, VIDIOC_STREAMON, &type);
		e = r ? errno : 0;
		*inj = nth_done();
		*err = e;
		if (!e) {
			r = vframes(5, why);
			if (vstreamoff(r ? why + strlen(why) : why) && !r)
				r = -1;
		} else {
			/* STREAMOFF gives every buffer back; then a clean start */
			r = vstreamoff(why);
			if (!r)
				r = vstream(5, why);
		}
		vunmap_all();
		if (vreqbufs(0) < 0 && !r) {
			snprintf(why, WHY, "REQBUFS 0 after: %s", ename(errno));
			r = -1;
		}
		if (!r)
			r = mem_zero(why);
		return r;

	case S_EDID:
		nth_set(n);
		r = s_edid(edid_blocks);
		e = r ? errno : 0;
		*inj = nth_done();
		*err = e;
		r = 0;
		if (e) {
			if (s_edid(edid_blocks)) {
				snprintf(why, WHY, "clean S_EDID: %s", ename(errno));
				r = -1;
			}
		}
		if (!r)
			r = edid_check(why);
		/* back to no EDID: HPD low, the input off */
		if (s_edid(0) && !r) {
			snprintf(why, WHY, "S_EDID 0 blocks: %s", ename(errno));
			r = -1;
		}
		return r;

	case PCM_OPEN:
		nth_set(n);
		r = snd_pcm_open(&p, pcmname, SND_PCM_STREAM_CAPTURE, 0);
		*inj = nth_done();
		*err = r < 0 ? -r : 0;
		if (r >= 0)
			snd_pcm_close(p);
		return acycle(why);

	case HW_PARAMS:
		r = snd_pcm_open(&p, pcmname, SND_PCM_STREAM_CAPTURE, 0);
		if (r < 0) {
			snprintf(why, WHY, "snd_pcm_open before: %s", snd_strerror(r));
			return -1;
		}
		hw = hw_setup(p);
		if (!hw) {
			snprintf(why, WHY, "hw params refine before failed");
			snd_pcm_close(p);
			return -1;
		}
		nth_set(n);
		r = snd_pcm_hw_params(p, hw);
		*inj = nth_done();
		*err = r < 0 ? -r : 0;
		snd_pcm_hw_params_free(hw);
		if (r < 0) {
			/* hw_free, then the same PCM set up again */
			snd_pcm_hw_free(p);
			hw = hw_setup(p);
			r = hw ? snd_pcm_hw_params(p, hw) : -EINVAL;
			if (hw)
				snd_pcm_hw_params_free(hw);
			if (r < 0) {
				snprintf(why, WHY, "clean snd_pcm_hw_params: %s",
					 snd_strerror(r));
				snd_pcm_close(p);
				return -1;
			}
		}
		r = aread(p, 5, why);
		snd_pcm_close(p);
		if (!r)
			r = acycle(why);
		return r;
	}
	return -1;
}

static int cmd_sweep(enum op op, unsigned int full, unsigned int stride)
{
	unsigned int n, points = 0, injected = 0, opfail = 0, rfail = 0;
	unsigned int ecount[160] = { 0 };
	char why[WHY], first[WHY + 32] = "";
	int inj, err, r, k;

	nth_open();
	if (op <= S_EDID) {
		vfd = open(vdev, O_RDWR | O_NONBLOCK | O_CLOEXEC);
		if (vfd < 0)
			die(vdev);
	}
	if (op == S_EDID) {
		FILE *f = fopen(edidfile, "rb");
		size_t len;

		if (!f)
			die(edidfile);
		len = fread(edid, 1, sizeof(edid), f);
		fclose(f);
		if (len < 128 || len % 128) {
			fprintf(stderr, "gc573-fault: %s: %zu bytes, not 128-byte blocks\n",
				edidfile, len);
			return 2;
		}
		edid_blocks = len / 128;
	}
	if (op >= PCM_OPEN) {
		/* alsa-lib reads its configuration at the first open, once */
		snd_pcm_t *p;

		r = snd_pcm_open(&p, pcmname, SND_PCM_STREAM_CAPTURE, 0);
		if (r < 0) {
			fprintf(stderr, "gc573-fault: snd_pcm_open %s: %s\n",
				pcmname, snd_strerror(r));
			return 2;
		}
		snd_pcm_close(p);
	}
	/* the state is sound before the first fault */
	r = op >= PCM_OPEN ? acycle(why) :
	    op == S_EDID ? (s_edid(0) ? (snprintf(why, WHY, "S_EDID 0 blocks: %s",
						  ename(errno)), -1) : 0) :
	    vcycle(4, 5, why);
	if (!r)
		r = mem_zero(why);
	if (r) {
		printf("FI %s setup: %s\n", opnames[op], why);
		return 2;
	}
	for (n = 1;; n = n < full ? n + 1 : n + stride) {
		r = step(op, n, &inj, &err, why);
		if (!inj) {
			/* n is past the last point: the step ran unfaulted */
			if (r) {
				printf("FI %s n=%u not injected, the step without a fault failed: %s\n",
				       opnames[op], n, why);
				rfail++;
			}
			points = n - 1;
			break;
		}
		injected++;
		if (err) {
			opfail++;
			ecount[err < 160 ? err : 0]++;
		}
		if (r) {
			rfail++;
			if (!first[0])
				snprintf(first, sizeof(first), "n=%u (%s): %s", n,
					 ename(err), why);
		}
		if (r || verbose)
			printf("FI %s n=%u injected rc=%s recover=%s%s\n",
			       opnames[op], n, ename(err), r ? "FAIL: " : "ok",
			       r ? why : "");
		fflush(stdout);
		if (rfail >= 20) {
			printf("FI %s stopped after 20 failed recoveries\n", opnames[op]);
			break;
		}
	}
	printf("FI %s points=%u injected=%u op_failed=%u errnos=", opnames[op],
	       points, injected, opfail);
	for (k = 0, r = 0; k < 160; k++)
		if (ecount[k])
			printf("%s%s:%u", r++ ? "," : "", k ? ename(k) : "other",
			       ecount[k]);
	printf("%s recover_fail=%u%s%s\n", r ? "" : "none", rfail,
	       first[0] ? " first " : "", first);
	if (vfd >= 0)
		close(vfd);
	return rfail ? 1 : 0;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: gc573-fault load -n N KO [PARAMS]\n"
		"       gc573-fault bind -n N BDF\n"
		"       gc573-fault sweep OP -d VDEV [-D PCM] [-e EDID] [-m DEBUGFS]\n"
		"                   [-F FULL] [-S STRIDE] [-v]\n"
		"       OP: vopen reqbufs s_fmt streamon s_edid pcm_open hw_params\n");
	exit(2);
}

int main(int argc, char **argv)
{
	unsigned int n = 0, full = 64, stride = 37;
	const char *cmd, *opname = NULL;
	int opt, k;

	if (argc < 2)
		usage();
	cmd = argv[1];
	if (!strcmp(cmd, "sweep")) {
		if (argc < 3)
			usage();
		opname = argv[2];
		optind = 3;
	} else {
		optind = 2;
	}
	while ((opt = getopt(argc, argv, "n:d:D:e:m:F:S:v")) != -1) {
		switch (opt) {
		case 'n': n = strtoul(optarg, NULL, 0); break;
		case 'd': vdev = optarg; break;
		case 'D': pcmname = optarg; break;
		case 'e': edidfile = optarg; break;
		case 'm': memfile = optarg; break;
		case 'F': full = strtoul(optarg, NULL, 0); break;
		case 'S': stride = strtoul(optarg, NULL, 0); break;
		case 'v': verbose = 1; break;
		default: usage();
		}
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (!strcmp(cmd, "load")) {
		if (!n || optind >= argc)
			usage();
		return cmd_load(n, argv[optind],
				optind + 1 < argc ? argv[optind + 1] : "");
	}
	if (!strcmp(cmd, "bind")) {
		if (!n || optind >= argc)
			usage();
		return cmd_bind(n, argv[optind]);
	}
	if (strcmp(cmd, "sweep") || !stride)
		usage();
	for (k = 0; k <= HW_PARAMS; k++)
		if (!strcmp(opname, opnames[k]))
			break;
	if (k > HW_PARAMS)
		usage();
	if ((k <= S_EDID && !vdev) || (k >= PCM_OPEN && !pcmname) ||
	    (k == S_EDID && !edidfile))
		usage();
	return cmd_sweep(k, full, stride);
}
