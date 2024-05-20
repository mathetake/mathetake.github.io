package main

import (
	"encoding/binary"
	"fmt"
	"syscall"
	"unsafe"
)

// exec is implemented as a Go Assembly function in main_arm64.s
// entrypoint is the initial address of the machine code.
func exec(entrypoint uintptr)

func main() {
	// 1. Allocate memory for machine code via mmap. At this point, the memory is not executable, but read-writable.
	machineCodeBuf := mustAllocateByMMap()

	// 2. Write machine code to machineCodeBuf.
	binary.LittleEndian.PutUint32(machineCodeBuf, 0xd6_5f_03_c0)

	// 3. Mark the memory region as executable. This marks the memory region as read-executable.
	mustMarkAsExecutable(machineCodeBuf)

	// 4. Execute the machine code.
	entrypoint := uintptr(unsafe.Pointer(&machineCodeBuf[0]))
	fmt.Printf("entrypoint: %#x\n", entrypoint)
	exec(entrypoint)

	fmt.Println("ok")
}

// mustAllocateByMMap returns a memory region that is read-writable via mmap.
func mustAllocateByMMap() []byte {
	machineCodes, err := syscall.Mmap(-1, 0,
		// For the purpose of blog post, we allocate 10 pages of memory. That should be enough.
		syscall.Getpagesize()*10,
		syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_ANON|syscall.MAP_PRIVATE,
	)
	if err != nil {
		panic(err)
	}
	return machineCodes
}

// mustMarkAsExecutable marks the memory region as read-executable via mprotect.
func mustMarkAsExecutable(machineCodes []byte) {
	if err := syscall.Mprotect(machineCodes, syscall.PROT_READ|syscall.PROT_EXEC); err != nil {
		panic(err)
	}
}
