// SPDX-License-Identifier: GPL-2.0
/*
 * GC573 audio capture: an ALSA card with one PCM capture substream, fed by
 * the FPGA's audio DMA. spec/audio.md, spec/interrupts.md (INT bits 4 and
 * 5), spec/regmap.md "Audio DMA", spec/hdmi-it6805.md 11.
 *
 * The FPGA fills two coherent buffers of one 10 ms period in turn and
 * raises INT bit 5 after each; AUDIO_DONE says which one is full. The hard
 * IRQ handler copies that period into the ALSA ring at once (the FPGA
 * returns to the buffer one period later) and reports the ALSA periods
 * that elapsed. The hardware pointer moves one 10 ms period at a time
 * (SNDRV_PCM_INFO_BATCH); ALSA periods are whole multiples of it.
 *
 * Format: S16_LE, 2 channels, 48 kHz: the only rate traced, and the only
 * one the default EDID offers (spec/hdmi-chips.md "Default EDID").
 *
 * Input loss and relock: the FPGA completes periods every 10 ms with or
 * without an input (spec/audio.md "Running"), so a stream runs on through
 * every input change. A period is delivered as silence unless audio is
 * known to be there: the IT6805 audio state ON (outputs driven,
 * spec/hdmi-it6805.md 11.2) and the FPGA measuring the stream's rate
 * (AUDIO_SAMPLE_PERIOD, all ones without audio). Samples return with the
 * first period after both hold again. The stream never stalls and never
 * reports an xrun for an input change; the application sees silence.
 *
 * Video stop: the spec's sequence (spec/init.md "Stream stop" step 3)
 * resets all three domains, and domain 8 holds the audio DMA: its reset
 * stops the DMA, clears DMA_RUN and raises no INT bit 4 (driver M4/M5,
 * open question 13; RD ran audio only with video idle). While a stream
 * runs, the video stop leaves domain 8 out and audio carries on. If domain
 * 8 is reset anyway (a stream started while the stop was under way), the
 * stream is started again right after it, as at a stream start, and the
 * time lost meanwhile (up to about 90 ms, measured between the
 * interrupts) is filled with silence, which keeps the stream in step with
 * the clock and with video.
 *
 * Pauses: at an input loss, and at times while a source plays, the FPGA
 * completes one period 10 ms late with AUDIO_DONE still in turn: one
 * period's samples never came (driver M4; its pacing follows the source).
 * Otherwise its 10 ms grid runs free (the interval after a late interrupt
 * is short by the latency), so the next period tells the two apart: on
 * time after a late one means a pause, early means a late interrupt (and
 * 10 ms or more of latency would merge two periods, out of turn). A pause
 * is filled with silence of its length, so the stream keeps time through
 * it. An interrupt more than 5 ms late followed by one nearly as late
 * (within 3 ms) would read as a pause and add that silence; debugfs
 * "audio" counts pauses.
 *
 * Unbind and remove do not wait for the card's files: the card is
 * disconnected (a running stream stopped and synced, every file failing
 * from then on) and goes when its last file closes. An open substream
 * holds a reference to struct gc573 until its close, the only callback
 * left after the disconnect, so the struct outlives every call that can
 * still reach it. Nothing of gc573 runs when the card itself goes: ALSA
 * drops its module reference before that, so no private_free.
 *
 * Locking: aud.lock protects the stream state shared with the hard IRQ
 * handler and the audio DMA registers. DMA_RUN (0x008) changes only by
 * read-modify-write under gc->dma_run_lock (spec/audio.md "Driver notes").
 * snd_pcm_period_elapsed() is called without aud.lock held: on an overrun
 * it stops the stream, and the trigger callback takes aud.lock.
 */

#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/moduleparam.h>
#include <linux/pci.h>
#include <linux/seq_file.h>
#include <linux/string.h>
#include <sound/core.h>
#include <sound/initval.h>
#include <sound/pcm.h>

#include "gc573.h"

