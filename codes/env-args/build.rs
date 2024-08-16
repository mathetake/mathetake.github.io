fn main() {
    let mut compiler = cc::Build::new();
    compiler.file("entry.S");
    compiler.compile("asm.o");

    println!("cargo:rustc-link-arg=-no-pie");
}
