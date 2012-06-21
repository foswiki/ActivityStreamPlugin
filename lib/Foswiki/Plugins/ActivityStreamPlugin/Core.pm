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

package Foswiki::Plugins::ActivityStreamPlugin::Core;

use strict;
use warnings;

=begin TML

---+ package ActivityStreamPlugin::Core

=cut

use Digest::MD5 ();
use Foswiki::Func ();
use Foswiki::Time ();
use Foswiki::Logger::ActivityLogger ();
use Foswiki::Logger::PlainFile ();
use constant DEBUG => 1; # toggle me

our %MONTHNAME = (
  'Jan' => 'January', 
  'Feb' => 'February', 
  'Mar' => 'March', 
  'Apr' => 'Apri', 
  'May' => 'May', 
  'Jun' => 'June',
  'Jul' => 'July', 
  'Aug' => 'August', 
  'Sep' => 'September', 
  'Oct' => 'October', 
  'Nov' => 'November', 
  'Dec' => 'December',
);

our %WEEKDAY = ( 
  'Mon' => 'Monday',
  'Tue' => 'Tuesday',
  'Wed' => 'Wednesday',
  'Thu' => 'Thursday',
  'Fri' => 'Friday',
  'Sat' => 'Saturday',
  'Sun' => 'Sunday',
);

# actions listed here are excluded from %ACTIVITYSTREAM
use constant RESTRICTED_ACTIONS => qw(view sql rdiff);

=begin TML

