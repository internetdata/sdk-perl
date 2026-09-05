#!/bin/bash

# Refreshes the pinned OpenAPI spec from the published one.
#
# The copy in spec/ is the wire contract this hand-written client is built
# against, so a build stays reproducible and offline and the diff shows exactly
# which spec version the client was checked against. Run this deliberately, then
# commit the spec change alongside whatever it made you change, so a reviewer
# sees both.

set -euo pipefail

cd "$(dirname "$0")/.."

SPEC_URL="${SPEC_URL:-https://s3.internetdata.io/internetdata-public/openapi/openapi.yaml}"

curl -fsS "$SPEC_URL" -o spec/openapi.yaml
echo "spec/openapi.yaml <- ${SPEC_URL}"
grep -m1 '^  version:' spec/openapi.yaml
