package Foswiki::Logger::ActivityLogger;

use strict;
use warnings;
use Assert;

use Foswiki::Logger ();
our @ISA = ('Foswiki::Logger');

use constant DEBUG => 1; # toggle me

=begin TML

---+ package Foswiki::Logger::ActivityLogger

DBI based implementation of the Foswiki Logger interface specialized for the ActivityStreamPlugin

=cut

use Foswiki::Plugins ();
use Foswiki::Logger::PlainFile ();
use DBI ();
use Error qw(:try);

=begin TML

---++ ClassMethod new()

constructor: also creates the tables if they don't exist yet

=cut

sub new {
  my $class = shift;
  my $this = bless({}, $class);

  writeDebug("called new()");

  try {
    $this->connect;
    $this->createTable;
  }
  catch Error::Simple with {
    my $error = shift;
    print STDERR "ERROR: unable to create database connection for dbi logger: " . $DBI::errstr . "\n";
  };

  my $secondaryLogger = $Foswiki::cfg{ActivityStreamPlugin}{SecondaryLogger};

  if (defined $secondaryLogger && $secondaryLogger ne 'none') {
    eval "require $secondaryLogger";
    if ($@) {
      print STDERR "Secondary logger load failed: $@";
    } else {
      $this->{secondaryLogger} = $secondaryLogger->new();
    }
  }

  foreach my $level qw(debug info warning error critical alert emergency) { 
    $this->{$level} = $Foswiki::cfg{ActivityStreamPlugin}{ucfirst($level)};
  }
  $this->{info} = 1 unless defined $this->{info}; # defaults to on

  return $this;
}

=begin TML

---++ ObjectMethod finish()

cleans up the mess we left behind

=cut

sub finish {
  my $this = shift;

  writeDebug("called finish()");

  $this->{secondaryLogger}->finish if defined $this->{secondaryLogger};

  if($this->{dbh}) {
    $this->{dbh}->disconnect;
    undef $this->{dbh};
  }

  if ($this->{sth_log}) {
    $this->{sth_log}->finish;
    undef $this->{sth_log};
  }
}

=begin TML

---++ ObjectMethod connect()

connects to the database

=cut

sub connect {
  my $this = shift;

  writeDebug("called connect()");

  unless (defined $this->{dbh}) {
    
    writeDebug("establishing a new connection");

    my $dsn = $Foswiki::cfg{ActivityStreamPlugin}{DSN};

    my $username = $Foswiki::cfg{ActivityStreamPlugin}{Username};

    my $password = $Foswiki::cfg{ActivityStreamPlugin}{Password};

    $this->{dbh} = DBI->connect(
      $dsn,
      $username,
      $password,
      { 
        PrintError => 0, 
        RaiseError => 1 
      });

    throw Error::Simple("Can't open database $dsn: ". $DBI::errstr)
      unless defined $this->{dbh};
  } else {
    writeDebug("reusing an already existing connection");
  }

  return $this->{dbh};
}

=begin TML

---++ ObjectMethod createTable()

creates the database tables if not existing yet

=cut

sub createTable {
  my $this = shift;

  writeDebug("called createTable()");

  $this->{dbh}->do(qq{create table if not exists logs (
    level enum("debug", "info", "warning", "error", "critical", "alert", "emergency"),
    time timestamp,
    user varchar(255),
    action varchar(255),
    web varchar(255),
    topic varchar(255),
    filename varchar(255),
    cached enum("yes", "no"),
    message text,
    agent varchar(255),
    referrer varchar(255),
    index(level),
    index(time),
    index(user),
    index(action),
    fulltext(message),
    index(web),
    index(topic),
    index(filename)
  )});
}

=begin TML

---++ ObjectMethod rebuild()

drops all of the logs table and creates a new one. 

CAUTION: you will have to import the data from the PlainLogger again to recover.

=cut

sub rebuild {
  my $this = shift;

  writeDebug("called rebuild()");

  $this->{dbh}->do("drop table logs");
  $this->createTable;
}

=begin TML

---++ ObjectMethod import($since) -> $count

imports data from the PlainFile logger into the database

The optional $since parameter specifies the timestamp in unix epoch seconds
from which on to import records. This defaults to the maximum time found in the
database so far.  This allows to cron-job the importer instead of loggin to the
database live.

If $since is specified will only import data since this 

returns the number of imported records

TODO: optionally import the other levels as well

=cut

