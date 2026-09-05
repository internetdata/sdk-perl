package InternetData;

use strict;
use warnings;

use Carp ();
use Mojo::IOLoop;
use Mojo::Promise;
use Mojo::URL;
use Mojo::UserAgent;
use Scalar::Util ();

use InternetData::Error;

our $VERSION = '1.0.0';

use constant DEFAULT_BASE_URL => 'https://internetdata.io';

my %OPTIONS = map { $_ => 1 } qw(api_key base_url retries timeout ua);

sub new {
    my ($class, %args) = @_;
    my @unknown = sort grep { !$OPTIONS{$_} } keys %args;
    Carp::croak("InternetData->new: unknown option(s): @unknown") if @unknown;
    # Required rather than optional: every endpoint here is licensed, so there
    # is no anonymous tier to fall back to and a keyless client could only ever
    # collect 401s.
    Carp::croak('InternetData->new: an api_key is required')
        if !defined $args{api_key} || !length $args{api_key};

    my $retries = defined $args{retries} ? $args{retries} : 2;
    Carp::croak('InternetData->new: retries cannot be negative') if $retries < 0;

    my $self = bless {
        api_key => $args{api_key},
        base_url => _base_url($args{base_url}),
        retries => $retries,
        ua => $args{ua} || Mojo::UserAgent->new,
    }, $class;

    # Mojo::UserAgent does not follow redirects by default, but MOJO_MAX_REDIRECTS
    # in the environment turns that on for every agent in the process. Setting it
    # here is what stops a download's 302 being chased into a multi-gigabyte
    # transfer, on a machine whose environment we do not own.
    $self->{ua}->max_redirects(0);
    $self->{ua}->request_timeout(defined $args{timeout} ? $args{timeout} : 30);
    $self->{ua}->transactor->name("internetdata-perl/$VERSION");
    return $self;
}

# Every database this organization may see, with where each one stands.
#
# NOT only the licensed ones: `standing` says whether a database is yours today,
# was, or has never been bought, so a caller can see what else is published
# without a sales email.
#
# What comes back is the SERVER's answer for THIS key and nothing else. A
# database commissioned for a single customer is absent entirely from a listing
# for anyone else, rather than present with an `unlicensed` standing, so a
# catalog held from one key is not an answer for another and is not a catalog of
# what exists. Nothing here is cached for exactly that reason.
sub list {
    my $self = shift;
    $self->_assert_blocking_ok('list');
    return $self->_wait($self->list_p(@_));
}

sub list_p {
    my ($self, %options) = @_;
    return $self->_body_p('list', \%options, '/api/v2/database/list')
        ->then(sub { $_[0]->{databases} });
}

# What is inside one database: schema, sample rows, row count and per-format
# sizes. Poll it to decide whether today's build is worth fetching, and read
# `$meta->{size}{$format}` to size a transfer before starting it.
sub metadata {
    my $self = shift;
    $self->_assert_blocking_ok('metadata');
    return $self->_wait($self->metadata_p(@_));
}

sub metadata_p {
    my ($self, $id, %options) = @_;
    Carp::croak('metadata: expected a database id') if !defined $id || !length $id;
    return $self->_body_p('metadata', \%options, '/api/v2/database/metadata', id => $id);
}

# The digests published alongside one file.
#
# Returns the WHOLE set rather than one algorithm: which digests a database
# publishes is the API's choice, not ours, and picking one here is how a caller
# ends up holding undef against a perfectly healthy API.
sub checksums {
    my $self = shift;
    $self->_assert_blocking_ok('checksums');
    return $self->_wait($self->checksums_p(@_));
}

sub checksums_p {
    my ($self, $id, $format, %options) = @_;
    _assert_database('checksums', $id, $format);
    return $self->_body_p(
        'checksums', \%options, '/api/v2/database/checksum', id => $id, format => $format,
    )->then(sub { $_[0]->{checksums} });
}

# Your organization's recent download attempts, newest first, refusals included:
# a denial is what answers "it stopped working", and its absence answers nothing.
sub downloads {
    my $self = shift;
    $self->_assert_blocking_ok('downloads');
    return $self->_wait($self->downloads_p(@_));
}

sub downloads_p {
    my ($self, %options) = @_;
    my $limit = delete $options{limit};
    return $self->_body_p(
        'downloads', \%options, '/api/v2/database/downloads',
        defined $limit ? (limit => $limit) : (),
    )->then(sub { $_[0]->{downloads} });
}

