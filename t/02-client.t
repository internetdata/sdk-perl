use strict;
use warnings;

use lib 't/lib';

use Mojo::IOLoop;
use Test::More;
use InternetData;
use InternetDataTest;
use InternetDataTest::Origin;

# The Perl-specific surface, as distinct from the shared corpus in
# t/01-conformance.t.

subtest 'the API key reaches the wire, and only one way' => sub {
    my $origin = InternetDataTest::Origin->new(sub {
        shift->render(json => { databases => [] });
    });

    InternetData->new(base_url => $origin->url, api_key => 'secret-key')->database->list;

    my ($request) = $origin->requests;
    is($request->{headers}{Authorization}, 'Bearer secret-key', 'sent as a bearer token');
    # `?apikey=` belongs to v1 on this same host, with a different key
    # vocabulary. Sending a v2 key that way would make it look plausible on the
    # version it does not belong to, and query strings end up in logs.
    is_deeply($request->{query}, {}, 'never as a query parameter');
    ok(!exists $request->{headers}{'X-Api-Key'}, 'nor under a second header');
};

subtest 'a keyless client builds and sends no credential at all' => sub {
    # Today every endpoint is licensed, so a keyless client only ever gets a
    # 401. It still has to BUILD, because a database offered without a licence
    # would need exactly this client - and an empty key is what an unset
    # `${{ secrets.X }}` interpolates to, where `Bearer ` is worse than nothing.
    my $origin = InternetDataTest::Origin->new(sub {
        shift->render(json => { databases => [] });
    });

    for my $args ([], [api_key => undef], [api_key => '']) {
        $origin->reset;
        ok(InternetData->new(base_url => $origin->url, @$args)->database->list,
            'the client built and called');
        my ($request) = $origin->requests;
        ok(!exists $request->{headers}{Authorization}, 'no empty Authorization without a key');
        is_deeply($request->{query}, {}, 'and no apikey query parameter');
    }
};

subtest 'responses are unwrapped at the right depth' => sub {
    my $family = InternetDataTest::family();
    my %bodies = (
        '/api/v2/database/list' => { databases => [$family] },
        '/api/v2/database/checksum' => {
            id => 'bogon_ip_v1', format => 'csvgz',
            checksums => { md5 => 'm', sha1 => 's1', sha256 => 's256', sha512 => 's512' },
        },
        '/api/v2/database/downloads' => { downloads => [{ dataset_id => 'bogon_ip_v1' }] },
        '/api/v2/database/metadata' => { id => 'bogon_ip_v1', entries => 42, size => { csvgz => 760 } },
    );
    my $origin = InternetDataTest::Origin->new(sub {
        my ($c) = @_;
        $c->render(json => $bodies{ $c->req->url->path->to_string });
    });
    my $client = InternetData->new(base_url => $origin->url, api_key => 'k');

    # `checksums` returns the WHOLE digest set. Reading a top-level sha256
    # shipped broken in another SDK: it returned undef against a healthy API.
    my $sums = $client->database->checksums('bogon_ip_v1', 'csvgz');
    is_deeply($sums, $bodies{'/api/v2/database/checksum'}{checksums}, 'the whole digest set');
    is($sums->{sha256}, 's256', 'the digest a caller actually wants is there');

    # v2 answers `databases`, where vpndetection's v1 answered `datasets`. One
    # letter of difference between two brands' feeds is exactly the sort of thing
    # a hand-written client gets wrong once and never notices.
    my $databases = $client->database->list;
    is_deeply($databases, [$family], 'list unwraps databases');
    is($databases->[0]{base}, 'bogon_ip', 'a family is keyed by base, not by a database id');
    is($databases->[0]{versions}[0]{id}, 'bogon_ip_v1', 'and the id to download hangs off versions');

    is_deeply($client->database->downloads, [{ dataset_id => 'bogon_ip_v1' }], 'downloads unwraps downloads');
    # metadata is the whole document rather than a member of it: it carries the
    # per-format size a caller budgets a transfer against.
    my $meta = $client->database->metadata('bogon_ip_v1');
    is($meta->{entries}, 42, 'metadata is the whole document');
    is($meta->{size}{csvgz}, 760, 'including the size that budgets a transfer');
};

