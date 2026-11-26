// SPDX-License-Identifier: GPL-2.0
/*
 * GC573 videobuf2 memory allocator: ZONE_DMA32 pages.
 *
 * The video DMA runs with a 32-bit DMA mask (64-bit DMA is untested,
 * spec/pci.md). videobuf2-vmalloc pages can land above 4 GiB, and without
 * an IOMMU every such page is bounced through swiotlb; videobuf2-dma-sg is
 * not available on every matrix kernel (EL9). So the buffers are built
 * here:
 * - alloc: pages from alloc_pages(GFP_KERNEL | __GFP_DMA32), largest
 *   blocks first (fewer DMA descriptors), split into order-0 pages, and
 *   an sg_table over them;
 * - cookie: that sg_table; the driver DMA-maps it in its buf_init and
 *   builds the descriptor lists from it (gc573_video.c);
 * - vaddr: vmap() on first use;
 * - mmap: vm_map_pages(). A refcount keeps the pages until the last
 *   mapping is gone, which can be after the driver is unbound.
 * MMAP only.
 */

#include <linux/device.h>
#include <linux/err.h>
#include <linux/gfp.h>
#include <linux/log2.h>
#include <linux/minmax.h>
#include <linux/mm.h>
#include <linux/refcount.h>
#include <linux/scatterlist.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <media/videobuf2-core.h>

#include "gc573.h"

/* largest block tried: GC573_DMA_SEG_MAX (2 MiB) */
#define GC573_MEM_MAX_ORDER	(ilog2(GC573_DMA_SEG_MAX) - PAGE_SHIFT)

struct gc573_mem_live gc573_mem_live;

struct gc573_mem {
	struct device *dev;
	struct page **pages;
	unsigned int n_pages;
	struct sg_table sgt;
	void *vaddr;
	refcount_t refcount;
};

static void gc573_mem_free_pages(struct page **pages, unsigned int n)
{
	while (n)
		__free_page(pages[--n]);
}

static int gc573_mem_alloc_pages(struct gc573_mem *m)
{
	unsigned int done = 0;

	while (done < m->n_pages) {
		int order = min_t(int, ilog2(m->n_pages - done),
				  GC573_MEM_MAX_ORDER);
		struct page *p;
		unsigned int i;

		for (;;) {
			gfp_t gfp = GFP_KERNEL | __GFP_DMA32 | __GFP_ZERO;

			/* a smaller block will do: no hard reclaim, no warning */
			if (order)
				gfp |= __GFP_NORETRY | __GFP_NOWARN;
			p = alloc_pages(gfp, order);
			if (p || !order)
				break;
			order--;
		}
		if (!p) {
			gc573_mem_free_pages(m->pages, done);
			return -ENOMEM;
		}
		split_page(p, order);
		for (i = 0; i < (1U << order); i++)
			m->pages[done++] = p + i;
	}
	return 0;
}

static void *gc573_mem_alloc(struct vb2_buffer *vb, struct device *dev,
			     unsigned long size)
{
	struct gc573_mem *m;
	int ret;

	m = kzalloc(sizeof(*m), GFP_KERNEL);
	if (!m)
		return ERR_PTR(-ENOMEM);

	m->n_pages = PAGE_ALIGN(size) >> PAGE_SHIFT;
	m->pages = kvcalloc(m->n_pages, sizeof(*m->pages), GFP_KERNEL);
	if (!m->pages) {
		ret = -ENOMEM;
		goto err_free;
	}

	ret = gc573_mem_alloc_pages(m);
	if (ret)
		goto err_free_array;

	/* segments no longer than the device's DMA max segment size */
	ret = sg_alloc_table_from_pages_segment(&m->sgt, m->pages, m->n_pages,
						0,
						(unsigned long)m->n_pages << PAGE_SHIFT,
						GC573_DMA_SEG_MAX, GFP_KERNEL);
	if (ret)
		goto err_free_pages;

	m->dev = get_device(dev);
	refcount_set(&m->refcount, 1);
	atomic_inc(&gc573_mem_live.bufs);
	atomic_long_add(m->n_pages, &gc573_mem_live.pages);
	return m;

err_free_pages:
	gc573_mem_free_pages(m->pages, m->n_pages);
err_free_array:
	kvfree(m->pages);
err_free:
	kfree(m);
	return ERR_PTR(ret);
}

static void gc573_mem_put(void *buf_priv)
{
	struct gc573_mem *m = buf_priv;

	if (!refcount_dec_and_test(&m->refcount))
		return;

	if (m->vaddr) {
		vunmap(m->vaddr);
		atomic_dec(&gc573_mem_live.vmaps);
	}
	sg_free_table(&m->sgt);
	gc573_mem_free_pages(m->pages, m->n_pages);
	atomic_long_sub(m->n_pages, &gc573_mem_live.pages);
	atomic_dec(&gc573_mem_live.bufs);
	kvfree(m->pages);
	put_device(m->dev);
	kfree(m);
}

/* process context: vmap() sleeps */
static void *gc573_mem_vaddr(struct vb2_buffer *vb, void *buf_priv)
{
	struct gc573_mem *m = buf_priv;
	void *va;

	if (!READ_ONCE(m->vaddr)) {
		va = vmap(m->pages, m->n_pages, VM_MAP, PAGE_KERNEL);
		if (va && cmpxchg(&m->vaddr, NULL, va))
			vunmap(va);
		else if (va)
			atomic_inc(&gc573_mem_live.vmaps);
	}
	return READ_ONCE(m->vaddr);
}

static void *gc573_mem_cookie(struct vb2_buffer *vb, void *buf_priv)
{
	struct gc573_mem *m = buf_priv;

	return &m->sgt;
}

static unsigned int gc573_mem_num_users(void *buf_priv)
{
	struct gc573_mem *m = buf_priv;

	return refcount_read(&m->refcount);
}

static void gc573_mem_vm_open(struct vm_area_struct *vma)
{
	struct gc573_mem *m = vma->vm_private_data;

	refcount_inc(&m->refcount);
}

static void gc573_mem_vm_close(struct vm_area_struct *vma)
{
	gc573_mem_put(vma->vm_private_data);
}

static const struct vm_operations_struct gc573_mem_vm_ops = {
	.open	= gc573_mem_vm_open,
	.close	= gc573_mem_vm_close,
};

/* vb2_mmap() has set vm_pgoff to 0: the whole buffer from its start */
static int gc573_mem_mmap(void *buf_priv, struct vm_area_struct *vma)
{
	struct gc573_mem *m = buf_priv;
	int ret;

	ret = vm_map_pages(vma, m->pages, m->n_pages);
	if (ret)
		return ret;

	vm_flags_set(vma, VM_DONTEXPAND | VM_DONTDUMP);
	vma->vm_private_data = m;
	vma->vm_ops = &gc573_mem_vm_ops;
	gc573_mem_vm_open(vma);
	return 0;
}

const struct vb2_mem_ops gc573_vb2_mem_ops = {
	.alloc		= gc573_mem_alloc,
	.put		= gc573_mem_put,
	.vaddr		= gc573_mem_vaddr,
	.cookie		= gc573_mem_cookie,
	.num_users	= gc573_mem_num_users,
	.mmap		= gc573_mem_mmap,
};
