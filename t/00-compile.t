use strict;
use warnings;

use Test::More;

my @modules = qw(
    InternetData
    InternetData::Database
    InternetData::Error
);

use_ok($_) for @modules;

# Makefile.PL takes the distribution version from InternetData.pm alone, so a
# module left behind would ship indexed at the wrong version. A forgotten bump is
# a test failure rather than a bad release.
my $version = InternetData->VERSION;
ok($version, "the distribution version is $version");
is($_->VERSION, $version, "$_ is at $version") for @modules;

done_testing();
