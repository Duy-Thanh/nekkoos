ENTRY(_start)
SECTIONS
{
  . = 0x40080000;
  .text   : { *(.text.boot) *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data   : { *(.data .data.*) }
  . = ALIGN(16);
  __bss_start = .;
  .bss    : { *(.bss .bss.* COMMON) }
  . = ALIGN(16);
  __bss_end = .;
  . = ALIGN(4096);
  . += 0x10000;
  __stack_top = .;
  __image_size = __bss_end - 0x40080000;
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
