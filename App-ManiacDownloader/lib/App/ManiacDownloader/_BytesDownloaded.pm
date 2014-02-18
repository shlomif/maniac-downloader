package App::ManiacDownloader::_BytesDownloaded;

use strict;
use warnings;

use MooX qw/late/;

use List::Util qw/min/;

has ['_bytes_dled', '_bytes_dled_last_timer'] =>
    (isa => 'Int', is => 'rw', default => sub { return 0;});

sub _add
{
    my ($self, $num_written) = @_;

    $self->_bytes_dled(
        $self->_bytes_dled + $num_written,
    );

    return;
}

sub _total_downloaded
{
    my ($self) = @_;

    return $self->_bytes_dled;
}

sub _flush_and_report
{
    my $self = shift;

    my $difference = $self->_bytes_dled - $self->_bytes_dled_last_timer;

    $self->_bytes_dled_last_timer($self->_bytes_dled);

    return ($difference, $self->_bytes_dled);
}

sub _my_init
{
    my ($self, $num_bytes) = @_;

    $self->_bytes_dled($num_bytes);
    $self->_bytes_dled_last_timer($num_bytes);

    return;
}


1;

