// SPDX-License-Identifier: GPL-2.0
/*
 * gc573-stress: randomized concurrent load on the GC573 driver (tests/live.sh
 * stress). Worker processes, each with its own random sequence, run for
 * -t seconds against the card at PCI address -B:
 *   video (-V, 3)  open; S_FMT, REQBUFS, mmap, QBUF, STREAMON, frames,
 *                  then STREAMOFF, or REQBUFS 0 or close while streaming;
 *                  DV timings (QUERY, S_DV_TIMINGS to the input's), event
 *                  subscriptions and DQEVENT, information ioctls, close
 *                  and open again
 *   audio (-A, 2)  open (non-blocking: one substream, so the other workers
 *                  get EBUSY), hw_params of a random period and buffer,
 *                  start, read, overrun recovery, drop, start again, close
 *   ctl (-C, 1)    open/ioctl/close of the video node and the ALSA control
 *                  node, reads of the driver's debugfs files
 *   edid (-E, 1)   VIDIOC_S_EDID every 2-10 s: the EDID found at the start
 *                  (G_EDID), the same with another serial number, or none
 *                  for a few seconds; each change is a hot-plug
 *   bind (-U)      unbind and bind the gc573 driver every 15-45 s; the
 *                  others see ENODEV and open again once the device is back
 * Every operation's error is checked against the errors it can have here
 * (another process owns the queue, the input is in other timings, the
 * device went away, ...): any other is "unexpected". REQBUFS 0 while
 * streaming is its own operation: vb2 refuses it with EBUSY ("streaming
 * active"), and its success is unexpected too. A watchdog in the
 * parent reports an operation still running after -w ms (default 10000;
 * 30000 for unbind and bind) as a hang. Run as root.
 *
 * gc573-stress -B BDF [-t SECS] [-V N] [-A N] [-C N] [-E N] [-U] [-s SEED]
 *              [-w MS]
 *
 * Output: "UNEXPECTED role.id OP: ERRNO" (the first 4 of each worker), and
 * at the end one "WORKER role.id ops=N errs=ERRNO:N,... unexpected=N
 * stalls=N slowest=OP:MS" line per worker ("stalls": video polls with no
 * frame and no error for 3 s, audio waits with no period for 2 s: counted,
 * not failed; the watchdog fails what does not return), "HANG role.id OP
 * for S s", and "RESULT stress PASS|FAIL workers=N ops=N unexpected=N
 * hangs=N stalls=N binds=N edids=N". Exit status: 0 = pass, 1 = an
 * unexpected error, 2 = usage, 3 = a hang (the hung worker is left).
 */
#define _GNU_SOURCE
#include <alsa/asoundlib.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define CAP		V4L2_BUF_TYPE_VIDEO_CAPTURE
#define MAX_WORKERS	32
#define MAX_BUFS	4
#define NERR		134	/* errno values counted; 0 = other */
#define NFIRST		4

enum op {
	OP_NONE = -1,
	V_OPEN, V_CLOSE, V_INFO, V_S_FMT, V_REQBUFS, V_QUERYBUF, V_MMAP,
	V_QBUF, V_STREAMON, V_DQBUF, V_STREAMOFF, V_REQBUFS0, V_REQBUFS0_ON,
	V_QUERY_DV,
	V_S_DV, V_G_EDID, V_S_EDID, V_SUBSCRIBE, V_DQEVENT, V_LOG_STATUS,
	A_OPEN, A_HW_PARAMS, A_PREPARE, A_START, A_READ, A_DROP, A_CLOSE,
	C_CTL, D_READ, B_UNBIND, B_BIND, B_WAIT,
	NOPS
};

static const char *const opname[NOPS] = {
	"open", "close", "info", "S_FMT", "REQBUFS", "QUERYBUF", "mmap",
	"QBUF", "STREAMON", "DQBUF", "STREAMOFF", "REQBUFS0",
	"REQBUFS0_streaming", "QUERY_DV_TIMINGS",
	"S_DV_TIMINGS", "G_EDID", "S_EDID", "SUBSCRIBE_EVENT", "DQEVENT",
	"LOG_STATUS", "pcm_open", "hw_params", "prepare", "start", "read",
	"drop", "pcm_close", "ctl", "debugfs", "unbind", "bind", "bind_wait",
};

