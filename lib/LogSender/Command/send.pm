package LogSender::Command::send;
use Mojo::Base 'Mojolicious::Command';
use Getopt::Long 2.25 qw(:config posix_default no_ignore_case);

#use Test::Mock::Net::FTP;
#Test::Mock::Net::FTP::mock_prepare(engelberg => {oetiker => {password => 'gugus',dir => [ "/home/oetiker/scratch/log/remote_ftp/", "/" ]},},);
#my $FTP = 'Test::Mock::Net::FTP';

use Net::FTP;
use Net::SFTP::Foreign;

use Mojo::URL;
use Mojo::Util qw(dumper);
use File::Basename;
use Time::HiRes qw(gettimeofday);
use POSIX qw(strftime);
use File::Spec;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use File::Temp;

=head1 NAME

LogSender::Command::send - LogSender send tool

=head1 SYNOPSIS

 ./logsender.pl send

=head1 DESCRIPTION

Run logsender to push local logfiles to the servers. The url parameter can contain ftp or sftp urls.
Note that the sftp functionality uses the localy installed ssh client to do the transfer. This means
that the user running logsender must be able to connect to the remote host without password. This
can be achieved by using ssh keys. These keys must be generated for the user running logsender and
the public key must be added to the remote users authorized_keys file. This all happens in the $HOME/.ssh
directory of the user running logsender.

=cut

has description => <<'EOF';
copy logfiles to a remote machine via ftp and keep track of what has been transfered
EOF

has usage => <<"EOF";
usage: $0 send [OPTIONS]

These options are available:

  --verbose   talk about your work
  --debug     talk even more
  --noaction  ONLY talk do not act

Operations of logsender send are configured in the logsend.cfg file. Use
the LOGSENDER_CFG environment variable to point to an alternate location
for this file.

EOF

my %opt;

has log => sub { shift->app->log };

has cfg => sub { shift->app->config->cfgHash };


sub run {
    my $self   = shift;
    local @ARGV = @_ if scalar @_;
    GetOptions(\%opt,'noaction|no-action|n', 'verbose|v','debug|d');
    if ($opt{verbose} or $opt{noaction}){
        $self->log->level('debug');
        $self->log->handle(\*STDOUT);
    }

    while(1){
        my $now = time;
        $self->action;
        my $sleep  = $self->cfg->{GENERAL}{logCheckInterval}-(time-$now);
        $self->log->debug("sleeping for $sleep s ...");
        sleep $sleep;
    }
}

sub action {
    my $self = shift;
    my $app = $self->app;
    my $cfg = $self->cfg;

    my $now = time;
    HOST:
    for my $host (@{$cfg->{HOSTS}}){
        my $suffix = $host->{transferSuffix};
        my $url = Mojo::URL->new($host->{url});
        $self->log->debug("Connect to $host->{url}");

        my $ftp;
        for ($url->scheme) {
            /^ftp$/ && do {
                $ftp = Net::FTP->new($url->host,Port=>$url->port||21,Passive=>1) or do {
                    $self->log->warn("Skipping ".$host->{url}.": ".$@);
                    next HOST;
                };
                $ftp->login($url->userinfo ? (split /:/,$url->userinfo) : () ) or do {
                    $self->log->error("login failed: " . $ftp->code() . ": " . $ftp->message());
                    next HOST;
                };

                $ftp->binary() or do {
                    $self->log->error("config binary failed: " . $ftp->code() . ": " . $ftp->message());
                    next HOST;
                };
                last;
            };
            /^sftp$/ && do {
                $ftp = Net::SFTP::Foreign->new(
                    host=>$url->host,
                    $url->port ? (port => $url->port) : (),
                    more => [ qw(-o PreferredAuthentications=publickey), ($opt{debug} ? ('-v') : ())]
                ) or do {

                    $self->log->error("ssh connection failed: " . $ftp->error() . ": " . $ftp->status());
                    next HOST;
                };
                last;
            };
        }
        $self->log->debug("Connected to $host->{url}");
        for my $file (@{$host->{FILES}}){
            my %glob;
            for my $gen ( 0..$cfg->{GENERAL}{logCheckPastIntervals}){
                $glob{strftime($file->{globPattern},localtime($now-($gen*$cfg->{GENERAL}{logCheckInterval})))} = 1;
            }
            # just try makeing the destination directory
            # if it failed, put will fail, so we don't check here.
            if ($url->scheme eq 'ftp') {
                $ftp->mkdir($file->{destinationDir},1) unless $opt{noaction};
            }
            elsif ($url->scheme eq 'sftp') {
                $ftp->mkpath($file->{destinationDir}) unless $opt{noaction};
            }
            for my $pattern (keys %glob){
                for my $path (glob $pattern){
                    next if $path =~ m/\Q${suffix}\E$/;
                    my $basename = basename($path);
                    next if $file->{skipFile} and strftime($file->{skipFile},localtime(time)) eq $basename;
                    next if $file->{stopFile} and $basename le $file->{stopFile};
                    next if not -f $path;
                    # only touch files which have not changed for 10 minutes
                    next if time - [stat($path)]->[10] < 600;
                    my $mark = $path.$suffix;
                    next if -e $mark;
                    my $start = gettimeofday();
                    if ($opt{noaction}){
                        $self->log->debug("skipping put $path (noaction mode)");
                        next;
                    }
                    my $src = $path;
                    my $fh;
                    if ($host->{'gunzip'} eq 'yes' and $basename =~ s/\.gz$//){
                        $fh = File::Temp->new( TEMPLATE => 'logsenderXXXXX', TMPDIR => 1 );
                        gunzip $path,$fh or do {
                            $self->log->error("gunzip $path failed: $GunzipError");
                        };
                        $fh->flush;
                        $fh->sync;
                        $src=$fh->filename;
                        $self->log->debug("gunzip $path to $src");
                    }
                    open my $touch,'>',$mark or do {
                        $self->log->error("aborting transfer of $path - creating $mark failed: $!");
                        next;
                    };
                    $self->log->debug("sending $src to $file->{destinationDir}/$basename");
                    $ftp->put($src,File::Spec->catfile($file->{destinationDir},$basename)) or do {
                        if ($url->scheme eq 'ftp') {
                            $self->log->error("aborting transfer of $path: " . $ftp->code() . ": " . $ftp->message());
                        } else {
                            $self->log->error("aborting transfer of $path: " . $ftp->error() . ": " . $ftp->status());
                        }
                        unlink $mark;
                        next;
                    };
                    my $size = -s $src;
                    my $end = gettimeofday();
                    $self->log->debug("$src transferred $size Bytes @ ".sprintf("%.1f MByte/s",($size/(1024*1024))/($end-$start)));
                }
            }
        }
    }
}

1;
__END__

=back

=head1 COPYRIGHT

Copyright (c) 2016 by OETIKER+PARTNER AG. All rights reserved.

=head1 LICENSE

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=head1 AUTHOR

S<Tobias Oetiker E<lt>tobi@oetiker.chE<gt>>

=head1 HISTORY

 2011-05-30 to 1.0 first version
 2023-05-12 to 1.2 added sftp support

=cut

# Emacs Configuration
#
# Local Variables:
# mode: cperl
# eval: (cperl-set-style "PerlStyle")
# mode: flyspell
# mode: flyspell-prog
# End:
#
# vi: sw=4 et
