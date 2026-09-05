#!/bin/bash

# Runs the suite inside the official perl image, so the box needs no Perl
# toolchain and every run starts from the same one.
#
#   ./scripts/test.sh                          # the whole suite
#   PERL_IMAGE=perl:5.22 ./scripts/test.sh     # the floor, and the oldest image
#                                              # current docker can still pull
#   ./scripts/test.sh t/02-client.t            # one file
#
# The tree is mounted READ ONLY and copied in, so a build can never leave blib/,
# a Makefile or a root-owned file behind. Dependencies live in a named docker
# volume per image, so only the first run pays for them.

set -euo pipefail

cd "$(dirname "$0")/.."

PERL_IMAGE="${PERL_IMAGE:-perl:5.40}"
DEPS_VOLUME="internetdata-perl-deps-$(echo "$PERL_IMAGE" | tr ':/' '__')"
TESTS="${*:-t}"

docker run --rm \
    -v "$PWD:/src:ro" \
    -v "$DEPS_VOLUME:/deps" \
    -e "PERL5LIB=/deps/lib/perl5" \
    "$PERL_IMAGE" sh -euc "
        cpanm --notest --quiet --skip-satisfied --local-lib=/deps \
            Mojolicious IO::Socket::SSL
        cp -R /src /w
        cd /w
        perl Makefile.PL
        make
        prove -Ilib -Iblib/lib -r ${TESTS}
    "