/* errors each operation can have here besides ENODEV (the device gone) */
static const int allowed[NOPS][6] = {
	[V_OPEN]	= { ENOENT, ENXIO },
	[V_INFO]	= { EINVAL, ENOLINK, ENOLCK, ERANGE, ENODATA },
	[V_S_FMT]	= { EBUSY },
	[V_REQBUFS]	= { EBUSY },
	[V_QUERYBUF]	= { EINVAL },
	[V_MMAP]	= { EINVAL },
	[V_QBUF]	= { EIO, EINVAL },
	[V_STREAMON]	= { EPIPE, EIO, EINVAL },
	[V_DQBUF]	= { EAGAIN, EIO, EINVAL },
	[V_STREAMOFF]	= { EINVAL },
	/* vb2 refuses REQBUFS while streaming: "streaming active" */
	[V_REQBUFS0_ON]	= { EBUSY },
	[V_QUERY_DV]	= { ENOLINK, ENOLCK, ERANGE },
	[V_S_DV]	= { EBUSY, EINVAL },
	[V_G_EDID]	= { ENODATA, EINVAL },
	[V_DQEVENT]	= { ENOENT },
	[A_OPEN]	= { EBUSY, ENOENT, ENXIO },
	[A_HW_PARAMS]	= { EBADFD },
	[A_PREPARE]	= { EBADFD },
	[A_START]	= { EBADFD, EBUSY, EPIPE },
	[A_READ]	= { EPIPE, EBADFD, EIO, ESTRPIPE },
	[A_DROP]	= { EBADFD },
	[C_CTL]		= { ENOENT, ENXIO },
	[D_READ]	= { ENOENT, EIO },
};

struct slot {
	pid_t pid;
	char name[16];
	int op;			/* running now, OP_NONE between */
	int64_t op_t0;		/* its start, CLOCK_MONOTONIC ns */
	uint64_t ops, stalls, binds, edids;
	uint32_t err[NERR];
	uint32_t unexpected;
	int slow_op;
	int64_t slow_ns;
	char first[NFIRST][96];
	int hung;		/* reported by the parent */
	int died;		/* exit status or signal, if not 0 */
};

struct shared {
	volatile int stop;
	int nslots;
	struct slot s[MAX_WORKERS];
};

static struct shared *sh;
static struct slot *me;
static const char *bdf;
static int64_t deadline_ns;
static uint64_t rng;

static int64_t now_ns(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

static uint32_t rnd(uint32_t n)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return n ? (uint32_t)(rng % n) : 0;
}

static void msleep(unsigned int ms)
{
	struct timespec t = { ms / 1000, (long)(ms % 1000) * 1000000 };

	while (nanosleep(&t, &t) && errno == EINTR)
		;
}

static int time_up(void)
{
	return sh->stop || now_ns() >= deadline_ns;
}

/* a long sleep, cut short by the end of the run */
static void nap(unsigned int ms)
{
	while (ms && !time_up()) {
		unsigned int d = ms < 100 ? ms : 100;

		msleep(d);
		ms -= d;
	}
}

static const char *ename(int e)
{
	const char *s = e ? strerrorname_np(e) : "0";

	return s ? s : "E?";
}

static void op_begin(int op)
{
	me->op_t0 = now_ns();
	__atomic_store_n(&me->op, op, __ATOMIC_RELEASE);
}

/* an unexpected result of operation op: what (an errno name, or more) */
static void note_unexpected(int op, const char *what)
{
	if (me->unexpected < NFIRST) {
		snprintf(me->first[me->unexpected], sizeof(me->first[0]),
			 "%s: %s", opname[op], what);
		printf("UNEXPECTED %s %s\n", me->name, me->first[me->unexpected]);
	}
	me->unexpected++;
}

/*
 * End of an operation; e = its errno (0: success). Returns e. ENODEV (the
 * device went away, as the bind role makes it) is always allowed.
 */
