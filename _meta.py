#!/usr/bin/env python

import string
import argparse
import commands
import os
import sys
import re
import ConfigParser


#
# GLOBALS
#

CF_PATH = "../conf/"
CF_PATH = "./"
CF_COMM = CF_PATH + 'common.conf'
CF_META = CF_PATH + "sapometa.conf"
CF_PKGS = CF_PATH + "packages.conf"

#
# System binaries
#
APTC = "/usr/bin/apt-cache"
GREP = "/bin/grep"
AWK  = "/usr/bin/awk"
HEAD = "/usr/bin/head"
SBMT = "/usr/bin/sudo -u debupload /servers/sapo-bofh-tools/bin/submitdeb"

#
# FPM related
#
FPM    = "/usr/local/bin/fpm"
FPMA   = "-f" # default args for FPM
FPMLOG = "fpm.log"

#
# TAGS
#
DEBTAGS = ( 'license:Debian',  'vendor:SAPO',    'category:-',       'provides:-',
            'replaces:-',      'config-files:-', 'architecture:all', 'deb-compression:-',
            'url:none',        'deb-suggests:-', 'deb-priority:-',   'deb-pre-depends:-',
            'section:-',       'deb-field:-',    'deb-recommends:-', 'deb-changelog:-',
            'deb-user:-',      'deb-group:-',    'before-install:-', 'before-remove:-',
            'after-install:-', 'after-remove:-', 'template-scripts:-' )

#
# Display list default sizes
#
DVALS = [ 20, 7, 4, 10, 0 ]; # Name, version, enabled, maintainers, description
SZDN  = 20;                  # Display Name size for printing
SZDM  = 10;                  # Display Maintainers size for printing

#
# Global Vars
#
_sapometa = None
_common   = None
_packages = None

LOGL   = 1
FORCE  = 0
SCRIPT = 0
PKG    = ""

packages    = ()
maintainers = {}
defaults    = {}

#
# Constants
#
# Verbosity levels: 0 = none, 1 = info, 2 = verbose, 3 = debug
DEBG = 3;
VERB = 2;
INFO = 1;

#
# FUNCTIONS
#

def var_dump( var, prefix='' ):
    """
    You know you're a php developer when the first thing you ask for
    when learning a new language is 'Where's var_dump?????'
    """
    my_type = '[' + var.__class__.__name__ + '(' + str(len(var)) + ')]:'
    print( prefix, my_type, '' )
    prefix += '    '
    for i in var:
        if type( i ) in ( list, tuple, dict, set ):
            var_dump( i, prefix )
        else:
            if isinstance( var, dict ):
                print( prefix, i, ': (', var[i].__class__.__name__, ') ', var[i], '' )
            else:
                print( prefix, '(', i.__class__.__name__, ') ', i, '' )

#
# Auxiliar function 
#
def toString( var, sep = "," ):

   if type( var ) is str:
     return var

   if type( var ) is tuple:
    return sep.join( var )

   return ""

#
# Logging!!!
#

def _log( level, text ):

  if ( level > VERB and level <= LOGL ):
    print "DEBUG: %s" % ( text )
    return

  if ( level <= LOGL ): 
    print "%s" % ( text )
  
#
# Return a string with the array items values
# 
def _a2s( _array ):
  return ', '.join( str( x ) for x in _array )

#
# Load config files
#
def loadConfig():

  global _sapometa, _common, _packages, packages, maintainers, defaults

  for fn in ( CF_META, CF_COMM, CF_PKGS ):
    if os.path.isfile( fn ) and os.access( fn, os.R_OK ):
       continue
    else:
      print "Configuration file not found: %s\nAborting.\n" % ( fn )
      os._exit( -1 ) 

  _sapometa = ConfigParser.ConfigParser()
  _common   = ConfigParser.ConfigParser()
  _packages = ConfigParser.ConfigParser()

  try:
    _sapometa.read( CF_META )
    _common.read( CF_COMM )
    _packages.read( CF_PKGS )

  except e:
    raise e
    os._exit( -1 )

  packages    = _packages.sections() + _sapometa.sections()
  maintainers = dict( _common.items( "maintainers" ) )
  defaults    = dict( _common.items( "defaults" ) )

  if ( LOGL >= VERB ):
    _log( DEBG, "==> sapometa sections: " + _a2s( _sapometa.sections() ) )
    _log( DEBG, "==> common sections: "   + _a2s( _common.sections() ) )
    _log( DEBG, "==> packages sections: " + _a2s( _packages.sections() ) )
    _log( VERB, "Processing packages: "   + _a2s( packages ) )


