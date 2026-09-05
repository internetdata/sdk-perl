#!/bin/bash

# The integration suite inside the official perl image, because the box needs no
# Perl toolchain. CI runs `perl scripts/run.pl` directly; this is the same entry
# point with an interpreter around it.
#
#   ./scripts/run.sh
#   PERL_IMAGE=perl:5.22 ./scripts/run.sh
#
# The key is passed through by NAME, so it never reaches a command line. Only the
# integration directory is mounted: the suite must see the published distribution
# and not the source sitting beside it.

set -euo pipefail

cd "$(dirname "$0")/.."

PERL_IMAGE="${PERL_IMAGE:-perl:5.40}"

docker run --rm \
    -v "$PWD:/app" -w /app \
    -e INTERNETDATA_STAGING_KEY \
    "$PERL_IMAGE" perl scripts/run.pl "$@"