sub import {
  my ($this, $since) = @_;

  writeDebug("called import()");

  my $plainLogger = new Foswiki::Logger::PlainFile;

  unless (defined $since) {
    my $sth = $this->{dbh}->prepare('select UNIX_TIMESTAMP(max(time)) from logs');
    $sth->execute;
    $since = $sth->fetchrow_array;
  }

  $since = 0 unless defined $since;

  # import info
  my $iter = $plainLogger->eachEventSince($since+1, "info");
  my $count = 0;
  while ($iter->hasNext) {
    my $entry = $iter->next;

    my @record = $this->createLogRecord('info', 
      time => shift @$entry,
      user => shift @$entry,
      action => shift @$entry,
      webTopic => shift @$entry,
      message => shift @$entry,
      remoteAddr => shift @$entry,
    );
    next unless @record;

    $this->insertLogRecord(@record);
    $count++;
    #writeDebug("$count records imported");
    #last if $count > 10; # for debugging;
  }

  return $count;
}

=begin TML

---++ ObjectMethod createLogRecord($level, %params) -> 
  ($level, $time, $user, $action, $web, $topic, $filename, $message, $cached, $agent, $remoteAddr)

this creates a database record suitable to be inserted into the logs table derived from
a set of properties given 

Known params are:

   * time: optinal timestamp (defaults to now)
   * user: optional login name of the user who triggered this entry (defaults to current session user)
   * action: optional action tag that triggered this record
   * webTopic: optional address of the location where the event happended
   * message: optional generic log message
   * remoteAddr: ip address of the http request

A couple of log actions are ignored

   * "rest": this event is too unspecific; best is to let the rest handlers log more specific events
   * "attach": this event is kind of deprecated in favour of "upload"
   * "changes": this event, emitted by UI::Changes is ignored for now
   * "viewfile": this event isn't representative for accessing attachments

SMELL: make above configurable

The "edit" event is mostly ignored as the "save" event coming later on is more meaningful,
with the exception when there's a "(not exist)" message. In this case a new topic has been
created. We only check if the resulting topic does exist to weed out those cases where
there are accidental edits without a "save". These "edits" are recasted into a "new" action.

=cut

