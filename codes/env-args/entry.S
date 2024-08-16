.global _start
_start:
	mov %rsp, %rdi
	jmp   rust_start
    ud2
.section .text