static int op_end(int e)
{
	int op = me->op;
	int64_t d = now_ns() - me->op_t0;
	unsigned int i;

	__atomic_store_n(&me->op, OP_NONE, __ATOMIC_RELEASE);
	me->ops++;
	if (d > me->slow_ns) {
		me->slow_ns = d;
		me->slow_op = op;
	}
	if (!e)
		return 0;
	me->err[e > 0 && e < NERR ? e : 0]++;
	if (e == ENODEV)
		return e;
	for (i = 0; i < 6 && allowed[op][i]; i++)
		if (allowed[op][i] == e)
			return e;
	note_unexpected(op, ename(e));
	return e;
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do {
		r = ioctl(fd, req, arg);
	} while (r < 0 && errno == EINTR);
	return r < 0 ? errno : 0;
}

/* one ioctl as one operation: its errno, checked */
static int vio(int op, int fd, unsigned long req, void *arg)
{
	op_begin(op);
	return op_end(xioctl(fd, req, arg));
}

/* ---- the device's nodes, from sysfs ---- */

static int sysfs_child(const char *sub, const char *prefix, char *out,
		       size_t len)
{
	char p[128];
	struct dirent *d;
	DIR *dir;
	int r = -1;

	snprintf(p, sizeof(p), "/sys/bus/pci/devices/%s/%s", bdf, sub);
	dir = opendir(p);
	if (!dir)
		return -1;
	while ((d = readdir(dir)))
		if (!strncmp(d->d_name, prefix, strlen(prefix))) {
			snprintf(out, len, "%s", d->d_name + strlen(prefix));
			r = 0;
			break;
		}
	closedir(dir);
	return r;
}

/* /dev/videoN of the card, or -1 while it has none */
static int video_node(char *path, size_t len)
{
	char n[32];

	if (sysfs_child("video4linux", "video", n, sizeof(n)))
		return -1;
	snprintf(path, len, "/dev/video%s", n);
	return 0;
}

/* the ALSA card number, or -1 (by index: alsa-lib opens that card alone) */
static int card_number(void)
{
	char n[32];

	if (sysfs_child("sound", "card", n, sizeof(n)))
		return -1;
	return atoi(n);
}

static int bound(void)
{
	char p[128];

	snprintf(p, sizeof(p), "/sys/bus/pci/drivers/gc573/%s", bdf);
	return !access(p, F_OK);
}

/* ---- video ---- */

static const uint32_t fmts[] = {
	V4L2_PIX_FMT_YUYV, V4L2_PIX_FMT_UYVY, V4L2_PIX_FMT_NV12,
	V4L2_PIX_FMT_YVU420, V4L2_PIX_FMT_BGR24, V4L2_PIX_FMT_XBGR32,
};

struct mbuf {
	void *p;
	size_t len;
};

static int vopen(void)
{
	char path[64];
	int fd;

	if (video_node(path, sizeof(path)))
		return -1;
	op_begin(V_OPEN);
	fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	op_end(fd < 0 ? errno : 0);
	return fd;
}

static void vclose(int fd)
{
	op_begin(V_CLOSE);
	op_end(close(fd) ? errno : 0);
}

static void vinfo(int fd)
{
	struct v4l2_capability cap;
	struct v4l2_format f = { .type = CAP };
	struct v4l2_fmtdesc fd_ = { .type = CAP, .index = rnd(8) };
	struct v4l2_dv_timings t;
	struct v4l2_streamparm parm = { .type = CAP };
	struct v4l2_control c = { .id = V4L2_CID_DV_RX_POWER_PRESENT };
	struct v4l2_enum_dv_timings et = { .index = rnd(12) };

	switch (rnd(8)) {
	case 0: vio(V_INFO, fd, VIDIOC_QUERYCAP, &cap); break;
	case 1: vio(V_INFO, fd, VIDIOC_G_FMT, &f); break;
	case 2:
		f.fmt.pix.pixelformat = fmts[rnd(6)];
		vio(V_INFO, fd, VIDIOC_TRY_FMT, &f);
		break;
	case 3: vio(V_INFO, fd, VIDIOC_ENUM_FMT, &fd_); break;
	case 4: vio(V_INFO, fd, VIDIOC_G_DV_TIMINGS, &t); break;
	case 5: vio(V_INFO, fd, VIDIOC_G_PARM, &parm); break;
	case 6: vio(V_INFO, fd, VIDIOC_G_CTRL, &c); break;
	default: vio(V_INFO, fd, VIDIOC_ENUM_DV_TIMINGS, &et); break;
	}
}

