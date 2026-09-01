#!/usr/bin/env bash
# Runs every tests/test_*.sh against a stubbed virsh/qemu-img/cloud-localds/
# virt-install (tests/fixtures/bin/) — no libvirt, KVM, or network required,
# and the real qemu:///system connection is never touched.
set -uo pipefail
cd "$(dirname "$0")"

total_fail=0
for t in test_*.sh; do
  echo "=== $t ==="
  if ./"$t"; then
    echo "--- $t: PASS"
  else
    echo "--- $t: FAIL"
    total_fail=1
  fi
  echo
done

if [[ $total_fail -eq 0 ]]; then
  echo "All tests passed."
else
  echo "Some tests failed."
fi
exit "$total_fail"
