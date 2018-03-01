package JSA::EnterData;

=head1 NAME

JSA::EnterData - Parse headers and store in database

=head1 SYNOPSIS

    # Create new object, with specific header dictionary.
    my $enter = new JSA::EnterData('dict' => '/path/to/dict');

    # Upload metadata for Jun 25, 2008.
    $enter->prepare_and_insert(date => '20080625');

=head1 DESCRIPTION

JSA::EnterData is a object oriented module to provide back end support
to load data to CADC.

Reads the headers of all data from either the current date or the
specified UT date, and uploads the results to the header database. If
no date is supplied the current localtime is used to determine the
relevant UT date (which means that it will still pick up last night's
data even if run after 2pm).

=cut

use strict;
use warnings;

use Data::Dumper;
use File::Temp;
use List::MoreUtils qw/any all/;
use List::Util qw/min max/;
use Log::Log4perl;
use Scalar::Util qw/blessed looks_like_number/;

use Astro::Coords::Angle::Hour;

use JSA::DB;
use JSA::Headers qw/read_jcmtstate read_wcs/;
use JSA::Datetime qw/make_datetime/;
use JSA::DB::TableCOMMON;
use JSA::EnterData::ACSIS;
use JSA::EnterData::DAS;
use JSA::EnterData::SCUBA2;
use JSA::EnterData::StarCommand qw/try_star_command/;
use JSA::Error qw/:try/;
use JSA::Files qw/looks_like_rawfile/;
use JSA::WriteList ();
use JSA::DB::TableTransfer;
use JCMT::DataVerify;

use OMP::ArchiveDB;
use OMP::DBbackend::Archive;
use OMP::Info::ObsGroup;
use OMP::DateTools;
use OMP::General;

use DateTime;
use DateTime::Format::ISO8601;

use NDF;

$| = 1; # Make unbuffered

BEGIN {
    # Make sure that bad status from SMURF triggers bad exit status
    $ENV{ADAM_EXIT} = 1;
}

=head2 METHODS

=over 2

=item B<new>

Constructor.  A data dictionary file name is required, which is set by
default.  It can be overridden as ...

  $enter = JSA::EnterData->new( 'dict' => '/file/path/' );

Configuration values which can be passed as key-value pairs are ...

=over 4

=item I<date> C<yyyymmdd>

Date to set given in C<yyyymmdd> format.
Default is the current date in local timezone (at the time of creation
of the object).

=item I<dict> C<file name>

File name for data dictionary.

=item I<force-disk> C<1 | 0>

A truth value whether to force looking for data on disk, not in
database.  Default is true.

When the value is true, I<force-db> is marked false.

=item I<force-db> C<1 | 0>

A truth value whether to force looking for data in database, not on
disk. Default is false.

Currently it does not do anything.

When the value is true, I<force-disk> is marked false.

=back

=cut

{
    my %default = (
        'date'              => undef,

        # $OMP::ArchiveDB::SkipDBLookup is changed.
        'force-disk'        => 1,
        'force-db'          => 0,

        'instruments'       => [
            JSA::EnterData::DAS->new,
            JSA::EnterData::ACSIS->new,
            JSA::EnterData::SCUBA2->new,
        ],

        # To make OMP::Info::Obs out of given files.
        'files'             => [],
    );

    #  Generate some accessor functions.
    for my $k (keys %default) {
        next if (any {$k eq $_} (
                # Special handling when date to set is given.
                'date',
                # Validate instruments before setting.
                'instruments',
                # Need to check for an array ref.
                'files',
            ))
            ||
            # Need to turn off the other if one is true.
            $k =~ m/^ force-d(?: isk | b ) $/x;

        {
            (my $sub = $k) =~ tr/-/_/;
            no strict 'refs';
            *$sub = sub {
                my $self = shift;

                return $self->{$k} unless scalar @_;

                $self->{$k} = shift;
                return;
            };
        }
    }

    sub new {
        my ($class, %args) = @_;

        my $obj = bless {%default, %args}, $class;

        # Sanity checks.
        $obj->_verify_dict;

        for (qw/date force-db force-disk/) {
            (my $sub = $_) =~ tr/-/_/;

            die "None such sub: $sub"
                unless $obj->can($sub);

            $obj->$sub($obj->$sub);
        }

        return $obj;
    }

}

=item B<instruments>

Returns a list of instrument objects when no arguments given.  Else,
the list of given instrument objects is accepted for further use.

    # Currently set.
    $instruments = $enter->instruments;

    # Set ACSIS as the only instrument.
    $enter->instruments( JSA::EnterData::ACSIS->new );

=cut

sub instruments {
    my $self = shift;

    unless (scalar @_) {
        my $inst = $self->{'instruments'};
        return
            defined $inst ? @{$inst} : () ;
    }

    foreach my $inst (@_) {
        throw JSA::Error "Instrument '$inst' is unknown."
            unless any {blessed $_ eq blessed $inst} (
                JSA::EnterData::DAS->new,
                JSA::EnterData::ACSIS->new,
                JSA::EnterData::SCUBA2->new,
            );
    }

    $self->{'instruments'} = [@_];

    return;
}

=item B<date>

Returns the set date if no arguments given.

    $date = $enter->date;

Else, sets the date to date given as L<DateTime> object or as a string
in C<yyyymmdd> format; returns nothing.  If date does not match
expected type, then current date in local timezone is used.

    $enter->date('20251013');

=cut

sub date {
    my $self = shift;

    return $self->{'date'} unless scalar @_;

    my $date = shift;

    if (! $date
            || (! ref $date && $date !~ /^\d{8}$/)
            || (ref $date && ! $date->isa('DateTime'))) {
        $date = DateTime->now( 'time_zone' => 'UTC' ) ;
    }
    elsif (! ref $date) {
        $date = DateTime::Format::ISO8601->parse_datetime($date);
    }

    $self->{'date'} = $date;

    return;
}

=item B<force_db>

Returns the truth value, when called without arguments, to indicate
whether searching the database for data is forced.

    $db = $enter->force_db;

Else, sets the given truth value; returns nothing.  When the value is
true, I<force-disk> is marked false (see I<new>).

    $enter->force_db( 0 );

=cut

sub force_db {
    my $self = shift;

    return
        ! ($OMP::ArchiveDB::FallbackToFiles && $OMP::ArchiveDB::SkipDBLookup)
        unless scalar @_;

    my ($force) = @_;

    $OMP::ArchiveDB::FallbackToFiles =
    $OMP::ArchiveDB::SkipDBLookup = ! $force;

    return;
}

=item B<force_disk>

Returns the truth value, when called without arguments, to indicate
whether searching the disk for data is forced.

    $disk = $enter->force_disk;

Else, sets the given truth value; returns nothing.  When the value is
true, I<force-db> is marked false (see I<new>).

    $enter->force_disk(1);

=cut

sub force_disk {

  my $self = shift;

  return
      $OMP::ArchiveDB::FallbackToFiles && $OMP::ArchiveDB::SkipDBLookup
      unless scalar @_;

  my ($force) = @_;

  # Force observation queries to query files on disk rather than the database.
  $OMP::ArchiveDB::FallbackToFiles =
  $OMP::ArchiveDB::SkipDBLookup = !! $force;

  return;
}

=item B<get_dict>

Returns the file name for the data dictionary.

    $dict_file = $enter->get_dict;

=cut

sub get_dict {
    my ($self) = @_;
    return $self->{'dict'};
}

=item B<files>

If no array reference is given, returns the array reference of file
names.

    $files = $enter->files();

Else, saves the given array reference  & returns nothing.

    $enter->files([file_list()]);

Throws I<JSA::Error> exception if the given argument is not an array
reference, or is empty.

=cut

sub files {
    my $self = shift @_;

    return $self->{'files'}
        unless scalar @_;

    my ($files) = @_;

    throw JSA::Error 'Need a non-empty array reference.'
        unless $files && ref $files && scalar @{ $files };

    my %seen;
    my $old = $self->{'files'};
    $self->{'files'} = [
        grep {! $seen{$_} ++} (
            ($old && ref $old ? @{$old} : ()),
            @{$files}
        )];

    return;
}

=item B<files_given>

Returns a truth value to indicate if any files were provided to process.

    $use_date = ! $enter->files_given();

=cut

sub files_given {
    my ($self) = @_;

    my $files = $self->files;
    return  !! ($files && scalar @{$files});
}

=item B<prepare_and_insert>

Inserts observation in database retrieved from disk (see also
I<insert_observations> method) for a date (see also I<date> method) or
given list of files (see I<files> method).

Date can be given to the method, or can be set via I<new()> or
I<date()> method. Current date is used if no date has been explicitly
set.

    # Insert either for the set or current date; disk is searched.
    $enter->prepare_and_insert();

    # Insert for Jun 25, 2008; ignores given files if any; disk is
    # searched.
    $enter->prepare_and_insert(date => '20080625');

    # Insert for only given files; ignores date; disk is not searched as
    # there is no reason to.
    $enter->prepare_and_insert(files => \@files);

Options:

=over 4

=item calc_radec

Calculate observation bounds.

=item dry_run

Do not write to the database.

=item process_simulation

Include simulation observations.

=item skip_state

Do not set file state in transfer table.

=item update_only_inbeam

Update only the C<INBEAM> header value.

=item update_only_obstime

Update only the times for an observation.

=back

=cut

