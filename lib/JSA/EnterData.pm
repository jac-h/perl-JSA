package JAS::EnterData;

BEGIN {
  use constant OMPLIB => '/jac_sw/omp/msbserver';

  $ENV{SYBASE} = "/local/progs/sybase" unless exists $ENV{SYBASE};
  $ENV{OMP_CFG_DIR} = OMPLIB."/cfg";
  $ENV{OMP_SITE_CONFIG} = "/home/jcmtarch/enterdata-cfg/enterdata.cfg";
}

use strict;
use warnings;
use FindBin;

use lib OMPLIB;
use lib "$FindBin::RealBin/../perlmods/JCMT-DataVerify/lib";

use Data::Dumper;
use File::Temp;
use Scalar::Util qw/ looks_like_number /;

use Astro::Coords::Angle::Hour;

use JCMT::DataVerify;

use OMP::DBbackend::Archive;
use OMP::Info::ObsGroup;
use OMP::General;

use DateTime;
use Time::Piece;
use Time::Seconds;

use NDF;

$| = 1; # Make unbuffered

# Make sure that bad status from SMURF triggers bad exit status
BEGIN {
  $ENV{ADAM_EXIT} = 1;
}

# Debugging.  Set to true to turn on.  Debugging means interact
# with the database, but don't actually do any inserts, and be
# very verbose.
our $debug = 0;

# Upload to header database?
our $MODDB = 1;

# Update mode
our $UPDATE = 0;

# Sybase date format
my $syb_date = '%Y-%m-%d %H:%M:%S';

# Force observation queries to query files on disk rather than
# the database.
$OMP::ArchiveDB::SkipDBLookup = 1;

# Instruments known to the database
my @instruments = qw/ACSIS/;

# Location of data dictionary
# NOTE: This should go in to the OMP config system at some point

my $dictionary =  $FindBin::RealBin. "/import/data.dictionary";

# Tables of interest.  All instruments reference the COMMON table, so it is
# first on the array.  Actual instrument table will be the second element.
my @tables = qw/COMMON/;

# Get the current date, unless one was supplied on the command line
my $date = $ARGV[0];
$date =
  $date && $date =~ /^\d{8}/
  ? Time::Piece->strptime($ARGV[0], "%Y%m%d")
  : localtime;

# Instantiate the archive database object
my $adb = OMP::DBbackend::Archive->new;

# Get the database handle
my $dbh;
$dbh = $adb->handle if defined $adb;

# The %columns hash will contain a key for each table, each key's value
# being an anonymous hash containing the column information.  Store this
# information for the COMMON table initially.
my %columns;
$columns{$tables[0]} = get_columns( $tables[0], $dbh );

# Read in dictionary contents
my %dict = create_dictionary($dictionary);

# Store observation objects for global access
my %observations;

