// SPDX-License-Identifier: GPL-2.0
/*
 * gc573-sec: single ioctls the security-review tests need
 * (tests/cases/20-ioctl-limits.sh), each with its result on one line.
 *
 * gc573-sec createbufs -d /dev/videoN [-s SIZE] [-n COUNT] [-k]
 *     VIDIOC_CREATE_BUFS of COUNT (default 1) MMAP buffers whose format is
 *     G_FMT's with sizeimage SIZE (default: G_FMT's). Prints
 *     "createbufs size=SIZE count=COUNT rc=0 granted=N index=I" or
 *     "... rc=-1 errno=NAME". -k: then print "held" and keep the buffers
 *     (the file open) until stdin reaches EOF, then close.
 * gc573-sec subscribe -d /dev/videoN -t source_change|ctrl [-i ID]
 *     VIDIOC_SUBSCRIBE_EVENT of that type and id (default 0), for a
 *     control event the id of V4L2_CID_DV_RX_POWER_PRESENT if no -i.
 *     Prints "subscribe type=T id=ID rc=0" or "... rc=-1 errno=NAME".
 * gc573-sec stopoff -d /dev/videoN [-n FRAMES] [-b BUFS]
 *     (tests/cases/22-stop-fault.sh) BUFS (4) MMAP buffers stream FRAMES
 *     (120) frames, then STREAMOFF ("streamoff rc=..."; the test makes
 *     that stop count as failed), then LOG_STATUS, G_EDID and S_EDID of 0
 *     blocks on the same file ("ioctl NAME rc=... errno=..."), then
 *     REQBUFS 0 gives the buffers back to the driver while they stay
 *     mapped ("ioctl REQBUFS0 rc=..."). Exit 0 once all ran.
 *
 * Exit status: 0 = the ioctl succeeded, 1 = it failed, 2 = usage or setup
 * error.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define STOPOFF_BUFS	32

static int usage(void);

static const char *ename(int e)
{
	const char *n = strerrorname_np(e);

	return n ? n : "?";
}

static int vopen(const char *dev)
{
	int fd = open(dev, O_RDWR);

	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", dev, strerror(errno));
		exit(2);
	}
	return fd;
}

static int cmd_createbufs(const char *dev, unsigned long size, unsigned int count,
			  int keep)
{
	struct v4l2_create_buffers cb;
	char buf[64];
	int fd, rc, err;

	fd = vopen(dev);
	memset(&cb, 0, sizeof(cb));
	cb.count = count;
	cb.memory = V4L2_MEMORY_MMAP;
	cb.format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	if (ioctl(fd, VIDIOC_G_FMT, &cb.format)) {
		fprintf(stderr, "G_FMT: %s\n", strerror(errno));
		return 2;
	}
	if (!size)
		size = cb.format.fmt.pix.sizeimage;
	cb.format.fmt.pix.sizeimage = size;
	rc = ioctl(fd, VIDIOC_CREATE_BUFS, &cb);
	err = errno;
	if (rc)
		printf("createbufs size=%lu count=%u rc=%d errno=%s\n", size, count,
		       rc, ename(err));
	else
		printf("createbufs size=%lu count=%u rc=0 granted=%u index=%u\n",
		       size, count, cb.count, cb.index);
	fflush(stdout);
	if (!rc && keep) {
		printf("held\n");
		fflush(stdout);
		while (read(0, buf, sizeof(buf)) > 0)
			;
	}
	close(fd);
	return rc ? 1 : 0;
}

static int cmd_subscribe(const char *dev, const char *type, long id)
{
	struct v4l2_event_subscription sub;
	int fd, rc, err;

	memset(&sub, 0, sizeof(sub));
	if (!strcmp(type, "source_change")) {
		sub.type = V4L2_EVENT_SOURCE_CHANGE;
		sub.id = id < 0 ? 0 : id;
	} else if (!strcmp(type, "ctrl")) {
		sub.type = V4L2_EVENT_CTRL;
		sub.id = id < 0 ? V4L2_CID_DV_RX_POWER_PRESENT : id;
	} else {
		fprintf(stderr, "unknown event type %s\n", type);
		return 2;
	}
	fd = vopen(dev);
	rc = ioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub);
	err = errno;
	if (rc)
		printf("subscribe type=%s id=%u rc=%d errno=%s\n", type, sub.id, rc,
		       ename(err));
	else
		printf("subscribe type=%s id=%u rc=0\n", type, sub.id);
	close(fd);
	return rc ? 1 : 0;
}

static void stopoff_ioctl(int fd, const char *name, unsigned long req, void *arg)
{
	int rc = ioctl(fd, req, arg);
	int err = errno;

	if (rc)
		printf("ioctl %s rc=%d errno=%s\n", name, rc, ename(err));
	else
		printf("ioctl %s rc=0\n", name);
}

static int cmd_stopoff(const char *dev, unsigned int frames, unsigned int nbufs)
{
	enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
	struct v4l2_requestbuffers rb;
	unsigned char edid[256];
	struct v4l2_buffer b;
	struct v4l2_edid e;
	unsigned int i, got = 0;
	void *map;
	int fd, rc, err;

	if (!nbufs || nbufs > STOPOFF_BUFS)
		return usage();
	fd = vopen(dev);
	memset(&rb, 0, sizeof(rb));
	rb.count = nbufs;
	rb.type = type;
	rb.memory = V4L2_MEMORY_MMAP;
	if (ioctl(fd, VIDIOC_REQBUFS, &rb) || rb.count < 1) {
		fprintf(stderr, "REQBUFS: %s\n", strerror(errno));
		return 2;
	}
	nbufs = rb.count;
	for (i = 0; i < nbufs; i++) {
		memset(&b, 0, sizeof(b));
		b.type = type;
		b.memory = V4L2_MEMORY_MMAP;
		b.index = i;
		if (ioctl(fd, VIDIOC_QUERYBUF, &b)) {
			fprintf(stderr, "QUERYBUF: %s\n", strerror(errno));
			return 2;
		}
		map = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED,
			   fd, b.m.offset);
		if (map == MAP_FAILED || ioctl(fd, VIDIOC_QBUF, &b)) {
			fprintf(stderr, "mmap/QBUF: %s\n", strerror(errno));
			return 2;
		}
	}
	if (ioctl(fd, VIDIOC_STREAMON, &type)) {
		fprintf(stderr, "STREAMON: %s\n", strerror(errno));
		return 2;
	}
	while (got < frames) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN };

		if (poll(&pfd, 1, 2000) != 1) {
			fprintf(stderr, "no frame within 2 s after %u\n", got);
			return 2;
		}
		memset(&b, 0, sizeof(b));
		b.type = type;
		b.memory = V4L2_MEMORY_MMAP;
		if (ioctl(fd, VIDIOC_DQBUF, &b) || ioctl(fd, VIDIOC_QBUF, &b)) {
			fprintf(stderr, "DQBUF/QBUF: %s\n", strerror(errno));
			return 2;
		}
		got++;
	}
	printf("streamed %u frames in %u buffers\n", got, nbufs);
	rc = ioctl(fd, VIDIOC_STREAMOFF, &type);
	err = errno;
	if (rc)
		printf("streamoff rc=%d errno=%s\n", rc, ename(err));
	else
		printf("streamoff rc=0\n");

	stopoff_ioctl(fd, "LOG_STATUS", VIDIOC_LOG_STATUS, NULL);
	memset(&e, 0, sizeof(e));
	e.blocks = 2;
	e.edid = edid;
	stopoff_ioctl(fd, "G_EDID", VIDIOC_G_EDID, &e);
	memset(&e, 0, sizeof(e));
	e.edid = edid;
	stopoff_ioctl(fd, "S_EDID", VIDIOC_S_EDID, &e);

	/* back to the driver while still mapped: the mappings go at exit */
	memset(&rb, 0, sizeof(rb));
	rb.type = type;
	rb.memory = V4L2_MEMORY_MMAP;
	stopoff_ioctl(fd, "REQBUFS0", VIDIOC_REQBUFS, &rb);
	return 0;
}

