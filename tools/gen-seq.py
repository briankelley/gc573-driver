#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Generate src/gc573_seq.[ch] from the register sequences in the spec/seq tables.

The driver runs named segments (row ranges) of these tables through a small
engine (src/gc573_chip.c); driver code decides which segment runs when.
This script owns the mapping from the tables' free-text columns to codes:
  - 'cond:' notes -> condition ids. Static conditions are flags the caller
    sets; dynamic ones are evaluated by the engine from a value read
    earlier in the same run (for example "ab was ca"). A segment can
    "assume" a condition: the driver only runs it when that holds.
  - X rows -> step ids, implemented in driver code (chapter procedures).
  - {expr} values and MODE rows -> variable ids, computed by driver code.
  - captures: named rows whose read value driver code needs.
Every note, X step or expression inside a segment must have a mapping, or
the script stops; each segment also pins its first and last row
(op, dev, reg), so renumbered or edited tables are caught. The dual-pixel
stable-entry tables must differ from the single-pixel one only in rows
that are mapped to variables or steps here.

Usage: tools/gen-seq.py [--check]   (--check: fail if the output differs)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEQ = os.path.join(ROOT, 'spec', 'seq')

# ---- conditions -------------------------------------------------------------
# (name, dynamic test or None for a caller flag, description)
# dynamic test: (dev, bank, reg, mask, value, equal): true when
# ((last value read from dev/bank:reg in this run) & mask) == value is equal
CONDS = [
    ('NEVER', None, 'row RD runs only in an untraced case or for its log: skipped'),
    ('TIMER', None, 'optional chip-timer rows (hdmi-splitter.md 5.3): skipped'),
    ('EDID_TOGGLE', None, 'EDID change while the source saw HPD high'),
    ('EQ_STORED', None, 'a stored EQ result is re-applied at lock'),
    ('NO_EQ_SEARCH', None, 'no EQ search is running'),
    ('RX10_2', None, 'RX event 0x10 bit2 was set'),
    ('LOCK_LOST', None, 'RX 0x06 bit0 with 0x13 bit7 = 0'),
    ('NO_EQ_STORED', None, 'no stored EQ result'),
    ('RX12_7', None, 'RX event 0x12 bit7 was set'),
    ('AB_CA', (0x70, 3, 0xab, 0xff, 0xca, True), '70/3:ab read ca'),
    ('AB_NOT_CA', (0x70, 3, 0xab, 0xff, 0xca, False), '70/3:ab did not read ca'),
    ('TX1_HPD', (0x6a, None, 0x03, 0x01, 0x01, True), '6a:03 bit0 read 1'),
    ('PLL_LOST', (0x6a, None, 0x03, 0x08, 0x00, True), '6a:03 bit3 read 0'),
    ('PATH_PRESTEP', (0x58, 0, 0x0d, 0xff, 0x00, True), '58/0:0d read 00'),
    ('TIMER1_EXPIRED', (0x58, 0, 0x07, 0x20, 0x20, True), '58/0:07 bit5 read 1'),
]

# 'cond:' note text (up to the first ';') -> condition
COND_TEXT = [
    (r'^only if 6a:03 bit0 = 0 and 6c:03 bit0 = 0', 'TIMER'),
    (r'^only if neither port 1 nor port 2 has HPD', 'TIMER'),
    (r'^HPD was high \(content change while connected\)', 'EDID_TOGGLE'),
    (r'^RD sleep with HPD low', 'EDID_TOGGLE'),
    (r'^end of the change toggle', 'EDID_TOGGLE'),
    (r'^ab was ca', 'AB_CA'),
    (r'^ab was not ca', 'AB_NOT_CA'),
    (r'^0x06 bit0 with 0x13 bit7 = 0 \(lock lost\)', 'LOCK_LOST'),
    (r'^stored EQ result for this mode', 'EQ_STORED'),
    (r'^no stored EQ result', 'NO_EQ_STORED'),
    (r'^0x10 bit2 set', 'RX10_2'),
    (r'^0x12 bit7', 'RX12_7'),
    (r'^0x07 bit5 and 0x70 reg 0x14 bits 5:3 = 0', 'NEVER'),
    (r'^0x07 bit5', 'TIMER1_EXPIRED'),
    (r'^PLL recovery, only if 0x03 bit3 = 0', 'PLL_LOST'),
    (r'^RD reads it for RGB/4:4:4 input', 'NEVER'),
    (r'^RD reads it only if valid and count', 'NEVER'),
    (r'^second check for 4:2:0 8-bit input', 'NEVER'),
]

