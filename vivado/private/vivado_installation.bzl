"""Repository rule for an ephemeral, Bazel-managed Vivado installation.

`vivado_installation` takes an AMD/Xilinx unified "SDI" (single-file download
image) installer archive, performs an unattended batch install of exactly the
requested components, and declares a `vivado_toolchain` pointing at the
result. Together with the `vivado` module extension (`//vivado:extensions.bzl`)
this gives a Vivado that Bazel provisions on first use, with no dependency on
a host installation or a container image.

The install flow inside the repository rule:

1.  Check the persistent install cache (see below); on a hit, only the
    repository's `BUILD.bazel`, `vivado.sh` and `defs.bzl` are regenerated --
    no extract, no install, the fetch completes in about a second.
2.  Otherwise, obtain the installer archive: either `download_and_extract` from
    `urls` (any URL Bazel supports), or extract the vendored `archive` label.
3.  Run `xsetup -b ConfigGen` to obtain the full default install configuration
    for the requested product/edition. This is also how the exact set of
    available module names (the "feature menu") is discovered.
4.  Rewrite the generated configuration: enable exactly the modules the user
    requested (everything else is disabled), point `Destination` into the
    install cache, and disable desktop integration.
5.  Run `xsetup --agree ... --batch Install --config ...` under a file lock,
    then record a `COMPLETE` marker in the cache.
6.  Delete the extracted installer payload to reclaim disk space.
7.  Write a `vivado.sh` shim that sets up a writable `HOME`, sources the
    installation's `settings64.sh`, and `exec`s the real `vivado`; plus a
    `BUILD.bazel` declaring a `@rules_vivado//vivado:toolchain.bzl%vivado_toolchain`
    around it.

### The install cache, and why it exists

Bazel refetches an external repository whenever the repository rule's
definition (this file), its attributes, or the output base change -- and a
Vivado reinstall costs a ~100 GB archive plus tens of minutes of installing,
for an artifact that never changes for given inputs. To make refetches cheap,
the actual installation lives *outside* the repository, in a content-addressed
cache directory inside Bazel's per-user output user root (by default
`<output_user_root>/toolchains_vivado/<version>-<key>`, e.g.
`~/.cache/bazel/_bazel_<user>/toolchains_vivado/...`), keyed by the archive
checksum (or, if absent, by a hash of the inputs and the component selection).
A refetch of the repository finds the cache entry by its `COMPLETE` marker and
skips straight to step 7 above.

Consequences to be aware of:

*   `bazel clean --expunge` does *not* delete the installation: it only deletes
    the workspace's output base, and the cache lives one level above, alongside
    all output bases of the user. Deleting the whole Bazel cache
    (`~/.cache/bazel`) removes the installations with it; to reclaim only
    Vivado's space, remove `~/.cache/bazel/_bazel_<user>/toolchains_vivado`.
*   After manually deleting the cache, force the (cheap) repository fetch to be
    redone with `bazel fetch --force --repo=@vivado_<name>` (or
    `bazel clean --expunge`), so the repository stops pointing at the removed
    path.
*   Concurrent Bazel servers (e.g. two workspaces using the same cache)
    coordinate through a lock file; the second server waits for the first
    install to finish and then reuses it.

IMPORTANT: this file deliberately load()s nothing. The transitive `.bzl` digest
of a repository rule is part of its identity, so any load edge would make
unrelated edits (e.g. to `extensions.bzl`) invalidate the repository and
trigger a refetch. Keep it self-contained. The pure helpers below are public
rather than private so that `//vivado/tests` can exercise them; a test loading
*this* file adds no load edge in the invalidating direction.
"""

# Kept in sync with DEFAULT_VIVADO_VERSION in //vivado:repositories.bzl by
# hand; this file has no load() edges (see the module docstring).
_DEFAULT_VIVADO_VERSION = "2025.2"