#define GC573_AUD_RATE			48000
#define GC573_AUD_CHANNELS		2
#define GC573_AUD_FRAME_BYTES		4		/* S16_LE, 2 channels */
/* spec/audio.md "Period": 10 ms; 48 kHz: 1920 bytes, register 0x1e0 */
#define GC573_AUD_HW_FRAMES		(GC573_AUD_RATE / 100)
#define GC573_AUD_HW_BYTES		(GC573_AUD_HW_FRAMES * GC573_AUD_FRAME_BYTES)
/* each DMA buffer on its own page */
#define GC573_AUD_BUF_STRIDE		PAGE_SIZE
/* driver limits: ALSA ring up to 2 s, periods up to 0.5 s */
#define GC573_AUD_BUFFER_MAX		(2 * GC573_AUD_RATE * GC573_AUD_FRAME_BYTES)
#define GC573_AUD_PERIOD_MAX		(GC573_AUD_RATE / 2 * GC573_AUD_FRAME_BYTES)
/* INT bit 4 came 38 us after the stop write (spec/audio.md "Stop") */
#define GC573_AUD_STOP_MS		100
/*
 * Silence filled in after a domain reset, at most: 1 s, and with the
 * period that follows less than the ring, so the pointer cannot wrap past
 * itself between two updates
 */
#define GC573_AUD_FILL_MAX		(GC573_AUD_RATE * GC573_AUD_FRAME_BYTES)
/* the hardware period; an interval above LATE_US: latency or a pause */
#define GC573_AUD_HW_US			10000
#define GC573_AUD_LATE_US		15000
/* after a late period, an interval of at least this is on time: a pause */
#define GC573_AUD_ON_TIME_US		7000

static bool exp_audio_raw;
module_param(exp_audio_raw, bool, 0644);
MODULE_PARM_DESC(exp_audio_raw, "Experiment, spec/audio.md \"Unknown\"; read per period. Deliver every period as the DMA left it, also without audio (0: silence then)");

static ushort exp_audio_fill;
module_param(exp_audio_fill, ushort, 0644);
MODULE_PARM_DESC(exp_audio_fill, "Experiment, spec/audio.md \"Unknown\"; read per period. Fill a DMA buffer with this 16-bit value once copied out, to show periods the FPGA did not write (0: off)");

/* spec/audio.md "Sample rate detection" */
static const unsigned int gc573_aud_rates[] = {
	32000, 44100, 48000, 88200, 96000, 176400, 192000,
};

/*
 * The rate AUDIO_SAMPLE_PERIOD gives: 1e8 / value rounded to 100, snapped
 * to the nearest standard rate within 1 %; 0 for none (all ones: no audio)
 */
static unsigned int gc573_aud_rate(u32 period)
{
	unsigned int fs, i, best = 0, d, dmin = UINT_MAX;

	if (!period || period == U32_MAX)
		return 0;
	fs = DIV_ROUND_CLOSEST(GC573_AUDIO_SAMPLE_PERIOD_HZ / 100, period) * 100;
	for (i = 0; i < ARRAY_SIZE(gc573_aud_rates); i++) {
		d = abs_diff(fs, gc573_aud_rates[i]);
		if (d < dmin) {
			dmin = d;
			best = gc573_aud_rates[i];
		}
	}
	return dmin <= best / 100 ? best : 0;
}

/* ---- hardware ---- */

