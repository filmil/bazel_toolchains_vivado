"""Module extension that provisions an ephemeral Vivado installation.

The `vivado` extension takes an AMD/Xilinx unified installer archive, installs
exactly the components you ask for, and registers the result as a
`@rules_vivado//vivado:toolchain_type` toolchain. No host Vivado, no container
image: every machine building the workspace gets the same Vivado, provisioned
on first use.

Configure it in your root module:

```python
bazel_dep(name = "rules_vivado", version = "0.4.1")
bazel_dep(name = "toolchains_vivado", version = "<see releases>")

vivado = use_extension("@toolchains_vivado//vivado:extensions.bzl", "vivado")
vivado.install(
    urls = ["file:///opt/archives/FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_1114_2157_1.tar"],
    sha256 = "...",
    # A name selects an installer menu entry exactly or as an unambiguous
    # substring: "Artix-7" selects the 2025.2 entry "Artix-7 FPGAs".
    #
    # The 2025.2 installer offers these modules -- device families:
    #   "Spartan-7 FPGAs", "Spartan UltraScale+",
    #   "Artix-7 FPGAs", "Artix UltraScale+ FPGAs",
    #   "Kintex-7 FPGAs", "Kintex UltraScale FPGAs",
    #   "Kintex UltraScale+ FPGAs",
    #   "Virtex UltraScale+ FPGAs", "Virtex UltraScale+ HBM FPGAs",
    #   "Virtex UltraScale+ 58G FPGAs",
    #   "Zynq-7000 All Programmable SoC", "Zynq UltraScale+ MPSoCs",
    #   Versal parts (offered individually): "xcv80", "xcvm1102",
    #   "xcve2002", "xcve2102", "xcve2202", "xcve2302",
    #   "Versal RF Series ES1",
    #   "Install devices for Alveo and edge acceleration platforms",
    #   "Install Devices for Kria SOMs and Starter Kits"
    # and optional tools:
    #   "DocNav", "Vitis Model Composer(A toolbox for Simulink)",
    #   "Vitis Embedded Development", "Vitis Networking P4",
    #   "Power Design Manager (PDM)"
    #
    # Other installer versions differ. To list the menu of *your* archive,
    # request a nonexistent module (e.g. `modules = ["?"]`): the fetch fails
    # with the full menu in the error message. After a successful install the
    # menu is also recorded as AVAILABLE_MODULES in @vivado_vivado//:defs.bzl.
    modules = ["Artix-7", "Zynq-7000"],
)
```

AMD downloads require a login, so there is no default URL: point `urls` at a
manually downloaded archive (`file:///...`) or an internal mirror, or vendor the
archive into your repository and use `archive`.

Because that path usually differs per machine while `MODULE.bazel` is committed
and shared, `VIVADO_INSTALLER_URL` overrides whatever the module declared:

```
# .bazelrc.user, which is gitignored
common --repo_env=VIVADO_INSTALLER_URL=file:///home/me/Downloads/FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_1114_2157_1.tar
```

The committed `sha256` still applies, so redirecting to a mirror of the same
archive is safe and a substituted one is caught; use `VIVADO_INSTALLER_SHA256`
alongside it when pointing at a genuinely different archive.

The extension always creates the `@vivado_toolchains` hub repository, which
`toolchains_vivado`'s own `MODULE.bazel` registers. Without an `install` tag the
hub is empty, so depending on this module without configuring it registers no
toolchain rather than failing.
"""

load(
    "//vivado:repositories.bzl",
    "DEFAULT_NAME",
    "DEFAULT_VIVADO_VERSION",
    "HUB_REPO_NAME",
)
load("//vivado/private:toolchains_repo.bzl", "toolchains_repo")
load("//vivado/private:vivado_installation.bzl", "DEFAULT_EULAS", "vivado_installation")

