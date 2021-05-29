#!/usr/bin/perl
#
# Program:      wled-manage.pl
# Author:       David Dee
# Date:         2021 APR 24
# Purpose:


######################################################################
# Declarations
######################################################################
# {{{1

use strict;
use English;

use File::Basename;
use LockFile::Simple;

# use Getopt::Long;
use Getopt::Long qw(:config no_ignore_case bundling);
use POSIX qw(strftime);
use Data::Dumper;
use Time::HiRes qw( usleep );

use REST::Client;
use JSON;

# }}}1
######################################################################
#  Global Constants
######################################################################
# {{{1

my $lockfile = sprintf "/var/tmp/%s.lock", basename($0);
# my $lockfile = sprintf "/var/tmp/%s-%s.lock", basename($0), getpwuid($EUID);

# printf "Lockfile: %s\n", $lockfile;


# }}}1
######################################################################
#  WLED Config Constants
######################################################################
# {{{1

my %wled_commands = (
    'setup_fam' => {
        'seg' => [
            { "id" => 0, "start" =>   0, "stop" =>  39 },
            { "id" => 1, "start" =>  40, "stop" =>  79 },
            { "id" => 2, "start" =>  80, "stop" => 120 },
        ],
    },
    'setup_kitchen' => {
        'seg' => [
            { "id" => 0, "start" =>   0, "stop" =>  90 },
            { "id" => 1, "start" =>  90, "stop" => 150 },
            { "id" => 2, "start" => 150, "stop" => 240 },
        ],
    },
    'init_kitchen' => {
        "on" => $JSON::true,"bri" => 174,"transition" => 7,"ps" => 1,"pl" => -1,
        "ccnf" => {"min" => 1,"max" => 5,"time" => 12},
        "nl" => {"on" => $JSON::false,"dur" => 30,"fade" => $JSON::true,"mode" => 1,"tbri" => 0,"rem" => -1},
        "udpn" => {"send" => $JSON::false,"recv" => $JSON::true},
        "lor" => 0,"mainseg" => 0,"seg" => [
            {"id" => 0,  "grp" => 1,"spc" => 0,"on" => $JSON::true,"bri" => 219,"col" => [[41,255,59],[0,0,0],[0,0,0]],"fx" => 99,"sx" => 13,"ix" => 74,"pal" => 0,"sel" => $JSON::true,"rev" => $JSON::false,"mi" => $JSON::false},
            {"id" => 1,  "grp" => 1,"spc" => 0,"on" => $JSON::true,"bri" => 220,"col" => [[0,127,255],[0,0,0],[0,0,0]],"fx" => 99,"sx" => 13,"ix" => 74,"pal" => 0,"sel" => $JSON::true,"rev" => $JSON::false,"mi" => $JSON::false},
            {"id" => 2,  "grp" => 1,"spc" => 0,"on" => $JSON::true,"bri" => 213,"col" => [[255,0,251],[0,0,0],[0,0,0]],"fx" => 99,"sx" => 13,"ix" => 74,"pal" => 0,"sel" => $JSON::true,"rev" => $JSON::false,"mi" => $JSON::false}
        ]
    },


    'off' => {
        "on" => $JSON::false,
    },
    'on' => {
        "on" => $JSON::true,
    },

    'foff' => {
        "on" => $JSON::false, "tt" => 0,
    },
    'fon' => {
        "on" => $JSON::true, "tt" => 0,
    },

    'off=0' => {
        'seg' => [ { "id" => 0, "on" => $JSON::false } ]
    },
    'off=1' => {
        'seg' => [ { "id" => 1, "on" => $JSON::false } ]
    },
    'off=2' => {
        'seg' => [ { "id" => 2, "on" => $JSON::false } ]
    },

    'on=0' => {
        'seg' => [ { "id" => 0, "on" => $JSON::true } ]
    },
    'on=1' => {
        'seg' => [ { "id" => 1, "on" => $JSON::true } ]
    },
    'on=2' => {
        'seg' => [ { "id" => 2, "on" => $JSON::true } ]
    },


    'alert_left' => {
        'seg' => [
            { "id" => 2, "on" => $JSON::true, "fx" => 28, "rev" => $JSON::false, "sx" => 240, "ix" => 64, "col" =>  [ [255,192,0], [0,0,0] ] }
        ],
    },
    'alert_left_off' => {
        'seg' => [
            { "id" => 2, "on" => $JSON::false},
        ],
    },
    'alert_right' => {
        'seg' => [
            { "id" => 0, "on" => $JSON::true, "fx" => 28, "rev" => $JSON::true, "sx" => 240, "ix" => 64, "col" =>  [ [255,192,0], [0,0,0] ] }
        ],
    },
    'alert_right_off' => {
        'seg' => [
            { "id" => 0, "on" => $JSON::false},
        ],
    },

);

# }}}1
######################################################################
#  Global Variables
######################################################################
# {{{1