# EULAs that `xsetup --agree` must accept for a batch install to proceed.
DEFAULT_EULAS = [
    "XilinxEULA",
    "3rdPartyEULA",
]

# Desktop-integration settings forced off: they are meaningless inside a
# Bazel-managed installation.
FORCED_SETTINGS = {
    "CreateDesktopShortcuts": "0",
    "CreateFileAssociation": "0",
    "CreateProgramGroupShortcuts": "0",
    "CreateShortcutsForAllUsers": "0",
}

# --------------------------------------------------------------------------
# Pure helpers. No repository_ctx, no side effects -- unit-tested by
# //vivado/tests:install_config_test.
# --------------------------------------------------------------------------

def entry_names(value):
    """Parses the names out of a `Name:0,Other Name:1,...` config value.

    Args:
      value: the right-hand side of a `Modules=` or `InstallOptions=` line.

    Returns:
      A list of entry names, in the order the installer offered them.
    """
    names = []
    for entry in value.split(","):
        colon = entry.rfind(":")
        name = (entry[:colon] if colon > 0 else entry).strip()
        if name:
            names.append(name)
    return names

def resolve_selection(requested, names, what):
    """Maps each requested name to the config entry it selects.

    A requested name matches an entry name exactly (case-insensitive), or as a
    case-insensitive substring when that identifies exactly one entry; so
    `Artix-7` selects the menu entry `Artix-7 FPGAs`. Ambiguous or unknown
    names fail with the menu of available names.

    Args:
      requested: names the user asked for.
      names: the full menu the installer offers.
      what: noun used in error messages, e.g. "module".

    Returns:
      A dict from selected entry name to the requested name.
    """
    by_lower = {n.lower(): n for n in names}
    selected = {}
    for req in requested:
        key = req.strip().lower()
        hit = by_lower.get(key)
        if hit == None:
            matches = [n for n in names if key in n.lower()]
            if len(matches) == 1:
                hit = matches[0]
            elif len(matches) > 1:
                fail(
                    ("vivado_installation: {} '{}' is ambiguous; it " +
                     "matches: {}").format(what, req, ", ".join(matches)),
                )
        if hit == None:
            fail(
                ("vivado_installation: {} '{}' is not offered by this " +
                 "installer.\nAvailable choices:\n  {}").format(
                    what,
                    req,
                    "\n  ".join(names),
                ),
            )
        selected[hit] = req
    return selected

def select_line(line, prefix, requested, what):
    """Rewrites a `Name:0/1` selection line to enable exactly `requested`.

    Args:
      line: the whole configuration line, including `prefix`.
      prefix: the key and `=`, e.g. `"Modules="`.
      requested: names the user asked for.
      what: noun used in error messages, e.g. "module".

    Returns:
      A `(new_line, names)` tuple; `names` is the full menu offered by the
      installer on this line.
    """
    names = entry_names(line[len(prefix):])
    selected = resolve_selection(requested, names, what)
    entries = [n + (":1" if n in selected else ":0") for n in names]
    return prefix + ",".join(entries), names

def patch_config(config_text, install_dir, modules, install_options):
    """Rewrites the generated install configuration.

    Enables exactly the requested modules and install options (all others are
    disabled), points the destination at the install cache, and disables
    desktop integration.

    Args:
      config_text: the configuration `xsetup -b ConfigGen` produced.
      install_dir: value for the `Destination=` line.
      modules: modules to enable; empty keeps the installer's defaults.
      install_options: install options to enable; empty keeps the defaults.

    Returns:
      A `(patched_text, available_modules)` tuple; `available_modules` is the
      full menu of module names offered by this installer.
    """
    available = []
    lines = []
    for line in config_text.splitlines():
        key = line.partition("=")[0]
        if line.startswith("Modules="):
            available = entry_names(line[len("Modules="):])
            if modules:
                new_line, _ = select_line(line, "Modules=", modules, "module")
                lines.append(new_line)
            else:
                lines.append(line)
        elif line.startswith("Destination="):
            lines.append("Destination=" + install_dir)
        elif line.startswith("InstallOptions=") and install_options:
            new_line, _ = select_line(
                line,
                "InstallOptions=",
                install_options,
                "install option",
            )
            lines.append(new_line)
        elif key in FORCED_SETTINGS:
            lines.append(key + "=" + FORCED_SETTINGS[key])
        else:
            lines.append(line)
    return "\n".join(lines) + "\n", available

