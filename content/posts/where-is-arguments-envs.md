---
title: "So, Where Exactly Do Arguments and Environment Variables Come From?"
date: "2024-08-16"
summary: "Identifying the source of arguments and environment variables in a Linux process."
toc: false
readTime: false
autonumber: true
math: true
tags: ["Linux", "ELF"]
showTags: false
hideBackToTop: true
---

A few months ago, I wrote two toy Linux ELF loaders in Rust. One is called [tvisor](https://github.com/mathetake/tvisor)
which is a system call interceptor, and the other is called [alvm](https://github.com/mathetake/alvm) which basically
tries to run a Linux ELF binary in a Apple Hypervisor.framework VM without a linux kernel. Both of them are just
PoC and not really useful in practice, but I learned a lot from writing them.

Loading an ELF by hand essentially requires you to understand, of course, the ELF format, but also how a Linux userland
process is created. One of the most important aspects of a user process is its arguments and environment variables. That is 
what every single one of programs out there uses in some way. So I figured I should write a short post about **Where
exactly are the arguments and environment coming from?** Of course, just reading the Linux kernel source code is one
way to understand this, but I'll try to explain it in a more digestible way.[^1]

In Go, you can access the arguments and environment variables of the current process using `os.Args` and `os.Environ()` respectively.
In Rust, you can use `std::env::args()` and `std::env::vars()`. How do these work? If you dig deep enough into Go runtime,
you will find[^2] that `os.Envs` is essentially coming from something called `argv` and `argc` ([source](https://github.com/golang/go/blob/0320616db9e21fd8811a2189a56f234b9737f95f/src/runtime/runtime1.go#L82-L95), [source2](https://github.com/golang/go/blob/0320616db9e21fd8811a2189a56f234b9737f95f/src/runtime/runtime1.go#L54-L57)).
Yes, `argv` and `argc` are the ones you might have seen in the `main` function in C: `main(int argc, char *argv[])`.

So now you know that args and envs are implemented through some mysterious `argv` and `argc` variables. But where are `argv` and `argc` coming from? How are they
created? How are they related to the environment variables?

The short answer is that arguments and environment variables are written to the initial program stack by the kernel. 
When a new process is created, the kernel sets up the initial stack for the process. Here, a stack means the 
memory region pointed by the stack pointer register (e.g. `rsp` regiter in x86_64 or `sp` register in AArch64) at the very beginning of the process. 
The kernel writes the arguments and environment _above_ the initial stack pointer, and it is a program's responsibility to parse them.
So essentially, when you have the initial stack pointer, you can access the arguments and environment variables in theory.

tvisor is a "freestanding Linux executable" written in Rust, and it loads a Linux ELF binary in the same process. In order to avoid conflicts
in glibc usage, the binary was built in a way that it doesn't use standard library, hence freestanding. But it still needs to
access the arguments and environment variables of the process. So, I had to implement the logic to parse `argv` and `argc` by hand.
I will use a simplified version of the source code in tvisor as an example for the rest of this post.

First of all, I had to pass the initial stack pointer to a Rust function. I did this by writing a small assembly code that
calls a Rust function with the stack pointer as an argument. The assembly code is as follows:

```asm
.global _start ;; Special symbol for the entry point.
_start:
    ;; Set the first argument to the stack pointer following
    ;; the standard calling convention.
	mov %rsp, %rdi
	;; Call the Rust function.
	jmp   rust_start
.section .text
```

where `rust_start` is a Rust function that takes the stack pointer as an argument. The actual source code is [here](https://github.com/mathetake/tvisor/blob/3c1bcb2a6fae7053a65909de10e0b09a190eee28/tvisor/asm/entry_x86_64.S).
Now, let's see what `main.rs` would look like.

```rust
#[no_mangle]
pub unsafe extern "C" fn rust_start(stack_ptr: *const *const u8) {
    let argc = *stack_ptr as isize;
    let argv = stack_ptr.offset(1);
    // ....
}
```

which simply declares a function `rust_start` that takes a pointer to a pointer to a `u8` as an argument as you expect[^3].
And more importantly, the first element of the stack is the `argc` which is the number of arguments, 
and the second element is the `argv` which is a pointer to the first argument ([the code is here](https://github.com/mathetake/tvisor/blob/3c1bcb2a6fae7053a65909de10e0b09a190eee28/tvisor/src/lib.rs#L84-L85)).

The following code is parsing the arguments and environment variables based on the `argc` and `argv`:

```rust
#[no_mangle]
pub unsafe extern "C" fn rust_start(stack_ptr: *const *const u8) {
    // ....

    // argv is a pointer to the first argument, and each argument is a null-terminated string.
    for i in 0..argc {
        let arg = *argv.offset(i);
        // Search the null terminator to get the size of the argument.
        let mut arg_size = 0;
        while *arg.offset(size) != 0 {
            size += 1;
        }
        // Do something with the arg.
    }

    // The enviroment variable starts after the arguments.
    // Each environment variable is a null-terminated string.
    // The number of environment variables is unknown, so we need to search for the null pointer
    // that is the end of the environment variable array.
    let mut envp = argv.offset(argc + 1) // +1 because NULL follows the arguments.
    while !(*envp).is_null() {
        let env = *envp;
        let mut env_size = 0;
        // Search the null terminator to get the size of the env.
        while *env.offset(size) != 0 {
            env_size += 1;
        }
        // Do something with the env.
    }

    // ........
}
```

as you can see, the stack is laid out in a way that the arguments are followed by the environment variables.
More precisely, the layout is as follows:

```
    Lower address
+-------------------+ <---- the initial stack pointer
|       argc        |
+-------------------+
|      argv[0]      |  -> points to the null-terminated first argument
+-------------------+
|      argv[1]      |  -> points to the null-terminated second argument
+-------------------+
|       ...         |
+-------------------+
|   argv[argc-1]    |  -> points to the null-terminated last argument
+-------------------+
|       NULL        |
+-------------------+
|      envp[0]      |  -> points to the null-terminated first environment variable
+-------------------+
|      envp[1]      |  -> points to the null-terminated second environment variable
+-------------------+
|       ...         |
+-------------------+
|       env[N]      |  -> points to the null-terminated last environment variable
+-------------------+
|       NULL        |
+-------------------+
   Higher address
```

so this is exactly where the arguments and environment variables are coming from. 
The kernel writes them to the initial stack of the process, and each item is a pointer to the actual string.
But you might wonder where are these actual "strings" stored? By inspecting the absolute addresses of each argument and environment variable pointer,
you can that the real "strings" are stored after some offset from the initial stack pointer.
You can run the complete code [here](https://github.com/mathetake/mathetake.github.io/tree/main/codes/env-args) to check the actual addresses of the arguments and environment variables strings.

After the environment variables, something called "auxiliary vectors" are stored. But that is 
out of the scope here. Basically, the auxiliary vectors are used to pass some additional information to userland processes. This article [_About ELF Auxiliary Vectors_ by Manu Garg](https://articles.manugarg.com/aboutelfauxiliaryvectors)
is the best resource I've found on the internet that explains the layout of the initial stack in a Linux process in detail.
I highly recommend reading it if you are interested in more details.

This post does nothing special but explains the basics of how arguments and environment variables are passed to a Linux user process.
I hope this post helps those who want to understand the internals of high-level standard library functions like `os.Args` and `os.Environ()`.

See you next time!

[^1]: Getting envs from "argv" is more generic than just on Linux, but I'll focus on Linux in this post.

[^2]: This is totally dependent on the target OS. For example, since there's no "memory stack" in WebAssembly, `os.Args` and `os.Environ()` are implemented via system calls `args_get` and `environ_get` in the case of WASI.

[^3]: The actual tvisor code is [here](https://github.com/mathetake/tvisor/blob/3c1bcb2a6fae7053a65909de10e0b09a190eee28/tvisor/src/lib.rs#L48-L50), though tvisor's core is a library
so the main function is defined in a macro in the actual code.