/* spec/audio.md "Start (RD order)"; under aud.lock */
static void gc573_aud_hw_start(struct gc573 *gc)
{
	struct gc573_audio *a = &gc->aud;
	dma_addr_t b1 = a->buf_dma + GC573_AUD_BUF_STRIDE;
	unsigned int i;

	/* 1: RD sizes the period from the rate; this stream's is fixed */
	a->sample_period = gc573_rd(gc, GC573_AUDIO_SAMPLE_PERIOD);
	gc573_wr(gc, GC573_AUD_CFG0, 0);				/* 2 */
	for (i = 0; i < GC573_AUD_SLOTS; i++)			/* 3 */
		gc573_wr(gc, GC573_AUD_SLOT(i), i);
	gc573_wr(gc, GC573_AUD_PERIOD_A, GC573_AUD_HW_BYTES / 4);	/* 4 */
	gc573_wr(gc, GC573_AUD_PERIOD_B, GC573_AUD_HW_BYTES / 4);
	gc573_wr(gc, GC573_AUD_BUF0_LO, lower_32_bits(a->buf_dma));	/* 5 */
	gc573_wr(gc, GC573_AUD_BUF0_HI, upper_32_bits(a->buf_dma));
	gc573_wr(gc, GC573_AUD_BUF1_LO, lower_32_bits(b1));
	gc573_wr(gc, GC573_AUD_BUF1_HI, upper_32_bits(b1));
	gc573_wr(gc, GC573_AUD_CFG1, 0);				/* 6 */
	gc573_dma_run_update(gc, GC573_DMA_RUN_AUDIO, GC573_DMA_RUN_AUDIO);	/* 7 */
}

/* spec/audio.md "Stop": INT bit 4 follows; under aud.lock */
static void gc573_aud_hw_stop(struct gc573 *gc)
{
	reinit_completion(&gc->aud.stopped);
	gc573_dma_run_update(gc, GC573_DMA_RUN_AUDIO, 0);
}

/* An audio stream is running: a video stop leaves its reset domain alone */
bool gc573_audio_running(struct gc573 *gc)
{
	struct gc573_audio *a = &gc->aud;
	unsigned long flags;
	bool running;

	spin_lock_irqsave(&a->lock, flags);
	running = a->running;
	spin_unlock_irqrestore(&a->lock, flags);
	return running;
}

/*
 * After a domain reset (gc573_video_hw_stop()): if it stopped the DMA of a
 * running stream, start it again and fill the gap at its first period
 */
void gc573_audio_reset_done(struct gc573 *gc)
{
	struct gc573_audio *a = &gc->aud;
	unsigned long flags;

	spin_lock_irqsave(&a->lock, flags);
	if (a->running && !a->dead &&
	    !(gc573_rd(gc, GC573_DMA_RUN) & GC573_DMA_RUN_AUDIO)) {
		a->st.restarts++;
		a->next = GC573_AUDIO_DONE_BUF0;
		a->resync = true;
		gc573_aud_hw_start(gc);
	}
	spin_unlock_irqrestore(&a->lock, flags);
}

/* Remove and shutdown, spec/init.md "Remove / quiesce" step 1 */
void gc573_audio_quiesce(struct gc573 *gc)
{
	struct gc573_audio *a = &gc->aud;
	unsigned long flags;
	bool run;

	spin_lock_irqsave(&a->lock, flags);
	a->dead = true;
	a->running = false;
	run = gc573_rd(gc, GC573_DMA_RUN) & GC573_DMA_RUN_AUDIO;
	if (run)
		gc573_aud_hw_stop(gc);
	spin_unlock_irqrestore(&a->lock, flags);
	/* the DMA stops within 38 us (INT bit 4); its memory goes after this */
	if (run)
		fsleep(1000);
}

/* ---- IRQ ---- */

/* Append @n bytes to the ring: from @src, or silence if NULL */
static void gc573_aud_put(struct gc573_audio *a, const u8 *src,
			  unsigned int n)
{
	unsigned int pos = a->pos, first = min(n, a->buffer_bytes - pos);

	if (src) {
		memcpy(a->area + pos, src, first);
		memcpy(a->area, src + first, n - first);
	} else {
		memset(a->area + pos, 0, first);
		memset(a->area, 0, n - first);
	}
	pos += n;
	if (pos >= a->buffer_bytes)
		pos -= a->buffer_bytes;
	WRITE_ONCE(a->pos, pos);
	a->part += n;
}

/*
 * Hard IRQ handler part: INT bit 4 and 5 (@pending), with AUDIO_DONE
 * (@done) read before the ack as RD does (spec/audio.md "Running"), and
 * the time of the interrupt (@ns).
 */
