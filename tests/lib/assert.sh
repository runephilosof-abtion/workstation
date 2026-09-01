#!/usr/bin/env bash
# Minimal assertion helpers for the plain-bash tests in tests/test_*.sh.
# No external framework: source this, call the assert_* functions, then finish.

FAILED=0

ok() { echo "  ok - $1"; }
bad() { echo "  FAIL - $1"; FAILED=1; }

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then ok "$desc"; else bad "$desc (expected: $expected | got: $actual)"; fi
}

assert_contains() {
  local desc=$1 haystack=$2 needle=$3
  if [[ $haystack == *"$needle"* ]]; then ok "$desc"; else bad "$desc (expected to contain: $needle | got: $haystack)"; fi
}

assert_not_contains() {
  local desc=$1 haystack=$2 needle=$3
  if [[ $haystack != *"$needle"* ]]; then ok "$desc"; else bad "$desc (expected NOT to contain: $needle | got: $haystack)"; fi
}

assert_file_exists() {
  local desc=$1 path=$2
  if [[ -e $path ]]; then ok "$desc"; else bad "$desc ($path missing)"; fi
}

assert_file_absent() {
  local desc=$1 path=$2
  if [[ ! -e $path ]]; then ok "$desc"; else bad "$desc ($path still present)"; fi
}

finish() { exit "$FAILED"; }
