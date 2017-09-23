package App::ManiacDownloader;

use strict;
use warnings;

use 5.012;

use autodie;

use MooX qw/late/;
use URI;
use AnyEvent::HTTP qw/http_head http_get/;
use AnyEvent::FTP::Client;
use Getopt::Long qw/GetOptionsFromArray/;
use Fcntl qw( SEEK_SET );
use List::UtilsBy qw(max_by);
use JSON::MaybeXS qw(decode_json encode_json);

use App::ManiacDownloader::_SegmentTask;
use App::ManiacDownloader::_BytesDownloaded;
use App::ManiacDownloader::_File;

my $DEFAULT_NUM_CONNECTIONS  = 4;
my $NUM_CONN_BYTES_THRESHOLD = 4_096 * 2;

has '_finished_condvar'      => ( is  => 'rw' );
has '_ranges'                => ( isa => 'ArrayRef', is => 'rw' );
has '_remaining_connections' => ( isa => 'Int', is => 'rw' );
has '_stats_timer'           => ( is  => 'rw' );
has '_last_timer_time'       => ( is  => 'rw', isa => 'Num' );
has '_len'                   => ( is  => 'rw', isa => 'Int' );
has '_downloaded' => (
    is      => 'rw',
    isa     => 'App::ManiacDownloader::_BytesDownloaded',
    default => sub { return App::ManiacDownloader::_BytesDownloaded->new; }
);
has '_file' => ( is => 'rw', isa => 'App::ManiacDownloader::_File' );

sub _serialize
{
    my ($self) = @_;

    return +{
        _ranges => [ map { $_->_serialize() } @{ $self->_ranges } ],
        _remaining_connections => $self->_remaining_connections,
        _bytes_dled            => $self->_downloaded->_total_downloaded,
        _len                   => $self->_len,
    };
}

