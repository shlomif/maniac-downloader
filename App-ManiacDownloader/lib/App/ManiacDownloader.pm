package App::ManiacDownloader;

use strict;
use warnings;

use MooX qw/late/;
use URI;
use AnyEvent::HTTP qw/http_head http_get/;
use Getopt::Long qw/GetOptionsFromArray/;
use File::Basename qw(basename);
use Fcntl qw( SEEK_SET );

our $VERSION = '0.0.1';

my $DEFAULT_NUM_CONNECTIONS = 4;

has '_finished_condvar' => (is => 'rw');

=head2 $self->run({argv => [@ARGV]})

Run the application with @ARGV .

=cut

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
    my $url_path = $url->path();
    my $url_basename = basename($url_path);

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
            map { +{start => $stops[$_], end => ($stops[$_+1]) } }
            0 .. ($num_connections-1)
        );

        my $remaining_connections = $num_connections;
        foreach my $_proto_idx (0 .. $num_connections-1)
        {
            my $idx = $_proto_idx;

            my $r = $ranges[$idx];

            open my $fh, "+<", $url_basename,
                or die "${url_basename}: $!";

            sysseek( $fh, $r->{start}, SEEK_SET );

            http_get $url,
                headers => { 'Range'
                    => sprintf("bytes=%d-%d", $r->{start}, $r->{end}-1)
                },
                on_body => sub {
                    my ($data, $hdr) = @_;
                    my $written = syswrite($fh, $data);
                    if ($written != length($data))
                    {
                        die "Written bytes mismatch.";
                    }
                    $r->{start} += length($data);
                    if ($r->{start} >= $r->{end}) {
                        close($fh);
                        if (not --$remaining_connections) {
                            $self->_finished_condvar->send;
                        }
                        return 0;
                    }
                },
                sub {
                    # Do nothing.
                    return;
                }
            ;
        }
    };

    $self->_finished_condvar->recv;

    return;
}

1;

=head1 NAME

App::ManiacDownloader - a maniac download accelerator.
