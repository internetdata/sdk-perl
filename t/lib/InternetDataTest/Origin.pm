package InternetDataTest::Origin;

use strict;
use warnings;

use Mojo::Server::Daemon;
use Mojolicious;

# A real HTTP origin on an ephemeral port, sharing the singleton event loop with
# the client under test.
#
# A stub user agent would be cheaper and would prove less: it cannot show that a
# redirect was NOT followed, that a refusal was asked for exactly once, or that
# the request reaching object storage carried no credential.
sub new {
    my ($class, $handler) = @_;

    my $self = bless { handler => $handler, requests => [] }, $class;

    my $app = Mojolicious->new;
    $app->log->level('fatal');
    # NOT `/*path`: a route placeholder named `path` collides with a reserved
    # stash value and the application dies at startup.
    $app->routes->any('/*rest' => sub {
        my $c = shift;
        push @{ $self->{requests} }, {
            path => $c->req->url->path->to_string,
            query => $c->req->url->query->to_hash,
            headers => $c->req->headers->to_hash,
        };
        $self->{handler}->($c, $self);
    });

    $self->{daemon} = Mojo::Server::Daemon->new(
        app => $app, listen => ['http://127.0.0.1'], silent => 1,
    )->start;
    $self->{port} = $self->{daemon}->ports->[0];
    return $self;
}

sub url {
    return "http://127.0.0.1:$_[0]{port}";
}

sub requests {
    return @{ $_[0]{requests} };
}

sub count {
    return scalar @{ $_[0]{requests} };
}

sub paths {
    return map { $_->{path} } @{ $_[0]{requests} };
}

sub reset {
    my ($self) = @_;
    @{ $self->{requests} } = ();
    return $self;
}

1;
