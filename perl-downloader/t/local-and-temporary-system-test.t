#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 3;

my $APACHE_PATH = "$ENV{HOME}/apps/apache2";
my $FILENAME = 'linux-3.1.tar.xz';

{
    # TEST
    is (system("$APACHE_PATH/bin/apachectl", "start"), 0,
        "Starting Apache is successful.");

    unlink($FILENAME);

    # TEST
    is (system("$^X", "perl-downloader.pl", "--url",
            "http://localhost:8080/$FILENAME"
        ), 0,
        "Could download the file.",
    );

    # TEST
    is (system("cmp", $FILENAME, "$APACHE_PATH/htdocs/$FILENAME"),
        0,
        "File downloaded correctly.",
    );
}
