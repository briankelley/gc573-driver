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
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/videodev2.h>

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

static int usage(void)
{
	fprintf(stderr,
		"usage: gc573-sec createbufs -d DEV [-s SIZE] [-n COUNT] [-k]\n"
		"       gc573-sec subscribe -d DEV -t source_change|ctrl [-i ID]\n");
	return 2;
}

int main(int argc, char **argv)
{
	const char *dev = NULL, *type = NULL, *cmd;
	unsigned long size = 0;
	unsigned int count = 1;
	int opt, keep = 0;
	long id = -1;

	if (argc < 2)
		return usage();
	cmd = argv[1];
	optind = 2;
	while ((opt = getopt(argc, argv, "d:s:n:kt:i:")) != -1) {
		switch (opt) {
		case 'd': dev = optarg; break;
		case 's': size = strtoul(optarg, NULL, 0); break;
		case 'n': count = strtoul(optarg, NULL, 0); break;
		case 'k': keep = 1; break;
		case 't': type = optarg; break;
		case 'i': id = strtol(optarg, NULL, 0); break;
		default: return usage();
		}
	}
	if (!dev)
		return usage();
	if (!strcmp(cmd, "createbufs"))
		return cmd_createbufs(dev, size, count, keep);
	if (!strcmp(cmd, "subscribe") && type)
		return cmd_subscribe(dev, type, id);
	return usage();
}
