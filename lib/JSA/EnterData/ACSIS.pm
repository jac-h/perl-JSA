package JSA::EnterData::ACSIS;

use strict;
use warnings;

use parent 'JSA::EnterData';

use Log::Log4perl;

=head1 NAME

JSA::EnterData::ACSIS - ACSIS specific methods.

=head1 SYNOPSIS

    # Create new object, with specific header dictionary.
    my $enter = JSA::EnterData::ACSIS->new();

    my $name = $enter->instrument_name();

    my @cmd = $enter->get_bound_check_command;
    system( @cmd ) == 0
        or die "Problem with running bound check command for $name.";

    # Use table in a SQL later.
    my $table = $enter->instrument_table;


=head1 DESCRIPTION

JAS::EnterData::ACSIS is a object oriented module, having instrument
specific methods.

=head2 METHODS

=over 2

=cut

=item B<new>

Constructor, returns an I<JSA::EnterData::ACSIS> object.

    $enter = new JSA::EnterData::ACSIS();

Currently, no extra arguments are handled.

=cut

sub new {
    my ($class, %args) = @_;

    my $obj = $class->SUPER::new(%args);
    return bless $obj, $class;
}

=item B<get_bound_check_command>

Returns a list of command and its argument to be executed to
check/find the bounds.

    @cmd = $inst->get_bound_check_command;

    system(@cmd) == 0
        or die "Problem running the bound check command";

=cut

sub get_bound_check_command {
    my ($self, $fh, $pos_angle) = @_;

    # Turn off autogrid; only rotate raster maps. Just need bounds.
    return (
        '/star/bin/smurf/makecube',
        "in=^$fh",
        'system=ICRS',
        'out=!',
        'pixsize=1',
        # Do not care about POL.
        'polbinsize=!',
        # Turn off autogrid - only rotate raster maps. Just need bounds.
        'autogrid=no',
        'msg_filter=quiet',
        (defined $pos_angle ? "crota=$pos_angle" : ()),
        'reset'
    );
}


=item B<instrument_name>

Returns the name of the instrument involved.

    $name = $enter->instrument_name();

=cut

sub instrument_name {
    return 'ACSIS';
}


=item B<instrument_table>

Returns the database table related to the instrument.

    $table = $enter->instrument_table();

=cut

sub instrument_table {
    return 'ACSIS';
}


=item B<raw_basename_regex>

Returns the regex to match base file name, with array, date and run
number captured ...

    qr{ a
        (\d{8})
        _
        (\d{5})
        _\d{2}_\d{4}[.]sdf
      }x;

    $re = JSA::EnterData::ACSIS->raw_basename_regex();

=cut

sub raw_basename_regex {
    return
        qr{ a
            (\d{8})       # date,
            _
            (\d{5})       # run number,
            _\d{2}        # subsystem.
            _\d{4}[.]sdf
          }x;
}


=item B<raw_parent_dir>

Returns the parent directory of a raw file without date and run number
components.

    $root = JSA::EnterData::ACSIS->raw_parent_dir();

=cut

sub raw_parent_dir {
    return '/jcmtdata/raw/acsis/spectra/';
}


=item B<make_raw_paths>

Given a list of base file names, returns a list of (unverified)
absolute paths.

    my @path = JSA::EnterData::ACSIS->make_raw_paths(@basename);

=cut

sub make_raw_paths {
    my ($self, @base) = @_;

    return unless scalar @base;

    my $re   = $self->raw_basename_regex();
    my $root = $self->raw_parent_dir();

    require File::Spec;

    my @path;
    foreach my $name (@base) {
        my ($date, $run) = ($name =~ $re);

        next unless $date && $run;

        push @path, File::Spec->catfile($root, $date, $run, $name);
    }

    return @path;
}


