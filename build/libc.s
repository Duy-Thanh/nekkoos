	.file "libc.pas"
# Begin asmlist al_procedures

.section .text.n_libc_$$_memset$pointer$byte$longword,"x"
	.balign 16,0x90
.globl	LIBC_$$_MEMSET$POINTER$BYTE$LONGWORD
LIBC_$$_MEMSET$POINTER$BYTE$LONGWORD:
.globl	MemSet_Pas
MemSet_Pas:
.Lc1:
.seh_proc LIBC_$$_MEMSET$POINTER$BYTE$LONGWORD
# [libc.pas]
# [34] begin
	pushq	%rbp
.seh_pushreg %rbp
.Lc3:
.Lc4:
	movq	%rsp,%rbp
.Lc5:
	leaq	-48(%rsp),%rsp
.seh_stackalloc 48
.seh_endprologue
# Var dest located at rbp-8, size=OS_64
# Var val located at rbp-16, size=OS_8
# Var count located at rbp-24, size=OS_32
# Var p located at rbp-32, size=OS_64
# Var i located at rbp-36, size=OS_32
	movq	%rcx,-8(%rbp)
	movb	%dl,-16(%rbp)
	movl	%r8d,-24(%rbp)
# [35] p := PByte(dest);
	movq	-8(%rbp),%rax
	movq	%rax,-32(%rbp)
# [36] for i := 0 to count - 1 do
	movl	-24(%rbp),%eax
	subl	$1,%eax
	movl	$4294967295,-36(%rbp)
	.balign 8,0x90
.Lj5:
	addl	$1,-36(%rbp)
# [38] p^ := val;
	movq	-32(%rbp),%rdx
	movb	-16(%rbp),%cl
	movb	%cl,(%rdx)
# [39] Inc(p);
	addq	$1,-32(%rbp)
	cmpl	-36(%rbp),%eax
	jnbe	.Lj5
# [41] end;
	leaq	(%rbp),%rsp
	popq	%rbp
	ret
.seh_endproc
.Lc2:

.section .text.n_libc_$$_memcopy$pointer$pointer$longword,"x"
	.balign 16,0x90
.globl	LIBC_$$_MEMCOPY$POINTER$POINTER$LONGWORD
LIBC_$$_MEMCOPY$POINTER$POINTER$LONGWORD:
.globl	MemCopy_Pas
MemCopy_Pas:
.Lc6:
.seh_proc LIBC_$$_MEMCOPY$POINTER$POINTER$LONGWORD
# [49] begin
	pushq	%rbp
.seh_pushreg %rbp
.Lc8:
.Lc9:
	movq	%rsp,%rbp
.Lc10:
	leaq	-48(%rsp),%rsp
.seh_stackalloc 48
.seh_endprologue
# Var dest located at rbp-8, size=OS_64
# Var src located at rbp-16, size=OS_64
# Var count located at rbp-24, size=OS_32
# Var dst located at rbp-32, size=OS_64
# Var s located at rbp-40, size=OS_64
# Var i located at rbp-44, size=OS_32
	movq	%rcx,-8(%rbp)
	movq	%rdx,-16(%rbp)
	movl	%r8d,-24(%rbp)
# [50] dst := PByte(dest);
	movq	-8(%rbp),%rax
	movq	%rax,-32(%rbp)
# [51] s := PByte(src);
	movq	-16(%rbp),%rax
	movq	%rax,-40(%rbp)
# [54] for i := 0 to count - 1 do
	movl	-24(%rbp),%eax
	subl	$1,%eax
	movl	$4294967295,-44(%rbp)
	.balign 8,0x90
.Lj10:
	addl	$1,-44(%rbp)
# [56] dst^ := s^;
	movq	-32(%rbp),%rcx
	movq	-40(%rbp),%rdx
	movb	(%rdx),%dl
	movb	%dl,(%rcx)
# [57] Inc(dst);
	addq	$1,-32(%rbp)
# [58] Inc(s);
	addq	$1,-40(%rbp)
	cmpl	-44(%rbp),%eax
	jnbe	.Lj10
# [60] end;
	leaq	(%rbp),%rsp
	popq	%rbp
	ret
.seh_endproc
.Lc7:

.section .text.n_libc_$$_memcmp$pointer$pointer$longword$$longint,"x"
	.balign 16,0x90
.globl	LIBC_$$_MEMCMP$POINTER$POINTER$LONGWORD$$LONGINT
LIBC_$$_MEMCMP$POINTER$POINTER$LONGWORD$$LONGINT:
.globl	MemCmp_Pas
MemCmp_Pas:
.Lc11:
.seh_proc LIBC_$$_MEMCMP$POINTER$POINTER$LONGWORD$$LONGINT
# [68] begin
	pushq	%rbp
