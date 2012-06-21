# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# ActivityStreamPlugin is Copyright (C) 2011-2012 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Plugins::ActivityStreamPlugin;

use strict;
use warnings;

=begin TML

---+ package ActivityStreamPlugin

=cut

use Foswiki::Func ();

our $VERSION = '$Rev$';
our $RELEASE = '0.01';
our $SHORTDESCRIPTION = 'Display yours and others activities on a Foswiki site';
our $NO_PREFS_IN_TOPIC = 1;
our $baseWeb;
our $baseTopic;
our $core;

=begin TML

---++ initPlugin($topic, $web, $user) -> $boolean

=cut

sub initPlugin {
  ($baseTopic, $baseWeb) = @_;

  Foswiki::Func::registerTagHandler('ACTIVITYSTREAM', sub {
    return getCore()->handleACTIVITYSTREAM(@_);
  });

  Foswiki::Func::registerRESTHandler('import', sub {
    return getCore()->handleImport(@_);
  });

  $core = undef;
  return 1;
}

=begin TML

---++ finishPlugin()

=cut

sub finishPlugin {
  undef $core;
}

=begin TML

---++ getCore()

=cut

sub getCore {
  unless (defined $core) {
    require Foswiki::Plugins::ActivityStreamPlugin::Core;
    $core = new Foswiki::Plugins::ActivityStreamPlugin::Core($baseWeb, $baseTopic);
  }

  return $core;
}

1;