void gc573_audio_irq(struct gc573 *gc, u32 pending, u32 done, u64 ns)
{
	struct gc573_audio *a = &gc->aud;
	struct snd_pcm_substream *elapsed = NULL;
	unsigned int buf, us, lost_us = 0;
	bool in_turn;
	u64 lost;
	u8 *src;
	u16 fill;

	spin_lock(&a->lock);
	if (pending & GC573_INT_AUD_STOP) {
		a->st.stops++;
		complete(&a->stopped);
	}
	if (!(pending & GC573_INT_AUD_DONE))
		goto out;
	if (!a->running) {
		a->st.stale++;
		goto out;
	}

	us = a->last_ns ? div_u64(ns - a->last_ns, NSEC_PER_USEC) : 0;
	a->last_ns = ns;

	buf = done & GC573_AUDIO_DONE_MASK;
	if (buf != GC573_AUDIO_DONE_BUF0 && buf != GC573_AUDIO_DONE_BUF1) {
		a->st.bad_done++;
		goto out;
	}
	in_turn = buf == a->next;
	if (!in_turn)
		a->st.order++;
	a->next = buf == GC573_AUDIO_DONE_BUF0 ? GC573_AUDIO_DONE_BUF1 :
						 GC573_AUDIO_DONE_BUF0;

	if (a->resync) {
		/* restarted after a domain reset: the time since the last period */
		if (us > GC573_AUD_HW_US)
			lost_us = us - GC573_AUD_HW_US;
		a->resync = false;
		a->pause_us = 0;
	} else if (us) {
		a->st.interval_max_us = max(a->st.interval_max_us, us);
		a->st.interval_min_us = min(a->st.interval_min_us, us);
		if (a->pause_us) {
			if (us >= GC573_AUD_ON_TIME_US) {
				lost_us = a->pause_us;
				a->st.pauses++;
			} else {
				a->st.late++;
			}
			a->pause_us = 0;
		}
		if (us > GC573_AUD_LATE_US) {
			if (in_turn)
				a->pause_us = us - GC573_AUD_HW_US;
			else
				a->st.late++;
		}
	}
	if (lost_us) {
		/* silence for the time lost, frame-exact */
		lost = DIV_ROUND_CLOSEST_ULL((u64)lost_us * a->rate, USEC_PER_SEC);
		lost = min_t(u64, lost * GC573_AUD_FRAME_BYTES,
			     min_t(unsigned int, GC573_AUD_FILL_MAX,
				   a->buffer_bytes - 2 * GC573_AUD_HW_BYTES));
		gc573_aud_put(a, NULL, lost);
		a->st.filled += lost / GC573_AUD_FRAME_BYTES;
	}
	src = (u8 *)a->buf + (buf - 1) * GC573_AUD_BUF_STRIDE;

	a->sample_period = gc573_rd(gc, GC573_AUDIO_SAMPLE_PERIOD);
	a->good = READ_ONCE(gc->hdmi.audio_on) &&
		  gc573_aud_rate(a->sample_period) == a->rate;
	gc573_aud_put(a, a->good || READ_ONCE(exp_audio_raw) ? src : NULL,
		      GC573_AUD_HW_BYTES);
	a->st.periods++;
	if (!a->good)
		a->st.silent++;

	fill = READ_ONCE(exp_audio_fill);
	if (fill)
		memset16((u16 *)src, fill, GC573_AUD_HW_BYTES / 2);

	if (a->part >= a->period_bytes) {
		a->part %= a->period_bytes;
		elapsed = a->ss;
	}
out:
	spin_unlock(&a->lock);
	if (elapsed)
		snd_pcm_period_elapsed(elapsed);
}

/* ---- PCM ---- */

