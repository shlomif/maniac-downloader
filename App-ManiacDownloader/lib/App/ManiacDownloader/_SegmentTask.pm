package App::ManiacDownloader::_SegmentTask;

use strict;
use warnings;

use MooX qw/late/;

use List::Util qw/min/;

has ['_start', '_end'] => (is => 'rw', isa => 'Int',);
has '_fh' => (is => 'rw',);
has 'is_active' => (is => 'rw', isa => 'Bool', default => 1);

has '_downloaded' => (is => 'rw', isa => 'App::ManiacDownloader::_BytesDownloaded', default => sub { return App::ManiacDownloader::_BytesDownloaded->new; }, handles => ['_flush_and_report'],);

sub _serialize
{
    my ($self) = @_;

    return
    +{
        _start => $self->_start,
        _end => $self->_end,
        is_active => $self->is_active,
    };
}

sub _deserialize
{
    my ($self, $record) = @_;

    $self->_start($record->{_start});
    $self->_end($record->{_end});
    $self->is_active($record->{is_active});

    return;
}

sub _write_data
{
    my ($self, $data_ref) = @_;

    my $written = syswrite($self->_fh, $$data_ref);
    if ($written != length($$data_ref))
    {
        die "Written bytes mismatch.";
    }

    $self->_downloaded->_add($written);

    my $init_start = $self->_start;
    $self->_start($init_start + $written);

    return
    {
        should_continue => scalar($self->_start < $self->_end),
        num_written => (min($self->_start, $self->_end) - $init_start),
    };
}

sub _close
{
    my ($self) = @_;
    close($self->_fh);
    $self->_fh(undef());
    $self->is_active(0);

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