for my $inst (@instruments) {
  print "Inserting data for [$inst] Date [". $date->ymd ."]\n";

  # Place instrument table on the tables array
  $tables[1] = $inst;

  # Retrieve instrument table columns
  $columns{$inst} = get_columns($inst, $dbh);
  $columns{FILES} = get_columns('FILES', $dbh);

  # Retrieve observations from disk
  # An Info::Obs object will be returned for each subscan
  # in the observation. No need to retrieve associated obslog comments
  # That's no. of subsystems used * no. of subscans objects
  # returned per observation.
  my $grp = new OMP::Info::ObsGroup(instrument => $inst,
                                    date => $date,
                                    nocomments => 1,
                                    retainhdr => 1,
                                    ignorebad => 1,);

  # Store observation objects in @obs
  my @obs = $grp->obs;

  # Go to next instrument if no observations returned
  if (! $obs[0]) {
    print "\tNo observations found for instrument $inst\n\n";
    next;
  }

  # Need to create a hash with keys corresponding to the observation
  # number (an array won't be very efficient since observations can be
  # missing and run numbers can be large). The values in this hash have
  # to be a reference to an array of Info::Obs objects representing each
  # subsystem. We need to construct new Obs objects based on the subsystem
  # number.  $observations{$runnr}->[$subsys_number] should be an Info::Obs object.

  for my $obs (@obs) {
    my $hdrref = $obs->hdrhash;
    my @subhdrs = $obs->subsystems;
    $observations{$obs->runnr} = \@subhdrs;
  }

  # For each observation:
  # 1. Insert a row in the COMMON table.
  # 2. Insert a row in the [INSTRUMENT] table for each subsystem used.
  # 3. Insert a row in the FILES table for each subscan
  #
  # Group all steps together in a single transaction, so that if any
  # insert fails, the entire observation fails to go in to the DB.

 OBS: for my $runnr (sort {$a <=> $b} keys %observations) {

    # Obtain COMMON table values from first obs object in the observation
    my $common_obs = $observations{$runnr}->[0];
    my $common_hdrs = $common_obs->hdrhash;

    print "\t[". join(",",$common_obs->simple_filename) ."] ... ";

    # Skip observation if SIMULATE header = T
    if (($common_hdrs->{SIMULATE})) {
      print "simulation data. Skipping\n";
      next;
    }

    # Verify the headers, and set invalid headers to undef
    my $verify = new JCMT::DataVerify(Obs => $common_obs);
    my %invalid = $verify->verify_headers;

    for (keys %invalid) {
      if ($invalid{$_}->[0] =~ /does not match/) {
        $common_hdrs->{$_} = undef;
      } elsif ($invalid{$_}->[0] =~ /should not/) {
        if ($common_hdrs->{$_} =~ /^UNDEF/) {
          $common_hdrs->{$_} = undef;
        }
      }
    }

    # Calculate RA/Dec (ICRS) extent and base position of observation
    # Both subsystems are identical so we only have to do this with the first one
    my $cstat = calc_radec( $common_obs, $common_hdrs );
    next unless $cstat;

    # Begin transaction
    $dbh->begin_work if $MODDB;

    my $error;

    # Create headers that don't exist
    create_headers('COMMON', $common_obs, $common_hdrs);

    # Create hash reference for named insert
    my $insert_ref = get_insert_values('COMMON', \%columns, \%dict, $common_hdrs);

    # Do insert
    my $error = _update_or_insert( 'COMMON', $dbh, $insert_ref );

    if ($error) {
      $dbh->rollback;
      if ($error =~ /insert duplicate key row/) {
        print "File metadata already present\n";
      } else {
        print "$error\n\n";
      }
      next;
    }

    add_subsys_obs( $dbh, $observations{$runnr}, \%columns, \%dict )
      or next OBS;

    # End transaction
    $dbh->commit if $MODDB;

    print "successful\n";

  }
}

# Close database connection
$adb->disconnect if defined $adb;

#---------------------- Subroutines ----------------------

# get_columns:  Given a table name and a DBI database handle object,
#               return a hash reference containing columns with
#               their associated data types.
#
#               get_columns( $table, $dbh )

sub get_columns {
  my $table = shift;
  my $dbh = shift;
  my %result;
  return {} unless defined $dbh;

  # Do query to retrieve column info (using the sp_columns stored procedure)
  my $col_href = $dbh->selectall_hashref("sp_columns $table", "column_name")
     or die "Could not obtain column information for table [$table]:". $dbh->errstr ."\n";

  for my $col (keys %$col_href) {

    # Get data type value from the type_name column
    $result{$col} = $col_href->{$col}{type_name};
  }

  return \%result;
}

# get_insert_values:  Given a table name, a hash reference containing
#                     table column information (see global hash %columns),
#                     a hash reference containing the dictionary contents,
#                     and a hash reference containing observation headers,
#                     return a hash reference with the table's columns as the
#                     keys, and the insertion values as the values.
#
#                     get_insert_values( $table, \%columns, \%dictionary, \%hdrhash );