/* the input's timings, if it is locked, set as the device's */
static void vtimings(int fd)
{
	struct v4l2_dv_timings t;

	if (vio(V_QUERY_DV, fd, VIDIOC_QUERY_DV_TIMINGS, &t))
		return;
	vio(V_S_DV, fd, VIDIOC_S_DV_TIMINGS, &t);
}

static void vevents(int fd)
{
	struct v4l2_event_subscription sub = { .type = V4L2_EVENT_SOURCE_CHANGE };
	struct v4l2_event ev;
	unsigned int i;

	if (vio(V_SUBSCRIBE, fd, VIDIOC_SUBSCRIBE_EVENT, &sub))
		return;
	sub.type = V4L2_EVENT_CTRL;
	sub.id = V4L2_CID_DV_RX_POWER_PRESENT;
	vio(V_SUBSCRIBE, fd, VIDIOC_SUBSCRIBE_EVENT, &sub);
	for (i = 0; i < 1 + rnd(20) && !time_up(); i++) {
		if (vio(V_DQEVENT, fd, VIDIOC_DQEVENT, &ev) == ENODEV)
			return;
		msleep(rnd(100));
	}
	if (rnd(2)) {
		sub.type = V4L2_EVENT_ALL;
		vio(V_SUBSCRIBE, fd, VIDIOC_UNSUBSCRIBE_EVENT, &sub);
	}
}

/*
 * A stream session. Returns 1 if the device went away (ENODEV) or the
 * file was closed while streaming (*fdp is -1 then), else 0.
 */
static int vstream(int *fdp)
{
	struct v4l2_format f = { .type = CAP };
	struct v4l2_requestbuffers rb = { .type = CAP, .memory = V4L2_MEMORY_MMAP };
	struct pollfd pf = { .fd = *fdp, .events = POLLIN };
	struct mbuf mb[MAX_BUFS] = { { 0 } };
	struct v4l2_buffer b;
	int fd = *fdp, e = 0, type = CAP, gone = 0, r, op0 = V_REQBUFS0;
	unsigned int i, n = 0, nf, k;
	int64_t t0;

	f.fmt.pix.pixelformat = fmts[rnd(6)];
	e = vio(V_S_FMT, fd, VIDIOC_S_FMT, &f);
	if (e)
		return e == ENODEV;
	rb.count = 2 + rnd(MAX_BUFS - 1);
	e = vio(V_REQBUFS, fd, VIDIOC_REQBUFS, &rb);
	if (e)
		return e == ENODEV;
	n = rb.count < MAX_BUFS ? rb.count : MAX_BUFS;
	for (i = 0; i < n; i++) {
		memset(&b, 0, sizeof(b));
		b.type = CAP;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		e = vio(V_QUERYBUF, fd, VIDIOC_QUERYBUF, &b);
		if (e)
			goto out;
		op_begin(V_MMAP);
		mb[i].p = mmap(NULL, b.length, PROT_READ, MAP_SHARED, fd,
			       b.m.offset);
		e = op_end(mb[i].p == MAP_FAILED ? errno : 0);
		if (e) {
			mb[i].p = NULL;
			goto out;
		}
		mb[i].len = b.length;
	}
	for (i = 0; i < n; i++) {
		memset(&b, 0, sizeof(b));
		b.type = CAP;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		e = vio(V_QBUF, fd, VIDIOC_QBUF, &b);
		if (e)
			goto out;
	}
	e = vio(V_STREAMON, fd, VIDIOC_STREAMON, &type);
	if (e)
		goto out;
	nf = rnd(120);
	for (k = 0; k < nf && !time_up(); k++) {
		t0 = now_ns();
		do {
			r = poll(&pf, 1, 200);
		} while (r == 0 && now_ns() - t0 < 3000000000LL && !time_up());
		if (r == 0) {
			if (!time_up())
				me->stalls++;
			break;
		}
		memset(&b, 0, sizeof(b));
		b.type = CAP;
		b.memory = V4L2_MEMORY_MMAP;
		e = vio(V_DQBUF, fd, VIDIOC_DQBUF, &b);
		if (e == EAGAIN)
			continue;
		if (e)
			break;
		if (!rnd(10))
			msleep(rnd(20));
		e = vio(V_QBUF, fd, VIDIOC_QBUF, &b);
		if (e)
			break;
	}
	if (e == ENODEV)
		goto out;
	switch (rnd(20)) {
	case 0:		/* close while streaming: the release path stops it */
		for (i = 0; i < n; i++)
			if (mb[i].p)
				munmap(mb[i].p, mb[i].len);
		vclose(fd);
		*fdp = -1;
		return 1;
	case 1:		/* REQBUFS 0 while streaming: refused (EBUSY) */
		op0 = V_REQBUFS0_ON;
		break;
	default:
		e = vio(V_STREAMOFF, fd, VIDIOC_STREAMOFF, &type);
	}
out:
	gone = e == ENODEV;
	for (i = 0; i < n; i++)
		if (mb[i].p)
			munmap(mb[i].p, mb[i].len);
	if (!gone) {
		rb.count = 0;
		e = vio(op0, fd, VIDIOC_REQBUFS, &rb);
		if (op0 == V_REQBUFS0_ON && !e)
			note_unexpected(op0, "succeeded while streaming");
		gone = e == ENODEV;
	}
	return gone;
}