#
# getMaintainers( VAR )
# VAR = string or array with a maintainer or a list
#
# Returns: string with maintainer(s) name and e-mail
#
def getMaintainers( entry ): 

  if entry is not None:

    if type( entry ) is tuple:
      ret = ', '.join( maintainers[ x ] for x in entry if maintainers.has_key( x ) )
      _log( DEBG, "Maintainers found: %s\n" % ret )
      return re.sub( r'\'', '', ret )

    if ( re.search( r',', entry ) ):
      entry = re.sub( r'\ ', '', entry )
      lst = entry.split( ',' )
      ret = ', '.join( maintainers[ x ] for x in lst if maintainers.has_key( x ) )
      _log( DEBG, "Maintainers found: %s\n" % ret )
      return re.sub( r'\'', '', ret )

    _log( DEBG, "Maintainer found: %s\n" % maintainers[ entry ] )
    return re.sub( r'\'', '', maintainers[ entry ] )

  # By default, if nothing is specified, the team is assigned
  # Even if a funny guy decided to remove the opers line from config file!

  _log( DEBG, "Tag 'opers' not found on configuration file. Forcing it.\n" );
  return '"Opers Team" <opers-team@co.sapo.pt>'

#
# incVersion( VAR )
# VAR = package block
#
# Returns: version incremented
#
def incVersion( config, pkg, ver ):

  ver = re.sub( r'"', '', ver )
  ret = None
  exp = re.compile( r'(?:[^\d]*(\d+)[^\d]*)+' )
  mtx = exp.search( ver )

  if mtx:
    nxt = str( int( mtx.group(1) ) + 1 )
    start, end = mtx.span(1)
    ret = str( ver[:max(end-len(nxt), start)] + nxt + ver[end:] )

    _log( INFO, "Incrementing version from '%s' to '%s'" % ( ver, ret ) );

  else:
    _log( INFO, "Version not found. Setting to default '1.0'" );
    ret = "1.0";

  # Save the new version
  config.set( pkg, 'version', ret )
  return ret;


#
# getAptVer
# Obtain a version from apt-cache for a specific package
#
def getAptVer( pkg, edv, ver = None ):

  # `$APTC show $pkg 2>/dev/null | $GREP '^Version' | $HEAD -1 | $AWK '{ print \$2 }'`;
  cmdline = "%s show %s 2>/dev/null | %s '^Version' | %s -1 | %s '{ print $2 }'" % \
            ( APTC, pkg, GREP, HEAD, AWK )

  _log( DEBG, "RUN: %s" % ( cmdline ) )
  ver = commands.getoutput( cmdline )

  if ( ver ): 

    _log( VERB, "Found version '%s' for dependency '%s'" % ( ver, pkg ) );

    # By default, we want exact versions on dependencies to make sure the package is
    # installed with same libs and such across multiple servers.
    # There are exceptions, ofc
    if ( edv and edv == "no" ):
      pkg = "%s (>= %s)" % ( pkg, ver )
    else:
      pkg = "%s (= %s )" % ( pkg, ver )

    _log( DEBG, "Final dependency added: %s" % pkg );
    return pkg;

  _log( INFO, "Warning: Package '%s' not found on any configured repositories. Skipping." % pkg )
  return ""

#
# getDependency( VAR )
# VAR = name of the package to find dependencies
#
# Returns: string with dependency list
#
def getDependency( pkg, edv ):

  lst = pkg.split( '|' )

  if ( len( lst ) > 1 ):

    ret = []
    for l in lst:
      ret += [ getDependency( l.strip(), edv ) ]

    return " | ".join( ret )

  # Assumptions:
  # - If there is a "name (any)", then just return package without any version reference
  # - If there is a "name (version)", then we want a specific one, just go ahead with it.

  ret = re.match( r'^([^ ]*)\s*\(\s*any\s*\)', pkg )
  if ( ret ): return ret.group().strip()

  ret = re.match( r'.*\s*\(.+\)', pkg )
  if ( ret ): return ret.group().strip()

  # default, get the current latest version from apt repo cache
#  return "%s (1.%s)" % (pkg, len(pkg))
  return getAptVer( pkg, edv )

#
# getDependencies( VAR )
# VAR = list of packages to find dependencies
#
# Returns: string with all dependencies
#
def getDependencies( deps, edv ):

  if ( not deps ):
    return None

  if ( type( deps ) is str ):

    deps = re.sub( r'"', '', deps )

    if ( re.search( r',', deps ) ):
      lst = deps.split( ',' )
      _log( DEBG, "Spliting packages into: %s\n" % lst )
      return getDependencies( lst, edv )
    else:
      ret = getDependency( deps, edv )
      _log( DEBG, "Dependency found: %s\n" % ret )
      return ret

  # Run through the list and call getDependency for each one
  ret = ", ".join( getDependency( x, edv ) for x in deps )
  _log( DEBG, "Deps found: %s\n" % ret )
  return ret


