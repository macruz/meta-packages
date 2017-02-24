#!/usr/bin/perl

use strict;
use warnings;


#
# Check for modules installed and FPM
#
BEGIN {

  my ( @MODS, $m, $c );
  @MODS = ( "Data::Dumper", "Config::Simple", "Perl::Version", "Getopt::Long" );
  $c = 0;

  for $m ( @MODS ) {
    eval "require $m" ? $m->import() :
       print( "Module $m not found. Install using: perl -MCPAN -e shell 'install $m'\n" ) &&
       $c++;
  }
  
  if ( ! -x "/usr/local/bin/fpm" ) {
    print( "This script uses Effing Package Management (FPM) to build packages.\n" );  
    print( "You can install it using: gem install fpm\n" );
    $c++;
  }

  exit( 47 ) if ( $c ); # Why 47 ? Because I can :)
}

use Config::Simple '-strict';

#
# Constants
#
# Verbosity levels: 0 = none, 1 = info, 2 = verbose, 3 = debug
my $DEBG = 3;
my $VERB = 2; 
my $INFO = 1;
#
# Display list default sizes
#
my @DVALS = ( 20, 7, 4, 10, 48 ); # Name, version, enabled, maintainers, description
my $SZDN  = 20;                  # Display Name size for printing
my $SZDM  = 10;                  # Display Maintainers size for printing
#
# Files and directories
#
my $BDIR    = "/servers/packages/meta-packages";
my $OUTD    = "$BDIR/archive";
my $CF_PKGS = "packages.conf";
my $CF_COMM = "common.conf";
my $CF_META = "sapometa.conf";
#
# System binaries
#
my $APTC = "/usr/bin/apt-cache";
my $GREP = "/bin/grep";
my $AWK  = "/usr/bin/awk"; 
my $HEAD = "/usr/bin/head";
my $SBMT = "/usr/bin/sudo -u debupload /servers/sapo-bofh-tools/bin/submitdeb";
#
# FPM related
#
my $FPM     = "/usr/local/bin/fpm";
my $FPMA    = "-f"; # default args for FPM
my $FPMLOG  = "fpm.log";
#
# FPM Parameters
# Syntax: '<param_name>:<default_value_if_none_given>'
# If default == '-' then ignore this parameter unless explicitly defined on each package config block
#
my @DEBTAGS = ( 'license:Debian',  'vendor:SAPO',    'category:-',       'provides:-', 
                'replaces:-',      'config-files:-', 'architecture:all', 'deb-compression:-', 
                'url:none',        'deb-suggests:-', 'deb-priority:-',   'deb-pre-depends:-', 
                'section:-',       'deb-field:-',    'deb-recommends:-', 'deb-changelog:-',  
                'deb-user:-',      'deb-group:-',    'before-install:-', 'before-remove:-',
                'after-install:-', 'after-remove:-', 'template-scripts:-' );
#
# Globals
#
my $LOGL   = 1;      # Current logging level defaults to INFO
my $FORCE  = 0;      # Do not force by default
my $SCRIPT = 0;      # Scriptable output
my $PKG    = "";     # Package name from command line

my $_common;         # Pointer to hash with contents of $CF_COMM
my $_packages;       # Pointer to hash with contents of $CF_PKGS
my $_sapometa;       # Pointer to hash with contents of $CF_META

my $defaults;
my $maintainers;
my @packages = ();

#
# Functions
#

#
# _log( LVL, TEXT )
# LVL = verbosity level
# TEXT = text to print
#
# Prints messages to system based on VERB level
# Returns:
#
sub _log {

  my ( $l, $t ) = @_;

  # Only print the tag, if we are in debug mode
  print "DEBUG: " if ( $l > $VERB && $l <= $LOGL );
  print "$t\n"    if ( $l <= $LOGL );
}

#
# _readConfigFile
# Loads config file and adds default dir if not found on current
#
sub _readConfigFile {

  my ( $fh, $fn ) = @_;

  $fn = "$BDIR/$fn" if ( ! -f $fn );

  $fh->read( $fn ) || die( "Config file not found: $fn\n" );
}

