---
title: "Runtime code generation and execution in Go: Part 1"
date: "2024-05-19"
summary: "Part 1 of the introduction to the weird world of runtime code generation and execution in Go"
toc: false
readTime: false
autonumber: true
math: true
tags: ["Go", "compiler"]
showTags: false
hideBackToTop: true
---

**Disclaimer: I won't expand on why/when you want to do kind of hack, and you should not do this unless you know exactly what you are doing. 
Everything I talk about here is completely unsafe and might not be accurate for the future Go versions. This is not a recommendation, but more of a fun story.**

A few days ago, I posted about the idea of a blog post on runtime code generation and execution in Go:

<blockquote class="twitter-tweet"><p lang="en" dir="ltr">feel like i should write a blog post about how to write JIT engine in pure Go and really weird bugs I encountered in the development of wazero&#39;s compiler if anyone wants to read</p>&mdash; Takeshi Yoneda(マスタケ) (@mathetake) <a href="https://twitter.com/mathetake/status/1791699003467542569?ref_src=twsrc%5Etfw">May 18, 2024</a></blockquote> <script async src="https://platform.twitter.com/widgets.js" charset="utf-8"></script>


And it got a lot of attention way more than I expected, so I decided to do it. I don't think single post is enough to cover all I want to share, 
so I'll split it into multiple posts (please hope I won't die before I finish it).

First of all, who am I? In case you don't know me, which is likely the case for most of you, 
I'm an open source software engineer working for a startup called [Tetrate.io](https://tetrate.io/).
In the last few years, I was knee-deep in the space of WebAssembly and its ecosystem, 
and service mesh related software like Envoy and Istio([^1],[^2]). I've mostly written Go/C++ at work, but also like to use Rust and Zig[^6] in side projects.