static void video_worker(void)
{
	int64_t last_log = 0;
	int fd = -1, gone = 0;
	unsigned int r;

	while (!time_up()) {
		if (fd < 0) {
			fd = vopen();
			if (fd < 0) {
				msleep(100 + rnd(400));
				continue;
			}
		}
		r = rnd(100);
		if (r < 50) {
			gone = vstream(&fd);
		} else if (r < 65) {
			vinfo(fd);
		} else if (r < 75) {
			vtimings(fd);
		} else if (r < 85) {
			vevents(fd);
		} else if (r < 97) {
			vclose(fd);
			fd = -1;
		} else if (now_ns() - last_log > 30000000000LL) {
			/* the kernel log: rarely */
			last_log = now_ns();
			vio(V_LOG_STATUS, fd, VIDIOC_LOG_STATUS, NULL);
		}
		if (fd >= 0 && gone) {
			vclose(fd);
			fd = -1;
		}
		gone = 0;
		if (!rnd(4))
			msleep(rnd(50));
	}
	if (fd >= 0)
		vclose(fd);
}

/* ---- audio ---- */

/* op_end() for an alsa-lib result: negative errno or >= 0 */
static int aerr(int r)
{
	return op_end(r < 0 ? -r : 0);
}

static void audio_session(void)
{
	static const unsigned int periods[] = { 480, 960, 1920, 4800 };
	snd_pcm_uframes_t period = periods[rnd(4)], buffer;
	snd_pcm_hw_params_t *hw;
	int16_t buf[4800 * 2];
	char name[32];
	snd_pcm_t *p;
	unsigned int s, k, np;
	int card = card_number(), r;

	if (card < 0) {
		msleep(200);
		return;
	}
	buffer = period * (2 + rnd(7));
	if (buffer > 96000)
		buffer = 96000;
	snprintf(name, sizeof(name), "hw:%d,0", card);
	op_begin(A_OPEN);
	r = snd_pcm_open(&p, name, SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK);
	if (aerr(r)) {
		msleep(50 + rnd(300));
		return;
	}
	snd_pcm_nonblock(p, 0);
	op_begin(A_HW_PARAMS);
	r = snd_pcm_hw_params_malloc(&hw);
	if (r < 0) {
		aerr(r);
		goto close;
	}
	r = snd_pcm_hw_params_any(p, hw);
	if (r >= 0)
		r = snd_pcm_hw_params_set_access(p, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
	if (r >= 0)
		r = snd_pcm_hw_params_set_format(p, hw, SND_PCM_FORMAT_S16_LE);
	if (r >= 0)
		r = snd_pcm_hw_params_set_channels(p, hw, 2);
	if (r >= 0)
		r = snd_pcm_hw_params_set_rate(p, hw, 48000, 0);
	if (r >= 0)
		r = snd_pcm_hw_params_set_period_size(p, hw, period, 0);
	if (r >= 0)
		r = snd_pcm_hw_params_set_buffer_size(p, hw, buffer);
	if (r >= 0)
		r = snd_pcm_hw_params(p, hw);
	snd_pcm_hw_params_free(hw);
	if (aerr(r))
		goto close;
	for (s = 0; s < 1 + rnd(4) && !time_up(); s++) {
		op_begin(A_PREPARE);
		if (aerr(snd_pcm_prepare(p)))
			break;
		op_begin(A_START);
		if (aerr(snd_pcm_start(p)))
			break;
		np = rnd(150);
		for (k = 0; k < np && !time_up(); k++) {
			op_begin(A_READ);
			r = snd_pcm_wait(p, 2000);
			if (r == 0) {
				op_end(0);
				me->stalls++;
				break;
			}
			if (r > 0)
				r = snd_pcm_readi(p, buf, period);
			if (aerr(r < 0 ? r : 0)) {
				if (r == -EPIPE) {
					op_begin(A_PREPARE);
					if (aerr(snd_pcm_prepare(p)))
						goto close;
					op_begin(A_START);
					if (aerr(snd_pcm_start(p)))
						goto close;
					continue;
				}
				goto close;
			}
		}
		op_begin(A_DROP);
		if (aerr(snd_pcm_drop(p)))
			break;
	}
close:
	op_begin(A_CLOSE);
	aerr(snd_pcm_close(p));
}

static void audio_worker(void)
{
	while (!time_up()) {
		audio_session();
		if (!rnd(3))
			msleep(rnd(200));
	}
}

/* ---- ctl: the control node, the video node, debugfs ---- */

static void ctl_worker(void)
{
	static const char *const dbg[] = { "video", "hdmi", "audio" };
	snd_ctl_card_info_t *info;
	char path[128], buf[4096];
	snd_ctl_t *ctl;
	int fd, card, r;
	ssize_t n;

	snd_ctl_card_info_malloc(&info);
	while (!time_up()) {
		switch (rnd(3)) {
		case 0:
			card = card_number();
			if (card < 0)
				break;
			snprintf(path, sizeof(path), "hw:%d", card);
			op_begin(C_CTL);
			r = snd_ctl_open(&ctl, path, SND_CTL_NONBLOCK);
			if (aerr(r))
				break;
			op_begin(C_CTL);
			aerr(snd_ctl_card_info(ctl, info));
			snd_ctl_close(ctl);
			break;
		case 1:
			fd = vopen();
			if (fd < 0)
				break;
			vinfo(fd);
			if (!rnd(4)) {
				struct v4l2_dv_timings t;

				vio(V_QUERY_DV, fd, VIDIOC_QUERY_DV_TIMINGS, &t);
			}
			vclose(fd);
			break;
		default:
			snprintf(path, sizeof(path), "/sys/kernel/debug/gc573-%s/%s",
				 bdf, dbg[rnd(3)]);
			op_begin(D_READ);
			fd = open(path, O_RDONLY | O_CLOEXEC);
			if (fd < 0) {
				op_end(errno);
				break;
			}
			do {
				n = read(fd, buf, sizeof(buf));
			} while (n > 0);
			r = n < 0 ? errno : 0;
			close(fd);
			op_end(r);
		}
		msleep(10 + rnd(90));
	}
	snd_ctl_card_info_free(info);
}

/* ---- edid ---- */

static uint8_t edid_def[256], edid_var[256];
static unsigned int edid_blocks;

static int edid_set(const uint8_t *e, unsigned int blocks)
{
	struct v4l2_edid ed = { .blocks = blocks, .edid = (uint8_t *)e };
	int fd = vopen(), r;

	if (fd < 0)
		return -1;
	r = vio(V_S_EDID, fd, VIDIOC_S_EDID, &ed);
	vclose(fd);
	if (!r)
		me->edids++;
	return r;
}

static void edid_worker(void)
{
	struct v4l2_edid ed = { .blocks = 2, .edid = edid_def };
	unsigned int i, sum = 0;
	int fd = -1, next = 1;

	/* the EDID the device has at the start: the default */
	while (!time_up() && !edid_blocks) {
		fd = vopen();
		if (fd >= 0) {
			ed.blocks = 2;
			if (!vio(V_G_EDID, fd, VIDIOC_G_EDID, &ed))
				edid_blocks = ed.blocks;
			vclose(fd);
		}
		if (!edid_blocks)
			msleep(500);
	}
	if (!edid_blocks)
		return;
	memcpy(edid_var, edid_def, sizeof(edid_def));
	edid_var[12] ^= 0x5a;		/* the serial number, bytes 12-15 */
	for (i = 0; i < 127; i++)
		sum += edid_var[i];
	edid_var[127] = (uint8_t)(256 - sum % 256);
	while (!time_up()) {
		nap(2000 + rnd(8000));
		if (time_up())
			break;
		if (!rnd(10)) {
			edid_set(edid_def, 0);	/* no EDID: the input off */
			nap(3000 + rnd(5000));
			next = 0;
		}
		if (next)
			edid_set(edid_var, edid_blocks);
		else
			edid_set(edid_def, edid_blocks);
		next = !next;
	}
	edid_set(edid_def, edid_blocks);
}

/* ---- bind ---- */

static int sysfs_write(const char *file, const char *s)
{
	int fd = open(file, O_WRONLY | O_CLOEXEC), e = 0;

	if (fd < 0)
		return errno;
	if (write(fd, s, strlen(s)) < 0)
		e = errno;
	close(fd);
	return e;
}

static int bind_wait(void)
{
	char path[64];
	int64_t t0;
	int ok = 0;

	op_begin(B_WAIT);
	for (t0 = now_ns(); now_ns() - t0 < 15000000000LL; msleep(100))
		if (bound() && !video_node(path, sizeof(path)) &&
		    card_number() >= 0) {
			ok = 1;
			break;
		}
	return op_end(ok ? 0 : ETIMEDOUT);
}

static void bind_worker(void)
{
	while (!time_up()) {
		nap(15000 + rnd(30000));
		if (time_up())
			break;
		if (bound()) {
			op_begin(B_UNBIND);
			if (op_end(sysfs_write("/sys/bus/pci/drivers/gc573/unbind", bdf)))
				continue;
			msleep(500 + rnd(2500));
		}
		op_begin(B_BIND);
		if (!op_end(sysfs_write("/sys/bus/pci/drivers/gc573/bind", bdf)))
			me->binds++;
		bind_wait();
	}
	if (!bound()) {
		op_begin(B_BIND);
		op_end(sysfs_write("/sys/bus/pci/drivers/gc573/bind", bdf));
		bind_wait();
	}
}

/* ---- the parent ---- */

static int add_worker(const char *role, int id, void (*fn)(void),
		      uint64_t seed)
{
	struct slot *s = &sh->s[sh->nslots];
	pid_t pid;

	if (sh->nslots == MAX_WORKERS)
		return -1;
	memset(s, 0, sizeof(*s));
	snprintf(s->name, sizeof(s->name), "%s.%d", role, id);
	s->op = OP_NONE;
	sh->nslots++;
	fflush(stdout);
	pid = fork();
	if (pid < 0)
		return -1;
	if (!pid) {
		me = s;
		rng = seed * 0x9e3779b97f4a7c15ULL + (uint64_t)sh->nslots * 7919 + 1;
		signal(SIGPIPE, SIG_IGN);
		fn();
		fflush(stdout);
		_exit(0);
	}
	s->pid = pid;
	return 0;
}

static void usage(void)
{
	fprintf(stderr, "usage: gc573-stress -B BDF [-t SECS] [-V N] [-A N] [-C N] [-E N] [-U] [-s SEED] [-w MS]\n");
	exit(2);
}

int main(int argc, char **argv)
{
	unsigned int secs = 600, nv = 3, na = 2, nc = 1, ne = 1, i, k;
	int ub = 0, opt, hangs = 0, alive, st;
	uint64_t seed = (uint64_t)time(NULL), ops = 0, stalls = 0, binds = 0, edids = 0;
	unsigned long unexpected = 0;
	int64_t wd = 10000, grace;
	char line[512];
	int l;

	while ((opt = getopt(argc, argv, "B:t:V:A:C:E:Us:w:")) != -1) {
		switch (opt) {
		case 'B': bdf = optarg; break;
		case 't': secs = strtoul(optarg, NULL, 0); break;
		case 'V': nv = strtoul(optarg, NULL, 0); break;
		case 'A': na = strtoul(optarg, NULL, 0); break;
		case 'C': nc = strtoul(optarg, NULL, 0); break;
		case 'E': ne = strtoul(optarg, NULL, 0); break;
		case 'U': ub = 1; break;
		case 's': seed = strtoull(optarg, NULL, 0); break;
		case 'w': wd = strtol(optarg, NULL, 0); break;
		default: usage();
		}
	}
	if (!bdf || nv + na + nc + ne + ub > MAX_WORKERS)
		usage();
	setvbuf(stdout, NULL, _IOLBF, 0);
	sh = mmap(NULL, sizeof(*sh), PROT_READ | PROT_WRITE,
		  MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (sh == MAP_FAILED) {
		perror("mmap");
		return 2;
	}
	memset(sh, 0, sizeof(*sh));
	deadline_ns = now_ns() + (int64_t)secs * 1000000000;
	printf("PARAMS bdf=%s secs=%u video=%u audio=%u ctl=%u edid=%u bind=%d seed=%llu watchdog_ms=%lld\n",
	       bdf, secs, nv, na, nc, ne, ub, (unsigned long long)seed,
	       (long long)wd);
	for (i = 0; i < nv; i++)
		add_worker("video", i, video_worker, seed);
	for (i = 0; i < na; i++)
		add_worker("audio", i, audio_worker, seed);
	for (i = 0; i < nc; i++)
		add_worker("ctl", i, ctl_worker, seed);
	for (i = 0; i < ne; i++)
		add_worker("edid", i, edid_worker, seed);
	if (ub)
		add_worker("bind", 0, bind_worker, seed);

	/* watch: an operation running too long is a hang; then wait */
	grace = 30000000000LL + wd * 1000000;
	for (;;) {
		int64_t t = now_ns();

		alive = 0;
		for (i = 0; i < (unsigned int)sh->nslots; i++) {
			struct slot *s = &sh->s[i];
			int op = __atomic_load_n(&s->op, __ATOMIC_ACQUIRE);
			int64_t lim = (op == B_UNBIND || op == B_BIND || op == B_WAIT ?
				       30000 : wd) * 1000000;

			if (s->pid > 0 && waitpid(s->pid, &st, WNOHANG) == s->pid) {
				s->pid = 0;
				if (!WIFEXITED(st) || WEXITSTATUS(st)) {
					s->died = 1;
					s->unexpected++;
					printf("UNEXPECTED %s died: %s %d\n", s->name,
					       WIFSIGNALED(st) ? "signal" : "exit",
					       WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
				}
			}
			if (s->pid > 0)
				alive++;
			if (s->pid > 0 && op != OP_NONE && !s->hung &&
			    t - s->op_t0 > lim) {
				s->hung = 1;
				hangs++;
				printf("HANG %s %s for %.1f s\n", s->name,
				       opname[op], (t - s->op_t0) / 1e9);
			}
		}
		if (!alive)
			break;
		if (t > deadline_ns)
			sh->stop = 1;
		if (t > deadline_ns + grace) {
			printf("HANG workers still running %lld s after the end: left\n",
			       (long long)(grace / 1000000000));
			hangs++;
			break;
		}
		msleep(200);
	}

	for (i = 0; i < (unsigned int)sh->nslots; i++) {
		struct slot *s = &sh->s[i];

		l = snprintf(line, sizeof(line), "WORKER %s ops=%llu errs=", s->name,
			     (unsigned long long)s->ops);
		for (k = 0, alive = 0; k < NERR; k++)
			if (s->err[k] && l < (int)sizeof(line) - 32)
				l += snprintf(line + l, sizeof(line) - l, "%s%s:%u",
					      alive++ ? "," : "",
					      k ? ename(k) : "other", s->err[k]);
		printf("%s%s unexpected=%u stalls=%llu slowest=%s:%lld ms%s%s\n", line,
		       alive ? "" : "none", s->unexpected,
		       (unsigned long long)s->stalls,
		       s->slow_ns ? opname[s->slow_op] : "-",
		       (long long)(s->slow_ns / 1000000),
		       s->unexpected ? " first: " : "",
		       s->unexpected ? s->first[0] : "");
		ops += s->ops;
		stalls += s->stalls;
		binds += s->binds;
		edids += s->edids;
		unexpected += s->unexpected;
	}
	printf("RESULT stress %s workers=%d ops=%llu unexpected=%lu hangs=%d stalls=%llu binds=%llu edids=%llu\n",
	       unexpected || hangs ? "FAIL" : "PASS", sh->nslots,
	       (unsigned long long)ops, unexpected, hangs,
	       (unsigned long long)stalls, (unsigned long long)binds,
	       (unsigned long long)edids);
	return hangs ? 3 : unexpected ? 1 : 0;
}