static const struct snd_pcm_hardware gc573_pcm_hw = {
	.info			= SNDRV_PCM_INFO_MMAP |
				  SNDRV_PCM_INFO_MMAP_VALID |
				  SNDRV_PCM_INFO_INTERLEAVED |
				  SNDRV_PCM_INFO_BATCH,
	.formats		= SNDRV_PCM_FMTBIT_S16_LE,
	.rates			= SNDRV_PCM_RATE_48000,
	.rate_min		= GC573_AUD_RATE,
	.rate_max		= GC573_AUD_RATE,
	.channels_min		= GC573_AUD_CHANNELS,
	.channels_max		= GC573_AUD_CHANNELS,
	.buffer_bytes_max	= GC573_AUD_BUFFER_MAX,
	.period_bytes_min	= GC573_AUD_HW_BYTES,
	.period_bytes_max	= GC573_AUD_PERIOD_MAX,
	.periods_min		= 2,
	.periods_max		= GC573_AUD_BUFFER_MAX / GC573_AUD_HW_BYTES,
};

static int gc573_pcm_open(struct snd_pcm_substream *ss)
{
	struct gc573 *gc = snd_pcm_substream_chip(ss);
	struct snd_pcm_runtime *rt = ss->runtime;
	int ret;

	rt->hw = gc573_pcm_hw;
	/* the pointer moves in hardware periods: ALSA periods are multiples */
	ret = snd_pcm_hw_constraint_step(rt, 0, SNDRV_PCM_HW_PARAM_PERIOD_SIZE,
					 GC573_AUD_HW_FRAMES);
	if (ret < 0)
		return ret;
	ret = snd_pcm_hw_constraint_integer(rt, SNDRV_PCM_HW_PARAM_PERIODS);
	if (ret < 0)
		return ret;
	/* struct gc573 stays until the close, which can come after remove */
	v4l2_device_get(&gc->v4l2_dev);
	return 0;
}

/* After an open that succeeded; also once the card is disconnected */
static int gc573_pcm_close(struct snd_pcm_substream *ss)
{
	struct gc573 *gc = snd_pcm_substream_chip(ss);

	v4l2_device_put(&gc->v4l2_dev);
	return 0;
}

static int gc573_pcm_prepare(struct snd_pcm_substream *ss)
{
	struct gc573 *gc = snd_pcm_substream_chip(ss);
	struct snd_pcm_runtime *rt = ss->runtime;
	struct gc573_audio *a = &gc->aud;

	spin_lock_irq(&a->lock);
	a->area = rt->dma_area;
	a->buffer_bytes = frames_to_bytes(rt, rt->buffer_size);
	a->period_bytes = frames_to_bytes(rt, rt->period_size);
	a->rate = rt->rate;
	a->pos = 0;
	a->part = 0;
	spin_unlock_irq(&a->lock);
	return 0;
}

/* Atomic: called with the PCM stream lock held, interrupts off */
static int gc573_pcm_trigger(struct snd_pcm_substream *ss, int cmd)
{
	struct gc573 *gc = snd_pcm_substream_chip(ss);
	struct gc573_audio *a = &gc->aud;
	int ret = 0;

	spin_lock(&a->lock);
	switch (cmd) {
	case SNDRV_PCM_TRIGGER_START:
		/* busy too while a system sleep is under way (gc573_pm_notify()) */
		if (a->dead || a->running || gc->sleeping) {
			ret = a->dead ? -ENODEV : -EBUSY;
			break;
		}
		memset(a->buf, 0, GC573_AUD_BUF_BYTES);
		a->ss = ss;
		a->next = GC573_AUDIO_DONE_BUF0;
		a->last_ns = 0;
		a->good = false;
		a->resync = false;
		a->pause_us = 0;
		a->st.starts++;
		a->st.interval_max_us = 0;
		a->st.interval_min_us = UINT_MAX;
		gc573_aud_hw_start(gc);
		a->running = true;
		break;
	case SNDRV_PCM_TRIGGER_STOP:
		if (!a->running)
			break;
		a->running = false;
		/* a domain reset in progress may have stopped it, silently */
		if (gc573_rd(gc, GC573_DMA_RUN) & GC573_DMA_RUN_AUDIO) {
			a->stopping = true;
			gc573_aud_hw_stop(gc);
		}
		break;
	default:
		ret = -EINVAL;
	}
	spin_unlock(&a->lock);
	return ret;
}