def version_from_root(vivado_root):
    """Derives the installed version from the Vivado tool directory path.

    Handles both layouts used by AMD installers: `.../<version>/Vivado`
    (2025.1 and later) and `.../Vivado/<version>` (2024.2 and earlier).

    Args:
      vivado_root: the directory holding `bin/vivado`.

    Returns:
      The version string, e.g. `"2025.2"`.
    """
    parts = vivado_root.split("/")
    if parts[-1] == "Vivado" and len(parts) >= 2:
        return parts[-2]
    return parts[-1]

# --------------------------------------------------------------------------
# repository_ctx-using implementation.
# --------------------------------------------------------------------------

def _find_xsetup_dir(rctx):
    """Locates the directory containing `xsetup` in the extracted archive."""
    root = rctx.path("installer_sdi")
    if root.get_child("xsetup").exists:
        return root
    for child in root.readdir():
        if child.get_child("xsetup").exists:
            return child
    fail(
        "vivado_installation: could not find `xsetup` in the extracted " +
        "installer archive (looked in {} and its direct subdirectories). ".format(root) +
        "Is this really an AMD/Xilinx unified installer (SDI) archive?",
    )

def _config_gen(rctx, xsetup_dir, home):
    """Runs `xsetup -b ConfigGen` and returns the generated config text.

    ConfigGen is non-interactive when the product and edition are passed via
    `-p`/`-e`. One quirk needs care: xsetup writes its logs under `$HOME/.Xilinx`
    (which the caller points into the repository), but the generated
    `install_config.txt` lands in the *real* home directory's `~/.Xilinx`
    (xsetup resolves it via the password database, not $HOME). Any pre-existing
    user config there is preserved: it is moved aside before the run and
    restored afterwards.
    """
    real_home = rctx.os.environ.get("HOME", "")
    real_config = real_home + "/.Xilinx/install_config.txt"
    backup = real_config + ".toolchains_vivado.bak"
    had_real_config = real_home != "" and rctx.path(real_config).exists
    if had_real_config:
        rctx.execute(["mv", real_config, backup])

    result = rctx.execute(
        [
            "./xsetup",
            "--batch",
            "ConfigGen",
            "--product",
            rctx.attr.product,
            "--edition",
            rctx.attr.edition,
        ],
        environment = {"HOME": home},
        working_directory = str(xsetup_dir),
        timeout = 1800,
    )

    config_text = None
    for candidate in [home + "/.Xilinx/install_config.txt", real_config]:
        if rctx.path(candidate).exists:
            config_text = rctx.read(candidate)
            break

    # Restore the user's own config, and drop the one xsetup just wrote into
    # the real home directory.
    if real_home != "" and rctx.path(real_config).exists:
        rctx.execute(["rm", "-f", real_config])
    if had_real_config:
        rctx.execute(["mv", backup, real_config])

    if config_text == None:
        fail(
            ("vivado_installation: `xsetup -b ConfigGen -p '{}' -e '{}'` " +
             "did not produce an install configuration file (exit code " +
             "{}).\nstdout:\n{}\nstderr:\n{}").format(
                rctx.attr.product,
                rctx.attr.edition,
                result.return_code,
                result.stdout,
                result.stderr,
            ),
        )
    return config_text

