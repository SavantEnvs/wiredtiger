#!/usr/bin/env bash
#
# mayhem/build.sh — build the WiredTiger fuzz harnesses (fuzz_config, fuzz_modify), their -standalone
# reproducers, and the normal-flags test build that mayhem/test.sh runs.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# WiredTiger's CMake flips ENABLE_STATIC/ENABLE_SHARED back to their defaults when an existing cache is
# reconfigured, so start from empty build dirs to keep re-runs idempotent.
rm -rf "$SRC/build-fuzz" "$SRC/build-tests"

# 1) Sanitized + SanCov-instrumented static libwiredtiger and the test_util helper library.
#    Upstream's own fuzz setup (test/fuzz/CMakeLists.txt) needs a PIC build and -fsanitize=fuzzer-no-link;
#    the dedicated build dir is gitignored by upstream's `build*/` rule, so `git clean -ffdX` resets it.
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S "$SRC" -B "$SRC/build-fuzz" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DENABLE_STATIC=1 -DENABLE_SHARED=0 -DWITH_PIC=1 -DENABLE_PYTHON=0 -DHAVE_DIAGNOSTIC=1 \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS"
cmake --build "$SRC/build-fuzz" -j"$MAYHEM_JOBS" --target wiredtiger_static test_util

# 2) Harnesses, each linked twice (libFuzzer engine / standalone run-once driver). The harness
#    sources are mayhem/<t>/<t>.c (upstream's test/fuzz targets, rejecting unusable input with -1);
#    they share upstream's test/fuzz/fuzz_util.c.
B="$SRC/build-fuzz"
INCS="-I$B/include -I$B/config -I$SRC/src/include -I$SRC/test/utility -I$SRC/test/fuzz"
LIBS="$B/test/utility/libtest_util.a $B/libwiredtiger.a -lpthread -ldl -lm -lrt"
OBJ="$B/mayhem-obj"
mkdir -p "$OBJ"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $INCS -c "$SRC/test/fuzz/fuzz_util.c" -o "$OBJ/fuzz_util.o"

for t in fuzz_config fuzz_modify; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INCS -c "$SRC/mayhem/$t/$t.c" -o "$OBJ/$t.o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
      "$OBJ/$t.o" "$OBJ/fuzz_util.o" "$OBJ/lsan_off.o" $LIBS -o "/mayhem/$t"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS \
      "$OBJ/$t.o" "$OBJ/fuzz_util.o" "$OBJ/lsan_off.o" "$OBJ/standalone_main.o" $LIBS -o "/mayhem/$t-standalone"
done

# 3) The functional-test build, with the project's NORMAL flags (no sanitizers, no -gdwarf-3, no
#    SanCov): the known-answer probe plus a few upstream csuite programs. test.sh only runs them.
cmake -S "$SRC" -B "$SRC/build-tests" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DENABLE_STATIC=1 -DENABLE_SHARED=0 -DWITH_PIC=1 -DENABLE_PYTHON=0 \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS" --target wiredtiger_static wt \
  test_wt3338_partial_update test_wt2719_reconfig test_wt11440_config_check test_wt1965_col_efficiency
$CC -O1 $COVERAGE_FLAGS -I"$SRC/build-tests/include" "$SRC/mayhem/kat/wt_kat.c" \
    "$SRC/build-tests/libwiredtiger.a" -lpthread -ldl -lm -lrt -o "$SRC/build-tests/wt_kat"