{
    # To keep track of already processed files.
    my ($old_date , %touched);

    sub prepare_and_insert {
        my ($self, %arg) = @_;

        my $log = Log::Log4perl->get_logger('');

        my $key_use_list = 'given-files';

        # Transitional: force usage of given files, if any.
        if (exists $arg{'files'}) {
            $self->files($arg{'files'});
            $arg{$key_use_list} = 1;
        }

        my ($date, $use_list) = @arg{('date', $key_use_list)};
        my $dry_run = $arg{'dry_run'};
        my $skip_state = $arg{'skip_state'};

        my %update_args = map {$_ => $arg{$_}} qw/
            calc_radec
            process_simulation
            update_only_inbeam update_only_obstime/;

        # Format date first before getting it back.
        $self->date($date) if defined $date;
        $date = $self->date;

        $arg{$key_use_list} = 0 unless defined $use_list;

        if (defined $old_date && $date->ymd ne $old_date->ymd) {
            $log->trace("clearing file cache");

            undef %touched;
        }

        $old_date = $date;

        # Tables of interest.  All instruments reference the COMMON table, so it is
        # first on the array.  Actual instrument table will be the second element.
        my @tables = qw/COMMON/;

        my $db = OMP::DBbackend::Archive->new;
        my $dbh = $db->handle;

        # The %columns hash will contain a key for each table, each key's value
        # being an anonymous hash containing the column information.  Store this
        # information for the COMMON table initially.
        my $columns;
        $columns->{$tables[0]} = $self->get_columns($tables[0], $dbh);

        my %dict = $self->create_dictionary;

        my ($observations, $group, $name, @files_added);

        foreach my $inst ($self->instruments) {
            $name = $inst->name;

            # Retrieve observations from disk.  An Info::Obs object will be returned
            # for each subscan in the observation.  No need to retrieve associated
            # obslog comments. That's <no. of subsystems used> *
            # <no. of subscans objects returned per observation>.
            $group = $self->_get_obs_group('name' => $name,
                                           'date' => $date,
                                           dry_run => $dry_run,
                                           skip_state => $skip_state,
                                           map {($_ => $arg{ $_ })}
                                               ($key_use_list));

            next unless $group
                     && ref $group;

            my @obs = $self->_filter_header(
                $inst,
                [$group->obs],
                'OBS_TYPE' => [qw/FLATFIELD/],
            );

            $log->debug(
                ! $self->files_given
                ? sprintf("Inserting data for %s. Date [%s]",
                          $name, $date->ymd)
                : "Inserting given files");

            unless ($obs[0]) {
                $log->debug("No observations found for instrument $name");
                next;
            }

            $tables[1] = $inst->table;

            $columns->{$name} = $self->get_columns($inst->table, $dbh);
            $columns->{FILES} = $self->get_columns('FILES', $dbh);

            # Need to create a hash with keys corresponding to the observation number
            # (an array won't be very efficient since observations can be missing and
            # run numbers can be large). The values in this hash have to be a reference
            # to an array of Info::Obs objects representing each subsystem. We need to
            # construct new Obs objects based on the subsystem number.
            # $observations{$runnr}->[$subsys_number] should be an Info::Obs object.

            foreach my $obs (@obs) {
                my @subhdrs = $obs->subsystems;
                $observations->{$obs->runnr} = \@subhdrs;
            }

            my $added = $self->insert_observations('db' => $db,
                                                   'instrument' => $inst,
                                                   'columns' => $columns,
                                                   'dict'    => \%dict,
                                                   'obs' => $observations,
                                                   dry_run => $dry_run,
                                                   skip_state => $skip_state,
                                                   %update_args);

            push @files_added, @{$added}
                if $added && scalar @{$added};
        }

        return \@files_added;
    }

=item B<insert_observations>

Inserts a row  in "FILES", "COMMON", and instrument related tables for
each observation for each subscan and subsystem used.  Every insert
per observation is done in one transaction.

It takes a hash of database handle; an instrument object
(I<JSA::EnterData::ACSIS>, I<JSA::EnterData::DAS>, or
I<JSA::EnterData::SCUBA2>); hash reference of observations (run number
as keys, array reference of sub headers as values); a hash reference
of columns (see I<get_columns>); and a hash reference of dictionary
(see I<create_dictionary>).

    $enter->insert_observations('dbhandle' => $dbh,
                                'instrument' => $inst,
                                'columns' => \%cols,
                                'dict'    => \%dict,
                                'obs'     => \%obs,
                                dry_run   => $dry_run,
                                skip_state=> $skip_state);

It is called by I<prepare_and_insert> method.

=cut

    sub insert_observations {
        my ($self, %args) = @_ ;

        my ($obs, $dry_run, $skip_state) =
            map {$args{$_}} qw/obs dry_run skip_state/;

        # Pass everything but observations hash reference to other subs.
        my %pass_args = map {$_ => $args{$_}}
            qw/instrument db calc_radec columns dict dry_run skip_state
               process_simulation
               update_only_obstime update_only_inbeam/;

        my @success;

        my (@sub_obs, @base);

        foreach my $runnr (sort {$a <=> $b} keys %{$obs}) {
            @sub_obs =  grep {$_} @{$obs->{$runnr}};

            @base = map {$_->simple_filename} @sub_obs;

            my ($ans, $comment);

            try {
                ($ans, $comment) = $self->insert_obs_set('run-obs' => \@sub_obs,
                                                         'file-id' => \@base,
                                                         %pass_args);
            }
            catch JSA::Error with {
                my ($e) = @_;

                $ans = 'error';
                $comment = "$e";
            };

            next unless defined $ans;

            if ($ans eq 'inserted') {
                push @success, map {$_->filename} @sub_obs;
            }
            elsif ($ans eq 'simulation') {
                unless ($dry_run or $skip_state) {
                    my $xfer = $self->_get_xfer_unconnected_dbh();
                    $xfer->put_state(
                        state => 'simulation', files => \@base);
                }
            }
            elsif ($ans eq 'error') {
                unless ($dry_run or $skip_state) {
                    my $xfer = $self->_get_xfer_unconnected_dbh();
                    $xfer->put_state(
                        state => 'error', files => \@base,
                        comment => $comment);
                }
            }
            elsif ($ans eq 'nothing-to-do') {
            }
            else {
                throw JSA::Error::BadArgs "Do not know what to run for state '$ans'."
            }
        }

        return \@success;
    }

    # For each observation:
    # 1. Insert a row in the COMMON table.
    # 2. Insert a row in the [INSTRUMENT] table for each subsystem used.
    # 3. Insert a row in the FILES table for each subscan
    #
    # fails, the entire observation fails to go in to the DB.
    sub insert_obs_set {
        my ($self, %arg) = @_;

        my $log = Log::Log4perl->get_logger('');

        my ($inst, $db, $run_obs, $files, $dry_run, $skip_state) =
           map {$arg{$_}} qw/instrument db run-obs file-id dry_run skip_state/;

        my $dbh  = $db->handle();
        my @file = @{$files};

        my %pass_arg = map {$_ => $arg{$_}} qw/instrument columns dict/;
        my %common_arg = map {$_ => $arg{$_}} qw/update_only_inbeam update_only_obstime/;

        foreach (@file) {
          if (exists $touched{$_}) {
              $log->trace("already processed: $_");

              return;
          }
        }

        @touched{@file} = ();

        for my $obs (@{$run_obs}) {
            my $headers = $obs->hdrhash();

            $headers = $self->munge_header_INBEAM($headers);

            if ($inst->can('fill_max_subscan')) {
              $inst->fill_max_subscan($headers, $obs);
            }

            if ($inst->can('transform_header')) {
              my ($hash , $array) = $inst->transform_header($headers);
              $obs->hdrhash($hash);
            }
        }

        my $common_obs = $run_obs->[0]
            or do {
                $log->debug('XXX First run obs is undefined|false; nothing to do.');
                return ('nothing-to-do', 'First run obs is undef|false');
            };

        # Break hash tie by copying & have an explicit anonymous hash ( "\%{ ... }"
        # does not untie).  This is so that a single element array reference when
        # assigned to one of the keys is assigned as reference (not as the element
        # contained with in).
        my $common_hdrs = {%{$common_obs->hdrhash}};

        $log->debug(sprintf "[%s]...", join ', ', @file);

        if (! $arg{'process_simulation'} && $self->is_simulation($common_hdrs)) {
            $log->debug("simulation data; skipping" );
            return ( 'simulation', '' );
        }

        # XXX Skip badly needed data verification for scuba2 until implemented.
        unless (JSA::EnterData::SCUBA2->name_is_scuba2($inst->name)) {
            my $verify = JCMT::DataVerify->new('Obs' => $common_obs)
                or do {
                    my $log = Log::Log4perl->get_logger('');
                    $log->logdie( _dataverify_obj_fail_text($common_obs));
                };

            my %invalid = $verify->verify_headers;

            foreach (keys %invalid) {
                my $val = $invalid{$_}->[0];

                if ($val =~ /does not match/i) {
                    $log->debug("$_ : $val");
                    undef $common_hdrs->{$_};
                }
                elsif ($val =~ /should not/i) {
                    $log->debug("$_ : $val");
                    undef $common_hdrs->{$_} if $common_hdrs->{$_} =~ /^UNDEF/ ;
                }
            }
        }

        if ($arg{'calc_radec'}
                && ! $self->skip_calc_radec('headers' => $common_hdrs)) {

            unless ($self->calc_radec($inst, $common_obs, $common_hdrs)) {
                $log->debug("problem while finding bounds; skipping");
                return ('error', $inst->name() . ': could not find bounds');
            }
        }

        # COMMON table.
        $db->begin_trans() if not $dry_run;

        $self->fill_headers_COMMON($common_hdrs, $common_obs);

        my $error = $self->_update_or_insert(
            %pass_arg,
            update_args => \%common_arg,
            'dbhandle' => $dbh,
            'table'    => 'COMMON',
            'headers'  => $common_hdrs,
            dry_run    => $dry_run);

        if ($dbh->err()) {
            my $text = $dbh->errstr();

            $db->rollback_trans();

            if ($self->_is_insert_dup_error($text)) {
                $log->debug('File metadata already present');
                return ('nothing-to-do' , 'ignored duplicate insert')
            }

            $log->debug($text) if defined $text;

            return ('error', $text);
        }

        # FILES, ACSIS, SCUBA2 tables.
        unless ($arg{'update_only_obstime'} || $arg{'update_only_inbeam'}) {
            $self->add_subsys_obs(%pass_arg,
                                  'db'  => $db,
                                  'obs' => $run_obs,
                                  dry_run => $dry_run,
                                  skip_state => $skip_state)
                or return ('error', "while adding subsys obs: $run_obs");
        }

        try {
            $db->commit_trans() if not $dry_run;
        }
        catch Error::Simple with {
            my ($e) = @_;
            throw JSA::Error $e;
        };

        $log->debug("successful");

        return ('inserted', '');
    }
}

sub _filter_header {
    my ($self, $inst, $obs, %ignore) = @_;

    my $log = Log::Log4perl->get_logger('');

    return unless scalar @{$obs};

    return @{$obs}
        if JSA::EnterData::ACSIS->name_is_similar($inst->name());

    my $remove_ok = sub {
        my ($href, $key) = @_;

        return unless exists $href->{$key}
                   && defined $ignore{$key};

        my $present = $href->{$key};

        return
            defined $present
            && any {
                    looks_like_number($_)
                        ? $present == $_
                        : $present eq $_
            } (ref $ignore{$key}
                    ? @{$ignore{$key}}
                    : $ignore{$key});

        };

    my @new;

    OBS: foreach my $cur (@{$obs}) {
        my $header = $cur->hdrhash;

        IGNORE: foreach my $key (keys %ignore) {
            if ($remove_ok->($header, $key)) {
                $log->debug(sprintf
                    'Ignoring observation with %s = %s',
                    $key, $header->{$key});

                next OBS;
            }

            push @new, $cur;
            my @subhead = $header->{'SUBHEADERS'} ? @{$header->{'SUBHEADERS'}} : ();

            next OBS unless scalar @subhead;

            my @new_sub;

            SUBHEAD: foreach my $sub (@subhead) {
                if ($remove_ok->($sub, $key)) {
                    $log->debug(sprintf
                        'Ignoring subheader with %s = %s',
                        $key, $sub->{$key});

                    next SUBHEAD;
                }

                push @new_sub, $sub;
            }

            $new[-1]->{'SUBHEADERS'} = [@new_sub];
        }
    }

    return @new;
}

=item B<_get_obs_group>

When no files are provided, returns a L<OMP::Info::ObsGroup> object
given instrument name and date as a hash.

    $obs = $enter->_get_obs_group('name' => 'ACSIS',
                                  'date' => '2009-06-09',
                                  dry_run => $dry_run,
                                  skip_state => $skip_state,
                                 );

Else, returns a L<OMP::Info::ObsGroup> object created with already
given files (see I<files> method).

    $obs = $enter->_get_obs_group;

Note: writes the file state in the transfer table unless the
dry_run argument is given.

=cut