More importantly, I am the creator of [wazero](https:://github.com/tetratelabs/wazero) WebAssembly runtime, and that's 
where I learned tons of things about runtime code generation and execution in Go.
wazero was once a part of my hobby project, but luckily it became a part of my job in the last 2.5 years thanks to the support by my employer.

wazero is an extremely unique and rare piece of production software out there in the Go ecosystem in the sense that
it generates semantically equivalent x86-64 and AArch64 machine code from WebAssembly bytecode at runtime,
and then provides the API to execute and interact with it **with zero dependency, hence without CGo**. At the GopherCon 2022, I gave a talk on wazero, so if you are more curious
about wazero itself, please take a look at my talk[^3] as well as the wazero's [website](https://wazero.io). It has a neat documentation about
how its optimizing compiler works[^5].

This post is decoupled from wazero itself, and I'll focus on the general concept of runtime code generation and execution in Go.
In the subsequent posts, if I have enough time and energy, I'll dive into quirky bugs I encountered in the development of wazero's compiler. 
Hope you can enjoy the post, and feel free to ask me anything on [X/Twitter](https://twitter.com/mathetake). 
I spend more of spare time on hacking weird low-level stuff you can find on my [GitHub](https://github.com/mathetake), so check it out if you are interested.


From here, I assume readers have the basic understanding of Go as well as the concepts of stack and function calls in the low-level programming.

## Terminology: Runtime Code Generation and Execution vs (JIT, AOT)

Okay, the first things first, let me clarify wtf I meant by "runtime code generation and execution".
I intentionally stick to use the phrase "runtime code generation and execution" instead of the simple "JIT" (Just-In-Time) or "AOT" (Ahead-Of-Time) compilation, where
the latter two are more common terms in general. But I find them confusing and misused sometimes[^4].

**AOT** generally refers to the process of compiling the source code into machine code **before** the execution of the program.
In contrast, **JIT** refers to the process of compiling the source code into machine code **during** the execution of the program.

But this creates a confusion: What if we compile a piece of source program _in a process_ and then execute it _in the same process_,
do you call it AOT or JIT? Sure, it is clear that that is not JIT in the same sense as the JIT in the JVMs because 
it doesn't compile during the execution, but on the other hand, it does "compilation during execution (of the host program)".
In WebAssembly community in general, people sometimes mistakenly call this kind of "runtime code generation and execution" as JIT.
Actually, wazero used to call itself as JIT runtime, but later we decided to avoid the term. As far as I understand, most of the "WebAssembly runtime"
out there are _not_ JIT in the sense of JVMs[^8], but they are more like AOT. 

So anyway, I stick to use the term "runtime code generation and execution" to avoid the confusion, though it is not a standard term and verbose.
In other words, what I am going to talk about is **a pure Go program that generates a machine code and executes it in the same process**. I might call the 
generated machine code as "JITed code", but it's the only exception.

## Prior art

So I guess the "runtime code generation and execution" sounds terrible and pretty crazy to you and normal Go developers.
I was also one of you until I started to work on wazero. But actually, there are some prior arts in the Go ecosystem that do similar things,
or at least there have been some attempts to do so. Basically, I am definitely not the only crazy person who wanted to do this kind of stuff in Go.
With the quick search on the web, I found the following projects besides wazero:

* https://github.com/nelhage/gojit
* https://github.com/bspaans/jit-compiler
* https://www.quasilyte.dev/blog/post/call-go-from-jit/
* https://github.com/quasilyte/go-jdk
* https://github.com/bytedance/sonic

Note that all of them were trying to do it without CGo since it's clearly possible to do runtime code generation and execution with CGo.
You can do whatever you want with CGo, but you know that's not what we want.

## Overview

Basically, the runtime code generation and execution in Go can be broken down into the following steps:

1. Generate Machine code represented as `[]byte` slice which contains the architecture-specific machine code.
2. Mark the machine code as executable and readable, usually using `mmap` on Unix-like systems.
3. Take the first address of the machine code as `unsafe.Pointer(&slice[0])`.
4. Call the "trampoline" Go Asm function with the address of the machine code as an argument.[^7]
5. Jump to the machine code from the trampoline function.

where the step 1 and 2 are the "code generation" part, and the rest is the "execution" part. To be clear, these will be 
almost the same for any language, but in the case of pure Go, we **really really really** need to be careful about the Go runtime behavior
and its implementation details in order to ensure the execution won't piss off the runtime. 
That affects the design of the code generation part as well as the execution part.

How serious is it? Well, let me give you some terrifying example of what can happen if you make a bug in the code generation part:
If you make this kind of bug like the following

```diff
diff --git a/internal/engine/wazevo/backend/isa/arm64/abi.go b/internal/engine/wazevo/backend/isa/arm64/abi.go
index 6615471c..1747eafa 100644
--- a/internal/engine/wazevo/backend/isa/arm64/abi.go
+++ b/internal/engine/wazevo/backend/isa/arm64/abi.go
@@ -19,9 +19,8 @@ var regInfo = &regalloc.RegisterInfo{
        AllocatableRegisters: [regalloc.NumRegType][]regalloc.RealReg{
                // We don't allocate:
                // - x18: Reserved by the macOS: https://developer.apple.com/documentation/xcode/writing-arm64-code-for-apple-platforms#Respect-the-purpose-of-specific-CPU-registers
-               // - x28: Reserved by Go runtime.
                // - x27(=tmpReg): because of the reason described on tmpReg.
-               regalloc.RegTypeInt: {
+               regalloc.RegTypeInt: {x28,
                        x8, x9, x10, x11, x12, x13, x14, x15,
                        x16, x17, x19, x20, x21, x22, x23, x24, x25,
                        x26, x29, x30,
```

where I mistakenly allows the use of AArch64's `x28` register in the generated machine code in wazero. The register is reserved and the value must
be the same across the execution to play nicely with the Go runtime.[^9] If you run the test, and then you would get errors like the following (really depends on the kind of bug you made and the platform you are on):
```shell
traceback: unexpected SPWRITE function runtime.morestack
fatal error: traceback

runtime stack:
runtime.throw({0x100ecb49d?, 0x100d05fa0?})
	/usr/local/go/src/runtime/panic.go:1023 +0x40 fp=0x1729aed40 sp=0x1729aed10 pc=0x100ccd1b0
runtime.(*unwinder).resolveInternal(0x1729aee90, 0x0?, 0xee?)
	/usr/local/go/src/runtime/traceback.go:364 +0x318 fp=0x1729aedc0 sp=0x1729aed40 pc=0x100cfa108
runtime.(*unwinder).next(0x1729aee90)
	/usr/local/go/src/runtime/traceback.go:512 +0x160 fp=0x1729aee50 sp=0x1729aedc0 pc=0x100cfa2b0
runtime.(*_panic).nextFrame.func1()
	/usr/local/go/src/runtime/panic.go:938 +0x8c fp=0x1729aef10 sp=0x1729aee50 pc=0x100cccddc
runtime.systemstack(0x7ff000)
	/usr/local/go/src/runtime/asm_arm64.s:243 +0x6c fp=0x1729aef20 sp=0x1729aef10 pc=0x100d05f0c
```

which is totally cryptic and hard to debug. This is just one example, and there are many other ways to make the Go runtime angry.
So in other words, the generated machine code must be tailored to the Go runtime behavior,
and that's the most challenging part of the runtime code generation and execution in Go.


## Smallest demo

The following is the smallest demo of the runtime code generation and execution in Go. I assume you are on a Unix-like system like Linux or macOS on an AArch64 machine,
and you have Go installed on your machine.

First, we prepare two source codes:
```shell
$ ls
go.mod          main.go         main_arm64.s
```

The main.go is the main Go source code, and the main_arm64.s is the Go Assembly source code.
The main.go is the following:

```go
// main.go
package main

import (
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

	// 2. TODO: Write machine code to machineCodeBuf.

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
```

where what the `main` function is supposed to do is the following:
1. Allocate memory for machine code via `mmap`. At this point, the memory is not executable, but read-writable.
2. Write machine code to the allocated memory region. At this point, I left it as TODO.
3. Mark the memory region as executable. This marks the memory region as read-executable.
4. Execute the machine code.

For the purpose of mmap and how they work in general, please refer to the wonderful article by [@elibendersky](https://x.com/elibendersky): [How to JIT - an introduction](https://eli.thegreenplace.net/2013/11/05/how-to-jit-an-introduction).
In my blog posts, I won't go into the details on that, and focus on the code generation and execution part.[^10]


The `exec` function is implemented as a Go Assembly function in `main_arm64.s` as follows[^11]:

```
// main_arm64.s
#include "funcdata.h"
#include "textflag.h"

TEXT ·exec(SB), NOSPLIT|NOFRAME, $0-8
    // Load the entry point of the executable into R27.
    MOVD entrypoint+0(FP), R27 
    // Jump to the entry point of the executable stored in R27.
    JMP  (R27)
```

That's it. Let's compile and run the program:

```
$ go run .
entrypoint: 0x1051c4000
SIGILL: illegal instruction
PC=0x1051c4000 m=0 sigcode=2
instruction bytes: 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0 0x0

goroutine 1 gp=0x140000021c0 m=0 mp=0x104e3a4c0 [running]:
runtime: g 1 gp=0x140000021c0: unknown pc 0x1051c4000
stack: frame={sp:0x1400010aec0, fp:0x0} stack=[0x1400010a000,0x1400010b000)
```

The error you are observing is something that you would **never** encounter in the normal Go program (if you encounter this with normal Go code, that is highly like a bug in the Go compiler!). 
But fear not, this is the expected behavior. If you take a closer look at the error message, you can see 
that the program tried to execute the machine code at the address `0x1051c4000`, 
which is the address of the machine code we allocated via `mmap`. But the machine code is not written yet,
so the CPU tried to execute the zero-filled memory region, and that's why you got the `SIGILL` error since
the AArch64 instruction encoded as `0x00000000` is ["Undefined/UDF" instruction](https://developer.arm.com/documentation/ddi0596/2020-12/Base-Instructions/UDF--Permanently-Undefined-).

One thing you also notice is that the error says `unknown pc 0x1051c4000`. This is because the Go runtime is not aware of the machine code you generated,
and it doesn't have the debug information for the machine code.

Okay, how can we fix this? One of the smallest functions is the one just that returns, so let's write the machine code for that:

```diff
--- a/codes/runtime_code_generation_in_go/main.go
+++ b/codes/runtime_code_generation_in_go/main.go
@@ -1,6 +1,7 @@
 package main
 
 import (
+       "encoding/binary"
        "fmt"
        "syscall"
        "unsafe"
@@ -14,7 +15,8 @@ func main() {
        // 1. Allocate memory for machine code via mmap. At this point, the memory is not executable, but read-writable.
        machineCodeBuf := mustAllocateByMMap()
 
-       // 2. TODO: Write machine code to machineCodeBuf.
+       // 2. Write machine code to machineCodeBuf that just returns.
+       binary.LittleEndian.PutUint32(machineCodeBuf, 0xd6_5f_03_c0)
 
        // 3. Mark the memory region as executable. This marks the memory region as read-executable.
        mustMarkAsExecutable(machineCodeBuf)
```

this patch writes the AArch64 machine code for the `RET` instruction to the allocated memory region.
The machine code `0xd6_5f_03_c0` is its encoding as described in the [AArch64 manual](https://developer.arm.com/documentation/ddi0596/2020-12/Base-Instructions/RET--Return-from-subroutine-).
Note that AArch64 is a little-endian architecture, and each instruction is encoded as a 32-bit word.

Let's run the program again:

```shell
$ go run .
entrypoint: 0x1050dc000
ok
```

Cool innit? The program successfully executed the machine code that just returns, and the program prints `ok` as expected from the `main` function.


## Conclusion

In this post, I introduced the concept of runtime code generation and execution in Go, and showed the smallest demo of it.
The demo is really simple, so I guess readers can understand the basic idea of runtime code generation and execution in Go, but at the same time
still have no idea on how to write the machine code for the real function or program. In other words, I didn't explain how to perform function calls just like
any normal Go program does as well as how to return the results from the JITed code to the caller in the Go world. That's what I am going to cover in the next series of posts.

If you have any questions or feedback, please let me know on [X/Twitter](https://twitter.com/mathetake). I am happy to answer any questions you have. 
Also, I am always looking for an exciting project/problem to work on, so if you have anything in mind and think I can help with it, please let me know as well, I would love to chat.

See you in the next post!

[^1]: I am one of the authors of Istio's Wasm plugin system: https://istio.io/latest/blog/2021/wasm-api-alpha/
[^2]: I served as a commiter of Envoy/Proxy-Wasm project before.
[^3]: [GopherCon 2022: Takeshi Yoneda - CGO-less Foreign Function Interface with WebAssembly](https://www.youtube.com/watch?v=HcRSe4Y-1Fc)
[^4]: In wazero, we switched to avoid the explicit use of AOT or JIT in the codebase and API. [wazero#560](https://github.com/tetratelabs/wazero/issues/560)
[^5]: https://wazero.io/docs/how_the_optimizing_compiler_works/
[^6]: [I contributed some patches to the Zig compiler](https://github.com/ziglang/zig/commits?author=mathetake)
[^7]: It is possible to convert the machine code as a Go function, but it gets hairy for various reasons.
[^8]: It is well-known that browser based WebAssembly runtime like V8 is JIT in typical sense.
[^9]: [Go internal ABI specification](https://github.com/golang/go/blob/49d42128fd8594c172162961ead19ac95e247d24/src/cmd/compile/abi-internal.md) details how the Go runtime uses the registers in its implementation.
[^10]: On AArch64, the OS typically forbids read-write-executable memory regions in the user land, so you need to mark the memory region as read-executable after writing the machine code. That is controlled by the `SCTL` register only accessible in the privileged mode. For more details, see "Preventing execution from writable locations" section in the [AArch64 manual](https://developer.arm.com/documentation/ddi0406/c/System-Level-Architecture/Virtual-Memory-System-Architecture--VMSA-/Memory-access-control/Execute-never-restrictions-on-instruction-fetching?lang=en#BEIEAHHI).
[^11]: For the syntax of assembly, please refer to [A Quick Guide to Go's Assembler](https://go.dev/doc/asm).