#
# getTagValue( ARGS )
# ARGS: current package block and tag reference
#
# Returns: string with tag and its value
#
def getTagValue( block, tag, deflt ):

  # Look inside current package block first
  if ( block.has_key( tag ) ):

    tagval = re.sub( r'"', '', block.get( tag ) )

    if ( type( tagval ) is list ): 
      tv = ', '.join( tagval )
    else:
      tv = tagval

    _log( VERB, "Adding tag: --%s '%s'" % ( tag, tv ) );
    return tv

  # Check if it is on defaults block from common file
  if ( defaults.has_key( tag ) ):

    tagval = re.sub( r'"', '', defaults.get( tag ) )

    if ( type( tagval ) is list ):
      tv = ', '.join( tagval )
    else:
      tv = tagval

    _log( VERB, "Adding tag: --%s '%s' [added from common]" % ( tag, tv ) );
    return tv

  if ( deflt and deflt != '-' ):
    _log( VERB, "Adding tag: --%s '%s' [using default value]" % ( tag, deflt ) );
    return deflt

  _log( DEBG, "Tag '%s' not used. Skipping." % ( tag ) );
  return ""

#
# addTag
#
def addTag( block, tref ):

  t, dflt = tref.split( ':' )

  val = getTagValue( block, t, dflt )

  if ( val ):
    return "--%s '%s' " % ( t, val )

  return ""

#
# createPackage( ARGS )
# ARGS = args for FPM
#
def createPackage( blk, name, _type, maint, deps, ver ):

  buildcmd = "%s %s -s %s " % ( FPM, FPMA, _type )
  pkgtype  = getTagValue( blk, 'pkgtype', 'deb' )

  if ( not re.search( 'rpm|deb', pkgtype ) ):

    _log( INFO, "Invalid target package type: $pkgtype. Skipping." )
    return None

  outpkg = "%s_%s_%s.%s" % ( name, ver, getTagValue( blk, 'architecture', 'all' ), pkgtype )

#   $buildcmd .= "-p $OUTD/$outpkg ";
  buildcmd += "-t %s -n %s -p %s --version '%s' --maintainer '%s' " \
              % ( pkgtype, name, outpkg, ver, maint )

  if ( deps ):         buildcmd += "--depends '%s' " % ( deps )
  if ( LOGL == VERB ): buildcmd += "--verbose "
  if ( LOGL == DEBG ): buildcmd += "--debug "

  for t in DEBTAGS:
    buildcmd += addTag( blk, t )

  if ( blk.has_key( 'description' ) ):

    desc = re.sub( r'"', '', blk.get( 'description' ) )

    if ( type( desc ) is not str ):
      _log( INFO, "Error: invalid description: '%s'\nSkipping package.\n" % desc );
      return 0

    if ( re.search( r'%V', desc ) ):
      desc = re.sub( '%V', ver, desc )
      _log( DEBG, "Updating desc with version: '%s'\n" % desc )

    _log( DEBG, "Adding description: %s\n" % desc )
    buildcmd += "--description '%s'" % desc

  else:
    buildcmd += "--description 'SAPO MetaPkg %s'" % name

  buildcmd += " 2>&1 >> %s" % FPMLOG

  _log( DEBG, "FPM COMMAND = %s\n" % buildcmd )

  print "\nFINAL CMD == %s\n" % buildcmd

  return 1

#
# buildPackage( VAR )
# VAR = ptr to file, input type, pakage name to build
#
def buildPackage( config, _type, pkg ):

  _log( INFO, "Loading package configuration for '%s'\n" % pkg )

  blk = dict( config.items( pkg ) )

  # Check if it's enabled
  if ( ( blk.has_key( 'disabled' ) and blk.get( 'disabled' ) == 'yes' ) or
       ( blk.has_key( 'enabled' ) and blk.get( 'enabled' ) == 'no' ) ):
    _log( INFO, "Package is not enabled. Skipping.\n" )
    return

  if ( LOGL >= DEBG ):
    _log( DEBG, "Package configuration block\n" )
    var_dump( blk )

  # Load package info
  maint = getMaintainers( blk.get( 'maintainers' ) )
  deps  = getDependencies( blk.get( 'dependencies' ), blk.get( 'exactdependenciesversions' ) )
  ver   = incVersion( config, pkg, blk.get( 'version' ) )

  if ( createPackage( blk, pkg, _type, maint, deps, ver ) ):
    print "yahoo!!!!"
#    config.write()

