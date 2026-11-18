#!/bin/sh
# Builds the replacement DTS decoder (module/hal/libHwAudio_dtshd.so). Needs clang with ARM target support.
# The stub liblog.so only satisfies the linker (the real one is on the device).
set -e
cd "$(dirname "$0")"
F="--target=armv7a-linux-androideabi21 -fPIC -marm -mfloat-abi=softfp -O2 -fno-builtin -nostdlib"
clang $F -shared -Wl,-soname,liblog.so -o liblog.so stubs.c
clang $F -shared -Wl,-soname,libHwAudio_dtshd.so -Wl,--no-as-needed -L. -llog -o libHwAudio_dtshd.so dtshd_passthrough.c
echo "built $(pwd)/libHwAudio_dtshd.so"
