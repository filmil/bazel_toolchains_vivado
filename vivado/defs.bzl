"""Public API re-exports for toolchains_vivado.

Most users only need the `vivado` module extension in
`//vivado:extensions.bzl`. These symbols are for callers who want to drive the
provisioning directly, for example from a `WORKSPACE`-style setup or a
higher-level macro of their own.
"""

load(
    "//vivado:repositories.bzl",
    _DEFAULT_NAME = "DEFAULT_NAME",
    _DEFAULT_VIVADO_VERSION = "DEFAULT_VIVADO_VERSION",
    _HUB_REPO_NAME = "HUB_REPO_NAME",
    _vivado_register_toolchains = "vivado_register_toolchains",
)
load(
    "//vivado/private:vivado_installation.bzl",
    _DEFAULT_EULAS = "DEFAULT_EULAS",
    _vivado_installation = "vivado_installation",
)

vivado_register_toolchains = _vivado_register_toolchains
vivado_installation = _vivado_installation

DEFAULT_EULAS = _DEFAULT_EULAS
DEFAULT_NAME = _DEFAULT_NAME
DEFAULT_VIVADO_VERSION = _DEFAULT_VIVADO_VERSION
HUB_REPO_NAME = _HUB_REPO_NAME