# conditions the tables give in prose rather than in a 'cond:' note
EXTRA_COND = {}
for n in range(49, 54):			# "if no EQ search runs: ... W 27-29 = 81"
    EXTRA_COND[('splitter-rx-signal-loss', n)] = 'NO_EQ_SEARCH'
for n in range(7, 12):			# row 6: "path pre-step only if 00"
    EXTRA_COND[('splitter-tx1-output-enable', n)] = 'PATH_PRESTEP'
for lo, hi in ((30, 40), (41, 52), (64, 74), (75, 86)):	# "skip if no HPD"
    for n in range(lo, hi):
        EXTRA_COND[('splitter-tx1-output-enable', n)] = 'TX1_HPD'

# ---- X steps ----------------------------------------------------------------
# (name, file, row, text the note must contain). Rows in XROWS are MODE
# rows that driver code replaces: they write another register per bus mode.
XSTEPS = [
    ('IT_CAL_WAIT', 'it6805-init', 161, 'calibration wait'),
    ('IT_FACTORY_READ', 'it6805-init', 205, 'factory-data read'),
    ('IT_TRIM', 'it6805-init', 210, 'oscillator trim'),
    ('IT_HPD_LOW', 'it6805-init', 227, 'HPD low'),
    ('IT_EDID_LOAD', 'it6805-init', 228, 'EDID load'),
    ('IT_MEASURE', 'it6805-lock', 2, 'measurement'),
    ('IT_DUAL', 'it6805-lock', 26, 'MODE: dual pixel only'),
    ('IT_UNBLANK', 'it6805-lock', 77, 'MODE: single pixel c5 = 18'),
    ('SP_RCLK', 'splitter-init', 53, 'rclk-compute'),
    ('SP_CAOF_WAIT', 'splitter-init', 94, 'caof-wait'),
    ('SP_EDID_BLOCK0', 'splitter-rx-edid-load', 6, 'edid-block0'),
    ('SP_EDID_BLOCK1', 'splitter-rx-edid-load', 7, 'edid-block1'),
    ('SP_TX_CLOCK', 'splitter-tx1-power-on', 14, 'tx-clock-measure'),
    ('SP_TIMING_READ', 'splitter-tx1-output-enable', 12, 'timing-read'),
]
XROWS = {('it6805-lock', 77)}

# ---- variables ----------------------------------------------------------------
# (name, expression as written in the tables, or None for a MODE row)
VARS = [
    ('BASE_HI', '{base >> 8}'), ('BASE_LO', '{base & 0xff}'),
    ('BASE1_HI', '{(base + 1) >> 8}'), ('BASE1_LO', '{(base + 1) & 0xff}'),
    ('RCLK10_0', '{rclk10 & 0xff}'), ('RCLK10_1', '{(rclk10 >> 8) & 0xff}'),
    ('RCLK10_2', '{(rclk10 >> 16) & 0x03}'),
    ('RCLK_MHZ', '{rclk / 1000}'), ('RCLK_FRAC', '{((rclk % 1000) * 32) / 125}'),
    ('PA_AB', '{pa_ab}'), ('PA_CD', '{pa_cd}'),
    ('CSUM0', '{csum0}'), ('CSUM1', '{csum1}'),
    ('HDMI_SINK', '{hdmi_sink << 6}'),
    ('EQ0', '{eq0}'), ('EQ1', '{eq1}'), ('EQ2', '{eq2}'),
    ('AFE84', '{afe84}'), ('AFE88', '{afe88}'), ('AFE87', '{afe87}'),
    ('AFE89', '{afe89}'), ('AFE8B', '{afe8b}'),
    ('R14', '{(r14 & 1) << 6}'), ('HDMI', '{hdmi}'),
    ('IT_B0', None), ('IT_DDR', None), ('IT_OCOL', None), ('IT_BD', None),
    ('IT_C4', None), ('IT_ICOL', None), ('IT_DVI', None), ('IT_DEPTH', None),
]
VAR_EXPR = {expr: name for name, expr in VARS if expr}