sub createLogRecord {
  my $this = shift;
  my $level = shift;
  my %params = @_;

  #writeDebug("called createLogRecord()");
  
  my $session = $Foswiki::Plugins::SESSION;
  my $request = $session->{request};

  # ignored actions
  my $action = $params{"action"} || '';
  return if $action =~ /^(rest|attach|viewfile)$/;

  # get web.topic info
  my ($web, $topic);
  if (defined $params{"webTopic"}) {
    ($web, $topic) = Foswiki::Func::normalizeWebTopicName($session->{webName}, $params{"webTopic"});
  } else {
    $web = $session->{webName}; 
    $topic = $session->{topicName};
  }
  $web =~ s/\//\./g;

  # get message
  my $message = $params{"message"} || '';
  $message =~ s/,?\s*(minor|dontlog).*$//g; # some cleanup

  # strip off any log info coming from test cases
  if ($message =~ /scumbag/ || $topic =~ /ScumBag/ || $web =~ /^Temporary.*/ || $topic =~ /AUTOINC|XXXXXXXXXX/ ) {
    return; # ignore
  }

  # get caching info
  my $cached = "no";
  if ($message =~ s/\s*\(cached\)\s*//) {
    $cached = "yes";
  }

  # get the user agent from the message string
  my $agent = $this->getUserAgent($message);
  $message =~ s/\s*$agent\s*$//;

  # get filename
  my $filename = $params{"filename"} || '';

  # ignore anything happening inside the Trash web
  if ($web eq $Foswiki::cfg{TrashWebName}) {
    return; # ignore
  }

  # get the user
  my $user = defined($params{"user"})?$params{"user"}:$session->{user};

  # get remote address
  my $remoteAddr = defined($params{"remoteAddr"})?$params{"remoteAddr"}:($request->remoteAddress || '');

  # time
  my $time = defined($params{"time"})?$params{"time"}:time;
  $time = Foswiki::Time::formatTime($time, "iso");

  # for view: dont log the views for non-existing topics;
  # maybe that info gets interesting for some reason later; for now we just strip that off
  if ($action eq 'view') {
    if ($message eq '(not exist)') {
      return; # ignore
    }
  }

  # for edit: check if this is a not-exist message; if so then recast the action to "new"
  elsif ($action eq 'edit') {
    if ($message =~ /\(not exist\)/) {
      $action = "new";
      $message = "";
    } else {

      # don't log normal edit events as there's a save event pairing up;
      # for now we are not interested in edits which there are no saves for
      return;
    }
  }

  # for login: remap login failures
  elsif ($action eq 'login') {
    if ($message =~ /AUTHENTICATION (FAILURE|SUCCESS) - (.*) -/) {
      $user = $2;
      $action = ($1 eq 'FAILURE')?"loginfailure":"login";
      $message = '';
    }
  }

  # for logout: move the user name from the message field back to the user field (wtf)
  # SMELL: how to restore the location _where_ the dude left the building
  elsif ($action eq 'logout') {
    if ($message =~ /AUTHENTICATION LOGOUT - (.*?) -/) {
      $user = $1;
      $message = '';
    }
  }

  # for move: a move to trash is a delete attachment
  elsif ($action eq 'move') {
    my $source = ''; 
    my $target = ''; 
    if ($params{"webTopic"} =~ /^\s*(.*?)\s*moved? to\s*(.*?)\s*$/) {
      $source = $1;
      $target = $2;

      #writeDebug("move source='$source', target='$target'");

      # distinguish renaming, moving and deleting attachments
      if ($target =~ /^$Foswiki::cfg{TrashWebName}\.TrashAttachment/) {
        $action = "deleteattachment";
        ($web, $topic, $filename) = parseAttachmentAddress($source);
        $message = "";
      } else {
        ($web, $topic, $filename) = parseAttachmentAddress($source);
        my ($targetWeb, $targetTopic, $targetFilename) = parseAttachmentAddress($target);
        #writeDebug("target=$target -> targetWeb=$targetWeb, targetTopic=$targetTopic, targetFilename=$targetFilename");
        $message = "target=".$targetWeb.".".$targetTopic."@".$targetFilename;
        
        if ($web eq $targetWeb && $topic eq $targetTopic) {
          $action = "renameattachment";
        } else {
          $action = "moveattachment";
        }
        #writeDebug("action now=$action web=$web, topic=$topic, filename=$filename, message=$message");
      }

    } else {
      # never reach
      #writeDebug("move message: ".$params{"webTopic"});
    }
  }

  # for rdiff: rewrite message to; map to compare
  elsif ($action =~ /^(compare|rdiff)$/) {
    $action = "compare";
    if ($message =~ /(\d+) (\d+)/) {
      $message = "rev1=$1 rev2=$2";
    } else {
      $message = "";
    }
  }

  # for register: strip off the domain part from the email addr
  elsif ($action eq 'register') {
    $message =~ s/^\s*(.*?)@(.*?)\s*$/$1/;
  }

  # for rename: rename the action to delete if it is a move to trash
  elsif ($action eq 'rename') {
    if ($message =~ /moved? to (.*)/) {
      my $target = $1;
      if ($target =~ /$Foswiki::cfg{TrashWebName}/) {
        $action = 'delete';
        $message = '';
      } else {
        $message = 'target='.$target;
      }
    }
  }

  # for renameweb: rewrite the message 
  elsif ($action eq 'renameweb') {
    if ($message =~ /moved? to (.*)/) {
      my $target = $1;
      if ($target =~ /$Foswiki::cfg{TrashWebName}/) {
        $action = 'deleteweb';
        $message = '';
      } else {
        $message = 'target='.$target;
      }
    }
  }

  # for save: recast "save" action to "edit" as the "save" event finally marks the completed edit
  elsif ($action eq 'save') {
    # is this an edit of an attachment
    if ($message ne '') {
      $action = "editattachment";
      $filename = $message;
      $message = "";
      #writeDebug("found an editattachment filename=$filename");
    } else {
      $action = "edit";

      # get change summary 
      # SMELL: doesn't generate anything readable
      #
      #require Foswiki::Meta;
      #my $meta = new Foswiki::Meta($session, $web, $topic);
      #$message = $meta->summariseChanges || '';
    }
  }

  # for upload: extract the filename from the message part
  elsif ($action eq 'upload') {
    $filename = $message;
    $message = "";
  }

  # must match insert sql statement
  return ($level, $time, $user, $action, $web, $topic, $filename, $message, $cached, $agent, $remoteAddr);
}

sub parseAttachmentAddress {
  my $webTopicFilename = shift;

  #writeDebug("called parseAttachmentAddress($webTopicFilename)");

  my @parts = split(/[\.\/]/, $webTopicFilename);
  #writeDebug("parts=".join(', ', @parts));

  # the first one is always a web
  my $web = shift @parts;
  my $topic;
 
  # SMELL: depends on the webs and topics to still exist ... which
  # isnt necessarily the case when importing old data
  while (my $part = shift @parts) {
    if (Foswiki::Func::topicExists($web, $part)) {
      $topic = $part;
      last;
    }

    if (Foswiki::Func::webExists($web.'.'.$part)) {
      $web .= '.'.$part;
      next;
    }

    $topic = $part;
    last;
  }

  my $filename = join('.', @parts);

  #writeDebug("got web=$web, topic=$topic, filename=$filename");

  return ($web, $topic, $filename);
}

