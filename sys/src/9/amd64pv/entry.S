#include "mem.h"
#include "amd64l.h"
#ifndef __ASSEMBLER__
#define __ASSEMBLER__
#endif

// It gets REALLY ugly to try  to link this at some low address and then have the rest of the
// kernel linked high. Really, really ugly. And that defines any attempt to load at a randome
// address. So, you have to learn to write position independent code here. 
// It will make you stronger. Assuming you survive the training.
.code32

#define pFARJMP32(s, o)	.byte 0xea;	.long o; .word s	/* far jump to ptr32:16 */


/* do we enter in 16-bit mode? If so, take the code from coreboot that goes from
 * 16->32
 */
/*
 * Enter here in 32-bit protected mode. Welcome to 1982.
 * Make sure the GDT is set as it should be:
 *	disable interrupts;
 *	load the GDT with the table in _gdt32p;
 *	load all the data segments
 *	load the code segment via a far jump.
 */
#define MULTIBOOT_PAGE_ALIGN  (1<<0)
#define MULTIBOOT_MEMORY_INFO (1<<1)
#define MULTIBOOT_HEADER_MAGIC (0x1BADB002)
#define MULTIBOOT_HEADER_FLAGS (MULTIBOOT_MEMORY_INFO | MULTIBOOT_PAGE_ALIGN)
#define CHECKSUM (-(MULTIBOOT_HEADER_MAGIC + MULTIBOOT_HEADER_FLAGS))

# The kernel bootstrap (this code) is linked and loaded at physical address
# 0x00100000 (1MB), which is the start of extended memory.  (See kernel.ld)

# Flagging boottext to be text.  Check out:
# http://sourceware.org/binutils/docs/as/Section.html
.section .boottext, "awx"

.code64
.align 4
_protected:
multiboot_header:
.long MULTIBOOT_HEADER_MAGIC
.long MULTIBOOT_HEADER_FLAGS
.long CHECKSUM

	// how easy is this? This easy: we have paging set up already.
	// but for now, let's see how it goes.
	.globl _start
_start:

/*
 * Make the basic page tables for CPU0 to map 0-4MiB physical
 * to KZERO, and include an identity map for the switch from protected
 * to paging mode. There`s an assumption here that the creation and later
 * removal of the identity map will not interfere with the KZERO mappings;
 * the conditions for clearing the identity map are
 *	clear PML4 entry when (KZER0 & 0x0000ff8000000000) != 0;
 *	clear PDP entry when (KZER0 & 0x0000007fc0000000) != 0;
 *	don`t clear PD entry when (KZER0 & 0x000000003fe00000) == 0;
 * the code below assumes these conditions are met.
 *
 * Assume a recent processor with Page Size Extensions
 * and use two 2MiB entries.
 */
/*
 * The layout is decribed in data.h:
 *	_protected:	start of kernel text
 *	- 4*KiB		unused
 *	- 4*KiB		unused
 *	- 4*KiB		ptrpage
 *	- 4*KiB		syspage
 *	- MACHSZ	m
 *	- 4*KiB		vsvmpage for gdt, tss
 *	- PTSZ		PT for PMAPADDR		unused - assumes in KZERO PD
 *	- PTSZ		PD
 *	- PTSZ		PDP
 *	- PTSZ		PML4
 *	- MACHSTKSZ	stack
 */

/*
 * Macros for accessing page table entries; change the
 * C-style array-index macros into a page table byte offset
 */
#define PML4O(v)	((PTLX((v), 3))<<3)
#define PDPO(v)		((PTLX((v), 2))<<3)
#define PDO(v)		((PTLX((v), 1))<<3)
#define PTO(v)		((PTLX((v), 0))<<3)

_warp64:
	movl	$_protected-(MACHSTKSZ+4*PTSZ+5*(4*KiB)+MACHSZ/*+KZERO*/), %esi

	movl	%esi, %edi
	xorl	%eax, %eax
	movl	$((MACHSTKSZ+4*PTSZ+5*(4*KiB)+MACHSZ)>>2), %ecx

	cld
	rep;	stosl				/* stack, P*, vsvm, m, sys */

	movl	%esi, %eax				/* sys-KZERO */
	addl	$(MACHSTKSZ), %eax		/* PML4 */
