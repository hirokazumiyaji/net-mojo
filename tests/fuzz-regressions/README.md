# Retained protocol regressions

Only small, reviewed inputs belong here. Generated corpora remain under
ignored `build/fuzz/`.

`hpack/serialized-xy.bin` contains one serialized `x: y` field: four-byte
big-endian name and value lengths (both 1), followed by `xy`. It records the
Issue #227 harness regression where deriving every encode limit from the last
input bytes could exclude successful encoding of an ordinary field.

The ordinary `hpack-test` checks its encoded bound, decoded field count,
header-list accounting and exact field contents. `fuzz-native-build` confirms
the same fixture reaches successful encoding through the native harness;
`fuzz-driver-test` confirms it enters both native and Mojo seed corpora.