#
# buildAll
#
def buildAll( pkglist ):

  if ( len( pkglist ) > 0 ):

    _log( INFO, "Building package(s): %s\n" % pkglist )
    
    for pkg in pkglist:

      if ( re.search( r'meta', pkg ) ):
        _log( DEBG, "Creating '%s' from sapometa config.\n" % pkg )
        buildPackage( _sapometa, "empty", pkg )
      else:
        _log( DEBG, "Creating '%s' from generic config.\n" % pkg )
        buildPackage( _packages, "dir", pkg ) 
  
  else:
   print "No packages matched given criteria."

#
# buildPkg
#
def buildPkg( pkg ):

  _log( DEBG, "Searching for %s in: %s\n" % (pkg, packages) )

  if ( re.match( r'^~', pkg ) ):
    pkg = re.sub( r'~', '', pkg )
    pkgs = filter( lambda x : pkg not in x, packages )  
  else:
    pkgs = filter( lambda x : pkg in x, packages )  

  _log( VERB, "Filtered packages: %s\n" % pkgs )
  buildAll( pkgs )
  
#
# getMaxDisplayValues
# VAR = config block
# Helper function for obtain the highest field values to print
#
def getMaxDisplayValues( config ):

  blocks = config.sections()

  for p in blocks:
    b = dict( config.items( p ) )
    m = toString( b.get( 'maintainers' ) )

    lp = len( p ) + 1
    lm = len( m ) + 1

    if ( lp > DVALS[0] ): DVALS[0] = lp
    if ( lm > DVALS[3] ): DVALS[3] = lm

  if ( LOGL >= DEBG ):
    _log( DEBG, "MAX VALS: \n" )
    var_dump( DVALS )

#
# printPkgInfo
# VARS = name, version, enabled, maintainers, dependencies
# Helper function to print with format
#
def printPkgInfo( n, v, e, m, d ):

  fmt  = "%%-%ds "  % DVALS[0]      # Name
  fmt += "%%%ds "   % DVALS[1]      # Version
  fmt += "%%%ds  "  % DVALS[2]      # Enabled
  fmt += "%%-%ds "  % DVALS[3]      # Maintainers
  fmt += "%s"

  if ( d is None or d == "" ):
    d = "--" # no dependencies defined -- "

  print fmt % ( n, v, e, m, d )

#
# printPkgsBlock
# VAR = block
# Prints all packages and their info
#
def printPkgsBlock( config ):

  for p in config.sections():
    e = "yes"
    b = dict( config.items( p ) )
    m = toString( b.get( 'maintainers' ) )

    if ( b.has_key( 'enabled' ) ): e = b.get( 'enabled' )
    elif ( b.has_key( 'disabled' ) ): e = b.get( 'disabled' ) 

    if ( m == "" ):   
      m = "opers"

    printPkgInfo( p, b.get( 'version' ), e, m, toString( b.get( 'dependencies' ) ) )

#
# listAllConfigs
#
#
def listAllConfigs():

  if ( LOGL >= DEBG ):
    _log( DEBG, "HASH PACKAGES: \n" )
    var_dump( _packages.sections() )
    _log( DEBG, "HASH META: \n" )
    var_dump( _sapometa.sections() )

  getMaxDisplayValues( _sapometa )
  getMaxDisplayValues( _packages )

  printPkgInfo( "Package Name", "Version", "Make", "Maintainer(s)", "Dependencies" )
  print "-" * 128

  printPkgsBlock( _sapometa )
  printPkgsBlock( _packages )

  sys.exit( 0 )

##
## M A I N 
##

LOGL = INFO
parser = argparse.ArgumentParser( prog="meta", description="Meta Packages Generator", epilog='\n' )

parser.add_argument( '--debug',    '-d',  action='store_true', help='Enables debug mode' )
parser.add_argument( '--verbose',  '-v',  action='store_true', help='Enables verbose messages' )
parser.add_argument( '--quiet',    '-q',  action='store_true', help='Enables quiet mode' )
parser.add_argument( '--list',     '-l',  action='store_true', help='Lists packages' )
parser.add_argument( '--yes',      '-y',  action='store_true', help='Assume "yes" to all answers' )
parser.add_argument( '--buildall', '-ba', action='store_true', help='Builds all packages' )
parser.add_argument( '--build',    '-b',  help='Builds specified package(s)' )


args = parser.parse_args()

#
# check for useful params before doing any work (we're lazy!)
#
if ( len( sys.argv ) <= 1 or not ( args.list or args.buildall or args.build ) ):
  parser.print_help()
  sys.exit( 1 )

# set logging level
if ( args.quiet ):   LOGL = -1
if ( args.verbose ): LOGL = VERB
if ( args.debug ):   LOGL = DEBG


loadConfig()

if ( args.list ):
  listAllConfigs()

if ( args.build ):
  buildPkg( args.build )