sub get_insert_values {
  my $table = shift;
  my $columns = shift;
  my $dictionary = shift;
  my $hdrhash = shift;

  # Map headers to columns, translating from the dictionary as
  # necessary.
  my %values;
  for my $header (keys %$hdrhash) {
    if (exists $columns{$table}{lc($header)}) {

      # Column exists, no need to translate
      $values{lc($header)} = $hdrhash->{$header};
    } else {

      # Header not found, try translating
      if (exists $dictionary->{lc($header)} and exists $columns{$table}{$dictionary->{lc($header)}}) {

        # Found header alias in dictionary and column exists in table
        my $alias = $dictionary->{lc($header)};
        $values{$alias} = $hdrhash->{$header};

        print "Mapped header [$header] to column [$alias]\n"
          if ($debug);
      }
    }
    print "Could not find alias for header [$header]. Skipped.\n"
      if ($debug and ! exists $values{lc($header)});
  }

  # Do value transformation
  transform_value($table, $columns, \%values);

  return \%values;
}

sub add_subsys_obs {

  my ( $dbh, $obs, $cols, $dict ) = @_;

  my $subsysnr = 0;
  my $totsub = scalar @{ $obs };

  for my $subsys_obs ( @{ $obs } ) {
    $subsysnr++;
    print "Processing subsysnr $subsysnr of $totsub\n";

    # Obtain instrument table values from this Obs object
    my $subsys_hdrs = $subsys_obs->hdrhash;

    # Need to calculate the frequency information
    calc_freq( $subsys_obs, $subsys_hdrs );

    # Create headers that don't exist
    create_headers('ACSIS', $subsys_obs, $subsys_hdrs);

    my $insert_ref = get_insert_values('ACSIS', $cols, $dict, $subsys_hdrs);

    my $error = _update_or_insert( 'ACSIS', $dbh, $insert_ref );

    if ($error) {
      $dbh->rollback if $MODDB;
      print "$error\n\n";
      return;
    }

    # Create headers that don't exist
    create_headers('FILES', $subsys_obs, $subsys_hdrs);

    $insert_ref = get_insert_values('FILES', $cols, $dict, $subsys_hdrs);

    if (!$UPDATE) {
      insert_hash('FILES', $dbh, $insert_ref)
        or $error = $dbh->errstr;
    }
    if ($error) {
      $dbh->rollback;
      print "$error\n\n";
      return;
    }
  }

  return 1;
}

sub _update_or_insert {

  my $ok = $UPDATE ? &update_hash : &insert_hash;
  return $dbh->errstr;
}

# update_hash:  Given a table name, a DBI database handle and
#               a hash reference, retrieve the current data values
#               based on OBSID or OBSID_SUBSYSNR, decide what has changed
#               and update the values
#
#               update_hash( $table, $dbh, \%to_update );
#
#               No-op for files table at the present time