subtest 'the query a call makes says what it asked for' => sub {
    my $origin = InternetDataTest::Origin->new(sub {
        my ($c) = @_;
        my %body = (
            '/api/v2/database/downloads' => { downloads => [] },
            '/api/v2/database/checksum' => { checksums => {} },
            '/api/v2/database/metadata' => {},
            '/api/v2/database/list' => { databases => [] },
        );
        $c->render(json => $body{ $c->req->url->path->to_string });
    });
    my $client = InternetData->new(base_url => $origin->url, api_key => 'k');

    $client->database->checksums('bogon_asn_v1', 'csvgz');
    $client->database->metadata('bogon_asn_v1');
    $client->database->downloads(limit => 5);
    $client->database->downloads;
    $client->database->list;

    my @requests = $origin->requests;
    is_deeply($requests[0]{query}, { id => 'bogon_asn_v1', format => 'csvgz' }, 'checksums');
    # No format: one metadata document describes every format the database is
    # built in.
    is_deeply($requests[1]{query}, { id => 'bogon_asn_v1' }, 'metadata takes an id alone');
    is_deeply($requests[2]{query}, { limit => 5 }, 'downloads passes a limit through');
    is_deeply($requests[3]{query}, {}, 'and sends none when none was given');
    is_deeply($requests[4]{query}, {}, 'list takes nothing at all');
};

subtest 'retries are configurable per call' => sub {
    my $origin = InternetDataTest::Origin->new(sub {
        shift->render(json => { rc => 'ERROR' }, status => 500);
    });
    my $client = InternetData->new(base_url => $origin->url, api_key => 'k', retries => 0);

    eval { $client->database->list(retries => 2) };
    isa_ok($@, 'InternetData::Error', 'still failed');
    is($origin->count, 3, 'one attempt plus two retries, not the client default of none');

    $origin->reset;
    eval { $client->database->list };
    is($origin->count, 1, 'the client default still applies without an override');
};

subtest 'a 429 is retried only when it carries Retry-After' => sub {
    my $attempts = 0;
    my $origin = InternetDataTest::Origin->new(sub {
        my ($c) = @_;
        my $retryable = $c->req->url->query->param('id') eq 'retryable';
        if (++$attempts == 1) {
            $c->res->headers->header('Retry-After' => 0) if $retryable;
            return $c->render(json => { rc => 'RATE_LIMITED' }, status => 429);
        }
        $c->render(json => { id => 'ok' });
    });
    my $client = InternetData->new(base_url => $origin->url, api_key => 'k', retries => 2);

    my $meta = $client->database->metadata('retryable');
    is($meta->{id}, 'ok', 'a rate limit was waited out');
    is($origin->count, 2, 'exactly one retry');

    $attempts = 0;
    $origin->reset;
    my $spent = eval { $client->database->metadata('spent') };
    ok(!defined $spent, 'a spent quota fails');
    is($@->kind, 'quota_exceeded', 'and is classified as such');
    is($origin->count, 1, 'a 429 without Retry-After is never retried');
};

subtest 'a Retry-After wait does not block the event loop' => sub {
    my $attempts = 0;
    my $origin = InternetDataTest::Origin->new(sub {
        my ($c) = @_;
        if (++$attempts == 1) {
            $c->res->headers->header('Retry-After' => 1);
            return $c->render(json => { rc => 'RATE_LIMITED' }, status => 429);
        }
        $c->render(json => { databases => [] });
    });
    my $client = InternetData->new(base_url => $origin->url, api_key => 'k', retries => 1);

    # A sleep inside a promise handler would freeze everything else sharing this
    # loop, the origin in this test included. A timer does not, and a recurring
    # tick is the difference made visible.
    my $ticks = 0;
    my $ticker = Mojo::IOLoop->recurring(0.05 => sub { $ticks++ });
    my $databases = $client->database->list;
    Mojo::IOLoop->remove($ticker);

    is_deeply($databases, [], 'the retry succeeded');
    cmp_ok($ticks, '>=', 5, "the loop kept running through the wait (ticked $ticks times)");
};

subtest 'the download redirect is never followed' => sub {
    my $origin = InternetDataTest::Origin->new(sub {
        my ($c, $o) = @_;
        if ($c->req->url->path->to_string eq '/api/v2/database/download') {
            $c->res->headers->location($o->url . '/huge');
            return $c->rendered(302);
        }
        # A real published file: announces gigabytes and then stalls. A client
        # that followed the redirect hangs here, and is caught by the request
        # count rather than by a transfer.
        $c->res->headers->content_length(8 * 1024 * 1024 * 1024);
        $c->res->headers->content_type('application/octet-stream');
        $c->render_later;
        $c->write('x' x 1024);
    });
    my $client = InternetData->new(base_url => $origin->url, api_key => 'k', timeout => 3);

    my $url = $client->database->download_url('bogon_ip_v1', 'mmdb');
    is($url, $origin->url . '/huge', 'the Location is the answer');
    is(scalar(grep { $_ eq '/huge' } $origin->paths), 0, 'the file itself was never requested');
    is($origin->count, 1, 'exactly one request was made');
};

