# meta-packages
Scripts to build a meta package, which is just an empty rpm or deb that has a specific list of dependencies such that once installed all dependencies will be as well.

These were done while I worked at SAPO (http://www.sapo.pt) to ease the installation of new servers with a specific set of packages depending on their function.
The package creation process requires the EPM (Effing Package Manager) to be installed and is used to create .deb and .rpm files and apt-file binary to locate the source package of a given file.

The script (meta.pl) will read 3 configuration files:
 - common.conf, which has globals for all packages
 - packages.conf, a generic list of assorted packages (not necessarily related, some for testing)
 - sapometa.conf, sapo related packages only

Once loaded and having a specified target package, the script will lookup all files needed and return a list of all packages required to have them inside a single .deb or .rpm as a dependency requirement.
This means we just neeed to install 1 package to have the full stack installed "automagically".

Custom packages were created in-house using a chroot environment were also present in a private repository that the script will query for dependency cascading as well.


There is also a \_meta.py script which is basically a "translation" to python of the perl script.
