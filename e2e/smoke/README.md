# Smoke test module

A consumer of `toolchains_vivado` in the shape a downstream user would write:
`bazel_dep` on `rules_vivado` and `toolchains_vivado`, one `vivado.install(...)`
tag, and no hand-written toolchain wiring at all.

It is also the module the [Bazel Central Registry presubmit](../../.bcr/presubmit.yml)
runs, so each release is validated against a real consumer before publishing.

Run it with:

```console
bazel test //...
```

The `vivado.install` tag points at the synthetic installer in
`//vivado/tests` rather than the real AMD archive, which is a ~100 GB download
behind a login and cannot run on a public CI runner. Everything else -- the
extension, the repository rule, the generated shim, toolchain resolution, and
`vivado_synthesize` itself -- is the real thing.