#
# loadConfig()
# Loads the configuration files and initializes global variables
#
sub loadConfig {

  $_common   = new Config::Simple();
  $_packages = new Config::Simple();
  $_sapometa = new Config::Simple();

  _readConfigFile( $_common, $CF_COMM );
  _readConfigFile( $_packages, $CF_PKGS );
  _readConfigFile( $_sapometa, $CF_META );
  
  $_common->autosave( 0 );
  $_packages->autosave( 0 );
  $_sapometa->autosave( 0 );

  # $common and $maintainters are pointers to hashes with the a=b values from get_block()
  $defaults    = $_common->get_block( "defaults" );
  $maintainers = $_common->get_block( "maintainers" );

  _log( $DEBG, "defaults\n" . Dumper( $defaults ) );
  _log( $DEBG, "maintainers\n" . Dumper( $maintainers ) );
  
  push( @packages, ( $_packages->get_block() ) );
  _log( $DEBG, "PKGS: packages = " . Dumper( @packages ) . "\n" );
  
  push( @packages, ( $_sapometa->get_block() ) );
  _log( $DEBG, "META: packages = " . Dumper( @packages ) . "\n" );

  _log( $VERB, "Processing packages = " . join( ", ", @packages ) . "\n" );
}

#
# getMaintainers( VAR )
# VAR = string or array with a maintainer or a list
#
# Returns: string with maintainer(s) name and e-mail
# 
sub getMaintainers {

  my $entry = shift;

  if ( defined( $entry ) ) {

    my $s;
    # The 'map' function ignores an element if we return an empty list: ()
    return join( ', ', map { $s = $maintainers->{$_}; $s ? $s : () } @{ $entry } )
      if ( ref( $entry ) eq 'ARRAY' );

    return $maintainers->{ $entry }; 
  }

  # By default, if nothing is specified, the team is assigned
  # Even if a funny guy decided to remove the opers line from config file!

  _log( $VERB, "Tag 'maintainers' not defined. Adding default 'opers'" );
  return $maintainers->{opers} if ( $maintainers->{opers} );

  _log( $VERB, "Tag 'opers' not found on configuration file. Forcing it.\n" );
  return '"Opers Team" <opers-team@co.sapo.pt>';
}

#
# incVersion( VAR )
# VAR = package block 
#
# Returns: version incremented
#
sub incVersion {

  my ( $cfg, $pkg, $v )  = @_;
  my $ret = "";

  if ( $v ) {

    my $nv = Perl::Version->new( $v );

    $nv->inc_version() if ( $v =~ /^\d+\.\d+$/ );
    $nv->inc_subversion() if ( $v =~ /^\d+\.\d+\.\d+$/ );

    _log( $INFO, "Incrementing version from '$v' to '$nv'" );
    $ret = $nv;

  } else {

    _log( $INFO, "Version not found. Setting to default '1.0'" );
    $ret = "1.0";
  }

  # Save the new version
  $cfg->param( "$pkg.version", "$ret" );
  return $ret;
}


#
# getAptVer
# Obtain a version from apt-cache for a specific package
#
sub getAptVer {

  my $pkg = shift;
  my $edv = shift;
  my $ver = 0;

  _log( $DEBG, "$APTC show $pkg 2>/dev/null | $GREP '^Version' | $HEAD -1 | $AWK '{ print \$2 }'" );
  $ver = `$APTC show $pkg 2>/dev/null | $GREP '^Version' | $HEAD -1 | $AWK '{ print \$2 }'`;

  if ( chomp( $ver ) ) {

    _log( $VERB, "Found version '$ver' for dependency '$pkg'" );

    # By default, we want exact versions on dependencies to make sure the package is 
    # installed with same libs and such across multiple servers.
    # There are exceptions, ofc
    ( defined( $edv ) && $edv eq "no" ) ? ( $pkg .= " (>= $ver)" ) : ( $pkg .= " (= $ver)" );

    _log( $DEBG, "Final dependency added: $pkg" );
    return $pkg;
  }

  _log( $INFO, "Warning: Package '$pkg' not found on any configured repository. Skipping." );
  return undef;
}

#
# getDependency( VAR )
# VAR = name of the package to find dependencies
#
# Returns: string with dependency list
#
sub getDependency {

  my $pkg = shift;
  my $edv = shift;

  if ( $pkg =~ /\|/ ) {

    my @ret = ();
    my @lst = split( /\|/, $pkg );

    foreach ( @lst ) {
      s/^\s+|\s+$//g;
      push( @ret, getDependency( $_, $edv ) );
    }

    return join( " | ", @ret );

  } else {

    # Assumptions: 
    # - If there is a "name (any)", then just return package without any version reference
    # - If there is a "name (version)", then we want a specific one, just go ahead with it.
    return $1   if ( $pkg =~ /^([^ ]*)\s*\(\s*any\s*\)/ );
    return $pkg if ( $pkg =~ /.*\s*\(.+\)/ );

    # default, get the current latest version from apt repo cache
    return getAptVer( $pkg, $edv );
  }
}

