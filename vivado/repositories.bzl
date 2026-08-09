"""Declare the repositories that provision Vivado.

This is the primary API, usable both from a module extension (see
`//vivado:extensions.bzl`) and directly. See
https://bazel.build/rules/deploying#dependencies
"""

load("//vivado/private:toolchains_repo.bzl", "toolchains_repo")
load("//vivado/private:vivado_installation.bzl", "vivado_installation")

# The Vivado version assumed when a caller does not say otherwise.
DEFAULT_VIVADO_VERSION = "2025.2"

# Base name for the generated repositories, and the name of a `vivado.install`
# tag that does not choose one.
DEFAULT_NAME = "vivado"

# The name of the hub repository holding the `toolchain()` declarations.
HUB_REPO_NAME = "vivado_toolchains"

def vivado_register_toolchains(name = DEFAULT_NAME, **kwargs):
    """Provisions a Vivado installation and declares a toolchain for it.

    Creates two repositories:

    *   `@vivado_<name>` -- the installation itself. Expensive: it extracts an
        AMD/Xilinx unified installer archive and runs an unattended batch
        install. Only fetched once a `vivado_*` action actually resolves to
        this toolchain.
    *   `@vivado_toolchains` -- a cheap hub holding the `toolchain()`
        declaration that points at it. Always fetched, so that toolchain
        resolution never triggers an install.

    Register the result with
    `register_toolchains("@vivado_toolchains//:all")`.

    Args:
      name: base name for the created repositories, e.g. `"vivado"` yields
        `@vivado_vivado`. Pick distinct names to provision several Vivado
        versions side by side.
      **kwargs: passed to the `vivado_installation` repository rule; see
        `//vivado/private:vivado_installation.bzl` for the full attribute
        documentation.
    """
    repo = "vivado_" + name
    vivado_installation(
        name = repo,
        hub_name = HUB_REPO_NAME,
        **kwargs
    )
    toolchains_repo(
        name = HUB_REPO_NAME,
        installs = {name: repo},
        versions = {name: kwargs.get("vivado_version", DEFAULT_VIVADO_VERSION)},
        version_constrained = [],
    )
