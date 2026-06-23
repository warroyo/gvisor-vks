#!/usr/bin/env bash
# Encode addon/addon-config-definition.yaml into the chart's ACD annotation. Run
# by release-chart.yml at package time. See README.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
acd="$repo_root/addon/addon-config-definition.yaml"
chart="$repo_root/charts/gvisor-vks/Chart.yaml"
annotation="addons.kubernetes.vmware.com/addon-config-definition"

command -v yq >/dev/null || { echo "yq required (https://github.com/mikefarah/yq)" >&2; exit 1; }

# gzip -n: omit timestamp/name so the encoding is reproducible across runs.
encoded="$(gzip -n -c "$acd" | base64 | tr -d '\n')"

ACD_ENCODED="$encoded" yq -i \
  ".annotations.\"$annotation\" = strenv(ACD_ENCODED)" \
  "$chart"

echo "Encoded ACD into $chart ($annotation)"
