#!/usr/bin/env bash
# Runs image.sh on top of a base image, with a coreutils wrapper whose `cp` keeps
# a read-only source read-only, as cp does on Windows. A copied oci-layout is then
# read-only and regctl cannot rewrite it.
set -o pipefail -o errexit -o nounset

readonly TEMPLATE="$1"
readonly JQ="$PWD/${2/external\//../}"
readonly COREUTILS="$PWD/${3/external\//../}"
readonly REGCTL="$PWD/${4/external\//../}"
readonly BASE="$5"

# This relies on Bazel outputs being read-only and the test not running as root:
# with writable outputs the copy stays writable, and root can write to a
# read-only file anyway, so the test would pass even without the fix.
readonly SHIM_DIR="$TEST_TMPDIR/shim"
mkdir -p "$SHIM_DIR"
# image.sh replaces PATH, so the wrapper only uses sh builtins and coreutils.
cat >"$SHIM_DIR/coreutils" <<SHIM
#!/bin/sh
set -e
"$COREUTILS" "\$@"
if [ "\$1" = cp ]; then
    src=""
    dest=""
    for arg in "\$@"; do
        src="\$dest"
        dest="\$arg"
    done
    if [ ! -w "\$src" ]; then
        "$COREUTILS" chmod a-w "\$dest"
    fi
fi
SHIM
chmod +x "$SHIM_DIR/coreutils"

readonly OUTPUT="$TEST_TMPDIR/image"
readonly SCRIPT="$TEST_TMPDIR/image.sh"
sed \
    -e "s#{{jq_path}}#$(dirname "$JQ")#" \
    -e "s#{{regctl_path}}#$(dirname "$REGCTL")#" \
    -e "s#{{coreutils_path}}#$SHIM_DIR#" \
    -e "s#{{output}}#$OUTPUT#" \
    -e "s#{{treeartifact_symlinks}}#0#" \
    "$TEMPLATE" >"$SCRIPT"
chmod +x "$SCRIPT"

"$SCRIPT" "--from=$BASE"

if [[ -z "$(find "$OUTPUT/oci-layout" -perm -u+w)" ]]; then
    echo "$OUTPUT/oci-layout is not writable" >&2
    exit 1
fi
if [[ "$("$JQ" -r .imageLayoutVersion "$OUTPUT/oci-layout")" != "1.0.0" ]]; then
    echo "unexpected oci-layout content" >&2
    exit 1
fi
