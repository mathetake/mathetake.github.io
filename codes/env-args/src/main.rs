#![no_std]
#![no_main]

use core::fmt;
use core::fmt::Write;
use syscalls::*;

#[no_mangle]
pub unsafe extern "C" fn rust_start(stack_ptr: *const *const u8) {
    println!("sp: {:p}", stack_ptr);
    let argc = *stack_ptr as isize;
    let argv = stack_ptr.offset(1);

    // Write argv.
    for i in 0..argc {
        let arg = *argv.offset(i);
        let mut size = 0;
        while *arg.offset(size) != 0 {
            size += 1;
        }
        let arg_str =
            core::str::from_utf8(core::slice::from_raw_parts(arg, size.try_into().unwrap()))
                .unwrap();
        println!("argv={:p}/arg={:p}: {}", argv.offset(i), arg, arg_str);
    }
    let mut envp = argv.offset(argc + 1);
    while !(*envp).is_null() {
        let env = *envp;
        let mut size = 0;
        while *env.offset(size) != 0 {
            size += 1;
        }
        let env_str =
            core::str::from_utf8(core::slice::from_raw_parts(env, size.try_into().unwrap()))
                .unwrap();
        println!("{:p}: {}", envp, env_str);
        envp = envp.offset(1);
    }
}

use core::panic::PanicInfo;
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    loop {}
}

#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => ($crate::_print(format_args!($($arg)*)));
}

#[macro_export]
macro_rules! println {
    () => ($crate::print!("\n"));
    ($($arg:tt)*) => ($crate::print!("{}\n", format_args!($($arg)*)));
}

pub fn _print(args: fmt::Arguments) {
    let mut stdout = Stderr;
    stdout.write_fmt(args).unwrap();
}

struct Stderr;

impl Write for Stderr {
    fn write_str(&mut self, s: &str) -> fmt::Result {
        emit_bytes(2, s.as_bytes());
        Ok(())
    }
}

fn emit_bytes(fd: i32, bytes: &[u8]) {
    unsafe {
        match syscall!(Sysno::write, fd, bytes.as_ptr(), bytes.len()) {
            Ok(_) => {}
            Err(err) => panic!("Failed to write bytes: {}", err),
        }
    }
}
