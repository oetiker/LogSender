package LogSender::Config;

use Mojo::Base -base;
use Mojo::JSON qw(decode_json);
use Mojo::Util qw(slurp);
use Mojo::Exception;
use Data::Processor;
use Data::Processor::ValidatorFactory;

=head1 NAME

LogSender::Config - the Config access  class

=head1 SYNOPSIS

 use LogSender::Config;
 my $conf = LogFetcher::Config->new(app=>$app,file=>'config.json');
 my $hash = $conf->cfgHash;
 print $hash->{GENERAL}{value};

=head1 DESCRIPTION

Load and preprocess a configuration file in json format.

=head1 ATTRIBUTES

All the attributes from L<Mojo::Base> as well as:

=head2 app

pointing to the app

=cut

has 'app';

has validatorFactory => sub {
    Data::Processor::ValidatorFactory->new;
};

has validator => sub {
    Data::Processor->new(shift->schema);
};

=head2 file

the path of the config file

=cut

has 'file';


=head2 SCHEMA

the flattened content of the config file

=cut

my $CONSTANT_RE = '[_A-Z]+';

has schema => sub {
    my $self = shift;
    my $vf = $self->validatorFactory;
    my $string = $vf->rx('^.*$','expected a string');
    my $url = $vf->rx('^ftp://[^:]+:[^@]+@.+$','expected ftp url: ftp://user:pass@host');
    my $integer = $vf->rx('^\d+$','expected an integer');

    return {
        GENERAL => {
            description => 'general settings',
            members => {
                logFile => {
                    validator => $vf->file('>>','writing'),
                    description => 'absolute path to log file',
                },
                logLevel => {
                    validator => $vf->rx('(?:debug|info|warn|error|fatal)','Pick a logLevel of debug, info, warn, error or fatal'),
                    description => 'mojo log level - debug, info, warn, error or fatal'
                },
                logCheckInterval => {
                    description => 'log check interval in seconds',
                    validator => $integer,
                },
                logCheckPastIntervals => {
                    description => 'how many intervals into the past to check',
                    validator => $integer,
                },
                timeout => {
                    description => 'how long to wait for transfer to timeout',
                    validator => $integer,
                    default => 5,
                },
            },
        },
        CONSTANTS => {
            description => 'define constants fo be used in globPattern properties.',
            optional => 1,
            members => {
                $CONSTANT_RE => {
                    regex => 1,
                    description => 'value of the constant',
                    validator => $string,
                }
            }

        },
        HOSTS => {
            description => 'where does our data go to.',
            array => 1,
            members => {
                url => {
                    description => 'ftp url with username and password',
                    example => 'ftp://myuser:mypass@myhost',
                    validator => $url
                },
                transferSuffix => {
                    description => <<DOC_END,
When a file has been successfully transfered, the LogSender will touch the filename with the transferSuffix appended
thus preventing any further transfers of the file.
DOC_END
                    validator => $string
                },
                gunzip => {
                    description => 'gunzip any file ending in .gz prior to transfer?',
                    validator => $vf->rx('yes|no','expected yes or no')
                },
                FILES => {
                    description => 'a map of globs on the remote machine',
                    array => 1,
                    members => {
                        destinationDir => {
                            description => 'destination directory on the ftp server',
                            validator => $string,
                            optional => 1
                        },
                        globPattern => {
                            description => 'a glob pattern to find all logfiles to send you can use ${CONSTANTS} and strftime placeholders',
                            example => '/var/log/archive/%Y/%m/%d/messages-*.gz',
                            validator => $string
                        },
                        skipFile => {
                            description => 'a string to match against the filename. If it matches the file will be skipped. You can use ${CONSTANTS} and strftime placeholders. It operates on localtime.',
                            example => 'access_log.%Y-%m-%d',
                            validator => $string,
                            optional => 1
                        },
                        stopFile => {
                            optional => 1,
                            description => 'If defined, no filename C<le> this one will be considered for transfer.',
                            validator => $string
                        },
                    }
                }
            }
        }
    };
};

=head2 rawCfg

raw config

=cut

has rawCfg => sub {
    my $self = shift;
    $self->n3kCommon->loadJSONCfg($self->file);
};


=head2 cfgHash

access the config hash

=cut

has cfgHash => sub {
    my $self = shift;
    my $cfg = $self->loadJSONCfg($self->file);
    my $validator = $self->validator;
    my $hasErrors;
    my $err = $validator->validate($cfg);
    for ($err->as_array){
        warn "$_\n";
        $hasErrors = 1;
    }
    die "Can't continue with config errors\n" if $hasErrors;
    # we need to set this real early to catch all the info in the logfile.
    $self->app->log->path($cfg->{GENERAL}{logFile});
    $self->app->log->level($cfg->{GENERAL}{logLevel});
    if (my $const = $cfg->{CONSTANTS}){
        my $CONST_MATCH = join('|',keys %$const);
        for my $host (@{$cfg->{HOSTS}}){
            for my $logFile (@{$host->{FILES}}){
                for my $key (qw(globPattern skipFile)){
                    $logFile->{$key} =~ s/\$\{($CONST_MATCH)\}/$const->{$1}/g;
                }
            }
        }
        delete $cfg->{CONSTANTS};
    }
    return $cfg;
};

=head1 METHODS

All the methods of L<Mojo::Base> as well as:

=head2 loadJSONCfg(file)

Load the given config, sending error messages to stdout and igonring /// lines as comments

=cut

sub loadJSONCfg {
    my $self = shift;
    my $file = shift;
    my $json = slurp($file);
    $json =~ s{^\s*//.*}{}gm;

    my $raw_cfg = eval { decode_json($json) };
    if ($@){
        if ($@ =~ /(.+?) at line (\d+), offset (\d+)/){
            my $warning = $1;
            my $line = $2;
            my $offset = $3;
            open my $json, '<', $file;
            my $c =0;
            warn "Reading ".$file."\n";
            warn "$warning\n\n";
            while (<$json>){
                chomp;
                $c++;
                if ($c == $line){
                    warn ">-".('-' x $offset).'.'."  line $line\n";
                    warn "  $_\n";
                    warn ">-".('-' x $offset).'^'."\n";
                }
                elsif ($c+3 > $line and $c-3 < $line){
                    warn "  $_\n";
                }
            }
            warn "\n";
            exit 1;
        }
        else {
            Mojo::Exception->throw("Reading ".$file.': '.$@);
        }
    }
    return $raw_cfg;
}


1;

__END__

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

 2016-03-22 to 0.0 first version

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