# The time-limited URL for one file.
#
# The API answers 302 and this returns the Location without following it, so the
# caller decides how to transfer a file that can run to gigabytes. The link
# carries its own authorization, which is what makes it safe to hand to another
# process: it names no credential of yours. It authorizes the START of a
# transfer, so one already running is not interrupted when it lapses.
sub download_url {
    my $self = shift;
    $self->_assert_blocking_ok('download_url');
    return $self->_wait($self->download_url_p(@_));
}

sub download_url_p {
    my ($self, $id, $format, %options) = @_;
    _assert_database('download_url', $id, $format);
    $self->_check_options('download_url', \%options, 'retries');
    my $url = $self->_url('/api/v2/database/download', id => $id, format => $format);
    my $retries = defined $options{retries} ? $options{retries} : $self->{retries};
    return $self->_retry_p($retries, sub {
        $self->_get_p($url)->then(sub {
            my $res = shift->res;
            return _location($res) if $res->code == 302;
            # A 2xx here means the user agent followed the redirect and read the
            # database into memory. Naming the cause beats reporting a shape
            # mismatch a caller cannot act on.
            die InternetData::Error->new(
                kind => 'server_error', status => $res->code,
                message => 'expected a redirect to object storage but got '
                    . $res->code . '; the user agent must not follow redirects',
            ) if $res->is_success;
            die InternetData::Error->from_response($res->code, $res->headers, $res->json);
        });
    });
}

# Stream one file to a path, and return the bytes written.
sub download {
    my $self = shift;
    $self->_assert_blocking_ok('download');
    return $self->_wait($self->download_p(@_));
}

sub download_p {
    my ($self, $id, $format, $path, %options) = @_;
    # Everything a caller can get wrong is refused before the file is opened, so
    # a mistyped id cannot leave a stray .part behind.
    _assert_database('download', $id, $format);
    $self->_check_options('download', \%options, 'retries');
    Carp::croak('download: expected a destination path') if !defined $path || !length $path;

    # The bytes land beside the destination and are renamed into place, so a
    # transfer that dies half way leaves no short file that reads as a whole
    # database. Opened BEFORE the request: an unwritable path costs no quota.
    my $partial = "$path.part";
    open my $handle, '>', $partial
        or Carp::croak("download: cannot open $partial: $!");
    binmode $handle;

    return $self->_transfer_p('download', $id, $format, \%options, sub {
        # A failure writing is the caller's to read rather than ours to retry: a
        # full disk and a reset socket are different problems.
        print {$handle} $_[0] or die "could not write the database to $partial: $!";
    })->then(sub {
        my $written = shift;
        close $handle or die "could not write the database to $partial: $!";
        rename $partial, $path or die "could not move the database into place at $path: $!";
        return $written;
    })->catch(sub {
        my $error = shift;
        close $handle;
        unlink $partial;
        die $error;
    });
}

# One file's bytes, in memory.
sub download_bytes {
    my $self = shift;
    $self->_assert_blocking_ok('download_bytes');
    return $self->_wait($self->download_bytes_p(@_));
}

sub download_bytes_p {
    my ($self, $id, $format, %options) = @_;
    _assert_database('download_bytes', $id, $format);
    my $bytes = '';
    return $self->_transfer_p('download_bytes', $id, $format, \%options, sub {
        $bytes .= $_[0];
    })->then(sub { return $bytes });
}

# The 302 is followed as a SECOND request, and that transfer is issued exactly
# once: `retries` covers the API call that hands out the link, not a transfer
# that may have moved gigabytes before it failed.
sub _transfer_p {
    my ($self, $method, $id, $format, $options, $on_chunk) = @_;
    $self->_check_options($method, $options, 'retries');
    return $self->download_url_p($id, $format, %$options)
        ->then(sub { $self->_stream_p(shift, $on_chunk) });
}