#
# getDependencies( VAR )
# VAR = list of packages to find dependencies
#
# Returns: string with all dependencies 
#
sub getDependencies {

  my $s    = undef;
  my $deps = shift;
  my $edv  = shift;
  
  return undef if ( !defined( $deps ) );
  return getDependency( $deps, $edv ) if ( ref( $deps ) ne 'ARRAY' );

  # Run through the list and call getDependency for each one
  # The 'map' function ignores an element if we return an empty list: ()
  # which is very useful for packages that are not found on repositories
  return join( ", ", map { $s = getDependency( $_, $edv ); $s || (); } @{ $deps } );
}

#
# getTagValue( ARGS )
# ARGS: current package block and tag reference
#
# Returns: string with tag and its value
#
sub getTagValue {

  my ( $block, $tag, $deflt ) = @_;
  
  # Look inside current package block first
  if ( $block->{$tag} ) {
    my $tv = "";

    ref( $block->{$tag} ) eq 'ARRAY' ? $tv = join( ', ', @{ $block->{$tag} } )
                                     : $tv = $block->{$tag};
 
    _log( $VERB, "Adding tag: --" . $tag . " '" . $tv . "'" );
    return $tv;
  }

  # Check if it is on defaults block from common file
  if ( $defaults->{$tag} ) {
    my $tv = "";

    ref( $defaults->{$tag} ) eq 'ARRAY' ? $tv = join( ', ', @{ $defaults->{$tag} } )
                                        : $tv = $defaults->{$tag};
 
    _log( $VERB, "Adding tag: --" . $tag . " '" . $tv . "' [added from common]" );
    return $tv;
  }

  if ( $deflt && $deflt ne '-' ) {

    _log( $VERB, "Adding tag: --" . $tag . " '" . $deflt . "' [using default value]" );
    return $deflt;
  }

  _log( $DEBG, "Tag '$tag' not used. Skipping." );
  return "";
}

sub addTag {
   
  my ( $block, $tref ) = @_;
  my ( $t, $dflt ) = split( /:/, $tref );
  
  my $val = getTagValue( $block, $t, $dflt );
  
  return "--" . $t . " '" . $val . "' " if ( $val );
  return "";
}

#
# createPackage( ARGS )
# ARGS = args for FPM
#
sub createPackage {

   my ( $blk, $name, $type, $maint, $deps, $ver ) = @_;
   my $outpkg;
   my $buildcmd = "$FPM $FPMA -s $type ";
   my $pkgtype  = getTagValue( $blk, 'pkgtype', 'deb' );

   if ( $pkgtype !~ /(rpm|deb)/ ) {

     _log( $INFO, "Invalid target package type: $pkgtype. Skipping." );
     return;
   }

   $outpkg = sprintf( "%s_%s_%s.%s", $name, $ver, getTagValue( $blk, 'architecture', 'all' ), $pkgtype );

   $buildcmd .= "-t $pkgtype -n $name ";
#   $buildcmd .= "-p $OUTD/$outpkg ";
   $buildcmd .= "-p $outpkg ";
   $buildcmd .= "--verbose " if ( $LOGL == $VERB );
   $buildcmd .= "--debug "   if ( $LOGL == $DEBG );
   $buildcmd .= "--version '" . $ver . "' ";
   $buildcmd .= '--depends "' . $deps . '" ' if ( $deps );
   $buildcmd .= "--maintainer '" . $maint . "' ";

   foreach my $t ( @DEBTAGS ) {
     $buildcmd .= addTag( $blk, $t );
   } 

   if ( $blk->{description} ) {

     if ( ref( $blk->{description} ) ) {
       _log( $INFO, "Error: description contains invalid caracters. Skipping package.\n" );
       return 0;
     }

     my $desc = $blk->{description};

     $desc =~ s/%V/$ver/g if ( $desc =~ /%V/ );

     _log( $DEBG, "Adding description: $desc\n" );
     $buildcmd .= "--description '" . $desc . "'";

   } else {

     $buildcmd .= "--description 'SAPO MetaPkg " . $name . "'";
   }

   $buildcmd .= " 2>&1 >> " . $FPMLOG;

   _log( $DEBG, "FPM COMMAND = " . $buildcmd . "\n" );

   `$buildcmd`;
#   print "\nFINAL CMD == " . $buildcmd . "\n";

  return 1;
}

