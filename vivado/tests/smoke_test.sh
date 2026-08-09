#!/usr/bin/env bash
# Asserts what the fake Vivado recorded when the toolchain ran it, which is how
# the shim's environment setup is verified: the log lines below can only be
# non-empty if `settings64.sh` was sourced and a writable HOME was created.
#
# $FILES is the space-separated `$(rootpaths)` of the vivado_smoke target, so
# the files are picked out by extension rather than by position.
set -euo pipefail

: "${FILES:?FILES not set}"

root="${TEST_SRCDIR}/${TEST_WORKSPACE}"
marker="" log=""
for f in ${FILES}; do
  case "${f}" in
    *.marker) marker="${root}/${f}" ;;
    *.log) log="${root}/${f}" ;;
  esac
done

fail() {
  echo "FAIL: $*" >&2
  if [[ -f "${log}" ]]; then
    echo "--- vivado log ---" >&2
    cat "${log}" >&2
  fi
  exit 1
}

[[ -n "${marker}" && -f "${marker}" ]] || fail "the toolchain produced no marker file"
[[ -n "${log}" && -f "${log}" ]] || fail "the toolchain produced no log file"

grep -q '^XILINX_VIVADO=.\+' "${log}" ||
  fail "XILINX_VIVADO was empty; the shim did not source settings64.sh"

home="$(sed -n 's/^HOME=//p' "${log}")"
[[ -n "${home}" ]] || fail "HOME was empty in the Vivado action"
case "${home}" in
  */.vivado_home) ;;
  *) fail "HOME was '${home}', expected the shim's action-local .vivado_home" ;;
esac

echo "PASS"
