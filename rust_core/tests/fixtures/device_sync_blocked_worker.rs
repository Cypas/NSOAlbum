// Test-only hostile worker: neither reads stdin nor writes stdout.
fn main() {
    loop {
        std::thread::park();
    }
}