my $debug = 0;
my $silent = 0;
my $verbose = 0;

my $strip = "";

my $client;

my $strip = "kitchen";          # default to kitchen
my @actions = ();

# }}}1
######################################################################
#  Common Routines
######################################################################
# {{{1

sub logit($@) {                                 # {{{2
    my $fmt = shift;

    print  strftime("%Y-%m-%d %H:%M:%S: ", localtime());
    printf $fmt, @_;
    print "\n";
}                                               # }}}2

sub substr_ellipse($$) {                        # {{{2
    my $s = shift;
    my $len = shift;

    if ( length($s) > $len ) {
        return substr($s,0,($len-3)) . "...";
    } else {
        return substr($s,0,$len);
    }
}                                               # }}}2

sub usage() {                           # {{{2
    printf "Usage:\n\n";
    printf "\t$0 [-svx] [-l <wled-strip>] <action> ... \n\n";
    printf "    -l  --light         WLED Light (ktchen, fam)\n";
    printf "    -s  --silent        Silent Mode\n";
    printf "    -v  --verbose       Verbose Mode\n";
    printf "    -x  --debug         Debug Mode\n";
    print  "Actions:";
    my $n = 0;
    foreach my $k (sort keys %wled_commands) {
        print "\n    "  if ( $n++ % 4 == 0 );
        printf "%-14s  ", $k;
    }
    print "\n\n";
}                                               # }}}2

sub get_state_file($$$) {                        # {{{2
    my $strip = shift;
    my $seg = shift;
    my $key = shift;
    return sprintf "/tmp/wled-%s.%s.%s.json", $strip, $seg, $key;
}                                               # }}}2

sub save_state($$$$) {                          # {{{2
    my $state = shift;
    my $strip = shift;
    my $seg = shift;
    my $key = shift;

    my $state_file = get_state_file($strip, $seg, $key);
    open SAVE, "> $state_file" or die "Could not save state in $state_file: $!\n ";
    print SAVE encode_json($state);
    close SAVE;
}                                               # }}}2

sub restore_state($$$) {                          # {{{2
    my $strip = shift;
    my $seg = shift;
    my $key = shift;

    $key =~ s/_off$//;

    my $state_file = get_state_file($strip, $seg, $key);
    printf "State File: %s\n", $state_file;
    if ( -r ${state_file} ) {
        open RESTORE, "< $state_file" or die "Could not save state in $state_file: $!\n ";
        my $text = <RESTORE>;
        printf "Restored text: '%s'\n", $text           if ( $verbose >= 1 );
        close RESTORE;
        chomp $text;

        unlink $state_file;

        # return decode_json($text);
        return $text;
    } else {
        printf "Restored text: empty.\n"                if ( $verbose >= 0 );
        return undef;
    }

}                                               # }}}2

sub wled_execute($$) {                          # {{{2
    my $command = shift;
    my $quiet = shift;

    if ( $command eq "get" ) {
        $client->GET('/json/state');
    } elsif ( $command =~ /^cmd:(.*)$/ ) {
        my $cmd = $1;
        print "     cmd: " . $cmd . "\n"                if ( $verbose );

        $client->POST('/json/state', $cmd);
    } elsif ( ! defined($wled_commands{$command}) ) {
        printf " Unknown Command: '%s': \n", $command;
    } else {
        printf " command: '%s': \n", $command;
        my $cmd = $wled_commands{$command};

        print "     cmd: " . encode_json($cmd) . "\n";

        $client->POST('/json/state', encode_json($cmd));
    }

    if( $client->responseCode() eq '200' ){
        if ( ! $quiet ) {
            printf "Received: %s\n", $client->responseContent();
        }
    } else {
        printf "   Error: %s\n", $client->responseCode();
        exit(1);
    }

    return decode_json($client->responseContent);;
}                                               # }}}2

# }}}1
######################################################################
#  Initialization Code
######################################################################
# {{{1

$Data::Dumper::Sortkeys = 1;
$OUTPUT_AUTOFLUSH = 1;


## Check Command Line Options

Getopt::Long::Configure('bundling');

if (! GetOptions(
                    "light|led|l:s"     => \$strip,
                    "verbose|v+"        => \$verbose,
                    "debug|x+"          => \$debug,
                    "silent|s"          => \$silent,
                )) {
    usage();
    exit(1);
}


# if ( $ARGV[0] == "" || $ARGV[1] == "" ) {
#     usage();
#     exit(1);
# }
#
# $strip = $ARGV[0];
# $action = $ARGV[1];


my $lockmgr = LockFile::Simple->make(
                                        -format => '%f',
                                        -max => 2,                                      # Try ## times to get lock before giving up
                                        -delay => 2,                                    # Wait ## secs between lock attempts
                                        -autoclean => 1,
                                        -stale => 1,
                                        -hold => (3600 * 4)                             # don't frag the log til its 14 hrs old
                                    );

