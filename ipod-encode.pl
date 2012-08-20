#!/usr/bin/env perl
###############################################################################
#
=pod

=head1 NAME

iPod::Video::Encode

=head1 SYNOPSIS

./vcode --title='A Title' [--debug] [--verbose] [--number-pattern=regex] video-1 [... video-n]

./vcode --title='Another Title' [--debug] [--verbose] --standalone video-file

=head1 DESCRIPTION

A video converter for the iPod, built on top of ffmpeg and mplayer.

=head1 SWITCHES

=over 4

=item --title

Set the title of the encoded video.  This is used both in the generation of the
filename, and in the metadata of the video itself.  Mandatory.

=item --number-pattern

When running over multiple files (the default), the number pattern is used
to extract the episode number.  The default is /[_\W]0*(\d+)/, which catches
almost everything, but you can specify your own here.

=item --standalone

It's normally assumed that this program will be operating over a group of
related videos (e.g. a complete series), and the episode number is put
into the title of the output.  --standalone forces it to use just the supplied
--title.  This mode cannot be used with multiple videos.

=item --verbose

Switch on chatty logging (not quite as much as --debug).

=item --debug

Switch on fine tracing of execution, and provide more information in crashes.

=head1 AUTHOR

Danny Woods (dannywoodz@yahoo.co.uk)

=head1 LICENSE