sub _start_connection
{
    my ( $self, $idx ) = @_;

    my $r = $self->_ranges->[$idx];

    sysseek( $r->_fh, $r->_start, SEEK_SET );

    my $is_ftp = $self->_file->_is_ftp;

    # We do these to make sure the cancellation guard does not get
    # preserved because it's in the context of the closures.
    my $on_body = sub {
        my ( $active_seq, $data, $hdr ) = @_;

        # Stale or wrong connection - probably AnyEvent::FTP::Client after a
        # quit.
        if ( ( !$r->_is_right_active_seq($active_seq) ) or ( !$r->is_active ) )
        {
            return;
        }

        my $ret = $r->_write_data( \$data );

        $self->_downloaded->_add( $ret->{num_written} );

        my $cont = $ret->{should_continue};
        if ( !$cont )
        {
            if ($is_ftp)
            {
                $r->_guard->quit;
            }
            my $largest_r = max_by { $r->_num_remaining } @{ $self->_ranges };
            if ( $largest_r->_num_remaining < $NUM_CONN_BYTES_THRESHOLD )
            {
                $r->_close;
                if (
                    not $self->_remaining_connections(
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
    };

    my $final_cb = sub { return; };

    my $url = $self->_file->_url;
    {
        my $active_seq = $r->_get_next_active_seq;

        my $seq_on_body = sub { return $on_body->( $active_seq, @_ ); };

        if ($is_ftp)
        {
            my $ftp = AnyEvent::FTP::Client->new( passive => 1 );
            $r->_guard($ftp);
            $ftp->connect( $url->host, $url->port )->cb(
                sub {
                    $ftp->login( $url->user, $url->password )->cb(
                        sub {
                            $ftp->type('I')->cb(
                                sub {
                                    $ftp->retr( $self->_file->_url_path,
                                        $seq_on_body, restart => $r->_start, );
                                }
                            );
                        }
                    );
                }
            );
        }
        else
        {
            my $guard = http_get $url,
                headers =>
                { 'Range' => sprintf( "bytes=%d-%d", $r->_start, $r->_end - 1 )
                },
                on_body => $seq_on_body,
                $final_cb;

            $r->_guard($guard);

            $guard = '';
        }
    }

    return;
}

my $MAX_CHECKS = 6;

sub _handle_stats_timer
{
    my ($self) = @_;

    my ( $num_dloaded, $total_downloaded ) =
        $self->_downloaded->_flush_and_report;

    my $_ranges = $self->_ranges;
    for my $idx ( 0 .. $#$_ranges )
    {
        my $r = $_ranges->[$idx];

        $r->_flush_and_report;
        if ( $r->is_active && $r->_increment_check_count($MAX_CHECKS) )
        {
            $r->_guard('');
            $self->_start_connection($idx);
        }
    }

    my $time      = AnyEvent->now;
    my $last_time = $self->_last_timer_time;

    printf "Downloaded %i%% (Currently: %.2fKB/s)\r",
        int( $total_downloaded * 100 / $self->_len ),
        ( $num_dloaded / ( 1024 * ( $time - $last_time ) ) ),
        ;
    STDOUT->flush;

    $self->_last_timer_time($time);

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

use Fcntl qw( O_CREAT O_RDWR );

sub _open_fh_for_read_write_without_clobbering
{
    my ( $path, $url_basename ) = @_;

# open with '+>:raw' will clobber the file.
# On the other hand, open with '+<:raw' won't create a new file if it
# does not exist.
# So we have to restort to this.
#
# For more information, see: http://perldoc.perl.org/perlopentut.html
#
# And:
#
# http://blogs.perl.org/users/shlomi_fish/2014/01/tech-tip-opening-a-file-for-readwrite-without-clobbering-it.html
#
# Thanks to Steven Haryanto for the better tip.
#
    my $fh;
    sysopen( $fh, $path, O_RDWR | O_CREAT )
        or die "${url_basename}: $!";

    return $fh;
}

sub _with_len_and_num_connections
{
    my ( $self, $len, $num_connections ) = @_;

    if ( !defined($len) )
    {
        die "Cannot find a content-length header.";
    }

    $self->_len($len);
    $self->_remaining_connections($num_connections);

    return $self->_init_from_len(
        {
            num_connections => $num_connections,
        }
    );
}

sub _init_from_len
{
    my ( $self, $args ) = @_;

    my $num_connections = $args->{num_connections};
    my $len             = $self->_len;
    my $url_basename    = $self->_file->_url_basename;

    my @stops = ( map { int( ( $len * $_ ) / $num_connections ) }
            0 .. ( $num_connections - 1 ) );

    push @stops, $len;

    my @ranges = (
        map {
            App::ManiacDownloader::_SegmentTask->new(
                _start => $stops[$_],
                _end   => $stops[ $_ + 1 ],
                )
        } 0 .. ( $num_connections - 1 )
    );

    $self->_ranges( \@ranges );

    my $ranges_ref = $args->{ranges};
    foreach my $idx ( 0 .. $num_connections - 1 )
    {
        my $r = $ranges[$idx];

        if ( defined($ranges_ref) )
        {
            $r->_deserialize( $ranges_ref->[$idx] );
        }

        if ( $r->is_active )
        {
            {
                $r->_fh(
                    scalar(
                        _open_fh_for_read_write_without_clobbering(
                            $self->_file->_downloading_path(),
                            $url_basename,
                        )
                    )
                );
            }

            $self->_start_connection($idx);
        }
    }

    my $timer = AnyEvent->timer(
        after    => 3,
        interval => 3,
        cb       => sub {
            $self->_handle_stats_timer;
            return;
        },
    );
    $self->_last_timer_time( AnyEvent->time() );
    $self->_stats_timer($timer);

    {
        no autodie;
        unlink( $self->_file->_resume_info_path() );
    }

    return;
}

sub _abort_signal_handler
{
    my ($self) = @_;

    open my $json_out_fh, '>:encoding(utf8)', $self->_file->_resume_info_path();
    print {$json_out_fh} encode_json( $self->_serialize );
    close($json_out_fh);

    exit(2);
}

sub run
{
    my ( $self, $args ) = @_;

    my $num_connections = $DEFAULT_NUM_CONNECTIONS;

    my @argv = @{ $args->{argv} };

    if (
        !GetOptionsFromArray(
            \@argv, 'k|num-connections=i' => \$num_connections,
        )
        )
    {
        die "Cannot parse argv - $!";
    }

    my $url_s = shift(@argv)
        or die "No url given.";

    $self->_file( App::ManiacDownloader::_File->new );
    $self->_file->_set_url($url_s);

    if ( -e $self->_file->_url_basename )
    {
        print STDERR
            "File appears to have already been downloaded. Quitting.\n";
        return;
    }

    $self->_finished_condvar( scalar( AnyEvent->condvar ) );

    if ( -e $self->_file->_resume_info_path )
    {
        my $record = decode_json( _slurp( $self->_file->_resume_info_path ) );
        $self->_len( $record->{_len} );
        $self->_downloaded->_my_init( $record->{_bytes_dled} );
        $self->_remaining_connections( $record->{_remaining_connections} );
        my $ranges_ref = $record->{_ranges};
        $self->_init_from_len(
            {
                ranges          => $ranges_ref,
                num_connections => scalar(@$ranges_ref),
            }
        );
    }
    else
    {
        my $url = $self->_file->_url;

        if ( $self->_file->_is_ftp )
        {
            my $ftp = AnyEvent::FTP::Client->new( passive => 1 );
            $ftp->connect( $url->host, $url->port )->recv;
            $ftp->login( $url->user, $url->password )->recv;
            $ftp->type('I')->recv;
            $ftp->size( $self->_file->_url_path )->cb(
                sub {
                    my $len = shift->recv;

                    $ftp->quit;
                    undef($ftp);

                    return $self->_with_len_and_num_connections( $len,
                        $num_connections );
                }
            );
        }
        else
        {
            http_head $url, sub {
                my ( undef, $headers ) = @_;
                my $len = $headers->{'content-length'};

                return $self->_with_len_and_num_connections( $len,
                    $num_connections );
            };
        }
    }

    my $signal_handler = sub { $self->_abort_signal_handler(); };
    local $SIG{INT}  = $signal_handler;
    local $SIG{TERM} = $signal_handler;

    $self->_finished_condvar->recv;
    $self->_stats_timer( undef() );

    if ( !$self->_remaining_connections() )
    {
        rename( $self->_file->_downloading_path(),
            $self->_file->_url_basename() );
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

=head1 Answers to Questions about Maniac Downloader

=head2 Does Maniac Downloader always guarantee the best possible speed of download?

The short answer is: “No”. The longer answer is that in today’s Internet
and networking world, there are simply too many factors at play to make sure
that downloading using a certain way will always be the fastest. Maniac
Downloader uses a certain scheme which may make things faster on certain
conditions (namely that individual connections is being capped), but it may
make the performance somewhat worse as well.

One thing we hope to guarantee is that it won’t make the download time B<much>
longer. If it does, please let us know.

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