# Create obsid_subsysnr
sub _fill_headers_obsid_subsys {
    my ($self, $header, $obsid) = @_;

    # Create obsid_subsysnr
    $header->{'obsid_subsysnr'} = join '_', $obsid,  $header->{'SUBSYSNR'};

    my $log = Log::Log4perl->get_logger('');
    $log->trace(sprintf(
        "Created header [obsid_subsysnr] with value [%s]",
        $header->{'obsid_subsysnr'}));

    return;
}


=item B<calc_freq>

Calculate frequency properties, updates given hash reference.

    JSA::EnterData->calc_freq($obs, $headerref);

It Calculates:
    zsource, restfreq
    freq_sig_lower, freq_sig_upper : BARYCENTRIC Frequency GHz
    freq_img_lower, freq_img_upper : BARYCENTRIC Frequency Image Sideband GHz

=cut

sub calc_freq {
    my ($self, $obs, $headerref) = @_;

    # Filenames for a subsystem
    my @filenames = $obs->filename;

    # need the Frameset
    my $wcs = $self->read_ndf($filenames[0]);

    # Change to BARYCENTRIC, GHz
    $wcs->Set('system(1)' => 'FREQ',
              'unit(1)' => 'GHz',
              stdofrest => 'BARY');

    # Rest Frequency
    $headerref->{restfreq} = $wcs->Get("restfreq");

    # Source velocity
    $wcs->Set(sourcesys => 'redshift');
    $headerref->{zsource} = $wcs->Get("sourcevel");

    # Upper and lower values require that we know the GRID bounds
    my @x = (1, $headerref->{NCHNSUBS});

    # need some dummy data for axis 2 and 3 (or else some code to split the
    # specFrame)
    my @y = (1, 1);
    my @z = (1, 1);

    my @observed = $wcs->TranP(1, \@x, \@y, \@z);

    # now need to switch to image sideband (if possible) (some buggy data is not
    # setup as a DSBSpecFrame)
    my @image;
    eval {
        my $sb = uc($wcs->Get("SideBand"));
        $wcs->Set('SideBand' => ($sb eq 'LSB' ? 'USB' : 'LSB'));

        @image = $wcs->TranP(1, \@x, \@y, \@z);
    };

    # need to sort the numbers
    my @freq = sort {$a <=> $b} @{$observed[0]};
    $headerref->{freq_sig_lower} = $freq[0];
    $headerref->{freq_sig_upper} = $freq[1];

    if (@image && @{$image[0]}) {
        @freq = sort {$a <=> $b} @{$image[0]};
        $headerref->{freq_img_lower} = $freq[0];
        $headerref->{freq_img_upper} = $freq[1];
    }

    return;
}

=item B<fill_max_subscan>

Fills in the I<max_subscan> for C<ACSIS> database table, given a
headers hash reference and an L<OMP::Info::Obs> object.

    $inst->fill_max_subscan(\%header, $obs);

=cut

sub fill_max_subscan {
    my ($self, $header, $obs) = @_;

    my $obsid = $obs->obsid;
    my @subscans = $obs->simple_filename;
    $header->{'max_subscan'} = scalar @subscans;

    return;
}


=item B<name_is_similar>

Given a instrument instance (L<JSA::EnterData::ACSIS>, L<JSA::EnterData::DAS>,
L<JSA::EnterData::SCUBA2>), returns a truth value if the name is similar to
"ACSIS" (for the purpose of data ingestion).

    $possibly = JSA::EnterData::ACSIS->name_is_similar($inst);

=cut

sub name_is_similar {
    my ($class, $name) = @_;

    return defined $name
           && scalar grep {lc $name eq lc $_} qw/acsis das/;
}

1;

=pod

=back

=head1 AUTHORS

=over 2

=item *

Anubhav E<lt>a.agarwal@jach.hawaii.eduE<gt>

=back

Copyright (C) 2008, 2013, Science and Technology Facilities Council.
All Rights Reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or (at
your option) any later version.

This program is distributed in the hope that it will be useful,but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place,Suite 330, Boston, MA  02111-1307,
USA

=cut
