#!/usr/bin/env bash
set -u

cd "$(dirname "$0")"
failed=0
passed=0

for t in *.test.sh; do
  [ -f "$t" ] || continue
  printf "RUN  %s ... " "$t"
  if bash "$t" >/tmp/cr-test-out.$$ 2>&1; then
    echo "PASS"
    passed=$((passed + 1))
  else
    echo "FAIL"
    cat /tmp/cr-test-out.$$
    failed=$((failed + 1))
  fi
  rm -f /tmp/cr-test-out.$$
done

echo
echo "RESULT: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