sub update_hash {
  my ($table, $dbh, $field_values) = @_;

  return if $table eq 'FILES';

  # work out which key uniquely identifies the row
  my $unique_key;

  if ($table eq 'COMMON') {
    $unique_key = "obsid";
  } elsif ($table eq 'ACSIS' || $table eq 'FILES') {
    $unique_key = "obsid_subsysnr";
  } else {
    die "Major problem with table name: '$table'\n";
  }
  my $unique_val = $field_values->{$unique_key};

  # run a query with this unique value (but on FILES table more than
  # one entry can be returned - we trap that because FILES for the minute
  # should not need updating

  my $sql = "select * from $table where $unique_key = '$unique_val'";
  my $ref = $dbh->selectall_arrayref( $sql, { Columns=>{} })
    or die("Error retrieving existing content using [$sql]:". $dbh->errstr);

  die "Only retrieved partial dataset: ".$dbh->errstr if $dbh->err;

  # how many rows
  die "Can only update if the row exists previously! Obsid $unique_val missing.\n"
    if @$ref == 0;
  die "Should not be possible to have more than one row. Got ".scalar(@$ref) if (@$ref > 1);
  my $indb = $ref->[0];

  my %differ;

  for my $key (keys %{$indb}) {
    next if $key eq 'last_modified'; # since that will update automatically
    if (exists $field_values->{$key}) {
      my $new = $field_values->{$key};
      my $old = $indb->{$key};

      if (defined $new && defined $old) {

        # Dates
        if ($old =~ /\d\d[AP]M$/ && $new =~ /^\d\d\d\d-\d\d-\d\d/) {
          # just assume that if both dates are there they are correct without parsing
          $new = $old;
        }

        if (looks_like_number($new)) {
          if ($new =~ /\./) {
            # floating point
            my $diff = abs($old - $new);
            if ($diff > 0.000001) {
              $differ{$key} = $new;
              # print "$key :Floating point $new != $old ($diff)\n";
            }
          } elsif ($new != $old) {
            $differ{$key} = $new;
          }
        } else {
          # string compare
          if ($new ne $old) {
            $differ{$key} = $new;
          }
        }
      } elsif (defined $new) {
        # not defined currently - inserting new value
        $differ{$key} = $new;
      } elsif (defined $old) {
        # defined in DB but undef in new version - not expecting this but assume this
        # means a null
        $differ{$key} = undef;
      } else {
        # both undef so nothing to do
      }
    }
  }

  return 1 unless keys %differ;

  # Now have to do an UPDATE
  $sql = "UPDATE $table SET ";
  my @changes;
  if (!$debug && $MODDB) {
    # real version with placeholders
    @changes = map { "$_ = ? " } sort keys %differ;
  } else {
    # debug version with unquoted values
    @changes = map { "$_ = $differ{$_} " } sort keys %differ;
  }
  $sql .= join(", ", @changes );
  $sql .= " where $unique_key = '$unique_val'";

  if (!$debug && $MODDB) {
    my $sth = $dbh->prepare($sql)
      or die "Could not prepare sql statement for insert\n". $dbh->errstr. "\n";
    my $status = $sth->execute( map { $differ{$_} } sort keys %differ );
    return $status if !$status; # return bad status
  } else {
    print "$sql\n";
  }
  return 1;
}

# insert_hash:  Given a table name, a DBI database handle and a
#               hash reference, insert the hash's contents into
#               the table.  Basically a named insert.  Returns the
#               executed statement output.  Copied from example in
#               DBI.pm.
#
#               If any of the values in %to_insert are array references
#               multiple rows will be inserted corresponding to the content.
#               If more than one row has an array reference the size of those
#               arrays must be identical.
#
#               insert_hash($table, $dbh, \%to_insert);

sub insert_hash {
  my ($table, $dbh, $field_values) = @_;

  # Go through the hash and work out whether we have multiple inserts
  my @have_ref;
  my $nrows = 1;
  for my $key (keys %$field_values) {
    if (ref($field_values->{$key})) {
      if (ref($field_values->{$key}) eq 'ARRAY' ) {
        my $row_count = scalar(@{$field_values->{$key}});
        if (@have_ref) {
          # count rows
          die "Uneven row count in insert hash ARRAY ref for key '$key' ($row_count != $nrows) compared to first key '$have_ref[0]' (table $table)\n"
            unless $row_count == $nrows;
        } else {
          $nrows = $row_count;
        }
        push(@have_ref, $key);
      } else {
        die "Unsupported reference type in insert hash!\n";
      }
    }
  }

  # Now create an array of insert hashes with array references unrolled
  my @insert_hashes;
  if (!@have_ref) {
    @insert_hashes = ( $field_values );
  } else {
    # take local copy of the array content so that we do not damage caller hash
    my %local = map { $_ => [ @{$field_values->{$_}} ] } @have_ref;

    # loop over the known number of rows
    for my $i (0..($nrows-1)) {
      my %row = %$field_values;
      for my $refkey (@have_ref) {
        $row{$refkey} = shift( @{$local{$refkey}});
      }
      push(@insert_hashes, \%row);
    }

  }


  # Get the fields in sorted order (so that we can match with values)
  # and create a template SQL statement. This can be done with the
  # first hash from @insert_hashes

  my @fields = sort keys %{$insert_hashes[0]}; # sort required
  my $sql = sprintf "insert into %s (%s) values (%s)",
    $table, join(",", @fields), join(",", ("?")x@fields);

  # cache the SQL statement
  my $sth;

  if (!$debug && $MODDB) {
    $sth = $dbh->prepare($sql)
      or die "Could not prepare sql statement for insert\n". $dbh->errstr ."\n";
  }

  # and insert all the rows
  for my $row (@insert_hashes) {
    my @values = @{$row}{@fields}; # hash slice
    if ($debug) {
      # print out some SQL that is not going to be executed
      for (@values) {
        if (defined $_) {
          if ($_ =~ /([a-zA-Z]|\s+)/ and $_ !~ /e\+/) {
            $_ = "\'$_\'";
          }
        } else {
          $_ = 'NULL';
        }
      }
      my $debug_sql = sprintf "insert into %s (%s) values (%s)",
         $table, join(",", @fields), join(",", @values);

      print "-----> SQL: $debug_sql\n";
    } elsif ($MODDB) {
      my $status = $sth->execute(@values);
      return $status if !$status; # return if bad status
    }
  }
  return 1;
}