# MODE rows of the stable-entry tables -> variable (hdmi-it6805.md 10)
MODE_ROWS = {
    5: 'IT_B0', 21: 'IT_DDR', 24: 'IT_OCOL', 33: 'IT_BD', 36: 'IT_C4',
    42: 'IT_ICOL', 43: 'IT_DVI', 46: 'IT_DDR', 49: 'IT_OCOL', 59: 'IT_DEPTH',
}
LOCK_TABLES = ('it6805-lock', 'it6805-lock-dual-sdr', 'it6805-lock-dual-ddr')

# ---- captures: rows whose read value driver code uses ------------------------
CAPTURES = [
    # (segment, name, row, (op, dev, reg))
    ('sp_init', 'OTP_W0_LO', 33, ('R', '58', '61')),
    ('sp_init', 'OTP_W0_HI', 34, ('R', '58', '62')),
    ('sp_init', 'OTP_W1_LO', 38, ('R', '58', '61')),
    ('sp_init', 'OTP_W1_HI', 39, ('R', '58', '62')),
    ('sp_init', 'OTP_A_LO', 43, ('R', '58', '61')),
    ('sp_init', 'OTP_A_HI', 44, ('R', '58', '62')),
    ('sp_init', 'OTP_B_LO', 48, ('R', '58', '61')),
    ('sp_init', 'OTP_B_HI', 49, ('R', '58', '62')),
    ('sp_eq_read', 'D5', 3, ('R', '70', 'd5')),
    ('sp_eq_read', 'D6', 4, ('R', '70', 'd6')),
    ('sp_eq_read', 'D7', 5, ('R', '70', 'd7')),
    ('sp_eq_read', 'D0', 6, ('R', '70', 'd0')),
    ('sp_biterr', 'EA0', 5, ('R', '70', 'ea')),
    ('sp_biterr', 'EB0', 6, ('R', '70', 'eb')),
    ('sp_biterr', 'EA1', 9, ('R', '70', 'ea')),
    ('sp_biterr', 'EB1', 10, ('R', '70', 'eb')),
    ('sp_biterr', 'EA2', 13, ('R', '70', 'ea')),
    ('sp_biterr', 'EB2', 14, ('R', '70', 'eb')),
    ('sp_tx1_output_enable', 'LINK', 86, ('R', '6a', '03')),
]

