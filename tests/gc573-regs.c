// SPDX-License-Identifier: GPL-2.0
/*
 * Read GC573 BAR0 registers through the PCI resource file, mapped
 * read-only, with 32-bit loads; print "OFFSET VALUE" per word. Only for
 * offsets spec/regmap.md lists: reads have no known side effect there (no
 * scaler AP_CTRL, whose done bit clears on read, no I2C engine registers).
 *
 * Usage: gc573-regs RESOURCE0 SPEC...
 *   SPEC: an offset (0x1000) or an inclusive range in steps of 4 (0x200-0x21c)
 * Build: gcc -O2 -Wall -o gc573-regs gc573-regs.c
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	volatile const uint32_t *bar;
	unsigned long a, b, o;
	struct stat st;
	char *end;
	int fd, i;

	if (argc < 3) {
		fprintf(stderr, "usage: %s RESOURCE0 OFF|OFF-END...\n", argv[0]);
		return 2;
	}
	fd = open(argv[1], O_RDONLY | O_SYNC);
	if (fd < 0 || fstat(fd, &st) < 0) {
		perror(argv[1]);
		return 1;
	}
	bar = mmap(NULL, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
	if (bar == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	for (i = 2; i < argc; i++) {
		a = strtoul(argv[i], &end, 0);
		b = *end == '-' ? strtoul(end + 1, &end, 0) : a;
		if (*end || (a & 3) || b < a || b + 4 > (unsigned long)st.st_size) {
			fprintf(stderr, "bad offset or range: %s\n", argv[i]);
			return 2;
		}
		for (o = a; o <= b; o += 4)
			printf("0x%05lx 0x%08x\n", o, bar[o / 4]);
	}
	return 0;
}
