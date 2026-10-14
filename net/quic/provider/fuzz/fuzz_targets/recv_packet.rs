#![no_main]

use libfuzzer_sys::fuzz_target;
use net_quic_provider_fuzz::{MAX_INPUT, receive};
use std::ffi::CString;
use std::sync::OnceLock;

fuzz_target!(|input: &[u8]| {
    if input.len() > MAX_INPUT {
        return;
    }
    static CERTIFICATES: OnceLock<(CString, CString)> = OnceLock::new();
    let (certificate, key) = CERTIFICATES.get_or_init(|| {
        (
            CString::new(std::env::var("NET_HTTP_TEST_CERT").unwrap()).unwrap(),
            CString::new(std::env::var("NET_HTTP_TEST_KEY").unwrap()).unwrap(),
        )
    });
    receive(input, certificate, key);
});