# ---- segments -----------------------------------------------------------------
# (name, file, first row, last row, (op, dev, reg) of first, of last,
#  conditions the segment assumes)
SEGMENTS = [
    ('it_init', 'it6805-init', 5, 245, ('W', '90', '0f'), ('W', '90', '0f'), ()),
    ('it_edid', 'it6805-init', 226, 240, ('W', '90', '4b'), ('M', '90', 'c5'), ()),
    ('it_unplug', 'it6805-unplug', 0, 15, ('W', '90', '0f'), ('W', '90', '0f'), ()),
    ('it_saving', 'it6805-power-saving', 0, 33, ('W', '90', '0f'), ('W', '90', '20'), ()),
    ('it_standby', 'it6805-power-standby', 0, 14, ('W', '90', '0f'), ('W', '90', '20'), ()),
    ('it_normal', 'it6805-power-normal', 0, 28, ('W', '90', '0f'), ('W', '90', '20'), ()),
    ('it_lock', 'it6805-lock', 0, 80, ('W', '90', '0f'), ('M', '90', '8c'), ()),
    ('sp_init', 'splitter-init', 7, 423, ('W', '58', '0a'), ('M', '6e', '88'), ()),
    ('sp_edid_load', 'splitter-rx-edid-load', 0, 11, ('M', '70', '34'), ('M', '58', '0f'), ()),
    ('sp_edid_toggle', 'splitter-rx-edid-load', 12, 45, ('M', '70', 'c5'), ('D', '-', '-'),
     ('EDID_TOGGLE',)),
    ('sp_edid_end', 'splitter-rx-edid-load', 53, 55, ('M', '70', 'c5'), ('M', '70', '34'), ()),
    ('sp_hpd_high', 'splitter-rx-hpd-high', 1, 6, ('M', '70', '0f'), ('W', '70', '55'), ()),
    ('sp_hpd_low', 'splitter-rx-hpd-low', 0, 7, ('M', '70', '0f'), ('W', '70', '55'), ()),
    ('sp_rx_power_down', 'splitter-rx-power-down', 0, 23, ('M', '70', '53'), ('M', '70', '0f'), ()),
    ('sp_5v_on', 'splitter-rx-5v-on', 23, 34, ('M', '58', '0c'), ('M', '58', '69'), ()),
    ('sp_tx0_power_down', 'splitter-rx-5v-off', 47, 81, ('M', '58', '08'), ('M', '68', '35'), ()),
    ('sp_tx2_power_down', 'splitter-rx-5v-off', 117, 151, ('M', '58', '08'), ('M', '6c', '35'), ()),
    ('sp_tx3_power_down', 'splitter-rx-5v-off', 152, 186, ('M', '58', '08'), ('M', '6e', '35'), ()),
    ('sp_clock_lost', 'splitter-rx-5v-off', 187, 206, ('W', '70', '05'), ('M', '70', '23'), ()),
    ('sp_scdt_off', 'splitter-rx-5v-off', 207, 228, ('R', '70', '19'), ('R', '6c', '03'), ()),
    ('sp_ack_12_7', 'splitter-rx-5v-off', 229, 234, ('R', '70', '1a'), ('M', '58', '0c'),
     ('RX12_7',)),
    ('sp_lock_lost', 'splitter-rx-signal-loss', 44, 53, ('M', '70', '53'), ('M', '70', '0f'),
     ('LOCK_LOST',)),
    ('sp_clock_stable', 'splitter-rx-lock', 24, 37, ('W', '70', '05'), ('R', '70', '14'), ()),
    ('sp_lock', 'splitter-rx-lock', 45, 58, ('M', '70', '53'), ('M', '70', '0f'), ()),
    ('sp_eq_search', 'splitter-rx-lock', 94, 108, ('W', '70', '07'), ('M', '70', '0f'),
     ('NO_EQ_STORED',)),
    ('sp_eq_read', 'splitter-rx-eq-apply', 2, 8, ('M', '70', '0f'), ('R', '70', 'd0'), ()),
    ('sp_eq_write', 'splitter-rx-eq-apply', 9, 21, ('M', '70', '22'), ('W', '70', '05'), ()),
    ('sp_biterr', 'splitter-rx-biterr', 0, 17, ('M', '70', '3b'), ('M', '70', '0f'), ()),
    ('sp_scdt_on_a', 'splitter-rx-scdt-on', 23, 31, ('M', '70', '40'), ('M', '58', '4e'), ()),
    ('sp_scdt_on_b', 'splitter-rx-scdt-on', 63, 69, ('R', '6c', '03'), ('M', '70', '0f'), ()),
    ('sp_main_event', 'splitter-main-event', 1, 18, ('R', '58', '06'), ('R', '70', '14'), ()),
    ('sp_tx1_power_down', 'splitter-tx1-power-down', 0, 34, ('M', '58', '08'), ('M', '6a', '35'), ()),
    ('sp_tx1_power_on_partial', 'splitter-tx1-power-on', 0, 5, ('M', '58', '08'), ('M', '6a', '19'), ()),
    ('sp_tx1_power_on_rest', 'splitter-tx1-power-on', 6, 29, ('W', '6a', '10'), ('M', '6a', '18'), ()),
    ('sp_tx1_output_enable', 'splitter-tx1-output-enable', 0, 97, ('R', '6a', '03'), ('W', '6a', '12'), ()),
    ('sp_tx1_unmute', 'splitter-tx1-output-enable', 99, 100, ('M', '6a', '91'), ('M', '6a', 'c1'), ()),
]