def _install_cache_root(rctx):
    """Resolves the install cache root directory.

    Resolution order: the `install_cache` attribute ("none" disables the
    cache), the `VIVADO_INSTALL_CACHE` environment variable, then
    `toolchains_vivado` inside Bazel's *output user root* (the per-user
    directory holding all output bases, e.g.
    `~/.cache/bazel/_bazel_<user>/toolchains_vivado`). The default ties the
    installation's lifetime to the user's Bazel cache: removing the Bazel cache
    removes the installations too, while `bazel clean --expunge` (which only
    deletes one workspace's output base) leaves them in place.

    Returns:
      The cache root path, or "" when caching is disabled.
    """
    if rctx.attr.install_cache == "none":
        return ""
    if rctx.attr.install_cache:
        return rctx.attr.install_cache
    env_cache = rctx.getenv("VIVADO_INSTALL_CACHE")
    if env_cache:
        return env_cache

    # This repository lives at <output_base>/external/<repo>; the output user
    # root is the output base's parent.
    output_user_root = rctx.path(".").dirname.dirname.dirname
    return str(output_user_root) + "/toolchains_vivado"

def _cache_key(rctx):
    """Computes the content-address of this installation in the cache.

    The archive checksum identifies the installation best; without one, a hash
    of the inputs and the component selection is used instead.
    """
    version = rctx.attr.vivado_version or _DEFAULT_VIVADO_VERSION
    if rctx.attr.sha256:
        return version + "-" + rctx.attr.sha256[:16]

    # A vendored archive has no declared checksum, so hash its bytes: the label
    # alone would not change when the file's contents do, and the cache would
    # then hand back an installation built from the previous archive.
    archive_digest = ""
    if rctx.attr.archive:
        result = rctx.execute(["sha256sum", str(rctx.path(rctx.attr.archive))])
        if result.return_code != 0:
            fail("vivado_installation: sha256sum failed: " + result.stderr)
        archive_digest = result.stdout.split(" ")[0]

    material = "\n".join(
        rctx.attr.urls +
        [archive_digest, rctx.attr.product, rctx.attr.edition] +
        rctx.attr.modules + rctx.attr.install_options + rctx.attr.eulas,
    )
    rctx.file("cache_key_material.txt", material, executable = False)
    result = rctx.execute(["sha256sum", "cache_key_material.txt"])
    if result.return_code != 0:
        fail("vivado_installation: sha256sum failed: " + result.stderr)
    return version + "-" + result.stdout.split(" ")[0][:16]

def _read_marker(rctx, marker):
    """Returns the COMPLETE marker's text, or None if it does not exist.

    Deliberately uses `cat` rather than repository_ctx file APIs: the marker
    lives outside the repository, and this rule must not register a Bazel watch
    on it (the marker is created *during* the fetch, and a watched path changing
    mid-fetch would immediately invalidate the just-fetched repository).
    """
    result = rctx.execute(["cat", marker])
    if result.return_code != 0:
        return None
    return result.stdout

# Runs the batch install into the install cache. Static on purpose: all
# parameters arrive via environment variables, so no .format() escaping of bash
# syntax is needed. The lock serializes concurrent Bazel servers that share the
# cache; whoever loses the race finds the marker and exits.
_INSTALL_SCRIPT = """\
#!/usr/bin/env bash
set -euo pipefail
marker="${CACHE_DIR}/COMPLETE"
dest="${CACHE_DIR}/install"
mkdir -p "${CACHE_DIR}"
exec 9> "${CACHE_DIR}/.lock"
flock 9
if [[ -f "${marker}" ]]; then
  exit 0
fi
# No marker: any content is a leftover partial install. Start clean.
rm -rf "${dest}"
mkdir -p "${dest}"
cd "${XSETUP_DIR}"
HOME="${XHOME}" ./xsetup --agree "${EULAS}" --batch Install \\
    --config "${CONFIG_FILE}"
root=""
for cand in "${dest}"/*/Vivado "${dest}"/Vivado/*; do
  if [[ -x "${cand}/bin/vivado" ]]; then
    root="${cand}"
    break
  fi
done
if [[ -z "${root}" ]]; then
  echo "vivado_installation: the batch install completed but no" \\
       "Vivado/bin/vivado was found under ${dest}" >&2
  exit 1
fi
{
  echo "vivado_root=${root}"
  cat "${MODULES_FILE}"
} > "${marker}.tmp"
mv "${marker}.tmp" "${marker}"
"""