# One file transfer. Every chunk is handed to $on_chunk and none is kept, so a
# body costs the same in memory whether it is 264 bytes or 5.34 GiB. Resolves
# with the number of bytes handed over.
sub _stream_p {
    my ($self, $url, $on_chunk) = @_;
    # Built here rather than through _get_p, which is the only place the API key
    # is ever attached: the presigned link authorizes itself, so carrying the key
    # would hand it to a host with no business holding it. Object storage answers
    # 400 to a presigned GET that also carries an Authorization header, so this
    # is not merely a leak - it breaks the download too.
    my $tx = $self->{ua}->build_tx(GET => $url);

    # Mojo asks for gzip on every request it builds. A published file is already
    # compressed, so the only thing that would buy is a Content-Length counting
    # bytes that never reach the sink, and that length is the only evidence the
    # transfer arrived whole.
    $tx->req->headers->remove('Accept-Encoding');
    # Mojo aborts a response past max_message_size, counting every byte it parses
    # whether or not it keeps any of them. Mojo::Message::Response defaults to
    # 2 GiB, which the catalog is already past, and MOJO_MAX_MESSAGE_SIZE lowers
    # it for every response in the process, on a machine whose environment we do
    # not own.
    $tx->res->max_message_size(0);

    my $received = 0;
    # Unsubscribing Mojo's own reader is what stops the body being collected into
    # the message. The subscriber hangs off the transaction, so holding the
    # transaction strongly inside it would be a cycle the interpreter never
    # collects; the user agent keeps it alive for as long as bytes are arriving.
    my $weak = $tx;
    Scalar::Util::weaken($weak);
    $tx->res->content->unsubscribe('read')->on(read => sub {
        my (undef, $bytes) = @_;
        # An error body is neither written out nor held: the status is what
        # separates a lapsed link from a refused one, and nothing bounds the size
        # of what a storage host puts in the body of a refusal.
        return unless $weak && ($weak->res->code || 0) == 200;
        $received += length $bytes;
        $on_chunk->($bytes);
    });

    return $self->_start_untimed_p($tx)->then(sub {
        my $res = shift->res;
        # No body to read: the handler above kept nothing that was not a 200,
        # because nothing bounds the size of what a storage host puts in a
        # refusal. So the message names where the refusal came from, and the
        # status still decides the kind - which is what says whether the link
        # lapsed or was never good.
        die InternetData::Error->from_response(
            $res->code, $res->headers, undef,
            'object storage refused the download link with status ' . $res->code,
        ) unless $res->code == 200;

        # A body that stops early reaches Perl as an ordinary end of stream: the
        # status was 200 and Mojo reports no error, so without this a half
        # transfer is a short file nobody notices.
        my $declared = $res->headers->content_length;
        die InternetData::Error->new(
            kind => 'network',
            message => "the transfer ended after $received of $declared bytes",
        ) if defined $declared && length $declared && $declared != $received;
        return $received;
    });
}

# request_timeout bounds the WHOLE response and Mojo::UserAgent has no
# per-transaction form of it, so the 30 seconds that is right for a metadata call
# is wrong for a gigabyte. It is lifted only across the hand-over: start_p reaches
# the agent synchronously, so no other request can be started inside the window.
sub _start_untimed_p {
    my ($self, $tx) = @_;
    my $ua = $self->{ua};
    my $bound = $ua->request_timeout;
    $ua->request_timeout(0);
    my $promise = eval { $ua->start_p($tx) };
    my $failed = $@;
    $ua->request_timeout($bound);
    die InternetData::Error->wrap($failed) unless $promise;
    return $promise->catch(sub {
        die InternetData::Error->new(kind => 'network', message => "$_[0]");
    });
}

sub _body_p {
    my ($self, $method, $options, $path, @query) = @_;
    $self->_check_options($method, $options, 'retries');
    my $url = $self->_url($path, @query);
    my $retries = defined $options->{retries} ? $options->{retries} : $self->{retries};
    return $self->_retry_p($retries, sub { $self->_json_p($url) });
}

# Recurses through $self rather than through a self-referential closure, which
# in Perl would be a reference cycle the interpreter never collects.
sub _retry_p {
    my ($self, $left, $attempt) = @_;
    return $attempt->()->catch(sub {
        my $error = InternetData::Error->wrap(shift);
        die $error if $left <= 0 || !$error->retryable;
        # A server-supplied delay is honored with a TIMER, never a sleep: this
        # promise may share an event loop with a Mojolicious application, and
        # sleeping here would stall every other thing on it.
        return Mojo::Promise->timer($error->retry_after || 0)
            ->then(sub { $self->_retry_p($left - 1, $attempt) });
    });
}

