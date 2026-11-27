// SPDX-License-Identifier: GPL-2.0
/*
 * Spec-session tool: a read-only BAR0 sampler for open question 41.
 * Maps BAR0 through sysfs read-only and does aligned 32-bit reads only.
 *
 *   bar0-sweep once  LOG OFF...           read each offset once, 0.2 s apart;
 *                                          LOG gets "about to read OFF" and is
 *                                          fsync'd before each read, so a hang
 *                                          leaves the culprit named
 *   bar0-sweep watch SECS US OFF...        sample every US microseconds for
 *                                          SECS; print the first sample and
 *                                          then a line per changed offset:
 *                                          CLOCK_MONOTONIC ns, offset, old, new
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define RES "/sys/bus/pci/devices/0000:07:00.0/resource0"
#define BAR_LEN 0x80000
#define MAXOFF 128

static uint64_t now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static volatile const uint32_t *map_bar(void)
{
	int fd = open(RES, O_RDONLY | O_SYNC);
	void *p;

	if (fd < 0) {
		perror(RES);
		exit(1);
	}
	p = mmap(NULL, BAR_LEN, PROT_READ, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		exit(1);
	}
	close(fd);
	return p;
}

static int parse_offs(int argc, char **argv, uint32_t *off)
{
	int n = 0;

	for (int i = 0; i < argc && n < MAXOFF; i++) {
		char *end;
		unsigned long v = strtoul(argv[i], &end, 16);

		if (*end || (v & 3) || v >= BAR_LEN) {
			fprintf(stderr, "bad offset %s\n", argv[i]);
			exit(2);
		}
		off[n++] = (uint32_t)v;
	}
	return n;
}

int main(int argc, char **argv)
{
	uint32_t off[MAXOFF], val[MAXOFF];
	volatile const uint32_t *bar;
	int n;

	if (argc >= 4 && !strcmp(argv[1], "once")) {
		FILE *log = fopen(argv[2], "a");

		if (!log) {
			perror(argv[2]);
			return 1;
		}
		n = parse_offs(argc - 3, argv + 3, off);
		bar = map_bar();
		for (int i = 0; i < n; i++) {
			fprintf(log, "about to read %#06x\n", off[i]);
			fflush(log);
			fsync(fileno(log));
			val[i] = bar[off[i] / 4];
			fprintf(log, "%#06x = %#010x\n", off[i], val[i]);
			fflush(log);
			fsync(fileno(log));
			printf("%#06x = %#010x\n", off[i], val[i]);
			usleep(200000);
		}
		fclose(log);
		return 0;
	}
	if (argc >= 5 && !strcmp(argv[1], "watch")) {
		double secs = atof(argv[2]);
		long us = atol(argv[3]);
		uint64_t t0, end, t;

		n = parse_offs(argc - 4, argv + 4, off);
		bar = map_bar();
		t0 = now_ns();
		end = t0 + (uint64_t)(secs * 1e9);
		for (int i = 0; i < n; i++)
			val[i] = bar[off[i] / 4];
		printf("%llu first", (unsigned long long)t0);
		for (int i = 0; i < n; i++)
			printf(" %#06x=%#010x", off[i], val[i]);
		printf("\n");
		while ((t = now_ns()) < end) {
			for (int i = 0; i < n; i++) {
				uint32_t v = bar[off[i] / 4];

				if (v != val[i]) {
					printf("%llu %#06x %#010x -> %#010x\n",
					       (unsigned long long)t, off[i], val[i], v);
					val[i] = v;
				}
			}
			usleep(us);
		}
		fflush(stdout);
		return 0;
	}
	fprintf(stderr, "usage: %s once LOG OFF... | watch SECS US OFF...\n", argv[0]);
	return 2;
}
