ipod-encode
===========

Script to drive ffmpeg and mplayer for iPod/iPhone video transcoding

Installation
------------

This script does not work on Windows, as it makes use of Perl's &POSIX::mkfifo. I've tested
it with both OS X and Linux, and it's fine on both.

You're going to need both ffmpeg and mplayer installed and in your PATH.

mplayer should have the required codec support to be able to play your source video;
ffmpeg should have libx264 and libfaac support in order to create compliant videos.

If you have these two programs, all you need is the script (and a Perl interpreter!)

Running
-------

Although packaged up as a Perl module, the program is intended to be run as a script (when
I've settled on an API, I'll upload it to CPAN).

There are two modes of operation:

1. Batch mode
2. Single-encode, 'standalone' mode

### Batch Mode

In batch mode, the script is invoked with multiple video files (e.g. a series).  Each one
should have a numeric marker that identifies the episode number, which is appended to the
base title when preparing the final output file, e.g.:

        ipod-encode.pl --title 'My Title' Video-01.avi Video-02.avi Video-03.avi

will produce 'My Title-1.m4v', 'My Title-2.m4v' and 'My Title-3.m4v'.

The numbers are extracted using a regular expression that can be overridden with the
--number-pattern switch.  The default is usually good enough (see the code for details).

If you don't care about the numbering, the special 'generate' --number-pattern can
tag each output file with an incrementing number instead.

### Standalone Mode

In standalone mode, the script is invoked with a single video file, and no numeric marker
differentiates it.

        ipod-encode --title 'My Title' SomeVideo.avi --standalone

will produce 'My Title.m4v'


