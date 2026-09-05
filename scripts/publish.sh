#!/bin/bash

# Uploads the distribution to PAUSE from inside the official perl image, so a
# release needs nothing installed locally beyond docker. The release workflow
# runs the same steps on a tag; this is the manual path for a first release or
# when Actions is not an option.
#
#   PAUSE_USER=... PAUSE_PASSWORD=... ./scripts/publish.sh
#   PAUSE_USER=... PAUSE_PASSWORD=... DRY_RUN=1 ./scripts/publish.sh
#
# PAUSE has no OIDC or trusted-publishing path, unlike npm, PyPI, RubyGems and
# crates.io, so every release needs the credential. Use the PAUSE account
# password, not a web session; there is nothing narrower to scope it to.

set -euo pipefail

cd "$(dirname "$0")/.."

: "${PAUSE_USER:?set PAUSE_USER to your PAUSE id}"
: "${PAUSE_PASSWORD:?set PAUSE_PASSWORD to your PAUSE password}"
PERL_IMAGE="${PERL_IMAGE:-perl:5.40}"
DRY_RUN="${DRY_RUN:-}"

upload='cpan-upload --user "$PAUSE_USER" --password "$PAUSE_PASSWORD" InternetData-*.tar.gz'
if [ -n "$DRY_RUN" ] ; then
    upload='echo "DRY_RUN: would upload $(ls InternetData-*.tar.gz)"'
fi

# The tree is mounted READ ONLY and copied in, so a build cannot leave blib/, a
# Makefile or a root-owned tarball behind in the working tree.
docker run --rm \
    -v "$PWD:/src:ro" \
    -e PAUSE_USER \
    -e PAUSE_PASSWORD \
    "$PERL_IMAGE" sh -euc "
        cp -R /src /w
        cd /w
        # Deps are resolved from the COPY, not from /src. cpanm writes Makefile
        # and MYMETA into the distribution directory it is pointed at, so
        # --installdeps against the read-only mount fails at configure time and
        # takes the whole release with it.
        cpanm --notest --quiet --installdeps .
        cpanm --notest --quiet CPAN::Uploader
        tag=\"\$(perl -Ilib -MInternetData -e 'print \$InternetData::VERSION')\"
        echo \"==> InternetData \$tag\"
        perl Makefile.PL
        make
        prove -Ilib -Iblib/lib -r t
        make manifest
        make dist
        $upload
    "