_install = tag_class(
    doc = "Provisions a Vivado installation and registers it as a toolchain.",
    attrs = {
        "archive": attr.label(
            doc = "A vendored installer archive checked into your repository, " +
                  "as an alternative to `urls`. Exactly one of the two must " +
                  "be set. Example: `archive = \"//third_party:vivado.tar\"`.",
        ),
        "edition": attr.string(
            default = "Vivado ML Standard",
            doc = "Installer edition menu entry to install. Example: " +
                  "`edition = \"Vivado ML Enterprise\"`.",
        ),
        "env": attr.string_dict(
            doc = "Extra environment variables for every Vivado action. " +
                  "`HOME`, `PATH` and `LD_LIBRARY_PATH` are already handled " +
                  "by the generated shim. Example: " +
                  "`env = {\"VIVADO_ALLOW_UNSUPPORTED\": \"1\"}`.",
        ),
        "eulas": attr.string_list(
            default = DEFAULT_EULAS,
            doc = "License agreements passed to `xsetup --agree`; by " +
                  "installing this way you confirm that you accept them. " +
                  "Example: `eulas = [\"XilinxEULA\", \"3rdPartyEULA\"]`.",
        ),
        "install_cache": attr.string(
            doc = "Root of the persistent install cache; \"\" resolves to " +
                  "`$VIVADO_INSTALL_CACHE`, then `toolchains_vivado` in " +
                  "Bazel's per-user output user root; \"none\" disables " +
                  "caching. Example: `install_cache = " +
                  "\"/opt/bazel-vivado-cache\"`.",
        ),
        "install_options": attr.string_list(
            doc = "Post-install steps to enable on the `InstallOptions=` " +
                  "line, matched like `modules`. Example: " +
                  "`install_options = [\"Acquire or Manage a License Key\"]`.",
        ),
        "install_timeout": attr.int(
            default = 4 * 60 * 60,
            doc = "Timeout in seconds for the batch install step. Example: " +
                  "`install_timeout = 7200`.",
        ),
        "keep_installer": attr.bool(
            default = False,
            doc = "Keep the extracted installer payload (debugging only; " +
                  "~100 GB). Example: `keep_installer = True`.",
        ),
        "license_server": attr.string(
            doc = "Value for `XILINXD_LICENSE_FILE`, set on every Vivado " +
                  "action. The default Vivado ML Standard edition needs no " +
                  "license. Example: " +
                  "`license_server = \"2100@license.example.com\"`.",
        ),
        "modules": attr.string_list(
            doc = "Installer modules (device families, optional tools) to " +
                  "enable; everything else is disabled. Names match menu " +
                  "entries exactly or as an unambiguous substring. Example: " +
                  "`modules = [\"Artix-7\", \"Zynq-7000\"]`.",
        ),
        "name": attr.string(
            default = DEFAULT_NAME,
            doc = "Base name for the generated repositories, allowing more " +
                  "than one Vivado installation to be registered. Overriding " +
                  "the default is only permitted in the root module, to " +
                  "prevent conflicting registrations in the global namespace " +
                  "of external repos.",
        ),
        "product": attr.string(
            default = "Vivado",
            doc = "Installer product menu entry to install. Example: " +
                  "`product = \"Vivado\"`.",
        ),
        "register_version_constraint": attr.bool(
            default = False,
            doc = "Add `@rules_vivado//vivado/constraints/version:<X.Y>` to " +
                  "the generated `toolchain()`'s `exec_compatible_with`. Off " +
                  "by default: a stock host platform declares no Vivado " +
                  "version constraint, so a constrained toolchain would never " +
                  "be selected. Turn it on when you register several " +
                  "versions side by side and select between them with " +
                  "`--platforms`, as described in rules_vivado's " +
                  "`vivado/toolchain.bzl` docs.",
        ),
        "requires_network": attr.bool(
            default = False,
            doc = "Whether Vivado actions need network access, adding the " +
                  "`requires-network` execution requirement. False (the " +
                  "default) suits license-free editions and node-locked " +
                  "`.lic` files; set True for a floating license server.",
        ),
        "sha256": attr.string(
            doc = "SHA-256 of the installer archive (`sha256sum <archive>`); " +
                  "also the install cache key. Still applies when " +
                  "`VIVADO_INSTALLER_URL` redirects to a mirror, so a " +
                  "substituted archive is caught; override it with " +
                  "`VIVADO_INSTALLER_SHA256` when pointing at a genuinely " +
                  "different one. Example: `sha256 = \"0f1e...e1f0\"`.",
        ),
        "strip_prefix": attr.string(
            doc = "Directory prefix to strip from the extracted archive " +
                  "(usually autodetected).",
        ),
        "urls": attr.string_list(
            doc = "URLs of the AMD/Xilinx unified SDI installer archive; " +
                  "`file:///...` works for a manually downloaded copy. " +
                  "Exactly one of `urls` or `archive` must be set. The " +
                  "`VIVADO_INSTALLER_URL` environment variable overrides " +
                  "this at fetch time, so a path that differs per machine " +
                  "does not have to be committed.",
        ),
        "vivado_version": attr.string(
            default = DEFAULT_VIVADO_VERSION,
            doc = "Vivado version; part of the install cache key and used for " +
                  "the version constraint. Example: " +
                  "`vivado_version = \"2025.2\"`.",
        ),
    },
)

