package App::ManiacDownloader;

use strict;
use warnings;

use MooX qw/late/;
use URI;
use AnyEvent::HTTP qw/http_head http_get/;
use Getopt::Long qw/GetOptionsFromArray/;
use File::Basename qw(basename);
use Fcntl qw( SEEK_SET );
use List::UtilsBy qw(max_by);

use App::ManiacDownloader::_SegmentTask;

our $VERSION = '0.0.1';

my $DEFAULT_NUM_CONNECTIONS = 4;
my $NUM_CONN_BYTES_THRESHOLD = 4_096 * 2;

has '_finished_condvar' => (is => 'rw');
has '_ranges' => (isa => 'ArrayRef', is => 'rw');
has '_url' => (is => 'rw');
has '_url_basename' => (isa => 'Str', is => 'rw');
has '_remaining_connections' => (isa => 'Int', is => 'rw');

sub _start_connection
{
    my ($self, $idx) = @_;

    my $r = $self->_ranges->[$idx];

    sysseek( $r->_fh, $r->_start, SEEK_SET );

    http_get $self->_url,
    headers => { 'Range'
        => sprintf("bytes=%d-%d", $r->_start, $r->_end-1)
    },
    on_body => sub {
        my ($data, $hdr) = @_;

        my $ret = $r->_write_data(\$data);
        if (! $ret)
        {
            my $largest_r = max_by { $r->_num_remaining } @{$self->_ranges};
            if ($largest_r->_num_remaining < $NUM_CONN_BYTES_THRESHOLD)
            {
                $r->_close;
                if (
                    not
                    $self->_remaining_connections(
                        $self->_remaining_connections() - 1
                    )
                )
                {
                    $self->_finished_condvar->send;
                }
            }
            else
            {
                $largest_r->_split_into($r);
                $self->_start_connection($idx);
            }
        }
        return $ret;
    },
    sub {
        # Do nothing.
        return;
    }
    ;
}

sub run
{
    my ($self, $args) = @_;

    my $num_connections = $DEFAULT_NUM_CONNECTIONS;

    my @argv = @{ $args->{argv} };

    if (! GetOptionsFromArray(
        \@argv,
        'k|num-connections=i' => \$num_connections,
    ))
    {
        die "Cannot parse argv - $!";
    }

    my $url_s = shift(@argv)
        or die "No url given.";

    my $url = URI->new($url_s);

    $self->_url($url);
    my $url_path = $url->path();
    my $url_basename = basename($url_path);

    $self->_url_basename($url_basename);

    $self->_finished_condvar(
        scalar(AnyEvent->condvar)
    );

    http_head $url, sub {
        my (undef, $headers) = @_;
        my $len = $headers->{'content-length'};

        if (!defined($len)) {
            die "Cannot find a content-length header.";
        }

        my @stops = (map { int( ($len * $_) / $num_connections ) }
            0 .. ($num_connections-1));

        push @stops, $len;

        my @ranges = (
            map {
                App::ManiacDownloader::_SegmentTask->new(
                    _start => $stops[$_],
                    _end => $stops[$_+1],
                )
            }
            0 .. ($num_connections-1)
        );

        $self->_ranges(\@ranges);

        $self->_remaining_connections($num_connections);
        foreach my $idx (0 .. $num_connections-1)
        {
            my $r = $ranges[$idx];

            {
                open my $fh, "+>", $self->_url_basename()
                    or die "${url_basename}: $!";

                $r->_fh($fh);
            }

            $self->_start_connection($idx);
        }
    };

    $self->_finished_condvar->recv;

    return;
}

1;

=head1 NAME

App::ManiacDownloader - a maniac download accelerator.

=head1 METHODS

=head2 $self->run({argv => [@ARGV]})

Run the application with @ARGV .

=cut