def die(msg):
    sys.stderr.write('gen-seq: %s\n' % msg)
    sys.exit(1)


def load(name):
    rows = {}
    with open(os.path.join(SEQ, name + '.tsv')) as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            col = line.split('\t')
            if col[0] == 'n':
                continue
            col += [''] * (8 - len(col))
            rows[int(col[0])] = col
    return rows


def num(s, what, fname, n):
    try:
        return int(s, 16)
    except ValueError:
        die('%s row %d: bad %s "%s"' % (fname, n, what, s))


def conds_of(fname, n, note, assume):
    conds = []
    m = re.search(r'cond:\s*([^;]*)', note)
    if m:
        text = m.group(1).strip()
        for pat, name in COND_TEXT:
            if re.search(pat, text):
                conds.append(name)
                break
        else:
            die('%s row %d: unmapped condition "%s"' % (fname, n, text))
    extra = EXTRA_COND.get((fname, n))
    if extra and extra not in conds:
        conds.append(extra)
    conds = [c for c in conds if c not in assume]
    if len(conds) > 2:
        die('%s row %d: more than two conditions' % (fname, n))
    return conds


def gen_row(fname, n, col, assume):
    _, op, dev, bank, reg, mask, val, note = col[:8]
    if op not in ('W', 'M', 'R', 'D', 'P', 'X'):
        die('%s row %d: unknown op %s' % (fname, n, op))
    e = {'op': op, 'dev': 0, 'bank': 'NB', 'reg': 0, 'mask': 0xff,
         'val': 0, 'flags': [], 'arg': '0'}
    if dev not in ('-', ''):
        e['dev'] = num(dev, 'dev', fname, n)
    if bank == '*':
        e['flags'].append('GC573_SEQ_F_BANKREG')
    elif bank not in ('-', ''):
        e['bank'] = '%d' % num(bank, 'bank', fname, n)
    if reg not in ('-', ''):
        e['reg'] = num(reg, 'reg', fname, n)
    if op in ('M', 'P'):
        e['mask'] = num(mask, 'mask', fname, n)
    conds = conds_of(fname, n, note, assume)
    if (fname, n) in XROWS:
        op = e['op'] = 'X'
    if op == 'D':
        e['arg'] = '%d' % int(val)
    elif op == 'X':
        for name, xf, xn, text in XSTEPS:
            if (xf, xn) == (fname, n):
                if text not in note:
                    die('%s row %d: X note "%s" lacks "%s"' % (fname, n, note[:60], text))
                e['arg'] = 'GC573_SEQ_X_' + name
                break
        else:
            die('%s row %d: unmapped X step "%s"' % (fname, n, note[:60]))
    elif op in ('W', 'M', 'P'):
        mode = MODE_ROWS.get(n) if fname in LOCK_TABLES else None
        if mode:
            if not note.startswith('MODE'):
                die('%s row %d: expected a MODE row' % (fname, n))
            e['flags'].append('GC573_SEQ_F_VAR')
            e['arg'] = 'GC573_SEQ_V_' + mode
        elif val == '{read}':
            e['flags'].append('GC573_SEQ_F_READ')
        elif val.startswith('{'):
            name = VAR_EXPR.get(val)
            if not name:
                die('%s row %d: unmapped expression %s' % (fname, n, val))
            e['flags'].append('GC573_SEQ_F_VAR')
            e['arg'] = 'GC573_SEQ_V_' + name
        else:
            if note.startswith('MODE'):
                die('%s row %d: MODE row without a variable' % (fname, n))
            e['val'] = num(val, 'value', fname, n)
    e['c1'] = 'GC573_SEQ_C_' + conds[0] if conds else '0'
    e['c2'] = 'GC573_SEQ_C_' + conds[1] if len(conds) > 1 else '0'
    return e