def _vivado_impl(module_ctx):
    installs = {}
    versions = {}
    version_constrained = []

    for mod in module_ctx.modules:
        for tag in mod.tags.install:
            if not mod.is_root:
                # A dependency cannot decide to install a ~100 GB toolchain on
                # the root module's behalf.
                # buildifier: disable=print
                print(
                    ("toolchains_vivado: ignoring vivado.install tag from " +
                     "non-root module '{}'; only the root module may " +
                     "configure a Vivado installation.").format(mod.name),
                )
                continue
            if tag.name in installs:
                fail(
                    ("toolchains_vivado: two vivado.install tags share the " +
                     "name '{}'. Give each installation a distinct `name`.").format(tag.name),
                )

            repo = "vivado_" + tag.name
            installs[tag.name] = repo
            versions[tag.name] = tag.vivado_version
            if tag.register_version_constraint:
                version_constrained.append(tag.name)

            vivado_installation(
                name = repo,
                archive = tag.archive,
                edition = tag.edition,
                env = tag.env,
                eulas = tag.eulas,
                hub_name = HUB_REPO_NAME,
                install_cache = tag.install_cache,
                install_options = tag.install_options,
                install_timeout = tag.install_timeout,
                keep_installer = tag.keep_installer,
                license_server = tag.license_server,
                modules = tag.modules,
                product = tag.product,
                requires_network = tag.requires_network,
                sha256 = tag.sha256,
                strip_prefix = tag.strip_prefix,
                urls = tag.urls,
                vivado_version = tag.vivado_version,
            )

    # Always created, even with no installs: MODULE.bazel registers
    # `@vivado_toolchains//:all` unconditionally, and an empty hub is how a
    # dependency on this module stays inert until it is configured.
    toolchains_repo(
        name = HUB_REPO_NAME,
        installs = installs,
        version_constrained = version_constrained,
        versions = versions,
    )

    return module_ctx.extension_metadata(
        # The set of repositories is fully determined by the tags above, so
        # Bazel can omit this extension from MODULE.bazel.lock.
        reproducible = True,
    )

vivado = module_extension(
    implementation = _vivado_impl,
    tag_classes = {"install": _install},
    doc = "Provisions Vivado installations and registers them as " +
          "`@rules_vivado//vivado:toolchain_type` toolchains. See the " +
          "module-level documentation.",
    # The same set of repositories is declared regardless of the host platform.
    # (The AMD installer is Linux-only; that is expressed as an
    # `exec_compatible_with` constraint on the generated toolchains, not by
    # declaring different repositories per host.)
    arch_dependent = False,
    os_dependent = False,
)