.seh_pushreg %rbp
.Lc13:
.Lc14:
	movq	%rsp,%rbp
.Lc15:
	leaq	-64(%rsp),%rsp
.seh_stackalloc 64
.seh_endprologue
# Var ptr1 located at rbp-8, size=OS_64
# Var ptr2 located at rbp-16, size=OS_64
# Var count located at rbp-24, size=OS_32
# Var $result located at rbp-28, size=OS_S32
# Var p1 located at rbp-40, size=OS_64
# Var p2 located at rbp-48, size=OS_64
# Var i located at rbp-52, size=OS_32
	movq	%rcx,-8(%rbp)
	movq	%rdx,-16(%rbp)
	movl	%r8d,-24(%rbp)
# [69] p1 := PByte(ptr1);
	movq	-8(%rbp),%rax
	movq	%rax,-40(%rbp)
# [70] p2 := PByte(ptr2);
	movq	-16(%rbp),%rax
	movq	%rax,-48(%rbp)
# [72] for i := 0 to count - 1 do
	movl	-24(%rbp),%eax
	subl	$1,%eax
	movl	$4294967295,-52(%rbp)
	.balign 8,0x90
.Lj15:
	addl	$1,-52(%rbp)
# [74] if p1^ < p2^ then
	movq	-40(%rbp),%rdx
	movq	-48(%rbp),%rcx
	movb	(%rdx),%dl
	cmpb	(%rcx),%dl
	jnb	.Lj19
# [76] MemCmp := -1;
	movl	$-1,-28(%rbp)
# [77] Exit;
	jmp	.Lj13
.Lj19:
# [79] else if p1^ > p2^ then
	movq	-40(%rbp),%rdx
	movq	-48(%rbp),%rcx
	movb	(%rdx),%dl
	cmpb	(%rcx),%dl
	jna	.Lj22
# [81] MemCmp := 1;
	movl	$1,-28(%rbp)
# [82] Exit;
	jmp	.Lj13
	.balign 4,0x90
.Lj22:
# [84] Inc(p1);
	addq	$1,-40(%rbp)
# [85] Inc(p2);
	addq	$1,-48(%rbp)
	cmpl	-52(%rbp),%eax
	jnbe	.Lj15
# [88] MemCmp := 0;
	movl	$0,-28(%rbp)
.Lj13:
# [89] end;
	movl	-28(%rbp),%eax
	leaq	(%rbp),%rsp
	popq	%rbp
	ret
.seh_endproc
.Lc12:
# End asmlist al_procedures
# Begin asmlist al_dwarf_frame

.section .debug_frame
.Lc16:
	.long	.Lc18-.Lc17
.Lc17:
	.long	-1
	.byte	1
	.byte	0
	.uleb128	1
	.sleb128	-4
	.byte	16
	.byte	12
	.uleb128	7
	.uleb128	8
	.byte	5
	.uleb128	16
	.uleb128	2
	.balign 4,0
.Lc18:
	.long	.Lc20-.Lc19
.Lc19:
	.secrel32	.Lc16
	.quad	.Lc1
	.quad	.Lc2-.Lc1
	.byte	4
	.long	.Lc3-.Lc1
	.byte	14
	.uleb128	16
	.byte	4
	.long	.Lc4-.Lc3
	.byte	5
	.uleb128	6
	.uleb128	4
	.byte	4
	.long	.Lc5-.Lc4
	.byte	13
	.uleb128	6
	.balign 4,0
.Lc20:
	.long	.Lc22-.Lc21
.Lc21:
	.secrel32	.Lc16
	.quad	.Lc6
	.quad	.Lc7-.Lc6
	.byte	4
	.long	.Lc8-.Lc6
	.byte	14
	.uleb128	16
	.byte	4
	.long	.Lc9-.Lc8
	.byte	5
	.uleb128	6
	.uleb128	4
	.byte	4
	.long	.Lc10-.Lc9
	.byte	13
	.uleb128	6
	.balign 4,0
.Lc22:
	.long	.Lc24-.Lc23
.Lc23:
	.secrel32	.Lc16
	.quad	.Lc11
	.quad	.Lc12-.Lc11
	.byte	4
	.long	.Lc13-.Lc11
	.byte	14
	.uleb128	16
	.byte	4
	.long	.Lc14-.Lc13
	.byte	5
	.uleb128	6
	.uleb128	4
	.byte	4
	.long	.Lc15-.Lc14
	.byte	13
	.uleb128	6
	.balign 4,0
.Lc24:
# End asmlist al_dwarf_frame

