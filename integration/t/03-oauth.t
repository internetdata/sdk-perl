use strict;
use warnings;

use lib 't/lib';

use Test::More;
use InternetData;
use InternetDataIntegration::Staging qw(STAGING);

# The published oauth accessor against staging's authorization server, on a
# client with NO key: none of these requests needs one.
#
# Only what is safe to repeat daily. Nothing here polls, since nobody approves a
# sign-in in CI, and a device authorization is started at most once a run: the
# server allows 30 a minute per source address, shared with every other SDK's
# run from the same runner.

# Already public in the CLI's source, and the only client staging accepts.
my $CLIENT_ID = 'internetdata-cli';
# Where staging sends a person to approve a device sign-in.
my $STAGING_CONSOLE = 'https://app-staging.internetdata.io';

my $oauth = InternetData->new(base_url => STAGING)->oauth;

subtest 'the metadata names staging as its issuer' => sub {
    my $metadata = $oauth->metadata;
    is($metadata->{issuer}, STAGING, 'issuer');
    ok($metadata->{device_authorization_endpoint}, 'a device authorization endpoint');
    ok((grep { $_ eq 'S256' } @{ $metadata->{code_challenge_methods_supported} || [] }), 'S256');
};

# The server answers 200 for any token, known or not.
subtest 'revoking a token nobody holds succeeds' => sub {
    my $ok = eval { $oauth->revoke($CLIENT_ID, 'mo_rt_sdk-ci-not-a-token'); 1 };
    ok($ok, 'revoked') or diag("$@");
};

# An unknown device code is refused before anything is recorded.
subtest 'an unknown device code is an expired token' => sub {
    eval { $oauth->exchange_device_code($CLIENT_ID, 'mo_dc_sdk-ci-not-a-code') };
    my $error = $@;
    isa_ok($error, 'InternetData::OauthExpiredTokenError');
    is(ref $error && $error->status, 400, 'status 400');
};

subtest 'a device authorization starts, or is slowed down' => sub {
    my $device = eval { $oauth->device_authorization($CLIENT_ID, scope => 'account.read') };
    if (my $error = $@) {
        # Other runs share this runner's address, and slow_down is the server working.
        isa_ok($error, 'InternetData::OauthError');
        is(ref $error && $error->error_code, 'slow_down', 'refused only with slow_down');
        return;
    }
    ok(length $device->{device_code}, 'a device code');
    ok(length $device->{user_code}, 'a user code');
    # The console's, not the apex's: the API is served at the apex here, so a page
    # taken from the API host would be the landing page's, which a /device suffix
    # alone still passes.
    is($device->{verification_uri}, "$STAGING_CONSOLE/device", 'the console device page');
    cmp_ok($device->{expires_in}, '>', 0, 'a positive expires_in');
    cmp_ok($device->{interval}, '>', 0, 'a positive interval');
};

done_testing();
