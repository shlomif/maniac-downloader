package App::ManiacDownloader::_SegmentTask;

use strict;
use warnings;

use MooX qw/late/;

has ['_start', '_end'] => (is => 'rw', isa => 'Int',);
has '_fh' => (is => 'rw',);

sub _write_data
{
    my ($self, $data_ref) = @_;

    my $written = syswrite($self->_fh, $$data_ref);
    if ($written != length($$data_ref))
    {
        die "Written bytes mismatch.";
    }

    $self->_start($self->_start + $written);
    if ($self->_start >= $self->_end) {

        close($self->_fh);
        $self->_fh(undef());

        return 0;
    }

    return 1;
}

1;

