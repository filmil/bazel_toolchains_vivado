# toolchains_vivado

An ephemeral, Bazel-managed Vivado toolchain for
[`rules_vivado`](https://github.com/hw-bzl/rules_vivado).

Point it at an AMD/Xilinx unified installer archive and Bazel does the rest: it
installs exactly the device families you ask for, into a content-addressed cache
outside the output base, and registers the result as a
`@rules_vivado//vivado:toolchain_type` toolchain. Nobody writes a shim script,
nobody documents "first, install Vivado to `/tools/Xilinx`", and every machine
building the workspace gets the same Vivado.

This module contributes *only* a toolchain. The rules themselves --
`vivado_synthesize`, `xsim_test`, `vivado_flow` and friends -- live in
`rules_vivado`, which is unchanged and unaware of this module.

## Setup

```starlark
bazel_dep(name = "rules_vivado", version = "0.4.1")
bazel_dep(name = "toolchains_vivado", version = "<see releases>")

vivado = use_extension("@toolchains_vivado//vivado:extensions.bzl", "vivado")
vivado.install(
    urls = ["file:///opt/archives/FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_1114_2157_1.tar"],
    sha256 = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
    modules = ["Artix-7"],
)
```

That is the whole setup. `vivado_*` rules resolve the toolchain automatically;
see [`e2e/smoke`](e2e/smoke) for a complete working consumer.

AMD downloads require a login, so there is no default URL and nothing is
fetched from AMD on your behalf. Download the unified "SDI" (single-file
download image) archive once and point `urls` at it (`file:///...` works), host
it on an internal mirror, or vendor it into your repository and use `archive`
instead of `urls`.

**By installing this way you accept the AMD/Xilinx license agreements** listed
in the `eulas` attribute; they are what `xsetup --agree` is given.

## Selecting installation components

A full Vivado install is enormous, and almost all of it is device support you
do not need. `modules` selects exactly what gets installed; everything else is
disabled.

A name matches an installer menu entry exactly (case-insensitively), or as a
substring when that identifies exactly one entry -- so `"Artix-7"` selects
`"Artix-7 FPGAs"`. An unknown name fails the fetch with the full menu in the
error message, which is the easiest way to discover what your archive offers:

```starlark
vivado.install(
    urls = [...],
    modules = ["?"],  # fails, printing every available module
)
```

The 2025.2 installer offers these device families:

`Spartan-7 FPGAs`, `Spartan UltraScale+`, `Artix-7 FPGAs`,
`Artix UltraScale+ FPGAs`, `Kintex-7 FPGAs`, `Kintex UltraScale FPGAs`,
`Kintex UltraScale+ FPGAs`, `Virtex UltraScale+ FPGAs`,
`Virtex UltraScale+ HBM FPGAs`, `Virtex UltraScale+ 58G FPGAs`,
`Zynq-7000 All Programmable SoC`, `Zynq UltraScale+ MPSoCs`, the Versal parts
(offered individually: `xcv80`, `xcvm1102`, `xcve2002`, `xcve2102`, `xcve2202`,
`xcve2302`), `Versal RF Series ES1`,
`Install devices for Alveo and edge acceleration platforms`, and
`Install Devices for Kria SOMs and Starter Kits`

and these optional tools: `DocNav`,
`Vitis Model Composer(A toolbox for Simulink)`, `Vitis Embedded Development`,
`Vitis Networking P4`, `Power Design Manager (PDM)`.

Other installer versions differ. After a successful install the exact menu is
recorded as `AVAILABLE_MODULES` in `@vivado_vivado//:defs.bzl`.

## The install cache

Bazel refetches an external repository whenever the repository rule, its
attributes, or the output base change. A Vivado reinstall costs a ~100 GB
download plus tens of minutes, for an artifact that never changes for given
inputs -- so the installation lives *outside* the repository, in a
content-addressed cache keyed on the archive checksum.

By default it lands in Bazel's per-user output user root, at
`~/.cache/bazel/_bazel_<user>/toolchains_vivado/<version>-<key>`. Override with
the `install_cache` attribute or the `VIVADO_INSTALL_CACHE` environment
variable; `install_cache = "none"` disables caching and installs inside the
repository instead.

Consequences worth knowing:

- **`bazel clean --expunge` does not delete the installation.** It deletes the
  workspace's output base; the cache lives one level above, shared by all output
  bases of the user. To reclaim the space, remove
  `~/.cache/bazel/_bazel_<user>/toolchains_vivado`.
- After deleting the cache by hand, force the (cheap) repository fetch to be
  redone so the repository stops pointing at the removed path:
  `bazel fetch --force --repo=@vivado_vivado`.
- Concurrent Bazel servers sharing a cache coordinate through a lock file; the
  second one waits for the first install and then reuses it.
- Setting `sha256` also makes Bazel keep the ~100 GB archive in its repository
  cache. That is the price of a verified, reproducible download.

## Licensing

The default edition, `Vivado ML Standard`, needs no license. For editions that
do, set `license_server`, which becomes `XILINXD_LICENSE_FILE` on every Vivado
action:

```starlark
vivado.install(
    urls = [...],
    edition = "Vivado ML Enterprise",
    license_server = "2100@license.example.com",
    requires_network = True,
)
```

`requires_network` adds the `requires-network` execution requirement to Vivado
actions. It defaults to `False` here, which is correct for license-free editions
and node-locked `.lic` files; a floating license server needs `True`.

## Several versions side by side

Give each installation a distinct `name` and turn on
`register_version_constraint`:

```starlark
vivado.install(name = "v2024_2", urls = [...], vivado_version = "2024.2", register_version_constraint = True)
vivado.install(name = "v2025_2", urls = [...], vivado_version = "2025.2", register_version_constraint = True)
```

Each toolchain then carries
`@rules_vivado//vivado/constraints/version:<X.Y>` in its
`exec_compatible_with`, and you select between them with execution platforms as
described in rules_vivado's `vivado/toolchain.bzl` documentation.

The constraint is off by default on purpose: a stock host platform declares no
Vivado version constraint, so a constrained toolchain would never be selected.

## How it works, and what it costs

Two repositories are created:

- `@vivado_toolchains` -- a cheap hub holding only the `toolchain()`
  declarations. Always fetched.
- `@vivado_<name>` -- the installation. Fetched only once a `vivado_*` action
  actually resolves to this toolchain, because Bazel resolves a `toolchain()`
  rule's `toolchain` attribute lazily.

That split is what keeps `bazel build` on an unrelated target from triggering a
100 GB install. It also means depending on `toolchains_vivado` without
configuring it is inert: the hub is generated empty, so no toolchain is
registered and nothing is fetched.

Two limitations are worth stating plainly:

- **The installation is referenced by absolute path.** Vivado is far too large
  for Bazel to track as action inputs (tens of gigabytes of files, per action),
  so the generated shim points at the install cache. That works under the
  default Linux sandbox, which mounts the host filesystem read-only, but it is
  not remote-execution safe: a remote worker will not have the cache. For remote
  execution, bake Vivado into the worker image and register a toolchain that
  points at it.
- **Linux only.** The AMD installer ships for Linux, so the generated toolchains
  carry an `@platforms//os:linux` execution constraint.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Commit messages follow
[Conventional Commits](https://www.conventionalcommits.org) -- releases are cut
from the commit history.

The test suite runs against a synthetic installer
(`vivado/tests/fake_installer/`) that implements enough of `xsetup`'s batch
interface to exercise the entire provisioning path in seconds, without an AMD
account. Regenerate the archive with
`vivado/tests/fake_installer/make_fake_installer.sh`.