/*
 * After a stop, before prepare, hw_free and close: the DMA has stopped
 * (INT bit 4) and no IRQ handler still holds the stream
 */
static int gc573_pcm_sync_stop(struct snd_pcm_substream *ss)
{
	struct gc573 *gc = snd_pcm_substream_chip(ss);
	unsigned int fault = READ_ONCE(gc573_exp_stop_fault);
	struct gc573_audio *a = &gc->aud;
	bool stopping, missing;
	u32 run;

	spin_lock_irq(&a->lock);
	stopping = a->stopping;
	a->stopping = false;
	spin_unlock_irq(&a->lock);

	if (!stopping)
		goto out;
	missing = !wait_for_completion_timeout(&a->stopped,
					       msecs_to_jiffies(GC573_AUD_STOP_MS));
	run = gc573_rd(gc, GC573_DMA_RUN);
	/* tests only: a stop confirmed, counted as failed */
	if ((fault & GC573_STOP_FAULT_AUD_SYNC) && !missing &&
	    run != U32_MAX && !(run & GC573_DMA_RUN_AUDIO)) {
		dev_warn(&gc->pdev->dev, "exp_stop_fault %#x: the audio stop was confirmed (INT bit 4 came, DMA_RUN %#010x), counted as no INT bit 4 and the audio DMA still on\n",
			 fault, run);
		missing = true;
		run |= GC573_DMA_RUN_AUDIO;
	}
	if (missing) {
		spin_lock_irq(&a->lock);
		a->st.stop_missing++;
		spin_unlock_irq(&a->lock);
		dev_warn(&gc->pdev->dev, "audio stop: no INT bit 4 in %u ms, DMA_RUN=%#010x\n",
			 GC573_AUD_STOP_MS, run);
	}
out:
	synchronize_irq(gc->irq);
	return 0;
}

static snd_pcm_uframes_t gc573_pcm_pointer(struct snd_pcm_substream *ss)
{
	struct gc573 *gc = snd_pcm_substream_chip(ss);

	return bytes_to_frames(ss->runtime, READ_ONCE(gc->aud.pos));
}

static const struct snd_pcm_ops gc573_pcm_ops = {
	.open		= gc573_pcm_open,
	.close		= gc573_pcm_close,
	.prepare	= gc573_pcm_prepare,
	.trigger	= gc573_pcm_trigger,
	.sync_stop	= gc573_pcm_sync_stop,
	.pointer	= gc573_pcm_pointer,
};

/* ---- debugfs ---- */