#
# buildPackage( VAR )
# VAR = ptr to file, input type, pakage name to build
#
sub buildPackage {

  my ( $config, $type, $pkg ) = @_;
  my ( $blk, $maint, $deps, $ver );

  _log( $INFO, "\nLoading package configuration for '$pkg'" );

  $blk = $config->get_block( $pkg );

  # Check if it's enabled
  if ( ( exists( $blk->{disabled} ) && lc( $blk->{disabled} ) eq 'yes') || 
       ( exists( $blk->{enabled} )  && lc( $blk->{enabled} )  eq 'no' ) ) {

    _log( $INFO, "Package is not enabled. Skipping." );
    return;
  }

  # Load package info
  $maint = getMaintainers( $blk->{maintainers} ); 
  $deps  = getDependencies( $blk->{dependencies}, $blk->{exactdependenciesversions} );
  $ver   = incVersion( $config, $pkg, $blk->{version} );

  _log( $DEBG, "Package configuration block\n" . Dumper( $blk ) );
  _log( $DEBG, "Maintainers found: $maint\n" );
  _log( $DEBG, "Dependencies found: $deps\n" ) if ( defined( $deps ) );

  if ( createPackage( $blk, $pkg, $type, $maint, $deps, $ver ) ) {

    $config->write();
  }
}

#
# getMaxDisplayValues
# VAR = config block
# Helper function for obtain the highest field values to print
#
sub getMaxDisplayValues {

  my $config = shift;
  my @blk = ();

  push( @blk, $config->get_block() ); 

  foreach my $p ( sort @blk ) {

    my ( $b, $m, $d, $j );

    $d = "";
    $j = $SCRIPT ? "," : ", ";
    $b = $config->get_block( $p );
    $m = ref( $b->{maintainers} )  eq 'ARRAY' ? join( $j, @{$b->{maintainers}} )  : $b->{maintainers};
    $d = ref( $b->{dependencies} ) eq 'ARRAY' ? join( $j, @{$b->{dependencies}} ) : $b->{dependencies}
       if ( !$SCRIPT );

    # This is to avoid: Use of uninitialized value in numeric gt (>) at ./meta.pl line 666!!!
    my $lp = length( $p ) || 1; 
    my $lm = length( $m ) || 1;
    my $ld = length( $d ) || 1;
  
    $DVALS[0] = $lp if ( $lp > $DVALS[0] );
    $DVALS[3] = $lm if ( $lm > $DVALS[3] );
  #  $DVALS[4] = $ld if ( $ld > $DVALS[4] );
  }

  #$DVALS[4] = 48 if ( $DVALS[4] > 48 );
  _log( $DEBG, "MAX VALS: " . Dumper( @DVALS ) . "\n" );
}

# 
# printPkgInfo
# VARS = name, version, enabled, maintainers, dependencies
# Helper function to print with format
#
sub printPkgInfo {

  my ( $n, $v, $e, $m, $d ) = @_;
  my ( $sep, $format );

  $sep = $SCRIPT ? "": "| ";

  $format  = $sep . "%-" . $DVALS[0] . "s ";                      # Name
  $format .= $sep . "%"  . $DVALS[1] . "s ";                      # Version
  $format .= $sep . "%"  . $DVALS[2] . "s ";                      # Enabled 
  $format .= $sep . "%-" . $DVALS[3] . "s ";                      # Maintainers
  $format .= $sep . ( $SCRIPT ? "%s" : "%-" . $DVALS[4] . "s " ); # Dependencies
  $format .= $sep . "\n";

  if ( !defined( $d) || $d eq "" ) {
    $d = " -- no dependencies defined -- ";
  } else {
    $d =~ tr/ //ds if ( $SCRIPT );
  }
  printf( $format, $n, $v, $e, $m, $d );
}

#
# printPkgsBlock
# VAR = block
# Prints all packages and their info
#
sub printPkgsBlock {

  my $config = shift;
  my @blk = ();
  my $p;

  push( @blk, $config->get_block() ); 

  foreach $p ( sort @blk ) {

    my $j = $SCRIPT ? "," : ", ";
    my $b = $config->get_block( $p );
    my $m = ref( $b->{maintainers} )  eq 'ARRAY' ? join( $j, @{$b->{maintainers}} )  : $b->{maintainers};
    my $d = ref( $b->{dependencies} ) eq 'ARRAY' ? join( $j, @{$b->{dependencies}} ) : $b->{dependencies};
    my $e = exists( $b->{enabled} ) ? lc( $b->{enabled} ) : 
            ( exists( $b->{disabled} ) ? lc( $b->{disabled} ) : "yes" );

    $m = "opers" if ( ! $m );

    printPkgInfo( $p, $b->{version}, $e, $m, $d );
  }
   
}