# The tracked executable every Vivado action invokes. rules_vivado runs actions
# with only the toolchain's `env` dict -- `use_default_shell_env` is never set --
# so everything Vivado needs has to be established here.
_SHIM_TEMPLATE = """\
#!/usr/bin/env bash
# Generated by the vivado_installation repository rule. Do not edit.
set -euo pipefail

# Vivado insists on a writable HOME for ~/.Xilinx and friends. Keeping it inside
# the action's working directory (rather than /tmp) keeps it sandbox-local, so
# concurrent actions cannot collide and nothing leaks between builds.
export HOME="${{PWD}}/.vivado_home"
mkdir -p "${{HOME}}"

# settings64.sh establishes XILINX_VIVADO, PATH and LD_LIBRARY_PATH. `set -u` is
# relaxed around it because the stock script reads unset variables.
set +u
source "{vivado_root}/settings64.sh"
set -u

exec "{vivado_root}/bin/vivado" "$@"
"""

_BUILD_TEMPLATE = """\
# Generated by the vivado_installation repository rule. Do not edit.

load("@rules_vivado//vivado:toolchain.bzl", "vivado_toolchain")

package(default_visibility = ["//visibility:public"])

exports_files(["vivado.sh"])

# The toolchain() registration lives in the @{hub_name} hub repository so
# that Bazel can resolve toolchains without fetching (and installing) this one.
vivado_toolchain(
    name = "vivado_toolchain",
    env = {env},
    requires_network = {requires_network},
    version = "{vivado_version}",
    vivado = "vivado.sh",
)
"""

_DEFS_TEMPLATE = """\
# Generated by the vivado_installation repository rule. Do not edit.

# Absolute path of the Vivado tool directory in the install cache.
VIVADO_PATH = "{vivado_path}"

# The installed Vivado version.
VIVADO_VERSION = "{vivado_version}"

# The full menu of module names offered by this installer, for reference when
# choosing the `modules` attribute of the `vivado.install` tag.
AVAILABLE_MODULES = {available_modules}
"""

def _emit_repo_files(rctx, marker_text):
    """Generates the repository contents from the COMPLETE marker."""
    vivado_root = None
    modules = []
    for line in marker_text.splitlines():
        if line.startswith("vivado_root="):
            vivado_root = line[len("vivado_root="):]
        elif line.startswith("module="):
            modules.append(line[len("module="):])
    if not vivado_root:
        fail(
            "vivado_installation: the install cache COMPLETE marker is " +
            "malformed (no vivado_root line). Delete the cache entry and " +
            "refetch with: bazel fetch --force --repo=@" + rctx.attr.name,
        )

    # The install layout is authoritative for what actually landed on disk; the
    # attribute is only the caller's expectation (and the cache key).
    version = version_from_root(vivado_root) or rctx.attr.vivado_version

    env = dict(rctx.attr.env)
    if rctx.attr.license_server:
        env["XILINXD_LICENSE_FILE"] = rctx.attr.license_server

    rctx.file(
        "vivado.sh",
        _SHIM_TEMPLATE.format(vivado_root = vivado_root),
        executable = True,
    )
    rctx.file(
        "BUILD.bazel",
        _BUILD_TEMPLATE.format(
            env = repr(env),
            hub_name = rctx.attr.hub_name,
            requires_network = repr(rctx.attr.requires_network),
            vivado_version = version,
        ),
        executable = False,
    )
    rctx.file(
        "defs.bzl",
        _DEFS_TEMPLATE.format(
            available_modules = repr(modules),
            vivado_path = vivado_root,
            vivado_version = version,
        ),
        executable = False,
    )

