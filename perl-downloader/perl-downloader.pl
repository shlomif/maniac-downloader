#!/usr/bin/perl

use strict;
use warnings;

use Carp;
use HTTP::Request;
use POE qw(Component::Client::HTTP);
 
POE::Component::Client::HTTP->spawn(
    Alias     => 'ua',                  # defaults to 'weeble'
    Timeout   => 3,                    # defaults to 180 seconds
    Streaming => 4096,                  # defaults to 0 (off)
);
 
# my $url = 'http://www.shlomifish.org/Files/files/video/Berry%20Sacharof%20-%20Mefaneh%20Maqom.flv';
my $url = 'http://localhost:8080/l.bz2.part';

POE::Session->create(
    inline_states => {
        _start => sub {
            my $heap = $_[HEAP];

            open my $fh, '>', 'l.bz2'
                or Carp::confess( "Cannot open file for writing - $!");

            my $common_heap = { fh => $fh, bytes_written => 0, };

            $heap->{common} = $common_heap;

            POE::Kernel->post(
                'ua',        # posts to the 'ua' alias
                'request',   # posts to ua's 'request' state
                'response',  # which of our states will receive the response
                HTTP::Request->new(GET => $url),    # an HTTP::Request object
            );
        },
        _stop => sub {},
        response => \&response_handler,
    },
);

POE::Kernel->run();
exit;
 
# This is the sub which is called when the session receives a
# 'response' event.
sub response_handler {
    my ($request_packet, $response_packet) = @_[ARG0, ARG1];

    my $heap = $_[HEAP];

    # HTTP::Request
    my $request_object  = $request_packet->[0];

    # HTTP::Response
    my $response_object = $response_packet->[0];

    my $stream_chunk;
    if (! defined($response_object->content) or !length($response_object->content)) {
        $stream_chunk = $response_packet->[1];
    }

    # Actually write the data.
    if (defined($stream_chunk))
    {
        print { $heap->{common}->{fh} } $stream_chunk;
        $heap->{common}->{bytes_written} += length($stream_chunk);

        if ($heap->{common}->{bytes_written} >= $response_object->header('Content-Length'))
        {
            close ($heap->{common}->{fh});
            delete($heap->{common}->{fh});
            $_[KERNEL]->stop();
        }
    }
}
