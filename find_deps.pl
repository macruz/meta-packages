#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
#use Data::Dumper;

#
# Globals
#
# NOTES: 
# - SAPO packages are excluded on purpose to avoid collisions with system libs with exact same name
# - prestine-tar is always returned because libbz2 which is included appears in path before system libbz2
#   and it's duplicated unnecessarily
#
my $IGN_LDD = '^/servers|linux-vdso|libc\.so|ld-linux-x86-64|:$|dynamic|sapo';
my $IGN_APT = '-dev|-dbg|libc6|lib32|sapo|pristine-tar';
#
my $arg = undef;
my %opts;
my @libsfound = ();
my @DEPS = ();
my $LIST = "";

die( "Error: Missing Parameters" ) if ( $#ARGV < 0 );

#
# PARAMS
# -x  Exclude a pkg from the Ãldd list output (prevents search for it)
# -v  Add >= version to output packages found
# -vv Add >> version to output packages found
# -a  Adds specific pkg even if it's not found (force it)
# -h  This list
#
Getopt::Long::Configure( "pass_through" );
GetOptions( \%opts, 'x=s', 'v', 'vv', 'a=s', 'h|help' );

$IGN_LDD .= "|$opts{x}" if ( $opts{x} );

$arg = join( " ", @ARGV );
# print "ARGS=$arg\n";
# print Dumper( \%opts );

# Obtain all the libs used from args executables
@libsfound = split( '\n', `/usr/bin/ldd $arg 2>/dev/null | /bin/egrep -v "$IGN_LDD" | awk '{ print \$1 }' | sort | uniq`);

$LIST = join( '\n', @libsfound ) . '\n';

# print "FOUND LIBS: @libsfound\n";
# print "LIST: $LIST\n";
# print "CMD = /bin/echo -e \"$LIST\" | /usr/bin/apt-file search -l -f - | /bin/egrep -v -- \"$IGN_APT\"\n";

@DEPS = split( '\n', `/bin/echo -e \"$LIST\" | /usr/bin/apt-file search -l -f - | /bin/egrep -v -- "$IGN_APT"` );
if ( $opts{a} ) {
  $opts{a} =~ s/,/ /gi;
  push( @DEPS, split( ' ', $opts{a} ) ) if ( $opts{a} );
}

#print "DEPS = @DEPS\n";
#print "DEPS = " . Dumper( @DEPS ) . "\n";

$LIST = "libc6";

foreach ( @DEPS ) {

 #dpkg assumes package is installed locally, which may not be the case
 #my $verstr = `/usr/bin/dpkg -p $_ 2>/dev/null | /bin/grep "^Version" | /usr/bin/head -1` || undef;
 my $verstr = `/usr/bin/apt-cache show $_ 2>/dev/null | /bin/grep "^Version" | /usr/bin/head -1` || undef;
 my $ver;

 if ( $verstr ) {
   $verstr =~ /.*: (.*)$/;
   $ver = $1;

   $LIST .= ", $_";
   $LIST .= " (>= $ver)"  if ( $opts{v} );
   $LIST .= " (>> $ver)" if ( $opts{vv} );

 } else {

   print STDERR "Warning: Package $_ is currently not installed on this host.\n";
 }
}

print STDOUT $LIST;
exit( 0 );