my $lockHandle;
if ( ! ($lockHandle = $lockmgr->lock($lockfile)) ) {
    # system("date");

    warn "could not lock file, $lockfile.   Current contents are: " .  `cat $lockfile`;

    die "terminating.\n";
}

# }}}1
######################################################################
#  Main Code
######################################################################
# {{{1

printf "WLED Strip: %s (wled-%s)\n", $strip, $strip;

$client = REST::Client->new();
$client->addHeader('Content-Type', 'application/json');

$client->setHost("http://wled-" . $strip);

if ( $#ARGV == -1 ) {
    printf "No actions specified.\n\n";
    usage();

} elsif ( $#ARGV == 0 && $ARGV[0] eq "demo" ) {
    @actions = (
                    'setup',
#                    'get',
                    'sleep',
                    'on',
                    'sleep=6',
                    'alert_left',
                    'sleep=3',
                    'alert_left_off',
                    'sleep=3',
                    'alert_right',
                    'sleep=3',
                    'alert_right_off',
                    'sleep=3',
                    'alert_left',
                    'alert_right',
                    'sleep=5',
                    'alert_left_off',
                    'alert_right_off',
                    'sleep=2',
                    'init',
                    'sleep=4',
                    'off',
                );
} else {
    @actions = @ARGV;
}

foreach my $action (@actions) {

    printf "  Action: %s\n", $action;

    if ( substr($action,0,5) eq "sleep") {
        if ( $action =~ m/^sleep(?:=)(\d+)?/ ) {
            sleep($1);
        } else {
            sleep(1);
        }
    } elsif ( $action =~ m/^(init|setup)$/ ) {
        wled_execute($action . "_" . $strip, 0);
    } elsif ( $action =~ /^alert_(left|right)$/ ) {
        my $state = wled_execute("get", 1);
        printf "Strip Power: '%s'  ", $state->{'on'} ? "On" : "Off";
        printf "Segment 0: '%s'  ", $state->{'seg'}->[0]->{'on'}  ? "On" : "Off";
        printf "Segment 1: '%s'  ", $state->{'seg'}->[1]->{'on'}  ? "On" : "Off";
        printf "Segment 2: '%s'  ", $state->{'seg'}->[2]->{'on'}  ? "On" : "Off";
        print "\n";

        if ( ! $state->{'on'} ) {
            if ( $action eq "alert_left" ) {
                wled_execute("off=0",0);
                wled_execute("off=1",0);
                wled_execute("on=2",0);
            } else {
                wled_execute("on=0",0);
                wled_execute("off=1",0);
                wled_execute("off=2",0);
            }
        }

        if ( $action eq "alert_left" ) {
            save_state($state->{'seg'}->[2], $strip, "seg2", $action);
        } else {
            save_state($state->{'seg'}->[0], $strip, "seg0", $action);
        }

        wled_execute("fon",0);
        wled_execute($action,0);

    } elsif ( $action =~ /^alert_(left|right)_off$/ ) {
        my $state = wled_execute("get", 1);
        printf "Strip Power: '%s'  ", $state->{'on'} ? "On" : "Off";
        printf "Segment 0: '%s'  ", $state->{'seg'}->[0]->{'on'}  ? "On" : "Off";
        printf "Segment 1: '%s'  ", $state->{'seg'}->[1]->{'on'}  ? "On" : "Off";
        printf "Segment 2: '%s'  ", $state->{'seg'}->[2]->{'on'}  ? "On" : "Off";
        print "\n";

        if ( $action eq "alert_left_off" ) {
            if ( ! $state->{'seg'}->[0]->{'on'} && ! $state->{'seg'}->[1]->{'on'} ) {
                printf "Seg 0 and 1 were off, turning everything off\n";
                wled_execute('foff',1);
                wled_execute('on=0',1);
                wled_execute('on=1',1);
            } else {
                printf "Seg 0 OR 1 were on, Leaving things on\n";
            }

            my $seg = restore_state($strip, "seg2", $action);
            wled_execute("cmd:{\"seg\":" . $seg . "}",1)        if ( defined($seg) );

        } else {
            if ( ! $state->{'seg'}->[1]->{'on'} && ! $state->{'seg'}->[2]->{'on'} ) {
                printf "Seg 1 and 2 were off, turning everything off\n";
                wled_execute('foff',1);
                wled_execute('on=1',1);
                wled_execute('on=2',1);
            } else {
                printf "Seg 1 OR 2 were on, Leaving things on\n";
            }

            my $seg = restore_state($strip, "seg0", $action);
            wled_execute("cmd:{\"seg\":" . $seg . "}",1)        if ( defined($seg) );

        }




    } else {
        wled_execute($action, 0);
    }

    print "----------------\n";
}


# }}}1
######################################################################
#  Cleanup Code
######################################################################
# {{{1

$lockHandle->release;

# }}}1

######################################################################
# vim:foldmethod=marker sw=4
