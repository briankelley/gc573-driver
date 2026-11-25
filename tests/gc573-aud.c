// SPDX-License-Identifier: GPL-2.0
/*
 * gc573-aud: ALSA capture test tool for the GC573 driver (M4), with an
 * optional V4L2 capture beside it for A/V timing. Build: gcc -O2 -Wall
 * gc573-aud.c -lasound -lm (needs libasound2-dev).
 *
 * gc573-aud [-D PCM] [-t SECS] [-p FRAMES] [-b FRAMES] [-o FILE] [-v]
 *           [-M FILE] [-V DEV [-P]] [-x SECS] [-s]
 *
 *   -D PCM     ALSA PCM (default hw:CARD=GC573,DEV=0)
 *   -t SECS    capture time (default 5)
 *   -p FRAMES  period size (default 480, one hardware period: every
 *              period then updates the timestamp), -b buffer (default 9600)
 *   -o FILE    write the samples (S16_LE, 2 channels) to FILE
 *   -v         one line per read: "A frames=N hw=N ts_ns=T peak=L,R"
 *              (hw: frames captured so far = read + avail; ts_ns: when the
 *              hardware pointer last moved, CLOCK_MONOTONIC)
 *   -M FILE    with -v: add AUDIO_SAMPLE_PERIOD (0x10a0), AUDIO_DONE
 *              (0x014) and DMA_RUN (0x008), read from BAR0 through FILE
 *              (the device's sysfs resource0, mapped read-only)
 *   -V DEV     also capture video from DEV: the current DV timings, YUYV,
 *              4 buffers; one line per frame "V seq=N ts_ns=T y=MEAN"
 *              (mean luma of a 16 x 9 grid; vb2 timestamp, CLOCK_MONOTONIC)
 *   -P         with -V, the picture of avsync.sh --pattern and show.sh
 *              --counter (tools/testsrc/counter-graph.sh): y is the mean
 *              luma of the flash box, and "c=N" the frame counter, -1 when
 *              a bit is neither black nor white (a torn or blended frame)
 *   -x SECS   on an overrun (-EPIPE) recover and go on, at most SECS
 *              apart, instead of failing at once
 *   -s SECS    stop/start: drop and restart the stream every SECS; each
 *              start prints "START at=SECS frames=N" (frames read so far)
 *
 * Output: "PARAMS ...", the lines above, "XRUN at=SECS" per overrun, and
 * at the end "RESULT audio frames=N secs=S rate=R xruns=N". Exit status:
 * 0 = ran, 1 = a read failed, 2 = usage or setup error.
 */
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
#include <time.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define RATE		48000
#define CHANNELS	2
#define NBUFS		4

static volatile uint32_t *bar;
static int vfd = -1;
static void *vbuf[NBUFS];
static size_t vlen[NBUFS];
static unsigned int vw, vh, vstride;
static int pattern;

static uint64_t now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int r;

	do
		r = ioctl(fd, req, arg);
	while (r < 0 && errno == EINTR);
	return r;
}

