package App::ManiacDownloader;

use strict;
use warnings;

use 5.012;

use autodie;

use MooX qw/late/;
use URI;
use AnyEvent::HTTP qw/http_head http_get/;
use Getopt::Long qw/GetOptionsFromArray/;
use File::Basename qw(basename);
use Fcntl qw( SEEK_SET );
use List::UtilsBy qw(max_by);
use JSON qw(decode_json encode_json);

use App::ManiacDownloader::_SegmentTask;

our $VERSION = '0.0.8';

my $DEFAULT_NUM_CONNECTIONS = 4;
my $NUM_CONN_BYTES_THRESHOLD = 4_096 * 2;

has '_finished_condvar' => (is => 'rw');
has '_ranges' => (isa => 'ArrayRef', is => 'rw');
has '_url' => (is => 'rw');
has '_url_basename' => (isa => 'Str', is => 'rw');
has '_remaining_connections' => (isa => 'Int', is => 'rw');
has ['_bytes_dled', '_bytes_dled_last_timer'] =>
    (isa => 'Int', is => 'rw', default => sub { return 0;});
has '_stats_timer' => (is => 'rw');
has '_last_timer_time' => (is => 'rw', isa => 'Num');
has '_len' => (is => 'rw', isa => 'Int');

sub _serialize
{
    my ($self) = @_;

    return
    +{
        _ranges => [map { $_->_serialize() } @{$self->_ranges}],
        _remaining_connections => $self->_remaining_connections,
        _bytes_dled => $self->_bytes_dled,
        _len => $self->_len,
    };
}

sub _downloading_path
{
    my ($self) = @_;

    return $self->_url_basename . '.mdown-intermediate';
}

sub _resume_info_path
{
    my ($self) = @_;

    return $self->_url_basename . '.mdown-resume.json';
}

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

        $self->_bytes_dled(
            $self->_bytes_dled + $ret->{num_written},
        );
        my $cont = $ret->{should_continue};
        if (! $cont)
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
        return $cont;
    },
    sub {
        # Do nothing.
        return;
    }
    ;
}

sub _handle_stats_timer
{
    my ($self) = @_;

    my $num_dloaded = $self->_bytes_dled - $self->_bytes_dled_last_timer;

    my $time = AnyEvent->now;
    my $last_time = $self->_last_timer_time;

    printf "Downloaded %i%% (Currently: %.2fKB/s)\r",
        int($self->_bytes_dled * 100 / $self->_len),
        ($num_dloaded / (1024 * ($time-$last_time))),
    ;
    STDOUT->flush;

    $self->_last_timer_time($time);
    $self->_bytes_dled_last_timer($self->_bytes_dled);

    return;
}

sub _slurp
{
    my $filename = shift;

    open my $in, '<', $filename
        or die "Cannot open '$filename' for slurping - $!";

    local $/;
    my $contents = <$in>;

    close($in);

    return $contents;
}

sub _open_fh_for_read_write_without_clobbering
{
    my ($path, $url_basename) = @_;

    # open with '+>:raw' will clobber the file.
    # On the other hand, open with '+<:raw' won't create a new file if it
    # does not exist.
    # So we have to restort to this.
    #
    # For more information, see: http://perldoc.perl.org/perlopentut.html
    {
        open my $fh_temp, '+>>:raw', $path
            or die "Cannot open '$path' for temp-creation. $!";
        close($fh_temp);
    }
    open my $fh, "+<:raw", $path
        or die "${url_basename}: $!";

    return $fh;
}

