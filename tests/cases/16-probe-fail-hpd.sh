#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# M3 review: a probe that fails after the HDMI chips came up must leave HPD
# low. bpftrace overrides gc573_video_init() (ALLOW_ERROR_INJECTION) with
# -ENOMEM for one bind; after that failed probe GPIO bit 2, the IT6805-side
# HPD (spec/hdmi-chips.md), must read 0 through resource0 (no driver holds
# the BAR then). First, as a check of the method: bit 2 reads 1 while bound
# (debugfs) and 0 after a normal unbind. SKIP without bpftrace, or when the
# kernel cannot override the function (CONFIG_FUNCTION_ERROR_INJECTION,
# CONFIG_BPF_KPROBE_OVERRIDE).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/../lib.sh"

command -v bpftrace >/dev/null || skip "bpftrace not installed"
tmp=$(mktemp -d)
bt=""
trap '[ -n "$bt" ] && kill "$bt" 2>/dev/null; rm -rf "$tmp"' EXIT

# One aligned 32-bit read of BAR0 through resource0
cat > "$tmp/bar32.c" <<'EOF'
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

int main(int argc, char **argv)
{
	unsigned long off = argc == 3 ? strtoul(argv[2], NULL, 0) : 1;
	volatile uint32_t *p;
	char *m;
	int fd;

	if (off & 3)
		return 2;
	fd = open(argv[1], O_RDWR | O_SYNC);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	m = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, off & ~4095UL);
	if (m == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	p = (volatile uint32_t *)(m + (off & 4095));
	printf("0x%08x\n", *p);
	return 0;
}
EOF
gcc -O2 -Wall -o "$tmp/bar32" "$tmp/bar32.c" || fail "cannot build bar32"
res=/sys/bus/pci/devices/$GC573_BDF/resource0
drv=/sys/bus/pci/drivers/$GC573_MOD
hpd() { echo $(( ($1 >> 2) & 1 )); }

gc573_load || fail "insmod failed"
gc573_bound || { gc573_unload; fail "not bound"; }
grep -q '^gc573_video_init' /sys/kernel/debug/error_injection/list 2>/dev/null || {
	gc573_unload
	skip "gc573_video_init not in the error injection list"
}
g=$(sed -n 's/^hdmi:.* gpio \(0x[0-9a-f]*\).*/\1/p' "$(gc573_hdmi_debugfs)")
echo "bound: GPIO $g, HPD $(hpd "$g")"
echo "$GC573_BDF" > "$drv/unbind"
g0=$("$tmp/bar32" "$res" 0x040)
echo "unbound: GPIO $g0, HPD $(hpd "$g0")"

bpftrace --unsafe -e 'kprobe:gc573_video_init { override(-12); }' > "$tmp/bt" 2>&1 &
bt=$!
for _ in $(seq 100); do
	grep -q '^Attaching' "$tmp/bt" && break
	sleep 0.1
done
sleep 1
echo "$GC573_BDF" > "$drv/bind" 2> "$tmp/bind"
brc=$?
kill "$bt" 2>/dev/null
wait "$bt" 2>/dev/null
bt=""
g1=$("$tmp/bar32" "$res" 0x040)
echo "bind with gc573_video_init failing: exit $brc ($(cat "$tmp/bind")), GPIO $g1, HPD $(hpd "$g1")"
echo "bpftrace: $(head -1 "$tmp/bt")"
bound=0
gc573_bound && bound=1
gc573_unload || fail "rmmod failed"

# the probe failure itself is the point of the case
echo 'error -ENOMEM: cannot register video device' >> "$GC573_KMSG_ALLOW"
[ "$(hpd "$g")" = 1 ] || fail "HPD not high while bound: method check"
[ "$(hpd "$g0")" = 0 ] || fail "HPD not low after unbind: method check"
[ "$brc" != 0 ] && [ "$bound" = 0 ] || fail "the probe did not fail (bpftrace override)"
[ "$(hpd "$g1")" = 0 ] || fail "HPD left high by the failed probe"
echo "failed probe: HPD low"
