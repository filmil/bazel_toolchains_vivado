"""A minimal rule that runs the resolved Vivado toolchain.

This is deliberately a re-implementation of what rules_vivado's
`run_tcl_template` (`@rules_vivado//vivado/private:common.bzl`) does, rather
than a call into it: it pins the contract this module has to satisfy, so a
change on either side shows up as a test failure here instead of as a broken
build in somebody's workspace.

The contract being asserted:

*   the toolchain resolves through `@rules_vivado//vivado:toolchain_type`;
*   `ToolchainInfo.vivado_info` carries `vivado`, `xilinx_env`,
    `requires_network`, `env` and `version`;
*   `vivado_info.vivado` is a `FilesToRunProvider`, invoked by exec path;
*   the action runs with only `vivado_info.env` in its environment, so the
    executable itself must establish `HOME`, `PATH` and `LD_LIBRARY_PATH`.
"""

load("@rules_vivado//vivado:toolchain.bzl", "TOOLCHAIN_TYPE")

def _vivado_smoke_impl(ctx):
    vivado = ctx.toolchains[TOOLCHAIN_TYPE].vivado_info

    tcl = ctx.actions.declare_file(ctx.label.name + ".tcl")
    marker = ctx.actions.declare_file(ctx.label.name + ".marker")
    log = ctx.actions.declare_file(ctx.label.name + ".log")
    journal = ctx.actions.declare_file(ctx.label.name + ".jou")

    ctx.actions.write(
        output = tcl,
        content = "# FAKE_VIVADO_TOUCH {}\n".format(marker.path),
    )

    command = ""
    if vivado.xilinx_env:
        command += "source " + vivado.xilinx_env.path + " && "
    command += " ".join([
        vivado.vivado.executable.path,
        "-mode batch",
        "-source " + tcl.path,
        "-log " + log.path,
        "-journal " + journal.path,
    ])

    inputs = [tcl]
    if vivado.xilinx_env:
        inputs.append(vivado.xilinx_env)

    execution_requirements = {}
    if vivado.requires_network:
        execution_requirements["requires-network"] = ""

    ctx.actions.run_shell(
        outputs = [marker, log, journal],
        inputs = inputs,
        tools = [vivado.vivado],
        command = command,
        env = vivado.env,
        execution_requirements = execution_requirements,
        mnemonic = "VivadoSmoke",
        progress_message = "Running the Vivado toolchain smoke check for %{label}",
        toolchain = TOOLCHAIN_TYPE,
    )

    return [DefaultInfo(files = depset([marker, log, journal]))]

vivado_smoke = rule(
    doc = "Runs the resolved Vivado toolchain on a trivial Tcl script and " +
          "captures its marker, log and journal.",
    implementation = _vivado_smoke_impl,
    toolchains = [TOOLCHAIN_TYPE],
)