# transform_value:  Given a table name, column name, and value
#                   to be inserted in a table, alter the
#                   value if the database expects the value
#                   to be in a different format than that of the
#                   headers
#
#                   transform_value($table, \%columns, \%values);

sub transform_value {
  my $table = shift;
  my $columns = shift;
  my $values = shift;

  # Transform data hash.  Each data type name contains a hash mapping
  # values from the headers to the values the database expects.
  my %transform_data = (
                        bit => {T => 1,
                                F => 0,},
                        int => {T => 1,
                                F => 0,},
                       );

  for my $column (keys %$values) {

    # Store column's current value
    my $val = $values->{$column};
    next unless defined($val);

    if (exists $columns->{$table}{$column}) {

      # Column is defined for this table, get the data type
      my $data_type = $columns->{$table}{$column};

      if ($data_type eq 'datetime' and $val =~ /T/) {

        # print "$column <---- ----> [$val]\n";

        # Convert date to sybase compatible
        my $date = Time::Piece->strptime($val,'%Y-%m-%dT%H:%M:%S');
        $values->{$column} = $date->strftime($syb_date);
        print "Converted date [$val] to [". $values->{$column} ."] for column [$column]\n"
          if ($debug);

      } elsif (exists $transform_data{$data_type}) {

        if (exists $transform_data{$data_type}{$val}) {

          # This value needs to be transformed to the new value
          # defined in the %transform_data hash
          $values->{$column} = $transform_data{$data_type}{$val};
          print "Transformed value [$val] to [". $values->{$column} ."] for column [$column]\n"
            if ($debug);
        }
      } elsif ($column eq 'lststart' or $column eq 'lstend') {

        # Convert LSTSTART and LSTEND to decimal hours
        my $ha = new Astro::Coords::Angle::Hour($val, units => 'sex');
        $values->{$column} = $ha->hours;
        print "Converted time [$val] to [". $values->{$column} ."] for column [$column]\n"
          if ($debug);
      }
    }
  }
  return 1;
}

# create_headers:  Create any headers that need to go into the database,
#                  but don't exist.  Currently these headers are:
#
#                  decj2000, decj2000_int, filename, idkey, raj2000,
#                  raj2000_int, ut_dmf, (and sometimes) RUN, UTDATE
#                  EXPOSED (out of date)
#
#                  These arguments should be provided in this order:
#                  name of the table to receive the headers,
#                  an OMP::Info::Obs object, and a reference to the
#                  header hash.  Returns true on success.
#
#                  create_headers( $common_table, $obs, \%headers );