static int video_open(const char *dev)
{
	struct v4l2_dv_timings t = { 0 };
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
	struct v4l2_requestbuffers rb = { 0 };
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	unsigned int i;

	vfd = open(dev, O_RDWR | O_NONBLOCK);
	if (vfd < 0 || xioctl(vfd, VIDIOC_QUERY_DV_TIMINGS, &t) ||
	    xioctl(vfd, VIDIOC_S_DV_TIMINGS, &t)) {
		perror("video: open/QUERY/S_DV_TIMINGS");
		return -1;
	}
	f.fmt.pix.width = t.bt.width;
	f.fmt.pix.height = t.bt.height;
	f.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
	f.fmt.pix.field = V4L2_FIELD_NONE;
	if (xioctl(vfd, VIDIOC_S_FMT, &f)) {
		perror("video: S_FMT");
		return -1;
	}
	vw = f.fmt.pix.width;
	vh = f.fmt.pix.height;
	vstride = f.fmt.pix.bytesperline;
	rb.count = NBUFS;
	rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	rb.memory = V4L2_MEMORY_MMAP;
	if (xioctl(vfd, VIDIOC_REQBUFS, &rb) || rb.count != NBUFS) {
		perror("video: REQBUFS");
		return -1;
	}
	for (i = 0; i < NBUFS; i++) {
		struct v4l2_buffer b = {
			.type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
			.memory = V4L2_MEMORY_MMAP, .index = i,
		};

		if (xioctl(vfd, VIDIOC_QUERYBUF, &b))
			return -1;
		vlen[i] = b.length;
		vbuf[i] = mmap(NULL, b.length, PROT_READ, MAP_SHARED, vfd,
			       b.m.offset);
		if (vbuf[i] == MAP_FAILED || xioctl(vfd, VIDIOC_QBUF, &b)) {
			perror("video: mmap/QBUF");
			return -1;
		}
	}
	if (xioctl(vfd, VIDIOC_STREAMON, &type)) {
		perror("video: STREAMON");
		return -1;
	}
	printf("PARAMS video %ux%u YUYV %.4f Hz\n", vw, vh,
	       (double)t.bt.pixelclock / (V4L2_DV_BT_FRAME_WIDTH(&t.bt) *
					  V4L2_DV_BT_FRAME_HEIGHT(&t.bt)));
	return 0;
}

/* Mean luma of [x0, x1) x [y0, y1) in a YUYV frame, every other pixel */
static unsigned int box_luma(const uint8_t *p, unsigned int x0,
			     unsigned int y0, unsigned int x1, unsigned int y1)
{
	unsigned long sum = 0, n = 0;
	unsigned int x, y;

	for (y = y0; y < y1; y += 2)
		for (x = x0; x < x1; x += 2, n++)
			sum += p[y * vstride + x * 2];
	return n ? sum / n : 0;
}

/*
 * The counter picture (counter-graph.sh; tests/obs-events.py geometry()):
 * bit k a square of B = H/27 pixels at x = W/16 + k * 3B/2, y = 4H/5 +
 * (H/5 - B)/2, read B/4 inside its edges; the flash box from 11W/16 to
 * 15W/16 on the same rows. Returns the counter, or -1 if a bit is neither
 * black nor white; *flash: the box's mean luma
 */
static int read_counter(const uint8_t *p, unsigned int *flash)
{
	unsigned int b = vh / 27, step = b * 3 / 2, x0 = vw / 16, q = b / 4;
	unsigned int y0 = vh * 4 / 5 + (vh - vh * 4 / 5 - b) / 2;
	int k, c = 0;

	*flash = box_luma(p, vw * 11 / 16 + 2 * q, y0, vw * 15 / 16 - 2 * q,
			  y0 + b);
	for (k = 0; k < 16; k++) {
		unsigned int y = box_luma(p, x0 + k * step + q, y0 + q,
					  x0 + k * step + b - q, y0 + b - q);

		if (y >= 64 && y <= 192)
			return -1;
		c |= (y > 128) << k;
	}
	return c;
}

/* Dequeue every completed frame, print it, requeue it */
static int video_service(void)
{
	for (;;) {
		struct v4l2_buffer b = {
			.type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
			.memory = V4L2_MEMORY_MMAP,
		};
		const uint8_t *p;
		unsigned int x, y, sum = 0;
		unsigned long long ts;

		if (xioctl(vfd, VIDIOC_DQBUF, &b)) {
			if (errno == EAGAIN)
				return 0;
			perror("video: DQBUF");
			return -1;
		}
		p = vbuf[b.index];
		ts = b.timestamp.tv_sec * 1000000000ull +
		     b.timestamp.tv_usec * 1000ull;
		if (pattern) {
			int c = read_counter(p, &y);

			printf("V seq=%u ts_ns=%llu y=%u c=%d\n", b.sequence,
			       ts, y, c);
		} else {
			for (y = 0; y < 9; y++)
				for (x = 0; x < 16; x++)
					sum += p[(vh * (2 * y + 1) / 18) *
						 vstride +
						 (vw * (2 * x + 1) / 32) * 2];
			printf("V seq=%u ts_ns=%llu y=%u\n", b.sequence, ts,
			       sum / 144);
		}
		if (xioctl(vfd, VIDIOC_QBUF, &b)) {
			perror("video: QBUF");
			return -1;
		}
	}
}

