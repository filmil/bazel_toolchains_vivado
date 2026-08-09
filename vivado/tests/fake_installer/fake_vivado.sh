#!/usr/bin/env bash
# Installed as `<install_root>/bin/vivado` by the fake xsetup. Accepts the
# command line rules_vivado builds -- `-mode batch -source <tcl> -log <log>
# -journal <jou>` -- and asserts the environment contract the generated shim is
# responsible for establishing.
#
# rules_vivado runs actions with `use_default_shell_env` unset, so the action
# environment is only the toolchain's `env` dict. Everything Vivado needs must
# therefore come from the shim. These checks fail the build loudly if it stops
# doing that.
set -euo pipefail

mode="" source_tcl="" log="" journal=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -mode) mode="$2"; shift 2 ;;
    -source) source_tcl="$2"; shift 2 ;;
    -log) log="$2"; shift 2 ;;
    -journal) journal="$2"; shift 2 ;;
    -notrace|-nolog|-nojournal) shift ;;
    *) shift ;;
  esac
done

fail() {
  echo "fake vivado: $*" >&2
  exit 1
}

[[ "${mode}" == "batch" ]] || fail "expected '-mode batch', got '${mode}'"
[[ -n "${source_tcl}" ]] || fail "no -source script given"
[[ -f "${source_tcl}" ]] || fail "no such -source script: ${source_tcl}"

# settings64.sh must have been sourced by the shim.
[[ -n "${XILINX_VIVADO:-}" ]] || fail "XILINX_VIVADO is unset; settings64.sh was not sourced"

# Vivado needs a writable HOME for ~/.Xilinx. The shim points it inside the
# action's working directory.
[[ -n "${HOME:-}" ]] || fail "HOME is unset"
[[ -d "${HOME}" ]] || fail "HOME '${HOME}' is not a directory"
touch "${HOME}/.writable" || fail "HOME '${HOME}' is not writable"

if [[ -n "${log}" ]]; then
  mkdir -p "$(dirname "${log}")"
  {
    echo "fake vivado ${XILINX_VIVADO}"
    echo "XILINX_VIVADO=${XILINX_VIVADO}"
    echo "HOME=${HOME}"
    echo "XILINXD_LICENSE_FILE=${XILINXD_LICENSE_FILE:-}"
    echo "source=${source_tcl}"
  } > "${log}"
fi
[[ -n "${journal}" ]] && : > "${journal}"

# A real Vivado would interpret the Tcl. This stub creates the files the script
# says it will produce, which is enough for rules_vivado's declared outputs to
# appear. Recognized forms:
#
#   # FAKE_VIVADO_TOUCH <path>      -- test hook
#   create_project <name> <dir> -part <part>
#   write_checkpoint -force <path>
#   report_timing_summary -file <path>
#   report_utilization -file <path>
#
# Those are the commands rules_vivado's own Tcl templates use to produce the
# outputs its rules declare, so a real `vivado_synthesize` completes against
# this stub.
emit() {
  local path="$1"
  [[ -n "${path}" ]] || return 0
  mkdir -p "$(dirname "${path}")"
  echo "fake vivado output" > "${path}"
}

while IFS= read -r line; do
  case "${line}" in
    create_project*)
      # `create_project <name> <dir> -part <part>`; the directory is a declared
      # output of the rule, so it has to exist even though it stays empty.
      mkdir -p "$(echo "${line}" | awk '{print $3}')"
      ;;
    *FAKE_VIVADO_TOUCH*)
      emit "$(echo "${line}" | sed -n 's/.*FAKE_VIVADO_TOUCH[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p')"
      ;;
    *write_checkpoint*)
      emit "$(echo "${line}" | sed -n 's/.*write_checkpoint[[:space:]]\{1,\}\(-force[[:space:]]\{1,\}\)\{0,1\}\([^[:space:]]*\).*/\2/p')"
      ;;
    *report_timing_summary*-file*|*report_utilization*-file*)
      emit "$(echo "${line}" | sed -n 's/.*-file[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p')"
      ;;
  esac
done < "${source_tcl}"

exit 0
