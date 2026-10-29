#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the WiredTiger functional checks that mayhem/build.sh built (normal flags).
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

B="$SRC/build-tests"
for f in "$B/wt_kat" "$B/wt" "$B/test/csuite/wt3338_partial_update/test_wt3338_partial_update" \
         "$B/test/csuite/wt2719_reconfig/test_wt2719_reconfig" \
         "$B/test/csuite/wt11440_config_check/test_wt11440_config_check" \
         "$B/test/csuite/wt1965_col_efficiency/test_wt1965_col_efficiency"; do
  [ -x "$f" ] || { echo "missing test binary $f (mayhem/build.sh should have built it)" >&2; emit_ctrf wiredtiger 0 1 0; exit 1; }
done

W="$(mktemp -d "${TMPDIR:-/tmp}/wt-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
passed=0; failed=0

check() { # check <name> <expected-file> <actual-file>
  if diff -u "$2" "$3" >&2; then passed=$((passed+1)); else echo "FAIL: $1" >&2; failed=$((failed+1)); fi
}

# 1) Known-answer probe of the public API: every output line is a separately counted check.
mkdir "$W/kat"
"$B/wt_kat" "$W/kat" > "$W/kat.out" 2> "$W/kat.err" || { cat "$W/kat.err" >&2; echo "FAIL: wt_kat exited non-zero" >&2; failed=$((failed+1)); }
exp_lines=$(wc -l < "$SRC/mayhem/kat/expected.txt")
act_lines=$(wc -l < "$W/kat.out")
for i in $(seq 1 "$exp_lines"); do
  sed -n "${i}p" "$SRC/mayhem/kat/expected.txt" > "$W/e"; sed -n "${i}p" "$W/kat.out" > "$W/a"
  check "kat line $i" "$W/e" "$W/a"
done
[ "$act_lines" -eq "$exp_lines" ] || { echo "FAIL: wt_kat printed $act_lines lines, expected $exp_lines" >&2; failed=$((failed+1)); }

# 2) The `wt` utility: create a table, write rows, then list / read / dump it back.
mkdir "$W/home"
"$B/wt" -h "$W/home" create -c key_format=S,value_format=S table:golden > "$W/create.out" 2>&1 || cat "$W/create.out" >&2
"$B/wt" -h "$W/home" write table:golden alpha one beta two gamma three > "$W/write.out" 2>&1 || cat "$W/write.out" >&2
"$B/wt" -h "$W/home" list > "$W/list.out" 2>&1 || true
printf 'colgroup:golden\nfile:golden.wt\ntable:golden\n' > "$W/list.exp"
check "wt list" "$W/list.exp" "$W/list.out"
"$B/wt" -h "$W/home" dump table:golden 2>&1 | sed -n '/^Data$/,$p' > "$W/dump.out"
printf 'Data\nalpha\\00\none\\00\nbeta\\00\ntwo\\00\ngamma\\00\nthree\\00\n' > "$W/dump.exp"
check "wt dump" "$W/dump.exp" "$W/dump.out"
"$B/wt" -h "$W/home" read table:golden beta > "$W/read.out" 2>&1 || true
printf 'two\n' > "$W/read.exp"
check "wt read" "$W/read.exp" "$W/read.out"

# 3) A few of upstream's csuite programs (each in its own home; exit code only).
for t in wt3338_partial_update wt2719_reconfig wt11440_config_check wt1965_col_efficiency; do
  mkdir "$W/$t"
  if (cd "$W/$t" && timeout 600 "$B/test/csuite/$t/test_$t" -h "$W/$t/WT_HOME" > "$W/$t.log" 2>&1); then
    passed=$((passed+1))
  else
    echo "FAIL: csuite $t" >&2; tail -20 "$W/$t.log" >&2; failed=$((failed+1))
  fi
done

emit_ctrf "wiredtiger-kat+csuite" "$passed" "$failed" 0