static int bar_open(const char *path)
{
	int fd = open(path, O_RDONLY | O_SYNC);
	void *p;

	if (fd < 0)
		return -1;
	p = mmap(NULL, 0x2000, PROT_READ, MAP_SHARED, fd, 0);
	close(fd);
	if (p == MAP_FAILED)
		return -1;
	bar = p;
	return 0;
}

static snd_pcm_t *pcm_open(const char *dev, snd_pcm_uframes_t period,
			   snd_pcm_uframes_t buffer)
{
	snd_pcm_hw_params_t *hw;
	snd_pcm_sw_params_t *sw;
	snd_pcm_t *pcm;
	int r;

	r = snd_pcm_open(&pcm, dev, SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK);
	if (r < 0) {
		fprintf(stderr, "snd_pcm_open %s: %s\n", dev, snd_strerror(r));
		return NULL;
	}
	snd_pcm_hw_params_alloca(&hw);
	snd_pcm_hw_params_any(pcm, hw);
	r = snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
	if (!r)
		r = snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_S16_LE);
	if (!r)
		r = snd_pcm_hw_params_set_channels(pcm, hw, CHANNELS);
	if (!r)
		r = snd_pcm_hw_params_set_rate(pcm, hw, RATE, 0);
	if (!r)
		r = snd_pcm_hw_params_set_period_size(pcm, hw, period, 0);
	if (!r)
		r = snd_pcm_hw_params_set_buffer_size(pcm, hw, buffer);
	if (!r)
		r = snd_pcm_hw_params(pcm, hw);
	if (r < 0) {
		fprintf(stderr, "hw_params: %s\n", snd_strerror(r));
		snd_pcm_close(pcm);
		return NULL;
	}
	snd_pcm_sw_params_alloca(&sw);
	snd_pcm_sw_params_current(pcm, sw);
	r = snd_pcm_sw_params_set_tstamp_mode(pcm, sw, SND_PCM_TSTAMP_ENABLE);
	if (!r)
		r = snd_pcm_sw_params_set_tstamp_type(pcm, sw,
						SND_PCM_TSTAMP_TYPE_MONOTONIC);
	if (!r)
		r = snd_pcm_sw_params_set_avail_min(pcm, sw, period);
	if (!r)
		r = snd_pcm_sw_params(pcm, sw);
	if (r < 0) {
		fprintf(stderr, "sw_params: %s\n", snd_strerror(r));
		snd_pcm_close(pcm);
		return NULL;
	}
	return pcm;
}