static int usage(void)
{
	fprintf(stderr,
		"usage: gc573-sec createbufs -d DEV [-s SIZE] [-n COUNT] [-k]\n"
		"       gc573-sec subscribe -d DEV -t source_change|ctrl [-i ID]\n"
		"       gc573-sec stopoff -d DEV [-n FRAMES] [-b BUFS]\n");
	return 2;
}

int main(int argc, char **argv)
{
	const char *dev = NULL, *type = NULL, *cmd;
	unsigned int count = 0, bufs = 4;
	unsigned long size = 0;
	int opt, keep = 0;
	long id = -1;

	if (argc < 2)
		return usage();
	cmd = argv[1];
	optind = 2;
	while ((opt = getopt(argc, argv, "d:s:n:kt:i:b:")) != -1) {
		switch (opt) {
		case 'd': dev = optarg; break;
		case 's': size = strtoul(optarg, NULL, 0); break;
		case 'n': count = strtoul(optarg, NULL, 0); break;
		case 'k': keep = 1; break;
		case 't': type = optarg; break;
		case 'i': id = strtol(optarg, NULL, 0); break;
		case 'b': bufs = strtoul(optarg, NULL, 0); break;
		default: return usage();
		}
	}
	if (!dev)
		return usage();
	if (!strcmp(cmd, "createbufs"))
		return cmd_createbufs(dev, size, count ? count : 1, keep);
	if (!strcmp(cmd, "subscribe") && type)
		return cmd_subscribe(dev, type, id);
	if (!strcmp(cmd, "stopoff"))
		return cmd_stopoff(dev, count ? count : 120, bufs);
	return usage();
}
