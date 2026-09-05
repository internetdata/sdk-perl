use strict;
use warnings;

use lib 't/lib';

use Test::More;
use InternetDataIntegration::Staging qw(
    FORMATS REDISTRIBUTION STANDINGS catalog client licensed skip_reason unlicensed
);

# The published distribution against the staging API: a real catalog, a real
# metadata document, and the refusal a database this organization does not
# license actually produces.

my $reason = skip_reason();
plan skip_all => $reason if $reason;

subtest 'the catalog reads as the published schema describes it' => sub {
    my $databases = catalog();

    ok(@$databases, 'staging published no databases at all') or return;
    for my $db (@$databases) {
        ok(length($db->{base} || ''), 'a family carries a base');
        ok(length($db->{name} || ''), "$db->{base} carries a name");
        # A family is keyed by `base` and the id a download takes hangs off
        # `versions`. A listing keyed by a database id could not tell a caller
        # what a licence covers.
        ok(!exists $db->{id}, "$db->{base} is keyed by base rather than by a database id");
        ok(scalar(grep { $_ eq ($db->{standing} || '') } @{ +STANDINGS }),
            "$db->{base}: standing is one the schema documents");
        ok(!defined $db->{redistribution}
            || scalar(grep { $_ eq $db->{redistribution} } @{ +REDISTRIBUTION }),
            "$db->{base}: redistribution is documented or absent");
        ok(ref $db->{versions} eq 'ARRAY' && @{ $db->{versions} },
            "$db->{base}: a family with no versions");
        for my $version (@{ $db->{versions} || [] }) {
            like($version->{id} || '', qr/\A[a-z0-9_]+\z/, "$db->{base}: version id");
            ok(ref $version->{formats} eq 'ARRAY' && @{ $version->{formats} },
                "$version->{id}: built in no format at all");
            for my $format (@{ $version->{formats} || [] }) {
                ok(scalar(grep { $_ eq $format } @{ +FORMATS }),
                    "$version->{id}: $format is a documented format");
            }
        }
    }
    note('catalog: ' . join(', ', map { "$_->{base}=$_->{standing}" } @$databases));
};

subtest 'this organization holds at least one live licence' => sub {
    # A licence carrying `expires` in the past reports as `expired`, so a CI
    # credential that quietly lapses shows up here rather than months later as a
    # refusal nobody can explain from the diff.
    my $live = licensed(catalog());

    ok(@$live, 'the CI credential licenses nothing, so nothing can be downloaded') or return;
    for my $db (@$live) {
        ok(defined $db->{redistribution}, "$db->{base}: a live licence with no redistribution term");
    }
    note('licensed: ' . join(', ', map { $_->{base} } @$live));
};

subtest 'metadata publishes a size for every format a version is built in' => sub {
    for my $db (@{ licensed(catalog()) }) {
        for my $version (@{ $db->{versions} }) {
            my $meta = eval { client()->database->metadata($version->{id}) };
            BAIL_OUT("reading metadata for $version->{id}: $@") unless $meta;

            is($meta->{id}, $version->{id}, "$version->{id}: answered about the id asked for");
            cmp_ok($meta->{entries}, '>=', 0, "$version->{id}: entries");
            like($meta->{updated} || '', qr/\A\d{4}-\d{2}-\d{2}\z/, "$version->{id}: updated");
            # The sizes are what every transfer in 02-download.t is budgeted
            # against, so a format built but unsized would make that budget a
            # no-op rather than a ceiling.
            for my $format (@{ $version->{formats} }) {
                my $size = $meta->{size}{$format};
                ok(defined $size && $size > 0,
                    "$version->{id}: built in $format and publishes a size for it");
            }
            is_deeply([sort keys %{ $meta->{size} }], [sort @{ $version->{formats} }],
                "$version->{id}: the formats listed and the formats sized agree");
        }
    }
};

subtest 'a database this organization does not license is refused without a retry' => sub {
    my $others = unlicensed(catalog());
    plan skip_all => 'staging published nothing this organization does not license'
        unless @$others;

    my $version = $others->[0]{versions}[-1];
    # Retries would only slow a refusal down: it is a client error either way,
    # and this asserts the library agrees rather than hammering a 403.
    my $meta = eval { client(retries => 3)->database->metadata($version->{id}) };
    my $error = $@;

    ok(!defined $meta, "$version->{id} is not licensed to this organization")
        or diag("$version->{id} is now licensed here, so this assertion says nothing");
    isa_ok($error, 'InternetData::Error', 'the refusal');
    is($error->kind, 'forbidden', "$version->{id}: classified as forbidden");
    is($error->status, 403, "$version->{id}: carrying the status");
    is($error->retryable, 0, "$version->{id}: a licence refusal is not worth retrying");
    # The API says WHICH refusal this is, under `rc`, and NOT_LICENSED and
    # LICENSE_EXPIRED are both 403. Falling back to the status means the client
    # never read the envelope.
    ok(scalar(grep { $_ eq $error->message } qw(NOT_LICENSED LICENSE_EXPIRED)),
        "$version->{id}: carries the API's rc, not the client fallback");
};

subtest 'the download history lists what this run has done' => sub {
    my $attempts = eval { client()->database->downloads(limit => 10) };
    BAIL_OUT("reading the download history: $@") unless $attempts;

    is(ref $attempts, 'ARRAY', 'the history is a list');
    cmp_ok(scalar @$attempts, '<=', 10, 'the limit was passed through');
    for my $attempt (@$attempts) {
        ok(scalar(grep { $_ eq ($attempt->{outcome} || '') }
            qw(ok unauthorized denied expired unknown unavailable)),
            "$attempt->{dataset_id}: outcome is one the schema documents");
        ok(exists $attempt->{created}, "$attempt->{dataset_id}: carries when it happened");
    }
};

done_testing();