//	movl	%eax, %CR3				/* load the mmu */
	movq	%rax, %R15				/* load the mmu */
	movl	%eax, %edx
	addl	$(PTSZ|PteRW|PteP), %edx		/* PDP at PML4 + PTSZ */
	movl	%edx, PML4O(0)(%eax)		/* PML4E for identity map */
	movl	%edx, PML4O(KZERO)(%eax)		/* PML4E for KZERO, PMAPADDR */

	addl	$PTSZ, %eax			/* PDP at PML4 + PTSZ */
	addl	$PTSZ, %edx			/* PD at PML4 + 2*PTSZ */
	movl	%edx, PDPO(0)(%eax)			/* PDPE for identity map */
	movl	%edx, PDPO(KZERO)(%eax)		/* PDPE for KZERO, PMAPADDR */

	addl	$PTSZ, %eax			/* PD at PML4 + 2*PTSZ */
	movl	$(PtePS|PteRW|PteP), %edx
	movl	%edx, PDO(0)(%eax)			/* PDE for identity 0-[24]MiB */
	movl	%edx, PDO(KZERO)(%eax)		/* PDE for KZERO 0-[24]MiB */
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+PGLSZ(1))(%eax)	/* PDE for KZERO [24]-[48]MiB */
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+PGLSZ(1)+PGLSZ(1))(%eax)	/* PDE for KZERO [4]-[6]MiB */
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+PGLSZ(1)+PGLSZ(1)+PGLSZ(1))(%eax)	/* PDE for KZERO [6]-[8]MiB */
	// and up through 12. This sucks, we'll make it better later. //
	// We'll just have init the pml2 at compile time. Apologies.
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+PGLSZ(1)+PGLSZ(1)+PGLSZ(1)+PGLSZ(1))(%eax)
	addl	$PGLSZ(1), %edx
	movl	%edx, PDO(KZERO+PGLSZ(1)+PGLSZ(1)+PGLSZ(1)+PGLSZ(1)+PGLSZ(1))(%eax)

	movl	%eax, %edx				/* PD at PML4 + 2*PTSZ */
	addl	$(PTSZ|PteRW|PteP), %edx		/* PT at PML4 + 3*PTSZ */
	movl	%edx, PDO(PMAPADDR)(%eax)		/* PDE for PMAPADDR */
	movq	%r15, %cr3				/* load the mmu */
/*
 * Long mode. Welcome to 2003.
 * Jump out of the identity map space;
 * load a proper long mode GDT.
 */
.code64

_identity:
	movq	$_start64v, %rax
	JMP	*%rax
.code64
.section .text
_gdt64v:
	.quad	0x0000000000000000		/* NULL descriptor */
	.quad	0x0020980000000000		/* CS */

_gdtptr64v:
	.word	3*8-1
	.quad	_gdt64v

// At this point, we are safe to use kernel addresses, as we are in
// kernel virtual address space.
_start64v:
	movq	$_gdtptr64v, %rax
	lgdt	(%rax)

	XORQ	%rdx, %rdx
	movw	%dx, %ds				/* not used in long mode */
	movw	%dx, %es				/* not used in long mode */
	movw	%dx, %fs
	movw	%dx, %gs
	movw	%dx, %ss				/* not used in long mode */

	movq	%rsi, %rsi				/* sys-KZERO */
	movq	%rsi, %rax
	addq	$KZERO, %rax
	movq	%rax, sys			/* sys */

	addq	$(MACHSTKSZ), %rax		/* PML4 and top of stack */
	movq	%rax, %rsp				/* set stack */

	PUSHQ	%rdx				/* clear flags */
	POPFQ

	movq	%rbx, %rbx				/* push multiboot args */
	movq	%rbx, %rsi
	movq	%rax, %rax
	movq	%rax, %rdi				/* multiboot magic */
	CALL	main

.globl ndnr
ndnr:	/* no deposit, no return */
	/* do not resuscitate */
_dnr:
	sti
	hlt
	JMP	_dnr				/* do not resuscitate */

