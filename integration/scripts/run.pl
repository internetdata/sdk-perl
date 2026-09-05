#!/usr/bin/env perl

use strict;
use warnings;

use Cwd ();
use File::Basename ();
use File::Path ();
use File::Spec ();

# Runs the integration suite against the distribution as PUBLISHED on CPAN, which
# is the one thing the offline suite cannot check: that suite tests this working
# tree, so it stays green through a tag that never landed, a MANIFEST that ships
# no lib/, or a prerequisite a consumer cannot resolve.
#
#   perl scripts/run.pl            # from integration/, with cpanm on PATH
#   ./scripts/run.sh               # the same thing in docker
#
# Two conditions make the run meaningless rather than failing, and each one skips
# with a reason instead:
#
#   1. Nothing published satisfies the floor in cpanfile. Before the first release
#      there is no artifact to test at all.
#   2. The staging key is missing. The suite then skips from inside Test::More, so
#      the skip and its reason land in the test output rather than only here.

my $MODULE = 'InternetData';
my $SECRET = 'INTERNETDATA_STAGING_KEY';
my $ROOT = Cwd::abs_path(File::Spec->catdir(File::Basename::dirname(__FILE__), '..'));
my $LOCAL_LIB = File::Spec->catdir($ROOT, 'local');
my $INSTALLED_LIB = File::Spec->catdir($LOCAL_LIB, 'lib', 'perl5');

main();

sub main {
    chdir $ROOT or fail("cannot enter $ROOT: $!");
    my $floor = required_version();

    my $published = published_version($floor);
    return unless defined $published;
    print "==> $MODULE $published is published, and cpanfile asks for $floor or newer\n";
    report_key();

    # Removed first, so every run resolves the floor afresh against CPAN. A kept
    # tree would pin whatever the first run happened to pick, and the daily run
    # would stop noticing new releases.
    File::Path::rmtree($LOCAL_LIB) if -d $LOCAL_LIB;
    run(cpanm(), '--notest', '--quiet', "--local-lib=$LOCAL_LIB", "$MODULE~>=$floor")
        or fail("cpanm could not install $MODULE~>=$floor");
    assert_installed($floor);

    # Overwritten rather than extended: an inherited PERL5LIB naming the working
    # tree beside this directory would put the unreleased code back in @INC, and
    # every test would pass against it.
    $ENV{PERL5LIB} = $INSTALLED_LIB;
    run('prove', '-It/lib', '-r', 't') or exit 1;
}

# The floor is declared once, in cpanfile, and read from there rather than
# repeated here: two copies of a version number drift.
sub required_version {
    open my $fh, '<', File::Spec->catfile($ROOT, 'cpanfile')
        or fail("cannot read cpanfile: $!");
    while (my $line = <$fh>) {
        return $1 if $line =~ /^\s*requires\s+'\Q$MODULE\E'\s*,\s*'([^']+)'/;
    }
    fail("cpanfile does not require $MODULE");
}

# What CPAN would actually resolve, asked with cpanm's own resolver so the answer
# is what an install will see. A distribution that has never been released
# answers "couldn't find", which is the state before the first tag.
#
# The version has to be compared HERE. `cpanm --info Foo~>=99` answers with the
# newest release and exits 0 even when nothing satisfies the range, so trusting
# its exit status would report an ancient release as a match, and only the
# install two steps later would notice.
sub published_version {
    my ($floor) = @_;
    my ($ok, $out) = capture(cpanm(), '--info', $MODULE);
    if (!$ok) {
        skip("$MODULE is not on CPAN, so there is no published distribution to test");
        return undef;
    }
    my ($version) = $out =~ /\Q$MODULE\E-([0-9][0-9._]*)\.(?:tar\.gz|tgz|zip)/;
    if (!defined $version) {
        skip("cpanm resolved $MODULE to '$out', which names no version");
        return undef;
    }
    if (!newer_or_same($version, $floor)) {
        skip("the newest published $MODULE is $version, and cpanfile asks for $floor or newer");
        return undef;
    }
    return $version;
}

# cpanm can exit 0 having installed NOTHING, and Makefile.PL only WARNS about a
# prerequisite it cannot satisfy, so the install is believed only once a probe
# process has LOADED the module and said where from. Without this the run fails
# several steps later inside the suite, with a message that reads like a code
# fault rather than a resolution one - which is exactly how the sibling Perl SDK
# went red.
sub assert_installed {
    my ($floor) = @_;
    my $probe = <<'PROBE';
        print "$InternetData::VERSION\n$INC{'InternetData.pm'}\n";
PROBE
    local $ENV{PERL5LIB} = $INSTALLED_LIB;
    my ($ok, $out) = capture($^X, "-I$INSTALLED_LIB", "-M$MODULE", '-e', $probe);
    fail("$MODULE did not install: it cannot be loaded from $INSTALLED_LIB\n$out") unless $ok;

    my ($version, $loaded) = split /\n/, $out;
    fail("$MODULE installed but reports no version") unless defined $version && length $version;
    fail("installed $MODULE $version, and cpanfile asks for $floor or newer")
        unless newer_or_same($version, $floor);

    # The suite is worthless if the toolchain handed it the working tree, and
    # that failure is silent: every test passes, against code that was never
    # released.
    my $resolved = Cwd::abs_path($loaded) || $loaded;
    my $installed = Cwd::abs_path($INSTALLED_LIB) || $INSTALLED_LIB;
    fail("$MODULE was loaded from $resolved, which is not the installed copy under $installed")
        unless index($resolved, "$installed/") == 0;
    print "==> testing $MODULE $version from $resolved\n";
}

sub report_key {
    if (!length($ENV{$SECRET} || '')) {
        print "==> no staging key: the suite will skip\n";
        notice("$SECRET is not set, so every served assertion is skipped");
        return;
    }
    print "==> staging key present\n";
}

sub cpanm {
    return $ENV{CPANM} || 'cpanm';
}

sub newer_or_same {
    my ($have, $want) = @_;
    my @have = split /[._]/, $have;
    my @want = split /[._]/, $want;
    for my $i (0 .. 2) {
        my $left = $have[$i] || 0;
        my $right = $want[$i] || 0;
        return 1 if $left > $right;
        return 0 if $left < $right;
    }
    return 1;
}

sub run {
    my @command = @_;
    print '==> ' . join(' ', @command) . "\n";
    return system(@command) == 0;
}

sub capture {
    my @command = @_;
    my $pid = open my $fh, '-|';
    fail("cannot fork: $!") unless defined $pid;
    if (!$pid) {
        open STDERR, '>&', \*STDOUT;
        exec @command or exit 127;
    }
    my $out = do { local $/; <$fh> };
    close $fh;
    $out = '' unless defined $out;
    $out =~ s/\s+\z//;
    return ($? == 0, $out);
}

# Exit 0: a skip means the run could say nothing, not that something is wrong.
sub skip {
    my ($reason) = @_;
    print "==> SKIPPED: $reason\n";
    notice("Integration suite skipped: $reason");
    exit 0;
}

sub fail {
    my ($reason) = @_;
    print STDERR "==> FAILED: $reason\n";
    exit 1;
}

# Surfaced on the workflow run itself, so a skip is visible without opening the
# log and reading to the end of it.
sub notice {
    my ($message) = @_;
    return unless ($ENV{GITHUB_ACTIONS} || '') eq 'true';
    print "::notice title=Integration::$message\n";
}
