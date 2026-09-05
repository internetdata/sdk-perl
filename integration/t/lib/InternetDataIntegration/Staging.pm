package InternetDataIntegration::Staging;

use strict;
use warnings;

use Cwd ();
use Exporter 'import';
use File::Basename ();
use Mojo::URL;
use Mojo::UserAgent;
use Test::More;
use InternetData;

our @EXPORT_OK = qw(
    DIGESTS FORMATS SECRET SIZE_CEILING STAGING STANDINGS LICENSE_TYPE
    api_host api_origin catalog client facts key licensed skip_reason unlicensed
);

# The staging fixtures the test files share: the guard that this is the
# PUBLISHED distribution, the request recorder, one client, one catalog, and the
# budget that keeps a mistaken id from pulling a real database through CI.

use constant STAGING => 'https://staging.internetdata.io';

# A read-only console key for one organization, licensed to a couple of the
# smallest published databases, so a run may download everything it is entitled
# to and still move a few kilobytes.
use constant SECRET => 'INTERNETDATA_STAGING_KEY';

# Every transfer is budgeted against `metadata`'s published size BEFORE it
# starts. The licensed databases are a few kilobytes; published ones reach
# 5.34 GiB, so a mistyped id is the difference between a free run and a very
# slow one.
use constant SIZE_CEILING => 8 * 1024 * 1024;

# The vocabularies the published schema documents. Asserted as membership rather
# than as an exact catalog: a database added tomorrow is not an SDK bug.
use constant FORMATS => [qw(csvgz mmdb)];
use constant STANDINGS => [qw(licensed expired unlicensed)];
use constant LICENSE_TYPE => [qw(evaluation standard redistribute)];
use constant DIGESTS => [qw(md5 sha1 sha256 sha512)];

# This suite exists to exercise the distribution as PUBLISHED, and the way it
# fails to is silent: with the working tree in @INC every test passes, against
# code that was never released. Checked at load, so `prove` run by hand refuses
# just as scripts/run.pl does.
assert_published();

sub assert_published {
    my $repo = File::Basename::dirname(_root());
    my $loaded = $INC{'InternetData.pm'};
    die "InternetData is not loaded, so there is nothing published to test\n" unless $loaded;

    # Only when the working tree is actually there to be picked up: run.sh mounts
    # the integration directory alone, and there is nothing to refuse then.
    return unless -e "$repo/lib/InternetData.pm";
    for my $path (Cwd::abs_path($loaded), map { Cwd::abs_path($_) || $_ } @INC) {
        next unless $path =~ m{\A\Q$repo\E/(?:lib|blib)(?:/|\z)};
        die "$path is the working tree, and this suite must test the published "
            . "distribution; run scripts/run.pl\n";
    }
    diag("testing InternetData $InternetData::VERSION from $loaded");
}

# Both derived from STAGING rather than declared beside it. A second constant
# spelling out the same host is a second thing to keep in step, and the one that
# drifts is the one the credential assertions compare against - which fails open,
# because a fact that matches no known origin is simply not checked.
sub api_origin {
    my $url = Mojo::URL->new(STAGING);
    return $url->scheme . '://' . $url->host_port;
}

sub api_host {
    return Mojo::URL->new(STAGING)->host_port;
}

sub key {
    my $value = $ENV{ +SECRET };
    return defined $value && length $value ? $value : undef;
}

sub skip_reason {
    return defined key() ? undef : SECRET . ' is not set';
}

# What a test is allowed to remember about a request it made.
#
# Only derived facts leave here. A failing assertion prints its operands and
# these logs are public, so a request is recorded as an origin and a path, and
# whether the key was carried is a boolean the caller can read without ever
# seeing the key.
my @FACTS;

sub facts {
    return @FACTS;
}

sub _note {
    my ($req) = @_;
    my $secret = key();
    my $carried = 0;
    if (defined $secret && length $secret) {
        $carried = 1 if index($req->url->query->to_string, $secret) >= 0;
        my $headers = $req->headers->to_hash;
        for my $value (values %$headers) {
            $carried = 1 if !ref $value && index($value, $secret) >= 0;
        }
    }
    push @FACTS, {
        origin => $req->url->scheme . '://' . $req->url->host_port,
        path => $req->url->path->to_string,
        carried_key => $carried,
    };
    return;
}

# Every client this suite builds records through the same list, so the key-never-
# reached-storage assertion covers the WHOLE run rather than one request.
sub client {
    my (%options) = @_;
    my $ua = Mojo::UserAgent->new;
    $ua->on(start => sub { _note($_[1]->req) });
    return InternetData->new(
        api_key => key(), base_url => STAGING, ua => $ua, %options,
    );
}

# One listing for the whole run, and the fixture every other file reads, so a
# catalog that fails to arrive fails once and loudly rather than four times.
my $CATALOG;

sub catalog {
    return $CATALOG if $CATALOG;
    my $databases = eval { client()->database->list };
    # Reported rather than thrown: a fixture that dies takes the whole file with
    # it and prints `Dubious, test returned 255`, which says nothing about what
    # refused.
    BAIL_OUT("listing the staging catalog: $@") unless $databases;
    # Checked HERE rather than in one test, so no comparison in either file can
    # be made against a run that silently went unauthenticated. An unsent key is
    # a 401 today, which would fail loudly on its own; this is what keeps the
    # guarantee once the API answers anything without one.
    BAIL_OUT('the key never reached the wire, so nothing below ran authenticated')
        unless grep { $_->{carried_key} } @FACTS;
    return $CATALOG = $databases;
}

# The families this organization holds a LIVE licence for, which is what a
# download may be attempted against. Everything else in the listing is published
# but not bought, and asking for it is the refusal one of the tests wants.
sub licensed {
    return [grep { $_->{standing} eq 'licensed' } @{ +shift }];
}

sub unlicensed {
    return [grep { $_->{standing} ne 'licensed' } @{ +shift }];
}

sub _root {
    return Cwd::abs_path(File::Basename::dirname(__FILE__) . '/../../..');
}

1;