subtest 'the redirect is not chased even when the environment says otherwise' => sub {
    # Mojo::UserAgent defaults max_redirects to 0, but MOJO_MAX_REDIRECTS in the
    # ENVIRONMENT overrides that for every agent in the process, including one a
    # caller hands in. Following the 302 would pull the whole file into memory
    # and lose the Location that IS the answer.
    local $ENV{MOJO_MAX_REDIRECTS} = 5;
    is(Mojo::UserAgent->new->max_redirects, 5, 'a fresh agent does follow redirects here');

    my $origin = InternetDataTest::Origin->new(sub {
        my ($c, $o) = @_;
        if ($c->req->url->path->to_string eq '/api/v2/database/download') {
            $c->res->headers->location($o->url . '/file');
            return $c->rendered(302);
        }
        $c->render(data => 'the whole database');
    });
    my $ua = Mojo::UserAgent->new;
    my $client = InternetData->new(base_url => $origin->url, api_key => 'k', ua => $ua);

    is($client->database->download_url('bogon_ip_v1', 'csvgz'), $origin->url . '/file',
        'the client still answers with the link');
    is($ua->max_redirects, 0, 'because it sets max_redirects on the agent it was given');
    is($origin->count, 1, 'and the file was never fetched');
};

subtest 'a 200 where a redirect belongs names the cause' => sub {
    my $origin = InternetDataTest::Origin->new(sub {
        shift->render(data => 'the whole database');
    });
    my $client = InternetData->new(base_url => $origin->url, api_key => 'k');

    my $url = eval { $client->database->download_url('bogon_ip_v1', 'csvgz') };

    ok(!defined $url, 'a success where a 302 was expected is a failure');
    like($@->message, qr/must not follow redirects/, 'and says what would cause it');
};

subtest 'a redirect with no Location is reported rather than returned empty' => sub {
    my $origin = InternetDataTest::Origin->new(sub { shift->rendered(302) });
    my $client = InternetData->new(base_url => $origin->url, api_key => 'k');

    my $url = eval { $client->database->download_url('bogon_ip_v1', 'csvgz') };

    ok(!defined $url, 'there is nothing to hand back');
    like($@->message, qr/without a Location header/, 'and the message says so');
};

subtest 'an unknown option is refused rather than ignored' => sub {
    my $client = InternetData->new(api_key => 'k');

    eval { InternetData->new(api_key => 'k', timout => 5) };
    like($@, qr/unknown option/, 'a typo in a constructor option croaks');
    eval { $client->database->list(retires => 2) };
    like($@, qr/unknown option/, 'and so does one in a per-call option');
    eval { $client->database->metadata('bogon_ip_v1', retires => 2) };
    like($@, qr/unknown option/, 'on every call, not just the first');
    eval { InternetData->new(api_key => 'k', retries => -1) };
    like($@, qr/retries cannot be negative/, 'and a value that cannot work is refused too');
};

subtest 'a call refuses arguments it cannot use' => sub {
    my $client = InternetData->new(api_key => 'k');

    eval { $client->database->metadata('') };
    like($@, qr/expected a database id/, 'metadata needs an id');
    eval { $client->database->checksums('bogon_ip_v1') };
    like($@, qr/expected a format/, 'checksums needs a format');
    eval { $client->database->download_url(undef, 'csvgz') };
    like($@, qr/expected a database id/, 'download_url needs an id');
};

subtest 'the non-blocking API works where the blocking one cannot' => sub {
    my $origin = InternetDataTest::Origin->new(sub {
        shift->render(json => { databases => [InternetDataTest::family()] });
    });
    my $client = InternetData->new(base_url => $origin->url, api_key => 'k');

    my $seen;
    $client->database->list_p->then(sub { $seen = shift })->wait;
    is($seen->[0]{base}, 'bogon_ip', 'list_p resolves with the catalog');

    # Mojo::Promise::wait is a no-op inside an already running loop, so a
    # blocking call in a Mojolicious application would silently return undef.
    # Croaking instead points at the promise form, and does it BEFORE any
    # request is spent.
    $origin->reset;
    my $croaked;
    Mojo::IOLoop->next_tick(sub {
        eval { $client->database->list };
        $croaked = $@;
        Mojo::IOLoop->stop;
    });
    Mojo::IOLoop->start;
    like($croaked, qr/list_p/, 'blocking inside a running loop points at the promise form');
    is($origin->count, 0, 'and costs no request finding out');
};

subtest 'a transport failure is a retryable network error' => sub {
    # Nothing is listening, so the request never gets far enough to have a
    # status. Mojo::UserAgent rejects with a plain string there, which is exactly
    # the transport failure the retry rule treats as worth another attempt.
    my $client = InternetData->new(
        base_url => 'http://127.0.0.1:1', api_key => 'k', retries => 0, timeout => 5,
    );

    my $databases = eval { $client->database->list };

    ok(!defined $databases, 'the call failed');
    isa_ok($@, 'InternetData::Error', 'with');
    is($@->kind, 'network', 'classified as a transport failure');
    is($@->retryable, 1, 'and worth another attempt');
    is($@->status, undef, 'carrying no status, because there was no response');
};

done_testing();