sub create_headers {
  my $table = shift;
  my $obs = shift;
  my $headerref = shift;

  # Get date of observation
  my $obsdate = $obs->utdate;

  # Get obsid
  my $obsid = $obs->obsid;

  # Get runnr
  my $runnr = $obs->runnr;

  if ($table eq 'COMMON') {

    # Create release_date (end of semester + one year)
    # for the general case but for OBSTYPE != SCIENCE or
    # STANDARD=T the release date is immediate
    my $release_date;
    if ($obs->isScience) {
      # semester release
      my $semester = OMP::General->determine_semester( date => $obsdate,
                                                     tel => 'JCMT' );
      my ($sem_begin, $sem_end) = OMP::General->semester_boundary( semester => $semester,
                                                                   tel => 'JCMT' );

      # Use DateTime so that we can have proper addition. Add 1 year 1 day because
      # sem_end refers to the UT date and doesn't specify hours/minutes/seconds
      $release_date = DateTime->from_epoch( epoch => $sem_end->epoch, time_zone => 'UTC' )
        + DateTime::Duration->new( years => 1, hours => 23, minutes => 59, seconds => 59 );

    } else {
      # immediate release
      $release_date = OMP::General->yesterday(1);
    }
    $headerref->{release_date} = $release_date->strftime($syb_date);

    print "Created header [release_date] with value [". $headerref->{release_date} ."]\n"
      if ($debug);

    # Create last_modifed
    my $today = gmtime;
    $headerref->{last_modified} = $today->strftime($syb_date);
    print "Created header [last_modified] with value [". $headerref->{last_modified} ."]\n"
      if ($debug);

  } elsif ($table eq 'ACSIS') {

    # Create max_subscan
    my @subscans = $obs->simple_filename;
    $headerref->{max_subscan} = scalar(@subscans);
    print "Created header [max_subscan] with value [". $headerref->{max_subscan} ."]\n"
      if ($debug);

  } elsif ($table eq 'FILES') {

    # Create file_id - also need to extract NSUBSCAN from subheader if we have more
    # than one file. (although simply using a 1-based index would be sufficient)
    my @files = $obs->simple_filename;
    $headerref->{file_id} = \@files;

    # We need to know whether a nsubscan header is even required so %columns really
    # needs to be accessed. For now we kluge it.
    if (!exists $headerref->{nsubscan}) {
      if (scalar(@files) > 1) {
        $headerref->{nsubscan} = [ map { $_->value("NSUBSCAN") } $obs->fits->subhdrs ];
      } elsif (exists $headerref->{NSUBSCAN}) {
        # not really needed because the key becomes case insensitive
        $headerref->{nsubscan} = $headerref->{NSUBSCAN};
      } else {
        die "Internal error - NSUBSCAN does not exist yet there is only one file!";
      }
    }

    print "Created header [file_id] with value [". join(",",@{$headerref->{file_id}}) ."]\n"
      if ($debug);
  }

  if ($table eq 'ACSIS' || $table eq 'FILES') {

    # Create obsid_subsysnr
    $headerref->{obsid_subsysnr} = $obsid . "_" . $headerref->{SUBSYSNR};
    print "Created header [obsid_subsysnr] with value [". $headerref->{obsid_subsysnr} ."]\n"
      if ($debug);
  }

}

# get_max_idkey:  Given the COMMON table name and a database handle object,
#                 return the highest idkey/index in the COMMON table
#
#                 $idkey = get_max_idkey( $common_table, $dbh );

sub get_max_idkey {
  my $table = shift;
  my $dbh = shift;
  return 1 unless $MODDB;

  my $sth = $dbh->prepare_cached("select max(idkey) from $table");
  $sth->execute or die "Could not obtain max idkey: ". $dbh->errstr ."\n";
  my $result = $sth->fetchall_arrayref;
  my $max = $result->[0]->[0];

  return $max;
}

# create_dictionary:  Given the location of the data dictionary,
#                     return a hash containing the dictionary contents.
#
#                     %dictionary = create_dictionary( $dictionary );