sub _get_obs_group {
    my ($self, %args) = @_;
    my $dry_run = $args{'dry_run'};
    my $skip_state = $args{'skip_state'};

    my $log = Log::Log4perl->get_logger('');

    my $xfer = $self->_get_xfer_unconnected_dbh();

    my %obs = (
        'nocomments' => 1,
        'retainhdr'  => 1,
        'ignorebad'  => 1,
        'header_search' => 'files',
    );

    require OMP::FileUtils;
    require OMP::Info::Obs;

    my @file;

    # OMP uses Time::Piece (instead of DateTime).
    require Time::Piece;

    $self->date($args{'date'} || $self->date());
    my $date = $self->date();

    unless ($args{'given-files'}) {
        @file = OMP::FileUtils->files_on_disk(
            'date' => Time::Piece->strptime($date->ymd(''), '%Y%m%d'),
            'instrument' => $args{'name'});
    }
    else {
        @file = $self->files();
    }

    # Flatten 2-D array reference.
    @file = map {! defined $_ ? () : ref $_ ? @{$_} : $_} @file;

    return unless scalar @file;

    my @obs;
    foreach my $file (@file) {
        my $base = _basename($file);

        unless (-r $file && -s _) {
            my $ignored = 'Unreadable or empty file';

            $xfer->put_state(
                    state => 'ignored', files => [$base], comment => $ignored)
                unless $dry_run || $skip_state;

            $log->warn("$ignored: $file; skipped.\n");

            next;
        }

        $xfer->add_found([$base], '')
            unless $dry_run || $skip_state;

        my $text = '';
        my $err;

        try {
            push @obs, OMP::Info::Obs->readfile($file , %obs);
        }
        catch OMP::Error::ObsRead with {
            ($err) = @_;

            #throw $err
            #  unless $err->text() =~ m/^Error reading FITS header from file/;
            $text = 'Error during file reading when making Obs:';
        }
        otherwise {
            ($err) = @_;

            $text = 'Unknown Error';
        };

        if ( $err ) {
            $text .=  ': ' . $err->text();

            $xfer->put_state(
                    state => 'error', files => [$base], comment => $text)
                unless $dry_run || $skip_state;

            $log->error($text);
        }
    }

    return unless scalar @obs;

    my @headers;
    for my $ob (@obs) {
        my $header = $ob->hdrhash;

        # These headers will be passed to OMP::FileUtils->merge_dupes which
        # in turn passes them to Astro::FITS::Header->new(Hash => ...).
        # That constructor drops any null or empty string headers.  Since
        # we need to see the INBEAM header for all files, replace blank
        # values with a dummy placeholder first.  (See also
        # munge_header_INBEAM where these placeholders are removed.)
        if (exists $header->{'INBEAM'}) {
            unless ((defined $header->{'INBEAM'})
                    and ($header->{'INBEAM'} ne '')) {
                $header->{'INBEAM'} = 'NOTHING';
            }
        }

        push @headers, {
            'filename' => $ob->{'FILENAME'}->[0],
            'header' => $header,
        };
    }

    my $merged = OMP::FileUtils->merge_dupes(@headers);

    @obs = OMP::Info::Obs->hdrs_to_obs('retainhdr' => $obs{'retainhdr'},
                                       'fits'      => $merged);

    return OMP::Info::ObsGroup->new('obs' => [@obs]);
}


=item B<skip_obs>

Returns a truth value indicating if an observation is a simulation run,
or for which RA/Dec cannot be calculated. It accepts an
L<OMP::Info::Obs> object.  If optional header hash reference (see
L<OMP::Info::Obs/hdrhash>) is not given, it will be retrieved from the
given L<OMP::Info::Obs> object.

    $skip = $enter->skip_obs($inst, $obs);

    $skip = $enter->skip_obs($inst, $obs, $header);

C<JSA::Error> exception is thrown if header hash (reference) is
undefined.

=cut

sub skip_obs {
    my ($self, $inst, $obs, $header) = @_;

    $header = $obs->hdrhash unless defined $header;

    # Alternatively could (silently) return false.
    throw JSA::Error "FITS headers are undefined."
        unless defined $header;

    # Tests are the same which control database changes.
    return $self->is_simulation($header)
        || ! $self->calc_radec($inst, $obs, $header);
}

=item B<is_simulation>

Returns a truth value to indicate if the given headers are of
"simulation".

An observation is marked as simulation if ...

    SIMULATE header has value of "T", or
    OBS_TYPE header has value of "RAMP".

    for my $obs (...) {

        ...

        next if $enter->is_simulation($obs->hdrhash());

        ...
    }

=cut

sub is_simulation {
    my ($self, $header) = @_;

    # Value changed from 'T' to 1 without notice. Now deal with both.
    my %sim = (
        'SIMULATE' => qr/^(?:[t1]|1\.0+)$/i,
        'OBS_TYPE' => qr/^ramp$/i,
    );

    # "SIMULATE" is more likely to be in the main header.
    my @order = ('SIMULATE', 'OBS_TYPE');

    foreach my $name (@order) {
      my $val = $self->_find_header('headers' => $header,
                                    'name'   => $name,
                                    'test'   => 'defined',
                                    'value'  => 1);

      my $test = $sim{$name};

      return 1
          if defined $val
          && $val =~ $test;
    }

    return;
}


=item B<add_subsys_obs>

Adds subsystem observations, given a hash of database handle; hash
reference of observations (run number as keys, array reference of sub
headers as values); a hash reference of columns (see I<get_columns>);
and a hash reference of dictionary (see I<create_dictionary>).

The observations hash reference is for a given run number, not the
the I<OMP::Info::Objects> in its entirety.

Returns true on success, false on failure.

    $ok = $enter->add_subsys_obs('dbhandle' => $dbh,
                                 'instrument' => $inst,
                                 'columns' => \%cols,
                                 'dict'    => \%dict,
                                 'obs'     => \%obs_per_runnr,
                                 dry_run   => $dry_run,
                                 skip_state=> $skip_state);

It is called by I<insert_observations> method.

=cut

sub add_subsys_obs {
    my ($self, %args) = @_;

    my $log = Log::Log4perl->get_logger('');

    foreach my $k (qw/instrument db columns dict obs/) {
        next if exists $args{$k} && $args{$k} && ref $args{$k};

        throw JSA::Error::BadArgs("No suitable value given for ${k}.");
    }

    my ($inst, $db, $obs, $dry_run, $skip_state) =
        map {$args{$_}} qw/instrument db obs dry_run skip_state/;

    my $dbh = $db->handle();

    # Need to pass everything but observations to other subs.
    my %pass_args = map {$_ => $args{$_}} qw/instrument columns dict/;

    my $subsysnr = 0;
    my $totsub = scalar @{$obs};

    foreach my $subsys_obs (@{$obs}) {
        $subsysnr++;
        $log->debug("Processing subsysnr $subsysnr of $totsub");

        # Obtain instrument table values from this Obs object.  Break hash tie.
        my $subsys_hdrs = {%{$subsys_obs->hdrhash}};

        # Need to calculate the frequency information
        $inst->calc_freq($self, $subsys_obs, $subsys_hdrs);

        my $grouped;
        if ($inst->can('transform_header')) {
            (undef, $grouped) = $inst->transform_header($subsys_hdrs);
        }

        my $added_files;
        foreach my $subh ($grouped ? @{$grouped} : $subsys_hdrs) {
            $inst->_fill_headers_obsid_subsys($subh, $subsys_obs->obsid);

            my $error;

            unless ($added_files) {
                $added_files++;

                $self->_change_FILES('obs'          => $subsys_obs,
                                     'headers'      => $subsys_hdrs,
                                     'instrument'   => $inst,
                                     'db'           => $db,
                                     dry_run        => $dry_run,
                                     skip_state     => $skip_state,
                                     map({$_ => $pass_args{$_}}
                                         qw/columns dict/));
            }

            if ($inst->can('merge_by_obsidss')
                    && exists $subsys_hdrs->{'SUBHEADERS'}) {

                my $sys_sub = $subsys_hdrs->{'SUBHEADERS'};
                my @temp = $inst->merge_by_obsidss($sys_sub);

                @{$sys_sub} = @{$temp[0]}
                    if scalar @temp;
            }

            $error = $self->_update_or_insert(
                %pass_args,
                'dbhandle' => $dbh,
                'table'   => $inst->table,
                'headers' => $subh,
                dry_run   => $dry_run);

            if ($dbh->err()) {
                my $text = $dbh->errstr();

                $db->rollback_trans() if not $dry_run;
                $log->debug("$error");

                return ( 'error', $text);
            }
        }

    }

    return 1;
}

sub prepare_insert_hash {
    my ($self, $table, $field_values) = @_;

    throw JSA::Error "Empty hash reference was given to insert."
        unless scalar keys %{$field_values};

    return $self->_handle_multiple_changes($table, $field_values);
}

sub _handle_multiple_changes {
    my ($self, $table, $vals) = @_;

    my $log = Log::Log4perl->get_logger('');

    # Go through the hash and work out whether we have multiple inserts
    my @have_ref;
    my $nrows = 1;
    foreach my $key (keys %$vals) {
        my $ref = ref $vals->{$key}
            or next;

        $log->logdie("Unsupported reference type in insert hash!\n")
            unless $ref eq 'ARRAY';

        my $row_count = scalar @{$vals->{$key}};
        if (@have_ref) {
            # count rows
            $log->logdie("Uneven row count in insert hash ARRAY ref for key '$key'",
                         " ($row_count != $nrows) compared to first key '$have_ref[0]'",
                         "(table $table)\n")
            unless $row_count == $nrows;
        }
        else {
          $nrows = $row_count;
        }

        push(@have_ref, $key);
    }

    # Now create an array of insert hashes with array references unrolled
    my @change;
    if (! @have_ref) {
        @change = ($vals);
    }
    else {
        # take local copy of the array content so that we do not damage caller hash
        my %local = map {$_ => [@{$vals->{$_}}]} @have_ref;

        # loop over the known number of rows
        foreach my $i (0 .. ($nrows-1)) {
            my %row = %$vals;

            foreach my $refkey (@have_ref) {
                $row{$refkey} = shift @{$local{$refkey}};
            }

            push(@change, \%row);
        }
    }

    return [@change];
}

=item B<insert_hash>

Given a table name, a DBI database handle and a hash reference, insert
the hash contents into the table.  Basically a named insert.  Returns
the executed statement output.  (Copied from example in L<DBI>.)

In case of error, returns the value as returned by C<DBI->execute>.

    $status = $enter->insert_hash('table'     => $table,
                                  'dbhandle' => $dbh,
                                  'insert'   => \%to_insert
                                  dry_run    => $dry_run);

=cut