sub _init_from_len
{
    my ($self, $args) = @_;

    my $num_connections = $args->{num_connections};
    my $len = $self->_len;
    my $url_basename = $self->_url_basename;

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

    my $ranges_ref = $args->{ranges};
    foreach my $idx (0 .. $num_connections-1)
    {
        my $r = $ranges[$idx];

        if (defined($ranges_ref))
        {
            $r->_deserialize($ranges_ref->[$idx]);
        }

        if ($r->is_active)
        {
            {
                $r->_fh(
                    scalar(
                        _open_fh_for_read_write_without_clobbering(
                            $self->_downloading_path(), $url_basename,
                        )
                    )
                );
            }

            $self->_start_connection($idx);
        }
    }

    my $timer = AnyEvent->timer(
        after => 3,
        interval => 3,
        cb => sub {
            $self->_handle_stats_timer;
            return;
        },
    );
    $self->_last_timer_time(AnyEvent->time());
    $self->_stats_timer($timer);

    {
        no autodie;
        unlink($self->_resume_info_path());
    }

    return;
}

sub _abort_signal_handler
{
    my ($self) = @_;

    open my $json_out_fh, '>:encoding(utf8)', $self->_resume_info_path();
    print {$json_out_fh} encode_json($self->_serialize);
    close ($json_out_fh);

    exit(2);
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

    if (-e $self->_url_basename)
    {
        print STDERR "File appears to have already been downloaded. Quitting.\n";
        return;
    }

    $self->_finished_condvar(
        scalar(AnyEvent->condvar)
    );

    if (-e $self->_resume_info_path)
    {
        my $record = decode_json(_slurp($self->_resume_info_path));
        $self->_len($record->{_len});
        $self->_bytes_dled($record->{_bytes_dled});
        $self->_bytes_dled_last_timer($self->_bytes_dled());
        $self->_remaining_connections($record->{_remaining_connections});
        my $ranges_ref = $record->{_ranges};
        $self->_init_from_len(
            {
                ranges => $ranges_ref,
                num_connections => scalar(@$ranges_ref),
            }
        );
    }
    else
    {
        http_head $url, sub {
            my (undef, $headers) = @_;
            my $len = $headers->{'content-length'};

            if (!defined($len)) {
                die "Cannot find a content-length header.";
            }

            $self->_len($len);
            $self->_remaining_connections($num_connections);

            return $self->_init_from_len(
                {
                    num_connections => $num_connections,
                }
            );
        };
    }

    my $signal_handler = sub { $self->_abort_signal_handler(); };
    local $SIG{INT} = $signal_handler;
    local $SIG{TERM} = $signal_handler;

    $self->_finished_condvar->recv;
    $self->_stats_timer(undef());

    if (! $self->_remaining_connections())
    {
        rename($self->_downloading_path(), $self->_url_basename());
    }

    return;
}

1;

=encoding utf8

=head1 NAME

App::ManiacDownloader - a maniac download accelerator.

=head1 SYNOPSIS

    # To download with 10 segments
    $ mdown -k=10 http://path.to.my.url.tld/path-to-file.txt

=head1 DESCRIPTION

This is B<Maniac Downloader>, a maniac download accelerator. It is currently
very incomplete (see the C<TODO.txt> file), but is still somewhat usable.
Maniac Downloader is being written out of necessity out of proving to
improve the download speed of files here (which I suspect is caused by a
misconfiguration of my ISP's networking), and as a result, may prove of
use elsewhere.

=head2 The Secret Sauce

The main improvement of Maniac Downloader over other downloader managers is
that if a segment of the downloaded file finishes, then it splits the
largest remaining segment, and starts another new download, so the slowest
downloads won't delay the completion time by much.

=head1 METHODS

=head2 $self->run({argv => [@ARGV]})

Run the application with @ARGV .

=head1 SEE ALSO

=head2 Asynchronous Programming FTW! 2 (with AnyEvent)

L<http://www.slideshare.net/xSawyer/async-programmingftwanyevent>

a talk by Sawyer X that introduced me to L<AnyEvent> of which I made use
for Maniac Downloader.

=head2 “Man Down”

“Man Down” is a song by Rihanna, which happens to have the same initialism
as Maniac Downloader, and which I happen to like, so feel free to check it
out:

L<http://www.youtube.com/watch?v=sEhy-RXkNo0>

=cut
