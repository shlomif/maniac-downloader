package App::ManiacDownloader::_File;

use strict;
use warnings;

use MooX qw/late/;

use File::Basename qw(basename);
use URI;

has '_url'          => ( is  => 'rw' );
has '_url_path'     => ( isa => 'Str',  is => 'rw' );
has '_url_basename' => ( isa => 'Str',  is => 'rw' );
has '_is_ftp'       => ( isa => 'Bool', is => 'rw' );

sub _set_url
{
    my ( $self, $url_s ) = @_;

    my $url = URI->new($url_s);
    $self->_url($url);

    my $url_path = $url->path();
    $self->_url_path($url_path);

    $self->_url_basename( basename($url_path) );

    my $is_ftp = ( $url->scheme eq 'ftp' );
    $self->_is_ftp($is_ftp);

    return;
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

1;