sub insert_hash {
    my ($self, %args) = @_;

    my ($table, $dbh, $insert, $dry_run, $conditional) =
        @args{qw/table dbhandle insert dry_run conditional/};

    my $log = Log::Log4perl->get_logger('');

    # Get the fields in sorted order (so that we can match with values)
    # and create a template SQL statement. This can be done with the
    # first hash from @insert_hashes

    my @insert_hashes = @{$insert};

    my (@prim_key);
    do {
        my $prim_key = _get_primary_key($table);
        @prim_key = ref $prim_key ? @{$prim_key} : $prim_key;
    };
    $log->logdie('Primary key not defined for table: ', $table)
        unless scalar @prim_key;

    my ($sql, $sth);

    # Conditional insert mode: for now pre-filter the list of hashes to
    # be inserted.  Could probably replace this for MySQL with a
    # INSERT ... ON DUPLICATE KEY statement at some point.
    if ($conditional) {
        my @insert_hashes_filtered = ();

        $sql = sprintf
            'SELECT COUNT(*) FROM %s WHERE %s ',
            $table,
            join(' AND ', map {" $_ = ? "} @prim_key);

        unless ($dry_run) {
            $sth = $dbh->prepare($sql)
                or $log->logdie(
                    "Could not prepare SQL statement for insert check\n",
                    $dbh->errstr);
        }

        for my $row (@insert_hashes) {
            my @prim_val = map {$row->{$_}} @prim_key;

            $log->trace('-----> SQL: ' . $sql);
            $log->trace(Dumper(\@prim_val));

            next if $dry_run;

            $sth->execute(@prim_val)
                or $log->logdie('SQL query for insert check failed: ', $dbh->errstr);

            my $result = $sth->fetchall_arrayref();

            $log->logdie('SQL query for insert check did not return 1 row')
                unless 1 == scalar @$result;

            # If there was no match (i.e. COUNT(*) = 0) then include this in
            # the filtered list of hashes.
            push @insert_hashes_filtered, $row unless $result->[0][0];
        }

        return undef unless scalar @insert_hashes_filtered;

        @insert_hashes = @insert_hashes_filtered;
    }

    my @fields = sort keys %{$insert_hashes[0]}; # sort required

    $sql = sprintf
        "INSERT INTO %s (%s) VALUES (%s)",
        $table,
        join(', ', @fields),
        join(', ', ('?') x scalar @fields);

    unless ($dry_run) {
        $sth = $dbh->prepare($sql)
            or $log->logdie(
                "Could not prepare SQL statement for insert\n",
                $dbh->errstr);
    }

    my ($sum, @file);
    # and insert all the rows
    for my $row (@insert_hashes) {
        my @values = @{$row}{@fields}; # hash slice

        $log->trace('-----> SQL: ' . $sql);
        $log->trace(Dumper(\@values));

        next if $dry_run;

        my $affected = $sth->execute(@values);

        if ($table eq 'FILES' && defined $affected && $affected > 0) {
            push @file, $row->{'file_id'};
        }

       return ($sum, scalar @file ? [@file] : ())
           unless $affected;

        $sum += $affected;
    }

    return ($sum, scalar @file ? [@file] : ());
}

=item B<prepare_update_hash>

Compare the given field values with those already in the given
database table.

Returns two lists of hashes, one corresponding to update operations
and one corresponding to insert operations which should be performed:

    Update operations:
        differ
        unique_key
        unique_val

    Insert operations:
        insert

Additional arguments may be given in hash form:

=over 4

=item update_only_inbeam

Update only the C<INBEAM> header value.

=item update_only_obstime

Update only the times for an observation.

=item update_only_obsradec

Only update obsra, obsdec and their associated tl, tr, bl, br values.

=back

=cut