sub create_dictionary {
  my $dictionary = shift;
  my %dict;

  open (my $DICT, "<", $dictionary )
    or die "Could not open data dictionary '$dictionary': $!\n";

  my @defs = grep {$_ !~ /^(#|\s)/} <$DICT>;  # Slurp!
  close($DICT) or die "Error closing data dictionary '$dictionary': $!\n";

  for my $def (@defs) {
    chomp $def;
    $def =~ s/\s+$//; # Remove trailing whitespace
    if ($def =~ /(.*?)\:\s(.*)/) {

      # Store each dictionary alias as a key whose value is a column name
      map {$dict{$_} = $1} split (/\s/, $2);
    }
  }
  return %dict;
}

# calc_radec: Calculate RA/Dec extent (ICRS) of the observation
#             and the base position
#
#             $status = calc_radec( $obs, $header );
#
# Populates header with corners of grid (in decimal degrees)
# Status is perl status: 1 good, 0 bad

sub calc_radec {
  my ($obs, $headerref) = @_;

  # Filenames for a subsystem
  my @filenames = $obs->filename;

  # Now need to write these files to  temp file
  my $fh = new File::Temp();
  print $fh map { $_ ."\n" } @filenames;
  close($fh);

  # PA (may not be present)
  my $pa = $headerref->{MAP_PA};
  $pa *= -1 if defined $pa;

  # command depends on ACSIS or SCUBA-2
  # turn off autogrid - only rotate raster maps. Just need bounds.
  my $systat = system( "/star/bin/smurf/makecube", "in=^$fh", "system=ICRS","out=!", "pixsize=1", "autogrid=no",
                     "msg_filter=quiet",(defined $pa ? "crota=$pa" : () ), "reset");

  if ($systat == 256) {
    # ADAM_EXIT - there will be a standard out message so the user should follow up
    return 0;
  } elsif ($systat != 0) {
    # probably control-C
    die "Error running SMURF: Status = $systat";
  }

  # Get the bounds
  my %result;
  for my $k ( qw/ FTL FBR FTR FBL /) {
    my $res = `/star/bin/kappa/parget $k makecube`;
    chomp($res);
    $res =~ s/^\s+//;
    $res =~ s/\s+$//;
    $result{$k} = [ map {Astro::Coords::Angle->new( $_, units => 'rad') } split(/\s+/,$res) ];
  }

  for my $corner (qw/ tl br tr bl / ) {
    my $parkey = "F".uc($corner);
    $headerref->{"obsra$corner"} = $result{$parkey}->[0]->degrees;
    $headerref->{"obsdec$corner"} = $result{$parkey}->[1]->degrees;
  }

  # and the base position (easier to just ask SMURF rather than opening the file) but
  # for a planet or comet/asteroid this will not be correct and should be set to undef
  # This means we have to look at JCMTSTATE anyway (but we still ask SMURF because that
  # will save us doing coordinate conversion)

  my (undef, %state ) = read_ndf( $filenames[0], qw/ TCS_TR_SYS / );
  die "Error reading state information from file $filenames[0]\n"
    unless keys %state;

  # check for APP or AZEL (should never be AZEL!)
  if ($state{TCS_TR_SYS} !~ /^(APP|AZ)/) {

    for my $k (qw/ REFLON REFLAT / ) {
      my $res = `/star/bin/kappa/parget $k makecube`;
      chomp($res);
      $result{$k} = $res;
    }

    # convert to radians
    $result{REFLON} = Astro::Coords::Angle::Hour->new( $result{REFLON}, units => 'sex', range => '2PI' )->degrees;
    $result{REFLAT} = Astro::Coords::Angle->new( $result{REFLAT}, units => 'sex', range => 'PI' )->degrees;

  } else {
    $result{REFLON} = undef;
    $result{REFLAT} = undef;
  }

  $headerref->{obsra} = $result{REFLON};
  $headerref->{obsdec} = $result{REFLAT};

  return 1;
}

# Calculate frequency properties
#
#  calc_freq( $obs, $headerref );
#
# Calculates:
#    zsource, restfreq
#    freq_sig_lower, freq_sig_upper : BARYCENTRIC Frequency GHz
#    freq_img_lower, freq_img_upper : BARYCENTRIC Frequency Image Sideband GHz

sub calc_freq {
  my $obs = shift;
  my $headerref = shift;

  # Filenames for a subsystem
  my @filenames = $obs->filename;

  # need the Frameset
  my $wcs = read_ndf( $filenames[0] );

  # Change to BARYCENTRIC, GHz
  $wcs->Set( 'system(1)' => 'FREQ',
             'unit(1)' => 'GHz',
             stdofrest => 'BARY' );

  # Rest Frequency
  $headerref->{restfreq} = $wcs->Get( "restfreq" );

  # Source velocity
  $wcs->Set( sourcesys => 'redshift' );
  $headerref->{zsource} = $wcs->Get( "sourcevel" );

  # Upper and lower values require that we know the GRID bounds
  my @x = (1, $headerref->{NCHNSUBS});

  # need some dummy data for axis 2 and 3 (or else some code to split the
  # specFrame)
  my @y = (1,1);
  my @z = (1,1);

  my @observed = $wcs->TranP( 1, \@x, \@y, \@z );

  # now need to switch to image sideband (if possible) (some buggy data is not setup as a DSBSpecFrame)
  my @image;
  eval {
    my $sb = uc($wcs->Get("SideBand"));
    $wcs->Set( 'SideBand' => ($sb eq 'LSB' ? 'USB' : 'LSB' ) );

    @image = $wcs->TranP( 1, \@x, \@y, \@z );
  };

  # need to sort the numbers
  my @freq = sort { $a <=> $b } @{ $observed[0] };
  $headerref->{freq_sig_lower} = $freq[0];
  $headerref->{freq_sig_upper} = $freq[1];
  if (@image && @{$image[0]}) {
    @freq = sort { $a <=> $b } @{ $image[0] };
    $headerref->{freq_img_lower} = $freq[0];
    $headerref->{freq_img_upper} = $freq[1];
  }
}

# Open an NDF file, read the frameset and the first entry from the supplied list
# of JCMTSTATE components (can be empty).
#
#  Returns hash of JCMTSTATE information and the Starlink::AST object
#
#  ($wcs, %state) = read_ndf( $file, @state );
#
#  returns empty list on error.
#  In scalar context just returns WCS frameset
#
#  $wcs = read_ndf( $file );

sub read_ndf {
  my $file = shift;
  my @statekeys = @_;
  my $status = &NDF::SAI__OK;
  my $bad;

  # begin context and open file
  err_begin( $status );
  ndf_begin( );
  ndf_find( NDF::DAT__ROOT, $file, my $indf, $status);

  # read the WCS
  my $wcs = ndfGtwcs( $indf, $status );

  # Get extension
  my %state;
  if (@statekeys) {
    ndf_xloc( $indf, "JCMTSTATE", "READ", my $sloc, $status);
    for my $k (@statekeys) {
      dat_find( $sloc, $k, my $lloc, $status);
      dat_type( $lloc, my $type, $status);
      dat_size( $lloc, my $size, $status);
      if ($status == &NDF::SAI__OK) {
        my @values;
        if ($type =~ /_CHAR/) {
          dat_getvc($lloc, $size, @values, my $el, $status );
        } elsif ($type =~ /^_[IUBL]/) {
          dat_getvi( $lloc, $size, @values, my $el, $status );
        } elsif ($type =~ /^_[DR]/) {
          dat_getvd( $lloc, $size, @values, my $el, $status );
        } else {
          if ($status == &NDF::SAI__OK) {
            $status = &NDF::SAI__ERROR;
            err_rep( " ", "Error with type $type", $status);
          }
        }
        if ($status == &NDF::SAI__OK) {
          $state{$k} = $values[0]; # first only
        }
      }
    }

  }

  # tidy up
  if ($status != &NDF::SAI__OK) {
    err_flush( $status );
    $bad = 1;
  }
  err_end( $status );
  ndf_end($status);

  return () if $bad;
  if (wantarray) {
    return ($wcs, %state);
  } else {
    return $wcs;
  }
}

1;

=head1 NAME

jcmtenterdata - Parse headers and store in database

=head1 SYNOPSIS

  jcmtenterdata
  jcmtenterdata 20070209

=head1 DESCRIPTION

Reads the headers of all data from either the current date or the specified UT date, and uploads
the results to the header database. If no date is supplied the current localtime is used to
determine the relevant UT date (which means that it will still pick up last night's data even
if run after 2pm).

=head1 NOTES

Skips any data files that are from simulated runs (SIMULATE=T).

=head1 AUTHORS

Kynan Delorey E<lt>k.delorey@jach.hawaii.eduE<gt>, Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright (C) 2006, 2007 Particle Physics and Astronomy Research Council.
All Rights Reserved.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful,but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc., 59 Temple
Place,Suite 330, Boston, MA  02111-1307, USA

=cut
