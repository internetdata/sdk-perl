use strict;
use warnings;

use lib 't/lib';

use Mojo::UserAgent;
use Test::More;
use InternetData;
use InternetDataIntegration::Staging qw(PROD STAGING client facts key skip_reason);

# The published distribution looking an address, an AS and a domain up: without a
# key against production and staging, and with the CI key against staging.
#
# Nothing here pins a field COUNT. A keyed answer is asserted as a superset of the
# keyless one, so a pricing change stays a pricing change instead of arriving as
# a red SDK build. What an answer must satisfy whatever the plan: a served flag
# reads as 0 or 1 rather than undef, and a field a key adds is ABSENT without one
# rather than false.

# A stable address, the one the README teaches.
use constant PROBE => '146.70.116.130';

for my $env ([production => PROD], [staging => STAGING]) {
    my ($name, $base) = @$env;

    subtest "a lookup without a key answers Unlimited's fields on $name" => sub {
        my $client = client(base_url => $base, api_key => undef, cache_size => 0);
        my $result = $client->lookup(PROBE);

        is($result->ip, PROBE, 'the wire answered about the address asked for');
        is($result->is_bogon, 0, 'and no bogon');
        for my $flag (qw(is_tor is_relay is_anycast is_carrier is_satellite is_ssh is_smtp is_web)) {
            like($result->$flag // 'undef', qr/\A[01]\z/, "$flag is served as 0 or 1");
        }
        ok(length $result->location->{country}, 'location names the country');
        ok(length $result->company->{name}, 'company names who holds it');
        # undef, 0 and '' are all false in Perl, which is exactly why these are
        # asserted on PRESENCE rather than on the value.
        is($result->has('is_hosting'), 0, 'is_hosting is not in Unlimited, so it is absent');
        is($result->is_hosting, undef, 'and reads as undef rather than as false');
        is($result->has('vpn'), 0, 'and so is the VPN detail');
        ok(!exists $result->location->{city}, 'and the city inside location');

        my $as = $client->lookup_asn(9009);
        is($as->asn, 9009, 'an AS answers its number');
        ok(length $as->name, 'and its operator');
        is($as->has('prefixes'), 0, 'and not its prefixes');

        my $domain = $client->lookup_domain('example.com');
        is($domain->domain, 'example.com', 'a domain answers itself');
        is($domain->is_registered, 1, 'and that it is registered');
        is($domain->has('dns'), 0, 'and not its records');

        my $me = $client->my_ip;
        like($me->ip, qr/[.:]/, 'my_ip answers the address this run calls from');

        ok(!grep({ $_->{carried_key} } facts()), 'no request carried a key');
    };

    subtest "a batch without a key is refused once on $name, and its bogon still answered" => sub {
        my $client = client(base_url => $base, api_key => undef, cache_size => 0);
        my $before = () = facts();

        # Two addresses on the wire: a keyless batch of one is answered as its lookup.
        my $answers = $client->lookup_batch([PROBE, '8.8.8.8', '10.0.0.1']);

        is($answers->{'10.0.0.1'}->is_bogon, 1, 'the private address was answered locally');
        for my $ip (PROBE, '8.8.8.8') {
            my $refused = $answers->{$ip};
            isa_ok($refused, 'InternetData::Error', "$ip in a batch without a key");
            is(ref $refused && $refused->kind, 'unauthorized', 'is refused as unauthorized');
            is(ref $refused && $refused->status, 401, 'with a 401');
        }
        my @sent = (facts())[$before .. scalar(facts()) - 1];
        is_deeply([map { $_->{path} } @sent], ['/batch'], 'one request, never retried');
    };
}

subtest 'a bogon is answered without touching the network' => sub {
    my $offline = InternetData->new(base_url => STAGING, ua => refusing_ua());

    my $result = $offline->lookup('10.0.0.1');

    is($result->is_bogon, 1, 'a private address is answered locally');
    is(InternetData::is_bogon('10.0.0.1'), 1, 'the exportable form agrees with the client');
    # Computed rather than served, so it carries every field whatever the plan.
    for my $flag (@InternetData::Result::FLAGS) {
        is($result->$flag, 0, "$flag is present and false on a bogon");
    }
    is_deeply($result->vpn, {}, 'a detail is present and empty');
    is_deeply($result->web, [], 'and Web IP an empty list');
    is($result->asn->{asn}, 0, 'and the AS is 0');
};

subtest 'the CI key reaches the wire, and its answer keeps the keyless one' => sub {
    my $reason = skip_reason();
    plan skip_all => $reason if $reason;

    my $keyed = client(cache_size => 0);
    my $plan = $keyed->my_entitlement->{plan};
    ok(grep({ $_->{carried_key} && $_->{path} eq '/api/v1/entitlement' } facts()),
        'the key reached the wire, so nothing below ran keyless');
    note("plan: $plan->{key}, tier $plan->{tier}");

    my $result = $keyed->lookup(PROBE);
    my $keyless = client(api_key => undef, cache_size => 0)->lookup(PROBE);
    my %served = map { $_ => 1 } $result->fields;
    for my $field (grep { $_ ne 'trial_expired' } $keyless->fields) {
        ok($served{$field}, "the keyed answer keeps $field, which Unlimited serves");
    }
    if ($result->has('trial_expired')) {
        # A free-plan key: its organization's first 100 lookups of the UTC day are
        # answered in full, and the rest as Unlimited's, so which half a run sees
        # depends on the day.
        is($result->has('is_hosting'), $result->trial_expired ? 0 : 1,
            'is_hosting is served exactly while the day lasts');
    }
    else {
        is($result->has('is_hosting'), 1, 'a paid plan serves is_hosting');
    }

    my $one = $keyed->lookup_batch([PROBE])->{+PROBE};
    isa_ok($one, 'InternetData::Result', 'a keyed batch of one');

    my $before = () = facts();
    my $answers = $keyed->lookup_batch([PROBE, '8.8.8.8']);
    for my $ip (PROBE, '8.8.8.8') {
        my $answer = $answers->{$ip};
        # Batch is a paid plan's, and a free-plan key's batch of two is refused
        # as a bad request: either way, each address is answered or refused alone.
        ok(ref $answer eq 'InternetData::Result' || (ref $answer && $answer->kind eq 'bad_request'
            && $answer->status == 402), "$ip in a keyed batch of two is answered, or refused as a 402");
        note("$ip: " . (ref $answer eq 'InternetData::Result' ? 'answered' : "refused: $answer"));
    }
    my @sent = (facts())[$before .. scalar(facts()) - 1];
    is_deeply([map { $_->{path} } @sent], ['/batch'], 'in one request, never retried');
    ok(!grep({ !$_->{carried_key} } @sent), 'which carried the key');
};

# Fails every request, so anything reaching the network is loud about it rather
# than merely slow.
sub refusing_ua {
    my $ua = Mojo::UserAgent->new;
    $ua->on(start => sub { die "the bogon path reached the network\n" });
    return $ua;
}

done_testing();