SHORT = [('GC573_SEQ_NOBANK', 'NB'), ('GC573_SEQ_F_', 'SQF_'), ('GC573_SEQ_C_', 'SQC_'),
         ('GC573_SEQ_X_', 'SQX_'), ('GC573_SEQ_V_', 'SQV_')]


def short(s):
    for a, b in SHORT:
        s = s.replace(a, b)
    return s


def pin_of(rows, n):
    return rows[n][1], rows[n][2], rows[n][4]


def check_pin(fname, rows, n, pin, which):
    if n not in rows:
        die('%s: row %d missing' % (fname, n))
    if pin_of(rows, n) != pin:
        die('%s row %d (%s row of a segment): %s %s %s, expected %s %s %s'
            % ((fname, n, which) + pin_of(rows, n) + pin))


def check_lock_variants(tables):
    """Dual-pixel tables: same rows, differing only where mapped."""
    base = tables.setdefault('it6805-lock', load('it6805-lock'))
    mapped = set(MODE_ROWS) | {xn for _, xf, xn, _ in XSTEPS if xf == 'it6805-lock'}
    for f in LOCK_TABLES[1:]:
        rows = load(f)
        if sorted(rows) != sorted(base):
            die('%s: row numbers differ from it6805-lock' % f)
        for n in rows:
            a, b = base[n][1:7], rows[n][1:7]
            if a == b or a[0] == 'R' or n in mapped:
                continue
            die('%s row %d differs from it6805-lock outside the MODE rows' % (f, n))