sub getUserAgent {
  my $this = shift;
  my $agent = shift;

  my $session = $Foswiki::Plugins::SESSION;

  $agent = $session->{request}->user_agent unless defined $agent;
  $agent ||= '';

  if ($agent =~ /(MSIE 6|MSIE 7|MSIE 8|MSI 9|Firefox|Opera|Konqueror|Chrome|Safari)/) {
    $agent = $1;
  } else {
    return '';
  }

  return $agent;
}

=begin TML

---++ ObjectMethod log($level, $user, $action, $webTopic, $message, $remoteAddr)

See Foswiki::Logger for the interface.

=cut

sub log {
  my $this = shift;
  my @params = @_;

  #writeDebug("called log()");
  $this->{secondaryLogger}->log(@params) if defined $this->{secondaryLogger} && $this->{secondaryLogger} ne 'none';

  # only pass it to the secondary logger in case the level has been switched off for logging into the database
  my $level = shift;
  return if $level =~ /^(debug|info|warning|error|critical|alert|emergency)$/ && !$this->{$level}; 

  # create a log record 
  my @record;

  if ($level eq 'info') {
    # called via Foswiki::logEvent
    my ($user, $action, $webTopic, $message, $remoteAddr) = @_;
    @record = $this->createLogRecord("info", 
      user => $user, 
      action => $action, 
      webTopic => $webTopic, 
      message => $message, 
      remoteAddr => $remoteAddr
    );
    return unless @record;

  } elsif ($level eq 'warning') {
    # via Foswiki::Func::writeWarning
    my $message = shift;
    $message .= ": ";
    $message .= shift;
    @record = $this->createLogRecord("warning", 
      message=>$message
    );

  } else {
    my $message = shift;
    @record = $this->createLogRecord($level, 
      message=>$message
    );
  }

  $this->insertLogRecord(@record);
}

=begin TML

---++ ObjectMethod insertLogRecord($level, $time, $user, $action, $web, $topic, $message, $cached, $agent, $referrer)

writes the given record to the database

=cut

sub insertLogRecord {
  my $this = shift;

  #writeDebug("called insertLogRecord");

  unless (defined $this->{sth_log}) {
    $this->{sth_log} = $this->{dbh}->prepare(qq{
      insert into logs 
        (level, time, user, action, web, topic, filename, message, cached, agent, referrer) values 
        (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    });
  }

  return $this->{sth_log}->execute(@_);
}

=begin TML

---++ StaticMethod eachEventSince($time, $level) -> $iterator

See Foswiki::Logger for the interface.

=cut

sub eachEventSince {
  my ($this, $time, $level) = @_;

  #writeDebug("called eachEventSince()");
  #return $this->{secondaryLogger}->eachEventSince($time, $level) if defined $this->{secondaryLogger};

  return new Foswiki::Logger::ActivityLogger::EventIterator($this->{dbh}, $time, $level);
}

# Private subclass of Iterator that returns the result set of the logs database
{

  package Foswiki::Logger::ActivityLogger::EventIterator;
  use Foswiki::Iterator ();
  @Foswiki::Logger::ActivityLogger::EventIterator::ISA = ('Foswiki::Iterator');

  sub new {
    my ($class, $dbh, $threshold, $level) = @_;

    my $this = bless(
      {
        dbh => $dbh,
        threshold => $threshold,
        level => $level,
      },
      $class
    );

    my @where = ();
    push @where, "level = '$level'" if $level;
    push @where, "time >= FROM_UNIXTIME('$threshold')" if $threshold;
    my $where = '';
    $where = "where ".join(" and ", @where) if @where;

    $this->{sth} = $dbh->prepare(
      "select time, user, action, web, topic, message, agent, referrer from logs order by time $where"
    );
    $this->{sth}->execute;

    return $this;
  }

  sub DESTROY {
    my $this = shift;
    
    $this->{sth}->finish if defined $this->{sth};

    undef $this->{dbh};
    undef $this->{nextEvent};
  }

  sub hasNext {
    return $_[0]->_getNextEvent?1:0;
  }

  sub _getNextEvent {
    my $this = shift;

    unless (defined $this->{nextEvent}) {
      my @values  = $this->{sth}->fetchrow_array;
      $this->{nextEvent} = \@values if @values;
    }

    return $this->{nextEvent};
  }

  sub next {
    my $this = shift;

    my $data = $this->_getNextEvent;
    undef $this->{nextEvent};

    return $data;
  }

}

=begin TML

---++ StaticMethodewriteDebug($string)

write debug output if the DEBUG flag is set

=cut

sub writeDebug {
  print STDERR "ActivityLogger - $_[0]\n" if DEBUG;
}

1;

__END__
Module of Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2011-2012 Michael Daum http://michaeldaumconsulting.com

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
