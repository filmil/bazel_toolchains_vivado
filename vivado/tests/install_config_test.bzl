"""Unit tests for the installer-configuration helpers.

These cover the part of `//vivado/private:vivado_installation.bzl` that is easy
to get wrong and expensive to debug through a real install: parsing the
installer's `Name:0,Name:1` menu lines and rewriting them to the requested
selection. See https://bazel.build/rules/testing#testing-starlark-utilities
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//vivado/private:vivado_installation.bzl",
    "entry_names",
    "patch_config",
    "resolve_selection",
    "select_line",
    "version_from_root",
)

# A trimmed version of what `xsetup -b ConfigGen` emits, matching the shape the
# fake installer reproduces.
_MENU = "Spartan-7 FPGAs:0,Artix-7 FPGAs:1,Zynq-7000 All Programmable SoC:0,DocNav:0"

_CONFIG = """\
#### Install Configuration ####
Edition=Vivado ML Standard
Product=Vivado
Destination=/tools/Xilinx
Modules={menu}
InstallOptions=Acquire or Manage a License Key:0
CreateProgramGroupShortcuts=1
CreateShortcutsForAllUsers=0
CreateDesktopShortcuts=1
CreateFileAssociation=1
""".format(menu = _MENU)

def _entry_names_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [
            "Spartan-7 FPGAs",
            "Artix-7 FPGAs",
            "Zynq-7000 All Programmable SoC",
            "DocNav",
        ],
        entry_names(_MENU),
        "the selection suffix is stripped and order is preserved",
    )
    asserts.equals(env, [], entry_names(""))

    # Names containing a colon keep everything before the *last* one.
    asserts.equals(env, ["Vitis HLS: legacy"], entry_names("Vitis HLS: legacy:0"))
    return unittest.end(env)

def _resolve_selection_impl(ctx):
    env = unittest.begin(ctx)
    names = entry_names(_MENU)

    # Exact match, case-insensitively.
    asserts.equals(
        env,
        {"DocNav": "docnav"},
        resolve_selection(["docnav"], names, "module"),
    )

    # An unambiguous substring is enough: "Artix-7" picks "Artix-7 FPGAs".
    asserts.equals(
        env,
        {"Artix-7 FPGAs": "Artix-7"},
        resolve_selection(["Artix-7"], names, "module"),
    )

    # Surrounding whitespace is ignored.
    asserts.equals(
        env,
        {"Artix-7 FPGAs": "  Artix-7  "},
        resolve_selection(["  Artix-7  "], names, "module"),
    )

    # Several requests at once.
    asserts.equals(
        env,
        {"Artix-7 FPGAs": "Artix-7", "DocNav": "DocNav"},
        resolve_selection(["Artix-7", "DocNav"], names, "module"),
    )
    return unittest.end(env)

def _select_line_impl(ctx):
    env = unittest.begin(ctx)
    line, names = select_line(
        "Modules=" + _MENU,
        "Modules=",
        ["Artix-7"],
        "module",
    )

    # Exactly the requested entry is enabled; everything else -- including the
    # entry the installer defaulted to on -- is turned off.
    asserts.equals(
        env,
        "Modules=Spartan-7 FPGAs:0,Artix-7 FPGAs:1," +
        "Zynq-7000 All Programmable SoC:0,DocNav:0",
        line,
    )
    asserts.equals(env, 4, len(names))
    return unittest.end(env)

def _patch_config_impl(ctx):
    env = unittest.begin(ctx)
    patched, available = patch_config(
        _CONFIG,
        "/cache/install",
        ["Zynq-7000"],
        ["Acquire or Manage a License Key"],
    )
    lines = patched.splitlines()

    asserts.true(
        env,
        "Destination=/cache/install" in lines,
        "the destination is redirected into the install cache",
    )
    asserts.true(
        env,
        "Modules=Spartan-7 FPGAs:0,Artix-7 FPGAs:0," +
        "Zynq-7000 All Programmable SoC:1,DocNav:0" in lines,
        "the previously-default Artix-7 selection is turned off",
    )
    asserts.true(
        env,
        "InstallOptions=Acquire or Manage a License Key:1" in lines,
        "install options are selected the same way modules are",
    )

    # Desktop integration is meaningless in a Bazel-managed install.
    for forced in [
        "CreateDesktopShortcuts=0",
        "CreateFileAssociation=0",
        "CreateProgramGroupShortcuts=0",
        "CreateShortcutsForAllUsers=0",
    ]:
        asserts.true(env, forced in lines, forced + " is forced off")

    # Unrelated lines survive untouched.
    asserts.true(env, "Product=Vivado" in lines)
    asserts.true(env, "Edition=Vivado ML Standard" in lines)

    asserts.equals(env, entry_names(_MENU), available)
    return unittest.end(env)

def _patch_config_defaults_impl(ctx):
    env = unittest.begin(ctx)

    # No `modules` means "keep whatever the installer selected by default".
    patched, _ = patch_config(_CONFIG, "/cache/install", [], [])
    asserts.true(env, "Modules=" + _MENU in patched.splitlines())
    asserts.true(
        env,
        "InstallOptions=Acquire or Manage a License Key:0" in patched.splitlines(),
    )
    return unittest.end(env)

def _version_from_root_impl(ctx):
    env = unittest.begin(ctx)

    # 2025.1 and later: <destination>/<version>/Vivado
    asserts.equals(
        env,
        "2025.2",
        version_from_root("/cache/install/2025.2/Vivado"),
    )

    # 2024.2 and earlier: <destination>/Vivado/<version>
    asserts.equals(
        env,
        "2024.2",
        version_from_root("/cache/install/Vivado/2024.2"),
    )
    return unittest.end(env)

_entry_names_test = unittest.make(_entry_names_impl)
_resolve_selection_test = unittest.make(_resolve_selection_impl)
_select_line_test = unittest.make(_select_line_impl)
_patch_config_test = unittest.make(_patch_config_impl)
_patch_config_defaults_test = unittest.make(_patch_config_defaults_impl)
_version_from_root_test = unittest.make(_version_from_root_impl)

def install_config_test_suite(name):
    """Declares the installer-configuration unit tests.

    Args:
      name: name of the generated test suite.
    """
    unittest.suite(
        name,
        _entry_names_test,
        _patch_config_defaults_test,
        _patch_config_test,
        _resolve_selection_test,
        _select_line_test,
        _version_from_root_test,
    )