int main(int argc, char **argv)
{
	const char *dev = "hw:CARD=GC573,DEV=0", *out = NULL, *vdev = NULL;
	snd_pcm_uframes_t period = 480, buffer = 9600;
	double secs = 5, xrun_gap = -1, last_xrun = -1e9;
	unsigned long long read_total = 0, nxrun = 0, nrestart = 0;
	uint64_t t0, t_first = 0, t_last = 0, hw_first = 0, hw_last = 0;
	double stress = 0;
	int verbose = 0, opt, ret = 0;
	snd_pcm_status_t *st;
	snd_pcm_t *pcm;
	int16_t *buf;
	FILE *of = NULL;
	double next_restart;

	while ((opt = getopt(argc, argv, "D:t:p:b:o:vM:V:Px:s:")) != -1) {
		switch (opt) {
		case 'D': dev = optarg; break;
		case 't': secs = atof(optarg); break;
		case 'p': period = strtoul(optarg, NULL, 0); break;
		case 'b': buffer = strtoul(optarg, NULL, 0); break;
		case 'o': out = optarg; break;
		case 'v': verbose = 1; break;
		case 'M':
			if (bar_open(optarg)) {
				perror(optarg);
				return 2;
			}
			break;
		case 'V': vdev = optarg; break;
		case 'P': pattern = 1; break;
		case 'x': xrun_gap = atof(optarg); break;
		case 's': stress = atof(optarg); break;
		default:
			fprintf(stderr, "usage: see the comment in gc573-aud.c\n");
			return 2;
		}
	}
	if (out) {
		of = fopen(out, "w");
		if (!of) {
			perror(out);
			return 2;
		}
	}
	buf = malloc(buffer * CHANNELS * 2);
	pcm = pcm_open(dev, period, buffer);
	if (!buf || !pcm)
		return 2;
	if (vdev && video_open(vdev))
		return 2;
	printf("PARAMS audio %s rate=%u channels=%u period=%lu buffer=%lu\n",
	       dev, RATE, CHANNELS, period, buffer);
	snd_pcm_status_alloca(&st);

	t0 = now_ns();
	next_restart = stress;
	if (snd_pcm_start(pcm) < 0)
		return 2;
	for (;;) {
		struct pollfd pfd[8];
		int n = snd_pcm_poll_descriptors(pcm, pfd, 7);
		double el = (now_ns() - t0) / 1e9;
		snd_pcm_sframes_t r;

		if (el >= secs)
			break;
		if (stress > 0 && el >= next_restart) {
			next_restart += stress;
			snd_pcm_drop(pcm);
			snd_pcm_prepare(pcm);
			snd_pcm_start(pcm);
			nrestart++;
			printf("START at=%.3f frames=%llu\n", el, read_total);
		}
		if (vfd >= 0) {
			pfd[n].fd = vfd;
			pfd[n].events = POLLIN;
			pfd[n].revents = 0;
			n++;
		}
		if (poll(pfd, n, 1000) < 0 && errno != EINTR) {
			perror("poll");
			ret = 1;
			break;
		}
		if (vfd >= 0 && (pfd[n - 1].revents & POLLIN) && video_service()) {
			ret = 1;
			break;
		}
		r = snd_pcm_readi(pcm, buf, buffer);
		if (r == -EAGAIN)
			continue;
		if (r == -EPIPE) {
			nxrun++;
			printf("XRUN at=%.3f\n", el);
			if (xrun_gap < 0 || el - last_xrun < xrun_gap) {
				ret = 1;
				break;
			}
			last_xrun = el;
			snd_pcm_prepare(pcm);
			snd_pcm_start(pcm);
			continue;
		}
		if (r < 0) {
			fprintf(stderr, "read: %s\n", snd_strerror(r));
			ret = 1;
			break;
		}
		read_total += r;
		if (of)
			fwrite(buf, CHANNELS * 2, r, of);
		if (snd_pcm_status(pcm, st) == 0) {
			snd_htimestamp_t ts;
			uint64_t tns, hw;

			snd_pcm_status_get_htstamp(st, &ts);
			tns = ts.tv_sec * 1000000000ull + ts.tv_nsec;
			hw = read_total + snd_pcm_status_get_avail(st);
			if (!t_first) {
				t_first = tns;
				hw_first = hw;
			}
			t_last = tns;
			hw_last = hw;
			if (verbose) {
				int pl = 0, pr = 0, i;

				for (i = 0; i < r; i++) {
					int l = abs(buf[2 * i]), rr = abs(buf[2 * i + 1]);

					if (l > pl)
						pl = l;
					if (rr > pr)
						pr = rr;
				}
				printf("A frames=%llu hw=%llu ts_ns=%llu peak=%d,%d",
				       read_total, (unsigned long long)hw,
				       (unsigned long long)tns, pl, pr);
				if (bar)
					printf(" sp=%08x done=%u run=%08x",
					       bar[0x10a0 / 4], bar[0x014 / 4] & 3,
					       bar[0x008 / 4]);
				printf("\n");
			}
		}
	}
	snd_pcm_drop(pcm);
	snd_pcm_close(pcm);
	if (of)
		fclose(of);
	printf("RESULT audio frames=%llu secs=%.3f rate=%.3f xruns=%llu restarts=%llu\n",
	       read_total, (t_last - t_first) / 1e9,
	       t_last > t_first ? (hw_last - hw_first) * 1e9 / (t_last - t_first) : 0,
	       nxrun, nrestart);
	return ret;
}