static int gc573_aud_debugfs_show(struct seq_file *m, void *unused)
{
	struct gc573 *gc = m->private;
	struct gc573_audio *a = &gc->aud;
	struct gc573_astats st;
	bool running, good;
	u32 sp;

	spin_lock_irq(&a->lock);
	st = a->st;
	running = a->running;
	good = a->good;
	spin_unlock_irq(&a->lock);
	sp = gc573_rd(gc, GC573_AUDIO_SAMPLE_PERIOD);

	seq_printf(m, "state %s, last period %s, it6805 audio %s\n",
		   running ? "running" : "idle", good ? "samples" : "silence",
		   READ_ONCE(gc->hdmi.audio_on) ? "on" : "off");
	seq_printf(m, "regs: DMA_RUN %#010x AUDIO_DONE %#010x AUDIO_SAMPLE_PERIOD %#010x (%u Hz)\n",
		   gc573_rd(gc, GC573_DMA_RUN), gc573_rd(gc, GC573_AUDIO_DONE),
		   sp, gc573_aud_rate(sp));
	seq_printf(m, "periods %llu silent %llu filled %llu pauses %u starts %u restarts %u stops %u stop_missing %u\n",
		   st.periods, st.silent, st.filled, st.pauses, st.starts,
		   st.restarts, st.stops, st.stop_missing);
	seq_printf(m, "order %u bad_done %u stale %u late %u interval_us %u..%u\n",
		   st.order, st.bad_done, st.stale, st.late,
		   st.interval_min_us == UINT_MAX ? 0 : st.interval_min_us,
		   st.interval_max_us);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(gc573_aud_debugfs);

void gc573_audio_debugfs(struct gc573 *gc)
{
	debugfs_create_file("audio", 0444, gc->debugfs, gc,
			    &gc573_aud_debugfs_fops);
}

/* ---- setup and teardown ---- */

void gc573_audio_early_init(struct gc573 *gc)
{
	spin_lock_init(&gc->aud.lock);
	init_completion(&gc->aud.stopped);
	gc->aud.st.interval_min_us = UINT_MAX;
}

/* Devres, with bus mastering off; kept after gc573_dma_dead() */
static void gc573_audio_free_buf(void *data)
{
	struct gc573 *gc = data;
	struct gc573_audio *a = &gc->aud;

	if (READ_ONCE(gc->dma_dead))
		atomic_long_add(GC573_AUD_BUF_BYTES, &gc573_mem_live.kept);
	else
		dma_free_coherent(&gc->pdev->dev, GC573_AUD_BUF_BYTES, a->buf,
				  a->buf_dma);
}

/*
 * The two DMA buffers, allocated before bus mastering and the quiesce's
 * devres actions are added (gc573_probe()), so that they go only after
 * both ran: whatever the audio DMA still does then, it does into memory
 * the driver owns. Kept for good if a stop was not confirmed.
 */
int gc573_audio_alloc(struct gc573 *gc)
{
	struct gc573_audio *a = &gc->aud;

	a->buf = dma_alloc_coherent(&gc->pdev->dev, GC573_AUD_BUF_BYTES,
				    &a->buf_dma, GFP_KERNEL);
	if (!a->buf)
		return -ENOMEM;
	return devm_add_action_or_reset(&gc->pdev->dev, gc573_audio_free_buf,
					gc);
}

/*
 * Devres, the first teardown step that frees DMA memory: every engine is
 * stopped first (gc573_dma_stop()). The card is disconnected, stopping a
 * running stream, and goes once every file on it is closed: an unbind
 * does not wait for them (snd_card_free() would, uninterruptibly, for as
 * long as any program keeps a node of the card open).
 */
static void gc573_audio_free(void *data)
{
	struct gc573 *gc = data;

	gc573_dma_stop(gc);
	snd_card_free_when_closed(gc->aud.card);
}

int gc573_audio_init(struct gc573 *gc)
{
	struct device *dev = &gc->pdev->dev;
	struct snd_card *card;
	struct snd_pcm *pcm;
	int ret;

	ret = snd_card_new(dev, SNDRV_DEFAULT_IDX1, "GC573", THIS_MODULE, 0,
			   &card);
	if (ret)
		return ret;
	strscpy(card->driver, "GC573", sizeof(card->driver));
	strscpy(card->shortname, "GC573 HDMI capture", sizeof(card->shortname));
	snprintf(card->longname, sizeof(card->longname), "%s at %s, irq %d",
		 card->shortname, pci_name(gc->pdev), gc->irq);

	ret = snd_pcm_new(card, "GC573 HDMI", 0, 0, 1, &pcm);
	if (ret)
		goto err;
	pcm->private_data = gc;
	strscpy(pcm->name, "GC573 HDMI", sizeof(pcm->name));
	snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_CAPTURE, &gc573_pcm_ops);
	snd_pcm_set_managed_buffer_all(pcm, SNDRV_DMA_TYPE_VMALLOC, NULL, 0, 0);

	ret = snd_card_register(card);
	if (ret)
		goto err;
	gc->aud.card = card;
	dev_info(dev, "audio: ALSA card %d (%s)\n", card->number, card->id);
	return devm_add_action_or_reset(dev, gc573_audio_free, gc);

err:
	snd_card_free(card);
	return ret;
}