GPLv3 (http://opensource.org/licenses/GPL-3.0)

=head1 API

=cut
#
###############################################################################

package iPod::Video::Encode;

use Getopt::Long qw(GetOptionsFromArray);
use Log::Log4perl qw(:levels);
use POSIX qw(mkfifo);
use File::Spec;
use File::Basename;
use Carp;
use v5.12;
use utf8;
use strict;
use warnings;
use constant DEFAULT_NUMBER_PATTERN => qr/[_\W]0*(\d+)/;

my @g_cleanup_list;

END {
  foreach my $file(@g_cleanup_list)
  {
    unlink($file) if -e $file;
  }
};

sub unique_filename_for
{
  my ($base, $extension) = @_;
  my $filename = $base . '.' . $extension;
  my $tries = 1;
  $filename = $base . '-' . $tries++ . '.' . $extension while -e $filename;
  return $filename;
}

sub encode
{
  my ($source, $title, %options) = @_;

  my ($vol, $dir, $source_filename) = File::Spec->splitpath($source);
  my $logger = Log::Log4perl->get_logger;
  my $fifo = unique_filename_for($source_filename, 'fifo');
  my $intermediate = unique_filename_for($source_filename, 'avi');
  my $destination = unique_filename_for($title, 'm4v');
  my $vbitrate = $options{vbitrate} || '768k';

  $logger->info('Encoding \'', $source, '\' to \'', $destination, '\'');

  #############################################################################
  # It might seem like a better idea to use Perl as the intermediary between
  # mplayer and ffmpeg rather than using an external named pipe, but the
  # mplayer devs recommend against writing video to stdout, instead preferring
  # the pipe approach (http://wiki.multimedia.cx/index.php?title=MPlayer_FAQ):
  #     How do I pipe mplayer/mencoder output to stdout?
  #     # mplayer devs reccomend using mkfifo (named pipe) instead of stdout.
  #############################################################################

  mkfifo($fifo, 0700) and push(@g_cleanup_list, $fifo) or die $!;

  my $mplayer = fork();

  if ( !$mplayer )
  {
    # mplayer child process
    my @command = ('mplayer', $source,
                   '-noconfig', 'all',
                   '-vf-clr',
                   '-nosound',
                   '-benchmark',
                   '-ass',
                   '-vf', 'scale=480:-10',
                   '-vo', "yuv4mpeg:file=\"$fifo\"");
    $logger->info('Executing ', join(' ', @command));
    {exec(@command)}
    croak('mplayer exec failed: ' . join(' ', @command));
  }

  my $ffmpeg  = fork();

  if ( !$ffmpeg )
  {
    # ffmpeg child process
    my @command = ('ffmpeg',
                   '-i', $fifo,
                   '-vcodec', 'libx264',
                   '-b:v', $vbitrate,
                   '-flags', '+loop+mv4',
                   '-cmp', '256',
                   '-partitions','+parti4x4+parti8x8+partp4x4+partp8x8+partb8x8',
                   '-me_method', 'hex',
                   '-subq', '7',
                   '-threads', 'auto',
                   '-trellis', '1',
                   '-refs', '5',
                   '-bf', '0',
                   '-coder', '0',
                   '-me_range', '16',
                   '-profile:v', 'baseline',
                   '-g', '250',
                   '-keyint_min', '25',
                   '-sc_threshold', '40',
                   '-i_qfactor', '0.71',
                   '-qmin', '10',
                   '-qmax', '51',
                   '-qdiff','4',
                   '-y',
                   $intermediate);
    $logger->info('Executing ', join(' ', @command));
    {exec(@command)}
    croak('ffmpeg exec failed on ' . join(' ', @command));
  }

  push(@g_cleanup_list, $intermediate);

  my $mplayer_failed = 0;
  my $ffmpeg_failed  = 0;

  while ( $ffmpeg || $mplayer )
  {
    my $child_pid = wait;
    given($child_pid)
    {
      when ($ffmpeg)  {
        $ffmpeg  = 0;
        $ffmpeg_failed = $?;
        kill(15, $mplayer) if $ffmpeg_failed && $mplayer;
      }
      when ($mplayer) {
        $mplayer = 0;
        $mplayer_failed = $?;
        kill(15, $ffmpeg) if $mplayer_failed && $ffmpeg;
      }
    }
  }

  unless ( $mplayer_failed | $ffmpeg_failed )
  {
    my @command = ('ffmpeg',
                   '-i', $source,
                   '-i', $intermediate,
                   '-acodec', 'libfaac',
                   '-b:a', '128k',
                   '-ac', '2',
                   '-vcodec', 'copy',
                   '-f', 'ipod',
                   '-map', '0:a',
                   '-map', '1:v',
                   '-metadata', "title=$title",
                   '-y', $destination);
    $logger->info('Executing ', join(' ', @command));
    croak('ffmpeg multiplex failed') unless system(@command) >> 8 == 0;
    unlink($intermediate);
  }
  else
  {
    $logger->warn('Not multiplexing, as earlier phase failed (mplayer: ', $mplayer_failed, '; ffmpeg: ', $ffmpeg_failed, ')');
  }
}

sub numbered_title_for
{
  my ($base_title, $filename, $number_pattern) = @_;
  my $logger = Log::Log4perl->get_logger;
  $filename = basename($filename); # Don't snag numbers in the directory name
  $number_pattern ||= DEFAULT_NUMBER_PATTERN;
  my $decorated_title = ( $filename =~ $number_pattern ) ?
    $base_title . '-' . $1 :
    croak("Unable to extract episode number from '$filename' using '$number_pattern'");
  $logger->debug('Title for \'', $filename, '\' is \'', $decorated_title, '\', extracted using \'', $number_pattern, '\'');
  return $decorated_title;
}

sub standalone_title_for
{
  return shift;
}

sub main
{
  Log::Log4perl->init(\*DATA);

  my $logger = Log::Log4perl->get_logger;
  my $number_pattern = DEFAULT_NUMBER_PATTERN;
  my $title;
  my @pairs;
  my $title_generator = \&numbered_title_for;

  GetOptionsFromArray(\@_,
                      'debug'   => sub {
                        $Carp::Verbose = 1;
                        $logger->level($DEBUG);
                      },
                      'standalone' => sub { $title_generator = \&standalone_title_for },
                      'title=s' => \$title,
                      'number-pattern=s' => sub { $number_pattern = qr/$_[1]/ },
                      'verbose' => sub { $logger->level($INFO) });

  croak('Missing --title') unless $title;

  # Completely assemble the titles first, not on-the-fly during encoding.
  # I do this because it's cheap, and because it's annoying to come back
  # to a batch encode of 12 items to find that title building failed for
  # the second item.  They're also stored in an array, as ordering is
  # useful.

  encode(@$_) for map { [ $_, $title_generator->($title, $_, $number_pattern) ] } @_;
}

main(@ARGV) unless caller;

1;

__DATA__
log4perl.rootLogger=WARN,Screen
log4perl.appender.Screen=Log::Log4perl::Appender::Screen
log4perl.appender.Screen.layout=PatternLayout
log4perl.appender.Screen.layout.ConversionPattern=%m%n
