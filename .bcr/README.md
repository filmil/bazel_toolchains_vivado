# Bazel Central Registry

This folder holds the configuration `publish-to-bcr` reads when the module is
submitted to the [Bazel Central Registry](https://registry.bazel.build):
`presubmit.yml` (how the registry tests the module), plus the `source` and
`metadata` templates for the registry entry.

There is deliberately **no publish workflow in this repository**. Which
registry fork the pull request is opened against, and which account opens it,
depend on where the module is hosted, so the submission is made by the hosting
organization's own tooling rather than pinned here. These templates are the
part that belongs to the module itself and stays correct either way.

See <https://github.com/bazel-contrib/publish-to-bcr/blob/main/templates/README.md>
for authoritative documentation about these files.