sub _json_p {
    my ($self, $url) = @_;
    return $self->_get_p($url)->then(sub {
        my $res = shift->res;
        die InternetData::Error->from_response($res->code, $res->headers, $res->json)
            unless $res->is_success;
        my $body = $res->json;
        die InternetData::Error->new(
            kind => 'server_error', status => $res->code,
            message => 'the API did not answer with a JSON object',
        ) unless ref $body eq 'HASH';
        return $body;
    });
}

# Mojo::UserAgent rejects with a plain string when the request never got far
# enough to have a status, which is exactly the transport failure the retry rule
# treats as worth another attempt.
sub _get_p {
    my ($self, $url) = @_;
    return $self->{ua}->get_p($url => $self->_headers)->catch(sub {
        die InternetData::Error->new(kind => 'network', message => "$_[0]");
    });
}

sub _headers {
    my ($self) = @_;
    # One scheme. The v1 endpoints on this same host take `?apikey=` with a
    # different key vocabulary, so sending a v2 key that way would make it look
    # plausible on the version it does not belong to, and query strings end up in
    # logs.
    return { Accept => 'application/json', Authorization => "Bearer $self->{api_key}" };
}

sub _url {
    my ($self, $path, %query) = @_;
    my $url = Mojo::URL->new($self->{base_url} . $path);
    $url->query(%query) if %query;
    return $url;
}

sub _wait {
    my ($self, $promise) = @_;
    my ($value, $error, $failed);
    $promise->then(sub { $value = shift }, sub { ($error, $failed) = (shift, 1) })->wait;
    die $error if $failed;
    return $value;
}

# Checked BEFORE the promise is built, not after: Mojo::UserAgent starts a
# transaction as soon as one is created, so croaking later would still have spent
# a request from the caller's allowance.
sub _assert_blocking_ok {
    my ($self, $method) = @_;
    return unless Mojo::IOLoop->is_running;
    Carp::croak(
        "InternetData::$method cannot block inside a running Mojo::IOLoop; "
        . "call ${method}_p instead, which returns a Mojo::Promise"
    );
}

sub _check_options {
    my ($self, $method, $options, @allowed) = @_;
    my %allowed = map { $_ => 1 } @allowed;
    my @unknown = sort grep { !$allowed{$_} } keys %$options;
    Carp::croak("InternetData::$method: unknown option(s): @unknown") if @unknown;
}

sub _assert_database {
    my ($method, $id, $format) = @_;
    Carp::croak("$method: expected a database id") if !defined $id || !length $id;
    Carp::croak("$method: expected a format") if !defined $format || !length $format;
}

sub _location {
    my ($res) = @_;
    my $location = $res->headers->location;
    die InternetData::Error->new(
        kind => 'server_error', status => $res->code,
        message => 'the API redirected without a Location header',
    ) if !defined $location || !length $location;
    return $location;
}

sub _base_url {
    my ($url) = @_;
    $url = DEFAULT_BASE_URL unless defined $url && length $url;
    $url =~ s{/+\z}{};
    return $url;
}

1;

__END__

=head1 NAME

InternetData - the official Perl client for the InternetData API

=head1 SYNOPSIS

    use InternetData;

    my $client = InternetData->new(api_key => $ENV{INTERNETDATA_API_KEY});

    for my $db (@{ $client->list }) {
        next unless $db->{standing} eq 'licensed';
        my $id = $db->{versions}[-1]{id};
        $client->download($id, 'csvgz', "./$id.csv.gz");
    }

=head1 DESCRIPTION

Downloads InternetData's licensed IP and network databases, and reads what the
API publishes about them: the catalog, per-database metadata, checksums, and
your organization's recent download attempts.

Every endpoint needs a key carrying the C<db.download> scope, which is why
L</new> requires one: there is no anonymous tier to fall back to.

=head1 METHODS

Every method has a C<_p> twin returning a L<Mojo::Promise>, and takes a per-call
C<retries> option. Failures die with an L<InternetData::Error>.

=head2 new

    my $client = InternetData->new(api_key => '...', %options);

=over 4

=item api_key

Required. A console-issued key carrying the C<db.download> scope. Keys are
default-deny, so an existing key does not reach these endpoints until the scope
is added to it.

=item base_url

Defaults to C<https://internetdata.io>.

=item retries

Attempts after a retryable failure. Defaults to 2, and is overridable per call.

=item timeout

Per-request timeout in seconds. Defaults to 30. It is lifted for a file
transfer, which is not a request whose duration a caller can predict.

=item ua

