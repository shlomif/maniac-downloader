package App::ManiacDownloader::_SegmentTask;

use strict;
use warnings;

use MooX qw/late/;

has ['_start', '_end'] => (is => 'rw', isa => 'Int',);
has '_fh' => (is => 'rw',);

1;

