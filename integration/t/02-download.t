use strict;
use warnings;

use lib 't/lib';

use Digest::SHA ();
use File::Temp ();
use Mojo::URL;
use Mojo::UserAgent;
use Test::More;
use InternetDataIntegration::Staging qw(
    DIGESTS SIZE_CEILING api_host api_origin catalog client facts key licensed skip_reason
);

# Real bytes, over the wire, verified against a digest the API published
# separately - and the credential discipline that a local origin can only
# approximate.

my $reason = skip_reason();
plan skip_all => $reason if $reason;

my $tmp = File::Temp->newdir;

# Every version this organization may actually fetch, budgeted against the size
# `metadata` publishes BEFORE anything is transferred. The point of doing it here
# rather than after is that a mistaken id never gets to move gigabytes.
sub transferable {
    my @out;
    for my $db (@{ licensed(catalog()) }) {
        for my $version (@{ $db->{versions} }) {
            my $meta = eval { client()->metadata($version->{id}) };
            BAIL_OUT("reading metadata for $version->{id}: $@") unless $meta;
            for my $format (@{ $version->{formats} }) {
                my $size = $meta->{size}{$format};
                BAIL_OUT("$version->{id}.$format publishes no size, so it cannot be budgeted")
                    unless $size;
                BAIL_OUT("$version->{id}.$format is $size bytes, past the "
                    . SIZE_CEILING . ' byte CI budget') if $size > SIZE_CEILING;
                push @out, { id => $version->{id}, format => $format, size => $size };
            }
        }
    }
    return @out;
}

my @TRANSFERABLE = transferable();
plan skip_all => 'this organization licenses nothing that can be downloaded'
    unless @TRANSFERABLE;

subtest 'a download matches the size and the digest the API published' => sub {
    for my $item (@TRANSFERABLE) {
        my ($id, $format, $size) = @{$item}{qw(id format size)};
        my $path = $tmp->dirname . "/$id.$format";

        my $written = eval { client()->download($id, $format, $path) };
        BAIL_OUT("downloading $id.$format: $@") unless defined $written;
        # Read AFTER the transfer, so a rebuild between the two calls shows up as
        # a digest mismatch rather than passing against the digest of nothing.
        my $published = eval { client()->checksums($id, $format) };
        BAIL_OUT("reading the checksums for $id.$format: $@") unless $published;

        is($written, $size, "$id.$format: bytes written match the published size");
        is(-s $path, $size, "$id.$format: bytes on disk match too");
        ok(!-e "$path.part", "$id.$format: the .part file did not outlive the transfer");

        # The digests nest under `checksums`; reading a top-level sha256 returns
        # nothing against a perfectly healthy API.
        like($published->{$_} || '', qr/\A[0-9a-f]+\z/, "$id.$format: $_ is hex")
            for @{ +DIGESTS };
        open my $fh, '<', $path or BAIL_OUT("reading $path back: $!");
        binmode $fh;
        my $body = do { local $/; <$fh> };
        is(Digest::SHA::sha256_hex($body), $published->{sha256},
            "$id.$format: the bytes on disk are the published file");
        is(client()->download_bytes($id, $format), $body,
            "$id.$format: download_bytes agrees with the streamed copy");
        note("$id.$format: $written bytes");
    }
};

subtest 'download_url is a credential-free link on object storage' => sub {
    my ($item) = @TRANSFERABLE;
    my ($id, $format, $size) = @{$item}{qw(id format size)};

    my $url = eval { client()->download_url($id, $format) };
    BAIL_OUT("asking for a link to $id.$format: $@") unless $url;

    like($url, qr{\Ahttps://}, 'the link is https');
    is(index($url, key()), -1, 'the API key is not in the link');
    isnt(Mojo::URL->new($url)->host_port, api_host(),
        'the link points at object storage rather than back at the API');

    # Fetched with an agent that has no key and no history, which is the whole
    # claim: the link authorizes itself, so it can be handed to anything that
    # speaks HTTP without handing over a credential.
    my $bare = Mojo::UserAgent->new->max_redirects(0);
    my $tx;
    $bare->get_p($url)->then(sub { $tx = shift })->catch(sub { diag("bare GET: $_[0]") })->wait;
    ok($tx, 'the bare request completed') or return;
    is($tx->res->code, 200, 'the link authorized its own transfer');
    is(length $tx->res->body, $size, 'and served the whole file');
};

subtest 'the key reached the API and never object storage' => sub {
    # Every request this whole run made went through one recorder, so this is the
    # run rather than one call.
    my @all = facts();
    ok(@all, 'requests were recorded at all') or return;

    my $api = api_origin();
    my @api = grep { $_->{origin} eq $api } @all;
    my @elsewhere = grep { $_->{origin} ne $api } @all;

    ok(scalar(grep { $_->{carried_key} } @api),
        'the key reached the API, so the assertions above ran authenticated');
    ok(@elsewhere, 'object storage was reached, so a 302 was genuinely followed');
    is($_->{carried_key}, 0, "the key was not sent to $_->{origin}$_->{path}") for @elsewhere;
    note('origins: ' . join(', ', do { my %o; grep { !$o{$_}++ } map { $_->{origin} } @all }));
};

done_testing();
