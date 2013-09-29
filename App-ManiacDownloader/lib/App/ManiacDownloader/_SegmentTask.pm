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
    if ($self->_start >= $self->_end)
    {
        return 0;
    }

    return 1;
}

sub _close
{
    my ($self) = @_;
    close($self->_fh);
    $self->_fh(undef());

    return;
}

sub _num_remaining
{
    my $self = shift;

    return $self->_end - $self->_start;
}

sub _split_into
{
    my ($self,$other) = @_;

    $other->_start(( $self->_start+$self->_end ) >> 1);
    $other->_end($self->_end);
    $self->_end($other->_start);

    return;
}


1;

