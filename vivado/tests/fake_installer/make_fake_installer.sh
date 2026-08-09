#!/usr/bin/env bash
# Regenerates //vivado/tests:fake_installer.tar from the sources next to this
# script.
#
# The archive has to be checked in rather than built by Bazel: repository rules
# run before the build graph exists, so `vivado.install(archive = ...)` can only
# point at a source file. Keeping the inputs next to it means the blob stays
# auditable -- run this script and `git diff` should be empty.
#
# The layout mirrors a real unified SDI archive: one top-level directory holding
# `xsetup`, which //vivado/private:vivado_installation finds by looking one
# level deep.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

readonly PREFIX="FPGAs_AdaptiveSoCs_Unified_SDI_2025.2_fake"
readonly OUT="../fake_installer.tar"

staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT

mkdir -p "${staging}/${PREFIX}"
install -m 0755 xsetup "${staging}/${PREFIX}/xsetup"
install -m 0755 fake_vivado.sh "${staging}/${PREFIX}/fake_vivado.sh"

# Reproducible tar: fixed mtime/uid/gid/order, so regenerating produces
# byte-identical output and the checked-in blob does not churn.
tar --create \
    --file "${OUT}" \
    --directory "${staging}" \
    --sort=name \
    --mtime=@0 \
    --owner=0 --group=0 --numeric-owner \
    --format=gnu \
    "${PREFIX}"

echo "wrote ${OUT}"
sha256sum "${OUT}"