def main():
    check = '--check' in sys.argv[1:]
    tables = {}
    out_c, out_h = [], []
    seg_rows = {}
    for name, fname, lo, hi, pin_lo, pin_hi, assume in SEGMENTS:
        rows = tables.setdefault(fname, load(fname))
        check_pin(fname, rows, lo, pin_lo, 'first')
        check_pin(fname, rows, hi, pin_hi, 'last')
        seg_rows[name] = (fname, lo, hi)
        out_c.append('/* spec/seq/%s.tsv rows %d-%d */' % (fname, lo, hi))
        out_c.append('static const struct gc573_seq_op gc573_seq_%s_ops[] = {' % name)
        for n in range(lo, hi + 1):
            if n not in rows:
                die('%s: row %d missing' % (fname, n))
            e = gen_row(fname, n, rows[n], assume)
            flags = ' | '.join(e['flags']) or '0'
            out_c.append('\t{ SQ_%s, 0x%02x, %s, 0x%02x, 0x%02x, 0x%02x, %s, %s, %s, %s, %d },'
                         % (e['op'], e['dev'], e['bank'], e['reg'], e['mask'], e['val'],
                            short(e['c1']), short(e['c2']), short(flags), short(e['arg']), n))
        out_c.append('};')
        out_c.append('')
        out_c.append('const struct gc573_seq gc573_seq_%s = {' % name)
        out_c.append('\t.name\t= "%s",' % name)
        out_c.append('\t.ops\t= gc573_seq_%s_ops,' % name)
        out_c.append('\t.n\t= ARRAY_SIZE(gc573_seq_%s_ops),' % name)
        out_c.append('};')
        out_c.append('')
        out_h.append('extern const struct gc573_seq gc573_seq_%s;' % name)
    check_lock_variants(tables)

    caps = []
    for seg, cname, n, pin in CAPTURES:
        fname, lo, hi = seg_rows[seg]
        check_pin(fname, tables[fname], n, pin, 'capture')
        if not lo <= n <= hi:
            die('capture %s: row %d outside segment %s' % (cname, n, seg))
        caps.append('#define GC573_SEQ_%s_%s\t%d\t/* row %d */' % (seg.upper(), cname, n - lo, n))

    dc = ['const struct gc573_seq_dcond gc573_seq_dconds[GC573_SEQ_C_NUM] = {']
    for cname, test, _ in CONDS:
        if test:
            dev, bank, reg, mask, val, eq = test
            dc.append('\t[GC573_SEQ_C_%s] = { 0x%02x, %s, 0x%02x, 0x%02x, 0x%02x, %s },'
                      % (cname, dev, 'GC573_SEQ_NOBANK' if bank is None else '%d' % bank,
                         reg, mask, val, 'true' if eq else 'false'))
    dc.append('};')

    note = '/* Generated by tools/gen-seq.py from the spec/seq tables. Do not edit. */'
    h = ['/* SPDX-License-Identifier: GPL-2.0 */', note, '#ifndef GC573_SEQ_H', '#define GC573_SEQ_H', '',
                '/* conditions (0 = none): caller flags, or tested by the engine */',
                'enum gc573_seq_cond {', '\tGC573_SEQ_C_NONE,']
    for cname, test, desc in CONDS:
        h.append('\tGC573_SEQ_C_%s,\t/* %s%s */' % (cname, 'engine: ' if test else '', desc))
    h += ['\tGC573_SEQ_C_NUM,', '};', '', '/* X steps: driver code */',
          'enum gc573_seq_x {', '\tGC573_SEQ_X_NONE,']
    for xname, xf, xn, _ in XSTEPS:
        h.append('\tGC573_SEQ_X_%s,\t/* %s row %d */' % (xname, xf, xn))
    h += ['};', '', '/* variables: driver code computes them when a row uses one */',
          'enum gc573_seq_var {']
    for vname, expr in VARS:
        h.append('\tGC573_SEQ_V_%s,\t/* %s */' % (vname, expr or 'MODE row'))
    h += ['\tGC573_SEQ_V_NUM,', '};', '', '/* captures: index of a row in its segment */']
    h += caps + ['', '/* longest segment */',
                 '#define GC573_SEQ_MAX_OPS\t%d' % max(hi - lo + 1 for _, lo, hi in seg_rows.values()),
                 ''] + out_h
    h += ['', 'extern const struct gc573_seq_dcond gc573_seq_dconds[GC573_SEQ_C_NUM];',
          '', '#endif /* GC573_SEQ_H */', '']
    defs = ['/* short names keep the rows readable */']
    defs += ['#define SQ_%s\tGC573_SEQ_%s' % (o, o) for o in 'WMRDPX']
    defs += ['#define NB\tGC573_SEQ_NOBANK',
             '#define SQF_BANKREG\tGC573_SEQ_F_BANKREG',
             '#define SQF_READ\tGC573_SEQ_F_READ',
             '#define SQF_VAR\tGC573_SEQ_F_VAR']
    defs += ['#define SQC_%s\tGC573_SEQ_C_%s' % (c[0], c[0]) for c in CONDS]
    defs += ['#define SQX_%s\tGC573_SEQ_X_%s' % (x, x)
             for x in dict.fromkeys(x[0] for x in XSTEPS)]
    defs += ['#define SQV_%s\tGC573_SEQ_V_%s' % (v[0], v[0]) for v in VARS]
    c = ['// SPDX-License-Identifier: GPL-2.0', note, '', '#include <linux/kernel.h>', '', '#include "gc573_chip.h"', ''] + defs + [''] + out_c + dc

    outs = {os.path.join(ROOT, 'src', 'gc573_seq.h'): '\n'.join(h),
            os.path.join(ROOT, 'src', 'gc573_seq.c'): '\n'.join(c) + '\n'}
    for path, text in outs.items():
        old = open(path).read() if os.path.exists(path) else None
        if old == text:
            continue
        if check:
            die('%s is out of date: run tools/gen-seq.py' % os.path.relpath(path, ROOT))
        with open(path, 'w') as f:
            f.write(text)
        print('wrote', os.path.relpath(path, ROOT))


if __name__ == '__main__':
    main()