---++ writeDebug($message(

prints a debug message to STDERR when this module is in DEBUG mode

=cut

sub writeDebug {
  print STDERR "ActivityStreamPlugin - $_[0]\n" if DEBUG;
}

=begin TML

---++ new($baseWeb, $baseTopic)

constructor for the plugin core

=cut

sub new {
  my ($class, $baseWeb, $baseTopic) = @_;

  my $this = bless({
    baseWeb=>$baseWeb,
    baseTopic=>$baseTopic,
  }, $class);

  my $result = Foswiki::Func::readTemplate("activitystream");

  return $this;
}

=begin TML

---++ DESTROY()

finalizer for the plugin core; called at the very end of the request handler

=cut

sub DESTROY {
  my $this;

  undef $this->{logger};
}

=begin TML

getter for the logger component

=cut

sub logger {
  my $this = shift;
    
  unless (defined $this->{logger}) {
    require Foswiki::Logger::ActivityLogger;
    $this->{logger} = new Foswiki::Logger::ActivityLogger;
  }

  return $this->{logger};
}

=begin TML

---++ handleACTIVITYSTREAM($session, $params) -> $result

implementation of this macro

=cut

sub handleACTIVITYSTREAM {
  my ($this, $session, $params) = @_;

  $this->addToZone;

  # get params
  my $theFormat = $params->{format};

  my $theHeader = $params->{header};
  my $theFooter = $params->{footer};
  my $theSep = $params->{separator} || '';

  my $theSubFormat = $params->{subformat};

  my $theAction = $params->{action};
  my $theLevel = $params->{level};

  if (!defined($theHeader) && !defined($theFooter)) {
    $theHeader = "<div class='activityStream jqTooltip jqShrinkUrls {size:25, trunc:\"middle\"}'>";
    $theFooter = "</div>"
  }

  $theLevel = "info" unless defined $theLevel;

  my $theAgent = $params->{agent};
  my $theInclude = $params->{include};
  my $theExclude = $params->{exclude};
  my $theUsers = $params->{users};

  my $theSort = $params->{sort} || 'time';
  if ($theSort =~ /^(level|user|time|action|agent)$/) {
    $theSort = $1;
  } else {
    $theSort = 'time';
  }

  my $theReverse = $params->{reverse};
  $theReverse = Foswiki::Func::isTrue($theReverse, $theSort eq 'time' ? 1:0);
 
  my $theWeb = $params->{web};
  my $theTopic = $params->{topic};

  if ($theTopic) {
    ($theWeb, $theTopic) = Foswiki::Func::normalizeWebTopicName($theWeb, $theTopic);
  }

  my $theTime = $params->{since};
  if (defined $theTime) {
    $theTime = Foswiki::Time::parseTime($theTime);
  } else {
    $theTime = 0;
  }

  my $theLimit = $params->{limit} || 10;
  my $theSkip = $params->{skip} || 0;
  $theSkip =~ s/[^\d]//g;
  $theLimit =~ s/[^\d]//g;

  my $dbh = $this->logger->{dbh};

  # construct where clause
  my @where = ();
  push @where, "level in(".join(", ", map($dbh->quote($_), split(/\s*,\s*/, $theLevel))).")" if defined $theLevel;
  push @where, "action in(".join(", ", map($dbh->quote($_), split(/\s*,\s*/, $theAction))).")" if defined $theAction;
  push @where, "agent in(".join(", ", map($dbh->quote($_), split(/\s*,\s*/, $theAgent))).")" if defined $theAgent;
  push @where, "user in(".join(", ", map($dbh->quote($_), split(/\s*,\s*/, $theUsers))).")" if defined $theUsers;
  push @where, "time >= FROM_UNIXTIME(".$dbh->quote($theTime).")" if $theTime;
  push @where, "web = ".$dbh->quote($theWeb) if $theWeb;
  push @where, "topic = ".$dbh->quote($theTopic) if $theTopic;
  push @where, "not action in (".join(", ", map($dbh->quote($_), RESTRICTED_ACTIONS)).")";
  push @where, "topic regexp ".$dbh->quote($theInclude) if $theInclude;
  push @where, "not topic regexp ".$dbh->quote($theExclude) if $theExclude;

  my $whereClause = '';
  $whereClause = "where ".join(" and ", @where) if @where;

  # construct the limit clause
  my $limitClause = '';
  if ($theLimit) {
    my $moreLimit = $theLimit * 2; # some buffer when filtering on application level, e.g. ACL :(
    if ($theSkip) {
      $limitClause = "limit $theSkip, $moreLimit";
    } else {
      $limitClause = "limit $moreLimit";
    }
  } else {
    if ($theSkip) {
      $limitClause = "limit $theSkip, 18446744073709551615";
    }
  }

  # construct the order by clause
  my $orderByClause = "order by $theSort ".($theReverse?'desc':'asc');

  # create sql statements
  my $statement = 'select level, max(time) as time, user, 
    group_concat(distinct web, ".", topic, "@", filename order by time desc, web, topic, filename separator ", " ) as objects, 
    group_concat(distinct message separator " ") as message, 
    action from logs '.
    $whereClause.
    ' group by user, action, round(UNIX_TIMESTAMP(time)/3600) '.
    $orderByClause.' '.$limitClause;

  writeDebug("statement=$statement");

  # execute and format result
  my $sth;
  my $error;
  eval {
    $sth = $dbh->prepare($statement);
    $sth->execute;
  };

  if ($@) {
    print STDERR "ERROR: ".$@."\n";
    return '<span class="foswikiAlert">ERROR: executing sql command</span>';
  };

  my @result = ();
  my $index = 0;
  my $prevTime;
  my $prevDate = '';
  my $wikiName = Foswiki::Func::getWikiName();
  my $loginName = Foswiki::Func::wikiToUserName($wikiName);

  # loop thru all records
  while (my $row = $sth->fetchrow_hashref) {
    last if $index >= $theLimit;

    my $time = $row->{"time"};

    my $date;
    if ($time =~ /^(.*) /) {
      $date = $1;
    }

    if ($date ne $prevDate) {
      my $dateFormat = $params->{dayheader};
      $dateFormat = Foswiki::Func::expandTemplate("activity::dayheader") unless defined $dateFormat;

      if ($dateFormat) {
        $dateFormat =~ s/\$date/$date/g;
        $dateFormat =~ s/\$formatTime\((.*)(?:, '(.*?)')\)/formatTime($1, $2)/ge;
        push @result, $dateFormat;
      }
    }
    $prevDate = $date;

    # get all objects affected by this action
    my @objects = ();
    foreach my $object (split(/\s*,\s*/, $row->{"objects"}||'')) {
      my ($thisWeb, $thisTopic, $thisFilename) = parseObjectAddress($object);
      push @objects, $object
        if Foswiki::Func::checkAccessPermission("VIEW", $wikiName, undef, $thisTopic, $thisWeb);
    }

    my $countObjects = scalar(@objects);
    next unless $countObjects;


    # get line format for this action
    my $action = $row->{"action"};
    my $line;
    my $subline;

    if ($countObjects > 0) {
      $action = "multi_".$action if $countObjects > 1;

      # get format for subline used in inner loops of multi-actions 
      $subline = $params->{$action."_subformat"};
      $subline = Foswiki::Func::expandTemplate("activity::".$action."_subformat") unless defined $subline;
      $subline = $theSubFormat unless $subline; # SMELL expandTemplate does not return undef?
      $subline = Foswiki::Func::expandTemplate("activity::subformat") unless $subline;
      $subline = '$web.$topic.$filename' unless $subline;
    }

    $line = $params->{$action."_format"};
    $line = Foswiki::Func::expandTemplate("activity::".$action."_format") unless defined $line;
    $line = $theFormat unless $line; # SMELL expandTemplate does not return undef?
    unless ($line) {
      if ($countObjects > 1) {
        $line = Foswiki::Func::expandTemplate("activity::multi_format");
      } else {
        $line = Foswiki::Func::expandTemplate("activity::format");
      }
    }

    # loop thru all objects affected in this record
    my @subresult = ();
    my $web;
    my $topic;
    my $filename;
    foreach my $object (@objects) {
      my ($thisWeb, $thisTopic, $thisFilename) = parseObjectAddress($object);

      # get the first web and topic info
      if (!defined($web) && !defined($topic)) {
        # format the first outside to get "You edited topic x and y more ... (list goes here)"
        $web = $thisWeb;
        $topic = $thisTopic;
        $filename = $thisFilename;
        $line =~ s/\$web/$web/g;
        $line =~ s/\$topic/$topic/g;
        $line =~ s/\$filename/$filename/g;
      }

      #writeDebug("action=$action, object=".join(", ", @objects).", message = $row->{message}");

      my $thisline = $subline;

      $thisline =~ s/\$filename/$thisFilename/g;
      $thisline =~ s/\$web/$thisWeb/g;
      $thisline =~ s/\$topic/$thisTopic/g;

      push @subresult, $thisline;
    }

    # insert subline into line
    $line =~ s/\$subformat(?:\((.*?)\))?/join($1||'', @subresult)/ge;
    $line =~ s/\$countobjects/$countObjects/g;

    # special handling of moveattachment
    # target=web.topic in message field
    if ($action =~ /^(multi_)?moveattachment$/) {
      if ($row->{message} =~ /^target=(.*)$/) { 
        my $target = $1;
        my ($targetWeb, $targetTopic) = Foswiki::Func::normalizeWebTopicName(undef, $target);
        $line =~ s/\$targetweb/$targetWeb/g;
        $line =~ s/\$targettopic/$targetTopic/g;
        $row->{message} = '';
      }
    }

    # special handling of rename
    # move to target topic in message field -> TODO: rewrite in logger using taget=...?
    if ($action eq 'rename') {
      if ($row->{message} =~ /^.*moved to ([^\s].*$)/) {
        my $target = $1;
        my ($targetWeb, $targetTopic) = Foswiki::Func::normalizeWebTopicName(undef, $target);
        $line =~ s/\$targetweb/$targetWeb/g;
        $line =~ s/\$targettopic/$targetTopic/g;
        $row->{message} = '';
      }
    }

    # special handling of renameattachment
    # target=filename in message field
    if ($action =~ /^(multi_)?renameattachment$/) {
      if ($row->{message} =~ /^target=(.*)$/) {
        my $target = $1;
        $line =~ s/\$targetfilename/$target/g;
      }
    }

    # special handling of renameweb
    # move to target web in message field -> TODO: rewrite in logger using taget=...?
    if ($action eq 'renameweb') {
      if ($row->{message} =~ /^.*moved to ([^\s].*$)/) {
        my $target = $1;
        $target =~ s/\//\./g;
        $line =~ s/\$targetweb/$target/g;
        $row->{message} = '';
      }
    }

    # special handling of comment events
    if ($action =~ /^comment/) {
      my $message = $row->{message};
      my $state = '';
      if ($message =~ s/state=\((.+?)\)\s*//) {
        $state = $1;
        $row->{message} = $message;
      }

      # get approval mode of the topic
      # SMLE: what about the multi_comment... actions?
      Foswiki::Func::pushTopicContext($web, $topic);
      my $approval = Foswiki::Func::getPreferencesValue("COMMENTAPPROVAL") || '';
      Foswiki::Func::popTopicContext;
      
      #writeDebug("action=$action, approval='$approval', state='$state', message=$message");

      # skip comment activities on unapproved comments in case the topic is in approval mode
      if ($action ne 'commentdelete' && $approval eq 'on' && $state =~ /unapproved/) {
        next;
      }
    }

    # insert columns from database
    foreach my $key (keys %$row) {
      my $val = $row->{$key} || '';
      $line =~ s/\$$key/$val/g;
      if ($key eq 'user') {
        if ($val eq $loginName || $val eq $wikiName) {
          $line =~ s/\$wiki(user)?name/You/g;
        } else {
          $line =~ s/\$wikiname/Foswiki::Func::getWikiName($val)/ge;
          $line =~ s/\$wikiusername/Foswiki::Func::getWikiUserName($val)/ge;
        }
      }
    }

    $line =~ s/\$formatTime\((.*)(?:, '(.*?)')\)/formatTime($1, $2)/ge;
    $line =~ s/\$index/$index/g;
    $line =~ s/\$topic/$topic/g;
    $line =~ s/\$web/$web/g;

    # skip "edit" records where the preceding record had exactly the same timestamp
    my $doSkip = 0;
    if (defined($prevTime) && defined($time) && $prevTime eq $time) {
      if ($action =~ /^edit/) {
        # prefering any other action in favour of a plain edit
        $doSkip = 1;
        #writeDebug("...suppress $action on $web.$topic");
      } else {
        # undo the previous line and replace it with this one
        my $prevLine = pop @result;
        #writeDebug("... undoing $prevLine");
      }
    } 
    
    push @result, $line unless $doSkip;

    $prevTime = $time;
    $index++;
  }

  return '' unless @result;

  my $result = $theHeader.join($theSep, @result).$theFooter;

  my $countRows = $this->countRows($dbh, $statement);
  $result =~ s/\$count/$countRows/g;

  return Foswiki::Func::decodeFormatTokens($result);
}

sub parseObjectAddress {
  my $object = shift;

  #writeDebug("called parseObjectAddress($object)");

  my ($web, $topic, $filename) = ('???', '???', '???');
  if ($object =~ /^(.*)\.(.*?)@(.*?)$/) {
    $web = $1;
    $topic = $2;
    $filename = $3 || '';
    ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);
  }

  #writeDebug("... web=$web, topic=$topic, filename=$filename)";

  return ($web, $topic, $filename);
}

sub countRows {
  my ($this, $dbh, $statement) = @_;

  my $key = "_countRows".Digest::MD5::md5($statement);
  my $count = $this->{$key};
  return $count if defined $count;

  my $countStatement = 'select count(*) from ('.$statement.') as temp_table';
  #writeDebug("countStatement=$countStatement");

  eval {
    my $sth = $dbh->prepare($countStatement); 
    $sth->execute;
    $this->{$key} = $count = $sth->fetchrow_array; 
  };

  if ($@) {
    print STDERR "ERROR counting results: ".$@."\n";
  }

  return $count;
}

sub addToZone {
  my $this = shift;

  return if defined $this->{doneAddToZone};
  $this->{doneAddToZone} = 1;

  Foswiki::Func::expandCommonVariables(Foswiki::Func::expandTemplate("activity::addtozone"));
}

=begin TML

---++ handleImport($session, $subject, $verb, $response)

import events logged by a PlainFile logger into the database

=cut

sub handleImport {
  my ($this, $session, $subject, $verb, $response) = @_;

  return "ERROR: only admin can import\n" unless Foswiki::Func::isAnAdmin();

  my $dbiLogger = new Foswiki::Logger::ActivityLogger;
  my $request = $session->{request};

  my $since = $request->param("since");
  $since = Foswiki::Time::parseTime($since) if defined $since && $since !~ /^\d$/;

  my $rebuild = $request->param("rebuild");

  if (Foswiki::Func::isTrue($rebuild, 0)) {
    writeDebug("rebuilding the data from scratch by droping all previous records");
    $dbiLogger->rebuild; 
  }

  my $count = $dbiLogger->import($since);
  writeDebug("imported $count records");
}

=begin TML

---++ formatTime($time, $format)

parse the date string and reformat it according to the given specification.
In addition to feed the time argument through Foswiki::Time::parseTime and Foswiki::Time::formatTime
isomonth names and weekdays are translated to more friendly full names

TODO: i18n 

=cut

sub formatTime {
  my ($time, $format) = @_;

  $time ||= 0;

  unless ($time =~ /^-?\d+$/) {
    $time = Foswiki::Time::parseTime($time);
  }

  $time ||= 0;

  my $result = Foswiki::Func::formatTime($time, $format);

  # map iso month to real month names
  $result =~ s/\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b/$MONTHNAME{$1}/ge;

  # map iso day to real day names
  $result =~ s/\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b/$WEEKDAY{$1}/ge;

  return $result;
}

1;