def _obtain_installer(rctx):
    """Places the installer payload under `installer_sdi/`."""
    if rctx.attr.archive:
        rctx.report_progress("Extracting the vendored Vivado installer archive")
        rctx.extract(
            archive = rctx.path(rctx.attr.archive),
            output = "installer_sdi",
            stripPrefix = rctx.attr.strip_prefix,
        )
        return
    rctx.report_progress(
        "Downloading and extracting the Vivado installer archive " +
        "(~100 GB, this takes a while)",
    )
    rctx.download_and_extract(
        url = rctx.attr.urls,
        output = "installer_sdi",
        sha256 = rctx.attr.sha256,
        stripPrefix = rctx.attr.strip_prefix,
    )

def _vivado_installation_impl(rctx):
    if not rctx.attr.urls and not rctx.attr.archive:
        fail(
            "vivado_installation: exactly one of `urls` or `archive` must be " +
            "set; neither was.",
        )
    if rctx.attr.urls and rctx.attr.archive:
        fail(
            "vivado_installation: exactly one of `urls` or `archive` must be " +
            "set; both were.",
        )

    cache_root = _install_cache_root(rctx)
    if cache_root:
        cache_dir = cache_root + "/" + _cache_key(rctx)
    else:
        # Caching disabled: install inside the repository, so that
        # `bazel clean --expunge` removes everything.
        cache_dir = str(rctx.path("cache"))
    marker = cache_dir + "/COMPLETE"

    marker_text = _read_marker(rctx, marker)
    if marker_text != None:
        rctx.report_progress("Reusing the cached Vivado installation")
        _emit_repo_files(rctx, marker_text)
        return

    # A writable HOME keeps xsetup's dotfiles (~/.Xilinx) inside the repo.
    home = str(rctx.path("xhome"))
    rctx.execute(["mkdir", "-p", home])

    _obtain_installer(rctx)
    xsetup_dir = _find_xsetup_dir(rctx)

    rctx.report_progress("Generating the Vivado batch install configuration")
    generated_config = _config_gen(rctx, xsetup_dir, home)
    config_text, available = patch_config(
        generated_config,
        cache_dir + "/install",
        rctx.attr.modules,
        rctx.attr.install_options,
    )
    rctx.file("install_config.txt", config_text, executable = False)
    rctx.file(
        "available_modules.txt",
        "".join(["module=" + m + "\n" for m in available]),
        executable = False,
    )
    rctx.file("install_vivado.sh", _INSTALL_SCRIPT, executable = True)

    rctx.report_progress("Running the Vivado batch install (this takes tens of minutes)")
    result = rctx.execute(
        ["./install_vivado.sh"],
        environment = {
            "CACHE_DIR": cache_dir,
            "CONFIG_FILE": str(rctx.path("install_config.txt")),
            "EULAS": ",".join(rctx.attr.eulas),
            "MODULES_FILE": str(rctx.path("available_modules.txt")),
            "XHOME": home,
            "XSETUP_DIR": str(xsetup_dir),
        },
        timeout = rctx.attr.install_timeout,
        quiet = False,
    )
    if result.return_code != 0:
        fail(
            ("vivado_installation: the batch install failed (exit code " +
             "{}).\nstdout:\n{}\nstderr:\n{}").format(
                result.return_code,
                result.stdout,
                result.stderr,
            ),
        )

    if not rctx.attr.keep_installer:
        rctx.report_progress("Deleting the extracted installer payload")
        rctx.delete("installer_sdi")

    marker_text = _read_marker(rctx, marker)
    if marker_text == None:
        fail(
            "vivado_installation: the batch install completed but the cache " +
            "marker {} was not written.".format(marker),
        )
    _emit_repo_files(rctx, marker_text)