sub prepare_update_hash {
    my ($self, $table, $dbh, $field_values, %args) = @_;

    my $log = Log::Log4perl->get_logger('');

    $log->logdie('prepare_update_hash cannot be used for table FILES')
        if $table eq 'FILES';

    # work out which key uniquely identifies the row
    my $unique_key = _get_primary_key($table);

    unless ($unique_key) {
        $log->logdie("No unique keys found for table name: '$table'\n");
    }

    my @unique_key = ref $unique_key ? @{$unique_key} : $unique_key ;

    my $rows = $self->_handle_multiple_changes($table, $field_values);

    my $sql = 'select * ';

    my (%start, %end);

    if ($table eq 'COMMON') {
        my %range = JSA::DB::TableCOMMON::range_columns();
        @start{keys %range} = ();
        @end{values %range} = ();

        $sql = 'select ' . join ', ', JSA::DB::TableCOMMON::column_names();
    }

    $sql .= " from $table where "
          . join ' AND ', map {" $_ = ? "} @unique_key;

    my @update_hash;
    my @insert_hash;
    foreach my $row (@{$rows}) {
        my @unique_val = map $row->{$_}, @unique_key;

        $log->trace(Dumper(\@unique_key));
        $log->trace(Dumper(\@unique_val));

        my $ref = $dbh->selectall_arrayref($sql, {Columns=>{}}, @unique_val)
            or $log->logdie("Error retrieving existing content using [$sql]: ", $dbh->errstr, "\n");

        $log->logdie("Only retrieved partial dataset: ", $dbh->errstr, "\n")
            if $dbh->err;

        # how many rows
        my $count = scalar @{$ref};

        if (0 == $count) {
            # Row does not already exist: add to the insert list.
            $log->debug("new data to insert: " . (join ' ', @unique_val));

            push @insert_hash, $row;

            next;
        }

        $log->logdie("Should not be possible to have more than one row. Got $count\n")
            if $count > 1;

        my $indb = $ref->[0];

        my %differ;
        my $ymd_start = qr/^\d{4}-\d{2}-\d{2}/;
        my $am_pm_end = qr/\d\d[APM]$/;

        my $obs_date_re = qr/\bDATE.(?:OBS|END)\b/i;

        my $inbeam_re = qr/\b INBEAM \b/xi;

        # Allowed to be set undef if key from $field_values is missing, say as a
        # result of external header munging.
        my $miss_ok = _or_regex(qw/INBEAM/,
                                _suffix_start_end_headers(qw/SEEING SEEDAT/));

        my $tau_val = qr/\b(?:WVMTAU|TAU225)(?:ST|EN)\b/i;

        my $only_obstime = $table eq 'COMMON' && $args{'update_only_obstime'};

        my $only_inbeam = $table eq 'COMMON' && $args{'update_only_inbeam'};

        my $only_obsradec = $args{'update_only_obsradec'};

        foreach my $key (sort keys %{$indb}) {
            if (($only_inbeam && $key !~ $inbeam_re)
                    or ($only_obstime && $key !~ $obs_date_re)
                    or ($only_obsradec && $key !~ /^obs(?:ra|dec)/i)) {
                $log->debug("skipping field: $key (due to field restriction)");
                next;
            }

            $log->debug("testing field: $key");

            next if ($key !~ $miss_ok && ! exists $field_values->{$key});

            my $new = $field_values->{$key};
            my $old = $indb->{$key};

            next unless (defined $old || defined $new);

            $log->debug("continuing with $key");

            my %test = (
                'start' => exists $start{$key},
                'end'   => exists $end{$key},
                'old'   => $old,
                'new'   => $new,
            );

            my $in_range = any {$test{$_}} (qw/start end/);

            # INBEAM header: special handling.
            if ($key =~ $inbeam_re) {
                my $combined = $self->_combine_inbeam_values($old, $new);
                $differ{$key} = $combined;
                $log->debug($key . ' = ' . ($combined // '<undef>'));
                next;
            }

            # Not defined currently - inserting new value.
            if (defined $new && ! defined $old) {
                $differ{$key} = $new;
                $log->debug( qq[$key = ] . $new );
                next;
            }

            # Defined in DB but undef in new version - not expecting this but assume
            # this means a null.
            if (! defined $new && defined $old) {
                $differ{$key} = undef;
                $log->debug("$key = <undef>");
                next;
            }

            # Dates.
            if ($new =~ $ymd_start
                    && ($old =~ $ymd_start || $old =~ $am_pm_end)) {
                if ($in_range) {
                    $new = _find_extreme_value(%test,
                                               'new>old' => _compare_dates($new, $old));
                    $log->debug("  possible new value for $key = " . $new );
                }

                if ($new ne $old) {
                    $differ{$key} = $new;
                    $log->debug("$key = " . $new);
                }

                next;
            }

            if (looks_like_number($new)) {
                # Override range check for tau values as there is no relation between start
                # & end values; these are weather dependent.
                if ($key =~ $tau_val && $new != $old) {
                    $differ{$key} = $new;
                    $log->debug("$key = " . $new);
                }
                elsif ($in_range) {
                    $new = _find_extreme_value(%test, 'new>old' => $new > $old);

                    if ($new != $old) {
                        $differ{$key} = $new if $new != $old;
                        $log->debug("$key = " . $new);
                    }
                }
                else {
                    if ($new =~ /\./) {
                      # floating point
                      my $diff = abs($old - $new);
                      if ($diff > 0.000001) {
                          $differ{$key} = $new;
                          $log->debug("$key = " . $new);
                      }
                    }
                    elsif ( $new != $old ) {
                        $differ{$key} = $new;
                        $log->debug("$key = " . $new );
                    }
                }

                next;
            }

            # String.
            if ($new ne $old) {
                $differ{$key} = $new;
                $log->debug("$key = " . $new);
            }
        }

        $log->debug("differences to update: " . (join ' ', keys %differ));

        push @update_hash, {
            'differ'        => {%differ},
            'unique_val'    => [@unique_val],
            'unique_key'    => [@unique_key],
        };

    }

    return (\@update_hash, \@insert_hash);
}

sub _suffix_start_end_headers {
    return map {; "${_}ST" , "${_}EN"} @_;
}

sub _or_regex_string {
    return join '|',
        map {quotemeta($_)}
        sort {length $b <=> length $a}
        @_;
}

sub _or_regex {
    my $re = _or_regex_string(@_);
    return qr/\b(?:$re)/i;
}

sub _or_regex_suffix_start_end_headers {
    my $re = _or_regex_string( @_ );
    return qr/\b (?: $re )(?: ST|EN )/ix;
}

=item B<_get_primary_key>

Returns the primary key for a given table in C<jcmt> database.

    $primary = _get_primary_key('ACSIS');

=cut

sub _get_primary_key {
    my ($table) = @_;

    my %keys = (
        'ACSIS'     => 'obsid_subsysnr',
        'COMMON'    => 'obsid',
        'FILES'     => [qw/obsid_subsysnr file_id/],
        'SCUBA2'    => 'obsid_subsysnr',
        'transfer'  => 'file_id',
    );

    return unless exists $keys{$table};
    return $keys{$table};
}

=item B<update_hash>

Given a table name, a DBI database handle and a hash reference,
retrieve the current data values based on OBSID or OBSID_SUBSYSNR,
decide what has changed and update the values.

    $enter->update_hash($table, $dbh, \%to_update, dry_run => $dry_run);

No-op for files table at the present time.

=cut

sub update_hash {
    my ($self, $table, $dbh, $change, %args) = @_;

    return if $table eq 'FILES'
           || ! $change;

    my $dry_run = $args{'dry_run'};

    my $log = Log::Log4perl->get_logger('');

    my @change      = @{$change};
    my @sorted      = sort keys %{$change[0]->{'differ'}};

    return 1 unless scalar @sorted;

    my @unique_key = @{$change[0]->{'unique_key'}};

    # Now have to do an UPDATE
    my $changes = join ', ', map {" $_ = ? "} @sorted;

    my $sql = sprintf "UPDATE %s SET %s WHERE %s",
                      $table,
                      $changes,
                      join ' AND ', map {" $_ = ? "} @unique_key;

    $log->trace($sql);

    unless ($dry_run) {
        my $sth = $dbh->prepare($sql)
            or $log->logdie("Could not prepare sql statement for UPDATE\n", $dbh->errstr, "\n");

        foreach my $row (@change) {
            my @bind = map {$row->{'differ'}{$_}} @sorted;
            push @bind, @{$row->{'unique_val'}};

            my $status = $sth->execute(@bind);
            throw JSA::Error::DBError 'UPDATE error: ' . $dbh->errstr() . "\n... with { $sql, @bind }"
                if $dbh->err();

            return $status;
        }
    }

    return 1;
}

=item B<transform_value>

Given a table name, column name, and value to be inserted in a table,
alter the value if the database expects the value to be in a different
format than that of the headers.

    $enter->transform_value($table, \%columns, \%values);

=cut

sub transform_value {
    my ($self, $table, $columns, $values) = @_;

    my $log = Log::Log4perl->get_logger('');

    # Transform boolean data hash.  Contains a hash mapping
    # values from the headers to the values the database expects.
    my %transform_bool = (
        T => 1,
        F => 0,
    );

    foreach my $column (keys %$values) {
      # Store column's current value
      my $val = $values->{$column};
      next unless defined($val);

      if (exists $columns->{$table}{$column}) {
          # Column is defined for this table, get the data type
          my $data_type = $columns->{$table}{$column};

          if ($data_type eq 'datetime') {
              # Temporarily (needs to be handled at the header source) set a
              # zero date (0000-00-00T00:00:00) to undef.
              (my $non_zero = $val) =~ tr/0T :-//d;

              unless ($non_zero) {
                  undef $values->{$column};

                  $log->trace(sprintf
                      "Converted date [%s] to [undef] for column [%s]",
                      $val, $column);
              }
          }
          elsif ($data_type =~ /^tinyint/ or $data_type =~ /^int/) {
              if (exists $transform_bool{$val}) {
                  # This value needs to be transformed to the new value
                  # defined in the %transform_bool hash
                  $values->{$column} = $transform_bool{$val};

                  $log->trace(sprintf
                      "Transformed value [%s] to [%s] for column [%s]",
                      $val, $values->{$column}, $column);
              }
          }
          elsif ($column eq 'lststart' or $column eq 'lstend') {
              # Convert LSTSTART and LSTEND to decimal hours
              my $ha = new Astro::Coords::Angle::Hour($val, units => 'sex');
              $values->{$column} = $ha->hours;

              $log->trace(sprintf
                  "Converted time [%s] to [%s] for column [%s]",
                  $val, $values->{$column}, $column);
          }
      }
    }

    return 1;
}

=item B<fill_headers_COMMON>

Fills in the headers for C<COMMON> database table, given a headers
hash reference and an L<OMP::Info::Obs> object.

    $enter->fill_headers_COMMON(\%header, $obs);

=cut

sub fill_headers_COMMON {
    my ($self, $header, $obs) = @_;

    my $log = Log::Log4perl->get_logger('');

    my $release_date = calculate_release_date($obs);

    $header->{'release_date'} = $release_date->strftime('%F %T');

    $log->trace(sprintf
        "Created header [release_date] with value [%s]",
        $header->{'release_date'});

    if (exists $header->{'INSTRUME'} && ! defined $header->{'BACKEND'}) {
        $header->{'BACKEND'} = $header->{'INSTRUME'};
    }

    _fix_dates($header);
    return;
}

# Sybase ASE 15 cannot convert '0.000000000000000e+00' to a datetime value.  Set
# those to undef, thus NULL.
sub _fix_dates {
    my ($header) = @_;

    my $date_re = qr/ (?: \b date | dat(?: en | st )\b ) /xi;

    my $zero_date_re = qr/^0{4} -? 00 -? 00/x;

    foreach my $k (keys %{$header}) {
        next unless $k =~ $date_re;

        my $date = $header->{$k};

        undef $header->{ $k }
            if ! $date
            || $date =~ $zero_date_re
            || (looks_like_number($date) && 0 == $date);
    }

    return;
}

=item B<fill_headers_FILES>

Fills in the headers for C<FILES> database table, given a
L<JSA::EnterData::ACSIS>, L<JSA::EnterData::DAS>, or
L<JSA::EnterData::SCUBA2> object, a headers hash reference and an
L<OMP::Info::Obs> object.

    $enter->fill_headers_FILES($inst, \%header, $obs);

=cut

sub fill_headers_FILES {
    my ($self, $inst, $header, $obs) = @_;

    my $log = Log::Log4perl->get_logger('');

    # Create file_id - also need to extract NSUBSCAN from subheader if we have more
    # than one file. (although simply using a 1-based index would be sufficient)
    my @files = $obs->simple_filename;
    $header->{'file_id'} = \@files;

    # We need to know whether a nsubscan header is even required so %columns really
    # needs to be accessed. For now we kluge it.
    unless (exists $header->{'nsubscan'}) {
        if (scalar(@files) > 1) {
            $header->{'nsubscan'} =
                [map {$_->value('NSUBSCAN')} $obs->fits->subhdrs];
        }
        elsif (exists $header->{'NSUBSCAN'}) {
            # not really needed because the key becomes case insensitive
            $header->{'nsubscan'} = $header->{'NSUBSCAN'};
        }
        else {
            $log->logdie("Internal error - NSUBSCAN does not exist yet there is only one file!\n");
        }
    }

    $log->trace(sprintf
        "Created header [file_id] with value [%s]",
        join ',', @{$header->{'file_id'}});

    $inst->_fill_headers_obsid_subsys($header, $obs->obsid);

    # Further work needs to be done for SCUBA2.
    if (my $fill = $inst->can('fill_headers_FILES')) {
        $inst->$fill( $header, $obs );
    }

    return;
}


=item B<munge_header_INBEAM>

Given a header hash reference, removes all the I<INBEAM> header occurrences
which have C<SHUTTER>; combines any remaining header values (in subheaders) in a
space separated list. Returns a possibly changed header hash reference.

    $changed = $enter->munge_header_INBEAM($header_hash);

=cut

sub munge_header_INBEAM {
    my ($self , $headers) = @_;

    my $name = 'INBEAM';

    # Find INBEAM values, but remove dummy placeholder values.
    # (See also _get_obs_group where these are inserted.)
    my @val = map {($_ eq 'NOTHING') ? undef : $_} $self->_find_header(
        'headers' => $headers,
        'name'   => $name,
        'value'  => 1,
    );

    $headers->{$name} = (scalar @val)
        ? $self->_combine_inbeam_values(@val)
        : undef;

    return $headers;
}

=item B<_combine_inbeam_values>

Combine multiple INBEAM header values.  Should be passed a list of
header values, each of which is a space-separated list of pieces of
equipment in the beam.  Rules for combining the values are as follows:

=over 4

=item

"shutter" should be removed unless present in all entries.

This is because many observations include sequences with the
shutter closed before (and/or after) main science sequence,
and we do not want to label the whole observation as having
the shutter in the beam because of that.

=item

Other entries are kept only if they appear without shutter,
unless shutter appears everywhere.

The reason for this is just in case a piece of equipment
is left in the beam from a previous observation for initial
closed-shutter sequences.  So if we observed the sky (i.e.
the shutter was not in the beam) we are only interested in
what was in the beam at that time.

=back

These rules need to work both when combining the headers
from several data files, and when merging a new value with
an existing value in the database in an incremental update
situation.

Returns a space-separated list of names in lower case,
sorted in alphabetical order to aid testing.  Undef is
returned if there are no entries to report.

=cut

sub _combine_inbeam_values {
    my $self = shift;

    my $n = 0;
    my $n_shutter = 0;

    my %entry_all = ();
    my %entry_wo_shutter = ();

    foreach (@_) {
        $n ++;

        next unless defined $_;

        my $shutter = 0;
        my @non_shutter = ();

        foreach (split ' ', lc($_)) {
            if ($_ eq 'shutter') {
                $shutter = 1;
            }
            else {
                $entry_all{$_} = 1;
                push @non_shutter, $_;
            }
        }

        if ($shutter) {
            $n_shutter ++;
        }
        else {
            $entry_wo_shutter{$_} = 1 foreach @non_shutter;
        }
    }

    my @vals;

    if ($n and $n == $n_shutter) {
        # Everything has shutter: include shutter and all the values.

        @vals = ('shutter', keys %entry_all);
    }
    else {
        # Not everything has shutter: return only those entries which
        # appear without it.
        @vals = keys %entry_wo_shutter;
    }

    # Nothing: return undef.
    return undef unless scalar @vals;

    return join(' ', sort {$a cmp $b} @vals);
}

=item B<get_columns>

Given a table name and a DBI database handle object, return a hash reference
containing columns with their associated data types.

    $cols = $enter->get_columns($table, $dbh)

=cut

sub get_columns {
    my ($self, $table, $dbh) = @_;

    return {} unless defined $dbh;

    # Do query to retrieve column info
    my $col_href = $dbh->selectall_hashref("SHOW COLUMNS FROM $table", "Field")
        or throw JSA::Error
            "Could not obtain column information for table [$table]: "
            . $dbh->errstr . "\n";

    my %result;
    for my $col (keys %$col_href) {
        $result{$col} = $col_href->{$col}{'Type'};
    }

    return \%result;
}

=item B<get_insert_values>

Given a hash of a table name; a hash reference containing table column
information (see global hash %columns); a hash reference containing
the dictionary contents; and a hash reference containing observation
headers, return a hash reference with the table's columns as the keys,
and the insertion values as the values.

For FILES table, an additional hash reference is needed to list the
already processed files.  Keys are the (base) file names, values could
be anything.

    $vals = $enter->get_insert_values('table' => $table,
                                      'columns' => \%columns,
                                      'dict' => \%dictionary,
                                      'headers' => \%hdrhash);

=cut

sub get_insert_values {
    my ($self, %args) = @_;
    #my ($self, $table, $columns, $dictionary, $hdrhash) = @_;

    my ($table, $columns) = map {$args{$_}} qw/table columns/;

    for (qw/SCUBA-2/) {
        $columns->{$table} = $columns->{$_}
            if 'scuba2' eq lc $table
            && ! exists $columns->{$table}
            && exists $columns->{$_};
    }

    # Map headers to columns, translating from the dictionary as
    # necessary.

    my $main = $self->extract_column_headers(%args);

    # Do value transformation
    $self->transform_value($table, $columns, $main);

    return $main;
}

sub extract_column_headers {
    my ($self, %args) = @_;

    my $log = Log::Log4perl->get_logger('');

    my ($hdrhash, $table, $columns, $dict) =
        map {$args{$_}} qw/headers table columns dict/;

    $log->trace(">Processing table: $table");

    my %values;

    foreach my $header (sort {lc $a cmp lc $b} keys %$hdrhash) {
        my $alt_head = lc $header;

        if (exists $columns->{$table}{$alt_head}) {
            $values{ $alt_head } = $hdrhash->{$header};
        }
        elsif (exists $dict->{$alt_head}
                && exists $columns->{$table}{$dict->{$alt_head}}) {
            # Found header alias in dictionary and column exists in table
            my $alias = $dict->{$alt_head};
            $values{$alias} = $hdrhash->{$header};

            $log->trace("  MAPPED header [$header] to column [$alias]");
        }

        $log->trace("  Could not find alias for header [$header].  Skipped.")
            unless exists $values{$alt_head};
    }

    return \%values;
}

=item B<create_dictionary>

Return a hash containing the dictionary contents.

    %dictionary = $enter->create_dictionary();

=cut

sub create_dictionary {
    my ($self) = @_;

    my $dictionary = $self->{'dict'};
    my %dict;

    my $log = Log::Log4perl->get_logger('');

    open my $DICT, '<', $dictionary
        or $log->logdie("Could not open data dictionary '$dictionary': $!\n");

    my @defs = grep {$_ !~ /^\s*(?:#|$)/} <$DICT>;  # Slurp!

    close $DICT
        or $log->logdie("Error closing data dictionary '$dictionary': $!\n");

    foreach my $def (@defs) {
        $def =~ s/\s+$//;

        if ( $def =~ /(.*?)\:\s(.*)/ ) {
            # Store each dictionary alias as a key whose value is a column name
            map {$dict{$_} = "$1"} split /\s/, "$2";
        }
    }

    return %dict;
}

=item B<skip_obs_calc>

Given a hash of C<headers> key with L<OMP::Info::Obs> object header hash
reference (or C<obs> key & L<OMP::Info::Obs> object); and C<test> as key & hash
reference of header name and related values as regular expression, returns a
truth value if observation should be skipped.

Throws L<JSA::Error::BadArgs> exception when headers (or L<*::Obs> object) are
missing or C<test> hash reference value is missing.

    print "skipped obs"
        if $enter->skip_obs_calc(
            'headers' => $obs->hdrhash(),
            'test' => {
                'OBS_TYPE' => qr/\b(?: skydip | FLAT_?FIELD  )\b/xi
            });

=cut

sub skip_obs_calc {
    my ($self, %arg) = @_;

    my $log = Log::Log4perl->get_logger('');

    # Skip list.
    my %test =
        exists $arg{'test'} && defined $arg{'test'} ? %{$arg{'test' }} : ();

    scalar keys %test
        or throw JSA::Error::BadArgs('No "test" hash reference given.');

    my $header;
    if (exists $arg{'headers'}) {
        throw JSA::Error::BadArgs('No "headers" value given to check if to find bounding box.')
            unless defined $arg{'headers'};

        $header = $arg{'headers'};
    }
    else {
        JSA::Error::BadArgs('No "obs" value given to check if to find bounding box.')
            unless exists $arg{'obs'} && defined $arg{'obs'};

        JSA::Error::BadArgs("Could not get header hash from \"$arg{'obs'}\"")
            unless $header = $arg{'obs'}->hdrhash();
    }

    foreach my $name (sort keys %test) {
        $self->_find_header('headers' => $header,
                            'name'    => $name,
                            'value-regex' => $test{$name})
            or next;

        $log->debug("Matched \"$name\" with $test{$name}; obs may be skipped.");

        return 1;
    }

    return;
}

=item B<skip_calc_radec>

Given a C<OMP::Info::Obs> object header hash reference -- or an
C<OMP::Info::Obs> object -- as a hash, returns a truth value if
bounding box calculation should be skipped.

    print "skipped calc_radec()"
        if $enter->skip_calc_radec('headers' => $obs->hdrhash());

Default skip list is ...

    'OBS_TYPE' => qr/\b skydips? \b/ix

Optionally accepts a skip list with I<skip> as key name, and a hash
reference as value of header names as keys and header values as
regular expressions ...

    print "skipped calc_radec()"
        if $enter->skip_calc_radec(
            'headers' => $obs->hdrhash(),
            'test' => {
                'OBS_TYPE' => qr/\b(?: skydip | FLAT_?FIELD  )\b/xi
            });

=cut

sub skip_calc_radec {
    my ($self, %arg) = @_;

    my $skip = qr/\b skydips? \b/xi;

    return $self->skip_obs_calc('test' => {'OBS_TYPE' => $skip}, %arg);
}

=item B<calc_radec>

Calculate RA/Dec extent (ICRS) of the observation and the base
position.  It populates header with corners of grid (in decimal
degrees).  Status is perl status: 1 is good, 0 bad.

    $status = JSA::EnterData->calc_radec($inst, $obs, $header);

=cut

sub calc_radec {
    my ($self, $inst, $obs, $headerref) = @_;

    my $log = Log::Log4perl->get_logger('');

    # File names for a subsystem
    my @filenames = $obs->filename;

    my $temp = File::Temp->new('template' => _file_template('radec'));
    $temp->unlink_on_destroy(1);
    # Now need to write these files to  temp file
    my $rc = JSA::WriteList::write_list($temp->filename(), [@filenames]);

    # PA (may not be present)
    my $pa = $headerref->{MAP_PA};
    $pa *= -1 if defined $pa;

    my @command  = $inst->get_bound_check_command($temp->filename(), $pa);

    $log->info(sprintf(
        "Performing bound calculation for files starting %s", $filenames[0]));

    # Get the bounds
    my @corner     = qw/TL BR TR BL/;
    my %par_corner = map {; $_ => 'F' . $_ } @corner;

    my $values = try_star_command(
        command => \@command,
        values => [qw/REFLAT REFLON/, values %par_corner]);

    return unless defined $values;

    my %result = ('REFLAT' => undef,
                  'REFLON' => undef);

    foreach my $k (sort values %par_corner) {
        my $res = $values->{$k};

        # Rarely happens but when it does, produces warnings about operations on
        # undef values.
        # XXX Need to ask if it is important enough to log.
        unless ($res) {
            $log->logwarn("No value found for parameter $k");
            # XXX return from sub instead?
            next;
        }

        $result{$k} = [
            map {
                Astro::Coords::Angle->new($_, units => 'rad')
            } split(/\s+/,$res)];
    }

    foreach my $corner (@corner) {
        my $parkey = $par_corner{$corner};
        my $radec  = exists $result{$parkey} ? $result{$parkey} : undef;

        next unless defined $radec;

        my $alt = lc $corner;
        $headerref->{"obsra$alt"}  = $radec->[0]->degrees;
        $headerref->{"obsdec$alt"} = $radec->[1]->degrees;
    }

    # and the base position (easier to just ask SMURF rather than opening the file) but
    # for a planet or comet/asteroid this will not be correct and should be set to undef
    # This means we have to look at JCMTSTATE anyway (but we still ask SMURF because that
    # will save us doing coordinate conversion)

    my $tracksys = $self->_find_header('headers' => $headerref,
                                       'name'   => 'TRACKSYS',
                                       'value'  => 1,
                                       'test'   => 'true');

    my %state;
    unless ($tracksys) {
        (undef, %state) = $self->read_ndf($filenames[0], qw/TCS_TR_SYS/);
        $log->logdie("Error reading state information from file $filenames[0]\n")
            unless keys %state;
    }

    my $not_app_azel = sub {
        return defined $_[0]
               && length $_[0]
               && $_[0] !~ /^(?:APP|AZEL)/i
    };

    # check for APP or AZEL (should never be AZEL!)
    if ($not_app_azel->($tracksys)
            || (exists $state{TCS_TR_SYS}
                && $not_app_azel->($state{TCS_TR_SYS}))) {
        foreach my $k (qw/REFLON REFLAT/) {
            $result{$k} = $values->{$k};
        }

        # convert to radians
        $result{REFLON} = Astro::Coords::Angle::Hour->new(
            $result{REFLON}, units => 'sex', range => '2PI')->degrees
            if defined $result{'REFLON'};

        $result{REFLAT} = Astro::Coords::Angle->new(
            $result{REFLAT}, units => 'sex', range => 'PI')->degrees
            if defined $result{'REFLAT'};
    }

    $headerref->{obsra}  = $result{REFLON};
    $headerref->{obsdec} = $result{REFLAT};

    return 1;
}

=item B<read_ndf>

Open an NDF file, read the frameset and the first entry from the
supplied list of JCMTSTATE components (can be empty).

Returns hash of JCMTSTATE information and the Starlink::AST object.

    ($wcs, %state) = JSA::EnterData->read_ndf($file, @state);

returns empty list on error.  In scalar context just returns WCS
frameset...

    $wcs = JSA::EnterData->read_ndf($file);

On error, flushes error to standard error and returns empty list.

=cut

sub read_ndf {
    my ($self, $file, @statekeys) = @_;

    my $log = Log::Log4perl->get_logger('');

    my $wcs;
    my $E;

    try {
        $wcs = read_wcs($file);
    } catch JSA::Error::FatalError with {
        $E = shift;
    } otherwise {
        $E = shift;
    };

    if (defined $E) {
        $log->error("$E");
        return ();
    }

    # if we have keys to read and are in list
    # context, read the state
    my %state;
    if (@statekeys && wantarray()) {
        try {
            %state = read_jcmtstate($file, 'start', @statekeys);
        } catch JSA::Error::FatalError with {
            $E = shift;
        } otherwise {
            $E = shift;
        };

        if (defined $E) {
            $log->error("$E");
            return ();
        }
    }

    return wantarray ? ($wcs, %state) : $wcs;
}

sub _change_FILES {
    my ($self, %arg) = @_;

    my $log = Log::Log4perl->get_logger('');

    my $table = 'FILES';

    my ($headers, $obs, $db, $inst, $dry_run, $skip_state) =
        @arg{qw/headers obs db instrument dry_run skip_state/};

    my $dbh = $db->handle();

    # Create headers that don't exist
    $self->fill_headers_FILES($inst, $headers, $obs);

    my $insert_ref = $self->get_insert_values(
        'table'     => $table,
        'headers'   => $headers,
        map({$_ => $arg{$_}} qw/columns dict/),
    );

    my ($files , $error);
    try {
        _verify_file_name($insert_ref->{'file_id'});

        my $hash = $self->prepare_insert_hash($table, $insert_ref);

        ($error, $files) = $self->insert_hash('table'   => $table,
                                              'dbhandle'=> $dbh,
                                              'insert'  => $hash,
                                              dry_run   => $dry_run,
                                              conditional => 1);

        $error = $dbh->errstr
            if $dbh->err();
    }
    catch JSA::Error with {
        $error = shift @_;
    };

    if ( $dbh->err() ) {
        $db->rollback_trans() if not $dry_run;

        $log->debug($self->_is_insert_dup_error($error)
                ? "File metadata already present"
                : $error)
            if defined $error;

        return;
    }

    if ((not ($dry_run || $skip_state)) and $files and scalar @{$files}) {
        my $xfer = $self->_get_xfer_unconnected_dbh();
        $xfer->put_state(
            state => 'ingested', files => [map _basename($_), @{$files}]);
    }

    return;
}

=item B<_update_or_insert>

It is a wrapper around I<update_hash> and I<insert_hash> methods.
It calls C<prepare_update_hash> to identify the necessary insert and
update operations, and then calls the above methods as appropriate.

Returns the error string the database handle, given a hash with
C<table>, C<columns>, C<dict>, C<headers> as keys.  For details about
values, see I<insert_hash>, I<update_hash>, and I<get_insert_values>
methods.

    $enter->_update_or_insert(%hash);

=cut

sub _update_or_insert {
    my ($self, %args) = @_;

    my $log = Log::Log4perl->get_logger('');

    my $vals = $self->get_insert_values(%args);

    my $table = $args{'table'};
    my $dry_run = $args{'dry_run'};

    my $update_args = $args{'update_args'} // {};

    my ($change_update, $change_insert) = $self->prepare_update_hash(
        @args{qw/table dbhandle/}, $vals, %$update_args);

    if (scalar @$change_insert) {
        $change_insert = $self->_apply_kludge_for_COMMON($change_insert)
            if 'COMMON' eq $table ;

        $self->insert_hash(
            insert => $change_insert,
            dry_run => $dry_run,
            map {$_ => $args{$_}} qw/table dbhandle/);
    }

    if (scalar @$change_update) {
        $self->update_hash(@args{qw/table dbhandle/}, $change_update,
                           dry_run => $dry_run);

    }

    return $args{'dbhandle'}->errstr;
}

# KLUDGE to avoid duplicate inserts due to same obsid.  First hash reference
# most likely have undef (AZ|AM|EL)(START|END).
sub _apply_kludge_for_COMMON {
    my ($self, $vals) = @_;

    return unless ref $vals eq 'ARRAY'
               || 1 < scalar @{$vals};

    my %val;
    for my $v (@{$vals}) {
        # Last one "wins".
        $val{$v->{'obsid'}} = $v;
    }

    return [map {$val{$_}} keys %val];
}

=item B<_find_header>

Returns a list of header values or a truth value, given a hash with
I<headers> and I<name> as the required keys. Respective hash values
are a header hash reference and header name to search for.  B<Default>
behaviour is to B<return a truth value if the given header exists>.
Returns nothing if the header is missing or specified test fails.
C<SUBHEADERS> are also searched along with the main header hash.

    print 'OBSEND header exists'
        if $enter->_find_header('headers' => $hdrhash,
                                'name' => 'OBSEND');

Optional keys are ...

=over 2

=item I<test> "true" | "defined"

To Test for the header value being true or defined by providing
I<test> key with value of "true" or "defined".

    print 'OBSEND header value is defined'
        if $enter->_find_header('headers' => $hdrhash,
                                'name' => 'OBSEND',
                                'test' => 'defined');

=item I<value> any value

To receive header value when defined, specify the I<value> key (with
any value).

    use Data::Dumper;
    print "OBSEND header value if present: ",
        Dumper( $enter->_find_header('headers' => $hdrhash,
                                     'name'  => 'OBSEND',
                                     'value' => undef));

=item I<value-regex> regex

To actually match header value, specify I<value-regex> key with value
of a regular expression, in which case I<C<value> is ignored>.

    print "OBS_TYPE is 'skydip'."
        if $enter->_find_header('headers' => $hdrhash,
                                'name'  => 'OBS_TYPE',
                                'value-regex' => qr/\b skydip \b/xi);

=back

=cut

sub _find_header {
    my ($self, %args) = @_;
    my ($head, $name, $val_re) =
      @args{qw/headers name value-regex/};

    defined $val_re && ! ref $val_re
        and $val_re = qr/\b${val_re}\b/x;

    my $test = sub {
        my ($head, $key) = @_;

        return unless exists $head->{$key};
        foreach ($args{'test'}) {
            last unless defined $args{'test'};

            return !! $head->{$key} if $_ eq 'true';

            return defined $head->{ $key } if $_ eq 'defined';
        }

        return 1;
    };

    my $array = ref $head eq 'ARRAY';

    foreach my $h ($array ? @{$head} : $head) {
        my $val = $test->($h, $name) ? $h->{$name} : undef;

        if (defined $val) {
            return $val =~ $val_re if defined $val_re;

            return 1 unless exists $args{'value'};

            return $val unless wantarray;

            $args{'store'}->{$val} = undef;
        }
    }

    if (wantarray and defined $args{'store'}) {
        my %seen;
        return grep ! $seen{$_} ++,
               keys %{$args{'store'}};
    }

    # Only one level of indirection is checked, i.e. header inside "SUBHEADER"
    # pseudo header with array reference of hash references as value.
    return if $array;

    my $subh = 'SUBHEADERS';
    return $self->_find_header(%args, 'headers' => $head->{$subh})
        if exists $head->{$subh};

    return;
}

sub _make_lowercase_header {
    my ($self, %args) = @_;

    my ($head, $name) = @args{qw/headers name/};

    return unless $head && ref $head;

    my $is_array = ref $head eq 'ARRAY';

    foreach my $h ($is_array ? @{$head} : $head) {
        next unless exists $h->{$name};

        my $type = ref $h->{$name};

        unless ($type) {
            $h->{$name} = uc $h->{$name};
            $args{'_case-changed'} ++;
            next;
        }

        if ($type eq 'ARRAY') {
            $h->{ $name } = [ map uc $_, @{ $h->{ $name } } ];
            $args{'_case-changed'}++;
            next;
        }

        if ($type eq 'HASH') {
            for my $k (keys %{$h->{$name}}) {
                $h->{$name}{$k} = lc $h->{$name}{$k};
                $args{'_case-changed'} ++;
            }
        }
    }

    # Only one level of indirection is checked, i.e. header inside "SUBHEADER"
    # pseudo header with array reference of hash references as value.
    return $args{'_case-changed'} if $is_array;

    my $subh = 'SUBHEADERS';
    return $self->_make_lowercase_header(%args, 'headers' => $head->{$subh})
        if exists $head->{$subh};

    return $args{'_case-changed'};
}

=item B<_is_insert_dup_error>

Returns a truth value to indicate if the error was due to insertion of duplicate
row, given a plain string or an L<Error> object.  It compares the expected
Sybase error text.

    $dbh->rollback
        if $enter->_is_insert_dup_error($dbh->errstr);

=cut

sub _is_insert_dup_error {
    my ($self, $err) = @_;

    my $text = ref $err ? $err->text : $err;

    return $text && $text =~ /duplicate entry/i;
}

=item B<_dataverify_obj_fail_text>

Given an observation returns a string to log, to die with when JCMT::DataVerify
object cannot be created.

    die _dataverify_obj_fail_text($obs);

Optionally accepts a string to be printed before observation summary (see
L<OMP::Info::Obs>). It also accepts an optional integer for that many space of
indent.

=cut

sub _dataverify_obj_fail_text {
    my ($obs, $prefix , $indent) = @_;

    $prefix //= 'Could not make JCMT::DataVerify object;';

    $indent //= 2;

    my $title_space = (' ') x $indent;
    my $data_space  = ($title_space) x $indent;

    my $files;
    my @file = sort grep {defined $_} $obs->filename();
    if (scalar @file) {
        $files = $title_space
               . 'obs file '
               . (scalar @file > 1
                    ? "range:\n" . $data_space . join (' - ', @file[0, -1])
                    : ":\n"      . $data_space . $file[0]);
    }

    my $summ = $obs->summary('text');

    if (defined $summ) {
        $summ =~ s/^/$data_space/mg;
        $summ = $title_space . "obs summary:\n" . $summ;
    }

    return unless (defined $files || defined $summ);

    return join "\n",
        $prefix,
        grep {defined $_ && length $_} $files, $summ;
}

=item B<_verify_dict>

Verifies that the data dictionary (set via I<new> method) is a
readable file.  On errors, throws L<JSA::Error::FatalError>
exceptions, else returns true.

    $ok = $enter->_verify_dict;

=cut

sub _verify_dict {
    my ($self) = @_;

    my $dict = $self->get_dict;

    throw JSA::Error::FatalError('No valid data dictionary given')
        unless defined $dict ;

    throw JSA::Error::FatalError("Data dictionary, $dict, is not a readable file.")
        unless -f $dict && -r _;

    return 1;
}

=item B<_verify_file_name>

Verifies that a file name is in format matching
C<{^ a 2\d{7} _ \d+ _ \d+ _ \d+ \. sdf $}x>, e.g.
C<a20080726_00001_01_0001.sdf>.  File names can be given either as
plain scalar or in an array reference.

Throws C<JSA::Error> with a message listing all the file names in
unexpected format.  Else, it simply returns.

=cut

sub _verify_file_name {
    my ($name) = @_;

    return unless defined $name;

    my @bad;
    for my $n (ref $name ? @{$name} : $name) {
        push @bad, $n unless looks_like_rawfile($n);
    }

    my $size = scalar @bad;

    return unless $size;

    throw JSA::Error sprintf "Bad file name%s: %s\n",
                             ($size > 1 ? 's' : ''), join ', ', @bad ;
}

# JSA::DB::TableTransfer object, to be created as needed.
# $dbh can be a subroutine reference, in which case it is called
# to get the database handle.  (This is so that, if the name is found
# in the cache, we need not make a new handle.)
{
    my %xfer;

    sub _get_xfer {
        my ($self, $dbh, $name) = @_;

        $name ||= 'default-xfer';

        return $xfer{$name}
            if exists  $xfer{$name}
            && defined $xfer{$name};

        if ('CODE' eq ref $dbh) {
            $dbh = $dbh->();
        }

        return $xfer{$name} =
            JSA::DB::TableTransfer->new('dbhandle'     => $dbh,
                                        'transactions' => 0);
    }
}

=item B<_get_xfer_unconnected_dbh>

It is similar to above I<_get_xfer> method about what it accepts and
returns.  Difference is that this method uses a new database handle
unconnected to the one used elsewhere.  (Note it's not entirely
unconnected -- if the default (or a previous) name is used, then
a cached object is returned.

=cut

sub _get_xfer_unconnected_dbh {
    my ($self, $name) = @_;

    $name ||= 'xfer-new-dbh';

    return $self->_get_xfer(sub {
            my $db = JSA::DB->new('name' => $name);
            $db->use_transaction(0);
            return $db->dbhandle();
        }, $name);
}

sub _compare_dates {
    my ($new, $old) = @_;

    # Sometimes a date-time value only has date, in which case time is appended
    # without a 'T'.
    $new =~ s/ /T/;

    $new = make_datetime($new);
    $old = make_datetime($old);

    return $new > $old;
}

sub _find_extreme_value {
    my (%arg) = @_;

    my $gt = $arg{'new>old'};
    my ($old, $new, $start, $end) = @arg{qw/old new start end/};

    # Smaller|earlier value.
    if ($start) {
        return ! $gt ? $new : $old;
    }

    # Larger|later value.
    if ($end) {
        return $gt ? $new : $old;
    }

    throw JSA::Error "Neither 'start' nor 'end' type was specified";
}

sub _basename {
    return unless scalar @_;

    require File::Basename;
    my ($base) = File::Basename::fileparse($_[0]);
    return $base;
}

sub _file_template {
    my ($prefix) = @_;

    return sprintf '/tmp/_%s-%s',
                   ($prefix // 'EnterData'),
                   join '', ('X') x 10;
}

# Note: methods below were imported from the calcbounds script.

sub calcbounds_find_files {
    my $self = shift;
    my %opt = @_;

    my $date = $opt{'date'};

    my $log = Log::Log4perl->get_logger('');

    my @file;
    unless ($opt{'avoid-db'}) {
        @file = $self->calcbounds_files_from_db(date => $date, obs_types => $opt{'obs_types'})
            or $log->info('Did not find any file paths in database.');
    }
    else {
        $log->error_die('No date given to find files.')
            unless $date;

        $log->info('Avoiding database for file paths.');

        @file = $self->calcbounds_files_for_date(date => $date)
            or $log->error('Could not find any readbles files for ',
                           'given file paths, file list, or date.');
    }

    return \@file;
}

sub calcbounds_files_for_date {
    my $self = shift;
    my %opt = @_;

    my $date = $opt{'date'};
    my ($inst) = $self->instruments();

    my $log = Log::Log4perl->get_logger('');

    if (! $date
            || $date !~ /^\d{8}$/
            || (ref $date && ! $date->isa('Time::Piece'))) {
        $log->error_die(sprintf "Bad date, '%s', given.\n",
                                defined $date ? $date : 'undef');
        return;
    }

    my $date_string = ref $date ? $date->ymd('') : $date;

    $log->debug('Finding files for date ', $date_string);

    # O::FileUtils requires date to be Time::Piece object.
    $date = Time::Piece->strptime($date, '%Y%m%d')
        unless ref $date;

    my @file;

    $log->debug('finding files for instrument ', $inst->name());

    push @file, OMP::FileUtils->files_on_disk('date'       => $date,
                                              'instrument' => $inst->name());

    $log->debug('Files found for date ', $date_string, ' : ', scalar @file);

    # Expand array references whcih come out from FileUtils sometimes.
    return map {$_ && ref $_ ? @{$_} : $_} @file;
}

sub calcbounds_files_from_db {
    my $self = shift;
    my %opt = @_;

    my $date = $opt{'date'};
    my $obs_types = $opt{'obs_types'};

    my ($inst) = $self->instruments();

    my $log = Log::Log4perl->get_logger('');

    $log->error_die('An instrument object was not given.')
        unless ($inst && ref $inst && $inst->can('name'));

    my $pattern = lc sprintf '%s%%', substr $inst->name(), 0, 1;
    $pattern = sprintf '%s%s%%', $pattern, $date if $date;

    $log->info('Getting file paths from database matching ', $pattern);

    # obsra & -dec may be null but not *{tl,tr,bl,br} if bounds do exist.
    my $sql = sprintf('SELECT f.file_id
        FROM COMMON c, FILES f
        WHERE c.obsid = f.obsid
          AND f.file_id like ?
          AND c.utdate = ?
          AND c.obs_type IN ( %s )
          AND ( c.obsra IS NULL and c.obsdec IS NULL )',
        join(',', ('?') x scalar @$obs_types));

    my $jdb = new JSA::DB();
    my $tmp = $jdb->run_select_sql(
        'sql'    => $sql,
        'values' => [$pattern, $date, @$obs_types]);

    my @file;
    @file = $inst->make_raw_paths(map {$_->{'file_id'}} @{$tmp})
        if $tmp
        && ref $tmp
        && scalar @{ $tmp };

    $log->debug('Found file paths in database: ' , scalar @file);

    return @file;
}

sub calcbounds_update_bound_cols {
    my ($self, %arg) = @_;
    my $dry_run = $arg{'dry_run'};
    my $skip_state = $arg{'skip_state'};
    my $skip_state_found = $arg{'skip_state_found'};
    my $obs_types = $arg{'obs_types'};

    # Transitional: set files and date in the object if given.
    $self->files($arg{'files'}) if exists $arg{'files'};
    $self->date($arg{'date'}) if exists $arg{'date'};

    my ($inst) = $self->instruments();

    my $n_err = 0;

    my $process_obs_re = join '|', @$obs_types;
       $process_obs_re = qr{\b( $process_obs_re )}xi;

    my $obs_list = $self->calcbounds_make_obs(
            dry_run => $dry_run,
            skip_state => ($skip_state or $skip_state_found))
        or return;

    my $log = Log::Log4perl->get_logger('');

    my @bound =
        # ";" is to indicate to Perl that "{" starts a BLOCK not an EXPR.
        map {; "obsra$_" , "obsdec$_"} ('', qw/tl bl tr br/);

    my $db = new OMP::DBbackend::Archive();
    my $dbh = $db->handle;

    my $table = 'COMMON';
    my %pass = (
        'dbhandle' => $dbh,
        'table'    => $table,
        # This is a hash reference, not just $cols, in order to cater to needs of
        # JSA::EnterData->get_insert_values().
        'columns'  => {$table => $self->get_columns($table, $dbh)},
        'dict'     => {$self->create_dictionary()},
    );

    my $inst_scuba2 = $inst->can('name') ? $inst->name() : '';
       $inst_scuba2 = JSA::EnterData::SCUBA2->name_is_scuba2($inst_scuba2);

    for my $obs (@{$obs_list}) {
        my @subsys_obs = $obs->subsystems()
          or next;

        my $common = $subsys_obs[0];
        my %header = %{$common->hdrhash()};

        my $obs_type;
        foreach my $name (map {; $_ , uc $_ } qw/obstype obs_type/) {
            if ( exists $header{$name} ) {
                $obs_type = $header{$name};
                last;
            }
        }

        next unless $obs_type;

        my $found_type = ($obs_type =~ $process_obs_re)[0]
            or next;

        my @file_id = map {$_->simple_filename()} @subsys_obs;

        $log->info(join "\n    ", 'Processing files', @file_id);

        if ($inst_scuba2) {
            unless (_calcbounds_any_header_sub_val(\%header, 'SEQ_TYPE', $found_type)) {
                $log->debug('  skipped uninteresting SEQ_TYPE');
                next;
            }

            if ($self->calcbounds_find_dark(\%header)) {
                $log->debug('  skipped dark.');
                next;
            }
        }

        _fix_dates(\%header);

        $log->debug('  calculating bounds');

        unless ($self->calc_radec($inst, $common, \%header)) {
            $log->error('  ERROR  while finding bounds');

            unless ($dry_run or $skip_state) {
                $log->debug('Setting file paths with error state');
                my $xfer = $self->_get_xfer_unconnected_dbh();
                $xfer->put_state(
                        state => 'error', files => \@file_id,
                        comment => 'bound calc');
            }

            $n_err ++;
            next;
        }

        unless (any {exists $header{$_}} @bound) {
            $log->warn('  did not find any bound values.');
            return;
        }

        $log->info('  UPDATING headers with bounds');

        $self->_update_or_insert(%pass,
                                 'headers'  => \%header,
                                 dry_run    => $dry_run,
                                 update_args => {update_only_obsradec => 1});
    }

    return $n_err;
}

sub calcbounds_make_obs {
    my ($self, %opt) = @_;
    my $dry_run = $opt{'dry_run'};
    my $skip_state = $opt{'skip_state'};

    my ($inst) = $self->instruments();

    my $log = Log::Log4perl->get_logger('');

    my $group = $self->_get_obs_group(
            'name' => $inst->name(),
            dry_run => $dry_run,
            skip_state => $skip_state,
            ($self->files_given() ? ('given-files' => 1) : ()))
        or do {
            $log->warn('Could not make obs group.');
            return;
        };

    my @obs = $group->obs()
        or do {
            $log->warn( 'Could not find any observations.' );
            return;
        };

    @obs = $self->_filter_header($inst, \@obs,
                                  'OBS_TYPE' => [qw/FLATFIELD/]);

    return unless scalar @obs;
    return \@obs;
}

sub calcbounds_find_dark {
    my ($self, $header) = @_;

    my ($inst) = $self->instruments();

    return unless $inst->can('_is_dark');

    my $dark = $inst->_is_dark($header);
    foreach my $sh (exists $header->{'SUBHEADERS'}
                         ? @{$header->{'SUBHEADERS'}}
                         : ()) {
        $dark =  $inst->_is_dark($sh)
          or last;
    }

    return $dark;
}

=back

=head2 FUNCTIONS

=over 2

=item B<calculate_release_date>

Calculate the release date to be written into the COMMON table
given an OMP::Info::Obs object.

    my $release_date = calculate_release_date($obs);

Create release date (end of semester + one year) for the general
case but for OBSTYPE != SCIENCE or STANDARD=T the release date is
immediate.

CLS special since its data is protected until one year after the
end of semester 14B.

=cut

sub calculate_release_date {
    my $obs = shift;

    # Get date of observation
    my $obsdate = $obs->utdate;

    if ( $obs->projectid =~ /^mjlsc/i && $obs->isScience) {
        # CLS. Should properly check the SURVEY FITS header
        return DateTime->new('month' => 3,
                             'year' => 2016,
                             'day' => 1,
                             'hour' => 23,
                             'minute' => 59,
                             'second' => 59,
                             'time_zone' => 'UTC');

    }
    elsif ($obs->projectid =~ /ec05$/i && $obs->isScience) {
        # EC05 is a public calibrator monitoring project
        return OMP::DateTools->yesterday(1);

    }
    elsif ($obs->projectid =~ /ec/i) {
        # Do not release EC data.

        return DateTime->new('month' => 1,
                             'year' => 2031,
                             'day' => 1,
                             'hour' => 0,
                             'minute' => 0,
                             'second' => 0,
                             'time_zone' => 0);

    }
    elsif ($obs->isScience) {
        # semester release
        my $semester = OMP::DateTools->determine_semester(date => $obsdate,
                                                          tel => 'JCMT');
        my ($sem_begin, $sem_end) =
            OMP::DateTools->semester_boundary(semester => $semester,
                                              tel => 'JCMT');

        # Use DateTime so that we can have proper addition. Add 1 year 1 day because
        # sem_end refers to the UT date and doesn't specify hours/minutes/seconds
        return DateTime->from_epoch(epoch => $sem_end->epoch,
                                    time_zone => 'UTC')
             + DateTime::Duration->new(years => 1, hours => 23,
                                       minutes => 59, seconds => 59);

    }
    else {
        # immediate release
        return OMP::DateTools->yesterday(1);
    }
}

# Note: functions below were imported from the calcbounds script.

sub _calcbounds_check_hash_val {
    my ($href, $key, $check) = @_;

    return
        unless $href
            && $key
            && $check
            && exists $href->{$key};

    my $string = $href->{$key};

    return unless defined $string;

    # Compiled regex given.
    if (ref $check) {
        my ($found) = ($string =~ $check);
        return $found;
    }

    return $string if $string eq $check;

    return;
}

sub _calcbounds_any_header_sub_val {
    my ($header, $key, $check) = @_;

    my $found = _calcbounds_check_hash_val($header, $key, $check);
    return $found if $found;

    if (exists $header->{'SUBHEADERS'}) {
        for my $sh (@{$header->{'SUBHEADERS'}}) {
            $found = _calcbounds_check_hash_val($sh, $key, $check);
            return $found if $found;
        }
    }

    return;
}


1;

__END__

=back

=head1 NOTES

Skips any data files that are from simulated runs (SIMULATE=T).

=head1 AUTHORS

=over 2

=item *

Anubhav E<lt>a.agarwal@jach.hawaii.eduE<gt>

=item *

Kynan Delorey E<lt>k.delorey@jach.hawaii.eduE<gt>

=item *

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

=back

Copyright (C) 2006-2014, Science and Technology Facilities Council.
Copyright (C) 2015 East Asian Observatory
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