#
# listAllConfigs
# 
#
sub listAllConfigs {

  my $p; 
  my @blk = ();
#  my $sz = 12; # Start with the size of field splitters " | "
 
  _log( $DEBG, "HASH PACKAGES: " . Dumper( $_packages ) );
  _log( $DEBG, "HASH META: " . Dumper( $_sapometa ) );

  getMaxDisplayValues( $_sapometa );
  getMaxDisplayValues( $_packages );

#  if ( ! $SCRIPT ) {
#    for ( my $i = 0; $i <= 4; $i++ ) { $sz += $DVALS[$i]; }
#    $sz += 2;
#    print "+" . "-" x $sz . "+" . "\n";
    printPkgInfo( "Package Name", "Version", "Make", "Maintainer(s)", "Dependencies" );
    print "-" x 128 . "\n";
#    print "|" . "-" x $sz . "|\n";
#  }

  printPkgsBlock( $_sapometa );
  printPkgsBlock( $_packages );

#  print "+" . "-" x $sz . "+\n" if ( ! $SCRIPT );

  exit( 0 );
}

#
# _continue
# Helper function to request user confirmation
#
sub _continue {

  my $r;

  print "Continue (Y/N) ? ";

  $r = <STDIN>;
  chomp( $r );

  return ( $r eq "Y" || $r eq "y" );
}

#
# buildAll
# VAR: pkg list
# Builds all packages listed on array parameter
#
sub buildAll {

  my @pkgs = @_;

  if ( @pkgs ) {

    _log( $INFO, "The following packages will be built:" );
    _log( $INFO, "- " . join( ', ', @pkgs ) );

    if ( $FORCE ||  _continue() ) {

      foreach ( @pkgs ) {
        /meta/ ? buildPackage( $_sapometa, "empty", $_ )
               : buildPackage( $_packages, "dir", $_ );
      }
    }

  } else {

    _log( $INFO, "No packages match given criteria" );
  }

  exit( 0 );
}

#
# buildPkg
# Builds specific pkgs
#
sub buildPkg {

  my $pkg = shift;
  my $go  = 0;
  my @lst = undef;

  $pkg =~ s/\*//g if ( $pkg =~ qr/\*/ );
  
  if ( $pkg =~ /^~/ ) {

    $pkg =~ s/~//g;
    @lst = grep( !/$pkg/, @packages );

  } else {

    @lst = grep( /$pkg/, @packages );
  }

  buildAll( @lst );
}

#
# usage()
# Prints the usage help message
#
sub usage {

  print "Usage: meta [-q|-v|-d|-y|-ba|-l|-ls|-h] [<package>]\n";
  print "\n";
  print "Parameters overview:\n";
  print "  -q\t\tQuiet mode\n";
  print "  -v\t\tVerbose mode\n";
  print "  -d\t\tDebug mode\n";
  print "  -y\t\tAssume 'yes' on any questions\n";
  print "  -ba\t\tBuild all packages\n";
  print "  -l\t\tLists all packages in configuration files\n";
  print "  -h\t\tThis message\n";
  print "  package\tBuilds package (will use egrep for matching [use ~ to exclude])\n";
  print "\n";
  exit( 0 );
}

#
# M A I N
#

my %opts = ();

Getopt::Long::Configure( "pass_through" );
GetOptions( \%opts, 'v', 'd', 'q', 'ls', 'l', 'y', 'h|help', 'ba', 'b' );

usage() if ( $opts{h} );

$LOGL   = 0 if ( $opts{q} );
$LOGL   = 2 if ( $opts{v} );
$LOGL   = 3 if ( $opts{d} );
$FORCE  = 1 if ( $opts{y} );
$SCRIPT = 1 if ( $opts{ls} || $opts{l} );
$PKG    = shift || undef;

_log( $DEBG, "ARGS: " . Dumper( %opts ) );

loadConfig();

listAllConfigs()      if ( $opts{l} || $opts{ls} );
buildAll( @packages ) if ( $opts{ba} );
buildPkg( $PKG )      if ( $PKG );

usage();

exit( 0 );