vivado_installation = repository_rule(
    implementation = _vivado_installation_impl,
    doc = """Installs Vivado from an AMD/Xilinx unified installer archive.

Prefer configuring this through the `vivado` module extension
(`@toolchains_vivado//vivado:extensions.bzl`) rather than instantiating it
directly: the extension pairs it with the toolchain hub repository that makes
toolchain resolution cheap. The extension's `install` tag accepts the same
attributes as this rule.

The installation is large: expect on the order of 100 GB of download, the same
again transiently for the extracted installer payload, plus the installed size
of the selected modules. The extracted payload is deleted after the install
completes. The installation itself lives in a persistent content-addressed
cache (see the module docs), so refetches of this repository -- after
`bazel clean --expunge`, edits to this file, or attribute changes that do not
change the selection -- reuse it instead of reinstalling.

A fully spelled out example:

```python
vivado_installation(
    name = "vivado_2025_2",
    # Where to fetch the unified single-file installer archive from. Any
    # Bazel-supported scheme works; AMD downloads require a login, so a local
    # file or an internal mirror is typical.
    urls = ["file:///opt/archives/FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_1114_2157_1.tar"],
    # Checksum of the archive (output of `sha256sum <archive>`).
    sha256 = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
    product = "Vivado",
    edition = "Vivado ML Standard",
    # Device families to install; everything else is left out.
    modules = ["Artix-7", "Zynq-7000"],
    vivado_version = "2025.2",
)
```
""",
    attrs = {
        "archive": attr.label(
            allow_single_file = True,
            doc = "A vendored installer archive checked into the repository, " +
                  "as an alternative to `urls`. Exactly one of the two must " +
                  "be set. Example: `archive = \"//third_party:vivado.tar\"`.",
        ),
        "edition": attr.string(
            default = "Vivado ML Standard",
            doc = "The edition to install, as named in the installer's " +
                  "edition menu. Example: `edition = \"Vivado ML " +
                  "Enterprise\"` for license holders; the default is the " +
                  "license-free `\"Vivado ML Standard\"`.",
        ),
        "env": attr.string_dict(
            doc = "Extra environment variables for every Vivado action, " +
                  "passed through to the `vivado_toolchain`. Note that " +
                  "rules_vivado runs actions with only this dict as their " +
                  "environment. `HOME`, `PATH` and `LD_LIBRARY_PATH` are " +
                  "already handled by the generated shim. Example: " +
                  "`env = {\"VIVADO_ALLOW_UNSUPPORTED\": \"1\"}`.",
        ),
        "eulas": attr.string_list(
            default = DEFAULT_EULAS,
            doc = "License agreements passed to `xsetup --agree`. By using " +
                  "this rule you confirm that you accept these AMD/Xilinx " +
                  "license terms. Example: `eulas = [\"XilinxEULA\", " +
                  "\"3rdPartyEULA\"]` (the default).",
        ),
        "hub_name": attr.string(
            default = "vivado_toolchains",
            doc = "Name of the toolchain hub repository that registers this " +
                  "installation. Informational; used in generated comments.",
        ),
        "install_cache": attr.string(
            doc = "Root directory of the persistent install cache. When " +
                  "empty, resolves to the `VIVADO_INSTALL_CACHE` environment " +
                  "variable, then `toolchains_vivado` inside Bazel's per-user " +
                  "output user root (`~/.cache/bazel/_bazel_<user>/" +
                  "toolchains_vivado`), tying the installation's lifetime to " +
                  "the user's Bazel cache. The special value `none` disables " +
                  "the cache: the installation then lives inside the " +
                  "repository and is redone on every refetch. Example: " +
                  "`install_cache = \"/opt/bazel-vivado-cache\"` for a " +
                  "shared machine-wide cache.",
        ),
        "install_options": attr.string_list(
            doc = "Post-install steps to enable on the `InstallOptions=` " +
                  "line of the install configuration, matched like `modules` " +
                  "entries. When empty, the installer defaults are kept (all " +
                  "steps off). Example: `install_options = [\"Acquire or " +
                  "Manage a License Key\"]`.",
        ),
        "install_timeout": attr.int(
            default = 4 * 60 * 60,
            doc = "Timeout in seconds for the `xsetup --batch Install` step. " +
                  "Example: `install_timeout = 7200` for two hours; the " +
                  "default is four.",
        ),
        "keep_installer": attr.bool(
            default = False,
            doc = "Keep the extracted installer payload in the repository " +
                  "instead of deleting it after the install. Example: " +
                  "`keep_installer = True` while debugging a failing install " +
                  "(costs ~100 GB).",
        ),
        "license_server": attr.string(
            doc = "Value for `XILINXD_LICENSE_FILE`, set on every Vivado " +
                  "action. Needed for editions that require a feature " +
                  "license; the default Vivado ML Standard does not. " +
                  "Example: `license_server = \"2100@license.example.com\"`.",
        ),
        "modules": attr.string_list(
            doc = "Installer modules (device families and optional tools) to " +
                  "install. Exactly these modules are enabled; all others " +
                  "are disabled, keeping the install small. A name selects a " +
                  "module menu entry either exactly or as a case-insensitive " +
                  "substring that matches only one entry: `Artix-7` selects " +
                  "the 2025.2 entry `Artix-7 FPGAs`. An unknown name fails " +
                  "with the full menu of available modules (a handy way to " +
                  "discover the menu: request `modules = [\"?\"]`). When " +
                  "empty, the installer's default selection is installed. " +
                  "After a successful install the full menu is recorded in " +
                  "`@<name>//:defs.bzl`. Example: `modules = [\"Artix-7\", " +
                  "\"Zynq-7000\"]`.",
        ),
        "product": attr.string(
            default = "Vivado",
            doc = "The product to install, as named in the installer's " +
                  "product menu. Example: `product = \"Vivado\"` (other menu " +
                  "entries, e.g. `\"Vitis\"`, are untested).",
        ),
        "requires_network": attr.bool(
            default = False,
            doc = "Whether Vivado actions need network access, which adds the " +
                  "`requires-network` execution requirement. False (the " +
                  "default) is correct for license-free editions (Vivado ML " +
                  "Standard / WebPACK) and node-locked `.lic` files read from " +
                  "disk. Set to True for a floating/network license server. " +
                  "Note that rules_vivado's own default is True; an " +
                  "ephemeral install of the default edition needs no network.",
        ),
        "sha256": attr.string(
            doc = "SHA-256 of the installer archive, as printed by " +
                  "`sha256sum <archive>`. Strongly recommended for " +
                  "reproducibility, and used as the install cache key; note " +
                  "that providing it also causes the ~100 GB archive to be " +
                  "stored in Bazel's repository cache. Ignored when " +
                  "`archive` is used. Example: `sha256 = \"0f1e...e1f0\"`.",
        ),
        "strip_prefix": attr.string(
            doc = "Directory prefix to strip from the extracted archive. " +
                  "Usually unnecessary: the rule finds `xsetup` one level " +
                  "deep on its own. Example: `strip_prefix = " +
                  "\"FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_1114_2157\"`.",
        ),
        "urls": attr.string_list(
            doc = "URLs of the AMD/Xilinx unified SDI installer archive (the " +
                  "single-file download, e.g. " +
                  "`FPGAs_AdaptiveSoCs_Unified_SDI_<version>_<build>.tar`). " +
                  "Any Bazel-supported URL scheme works, including " +
                  "`file:///...` for a manually downloaded archive. Exactly " +
                  "one of `urls` or `archive` must be set.",
        ),
        "vivado_version": attr.string(
            default = _DEFAULT_VIVADO_VERSION,
            doc = "Vivado version; part of the install cache key, reported to " +
                  "the toolchain, and used to pick the version constraint " +
                  "when the hub registers one. When empty, the version is " +
                  "derived from the install layout. Example: " +
                  "`vivado_version = \"2025.2\"`.",
        ),
    },
)