Your own L<Mojo::UserAgent>, for a proxy or custom TLS settings. The client sets
C<max_redirects> to 0 on whichever agent it is given: the download endpoint
answers C<302> and that redirect is the answer, so following it would pull a
multi-gigabyte file into memory.

=back

=head2 list

    my $databases = $client->list;

An array reference of the database B<families> this organization may see. A
licence is held against a family, and each family carries every published
version of itself:

    {
        base => 'bogon_ip',              # what a licence is held against
        name => 'Bogon IP',
        summary => 'IP ranges that cannot legitimately appear on the internet.',
        standing => 'licensed',          # licensed, expired or unlicensed
        redistribution => 'internal',    # evaluation, internal, redistribute or undef
        starts => '2026-09-04T07:49:45.118Z',
        expires => undef,                # undef when the licence has no end date
        versions => [
            {
                id => 'bogon_ip_v1',     # this is what you download
                version => 1,
                summary => 'IP ranges that cannot legitimately appear on the internet.',
                formats => ['csvgz', 'mmdb'],
            },
        ],
    }

The id every other method takes is C<< $version->{id} >>, never
C<< $family->{base} >>.

=head3 The listing is not the same for everyone

C<standing> reports where your organization stands against a database, so an
unlicensed one is listed and you can see that it exists. A B<private> database
is different: it was commissioned for a single customer, so it is B<absent
entirely> from a listing for anyone else rather than present with an
C<unlicensed> standing. Listing it would advertise that customer.

The server decides this per key. So do not reconstruct a catalog from any other
source, do not hold one listing and reuse it for a different key, and do not
treat what you got as a list of what InternetData publishes. Nothing here is
cached for that reason.

=head2 metadata($id)

One database's build document: C<updated>, C<entries>, per-format C<schema>,
C<sample> and C<size>. Poll it to decide whether today's build is worth
fetching, and read C<< $meta->{size}{$format} >> to size a transfer before
starting it.

=head2 checksums($id, $format)

The whole digest set for one published file, as a hash reference keyed by
algorithm.

=head2 downloads(%options)

Your organization's recent download attempts, newest first, refusals included.
C<limit> caps the number returned.

=head2 download_url($id, $format)

A time-limited URL for one file. The API answers C<302> and this returns the
C<Location> without following it. The link carries its own authorization and
names no credential of yours, so it is safe to hand to another process; it
authorizes the START of a transfer, so one already running is not interrupted
when it lapses.

=head2 download($id, $format, $path)

Streams one file to C<$path> and returns the bytes written. Nothing beyond one
chunk is ever held, whatever the database weighs.

The bytes land in a neighboring C<.part> file that is renamed on completion, so
a transfer that dies half way leaves nothing behind that reads as a whole
database. A body that stops early is raised rather than accepted: the file is
never left short and silent.

=head2 download_bytes($id, $format)

Downloads one file and returns its bytes.

B<This holds the entire file in memory>, and the catalog spans seven orders of
magnitude, from C<bogon_asn_v1> at 264 bytes to C<resproxy_ip_14d_v1> at
5.34 GiB. Reach for it at the small end, where the bytes go straight into a
parser, and use L</download> for anything you have not measured; L</metadata>
publishes the size per format without transferring anything, which is how you
find out which end you are at.

=head1 TRANSFERS

C<download> and C<download_bytes> follow the redirect as a second request
carrying B<no credential>: the link authorizes itself, so forwarding the API key
would hand it to a host with no business holding it - and object storage answers
C<400> to a presigned GET that also carries an C<Authorization> header, so it
would break the download too.

That transfer is issued exactly once. C<retries> covers the API call that hands
out the link, not a transfer that may already have moved gigabytes before it
failed, and the per-request timeout that bounds an API call is lifted for it.

=head1 NON-BLOCKING USE

Every call has a C<_p> twin returning a L<Mojo::Promise>, so the library drops
into a Mojolicious application without a worker. The blocking forms are those
promises plus a C<wait>, so nothing is duplicated and both paths retry
identically.

    $client->list_p
        ->then(sub { say $_->{base} for @{ shift() } })
        ->catch(sub { warn shift })
        ->wait;

Inside an already running L<Mojo::IOLoop> the blocking forms cannot work and
croak saying so. Use the C<_p> forms there.

=head1 SEE ALSO

L<InternetData::Error>.

=head1 LICENSE

MIT. Copyright Mslm Dev.

=cut
