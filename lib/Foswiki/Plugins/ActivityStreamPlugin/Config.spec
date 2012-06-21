# ---+ Extensions
# ---++ ActivityStreamPlugin
# This is the configuration used by the <b>ActivityStreamPlugin</b>.
# Please make sure that you configured the {Log}{Implementation} to <code>Foswiki::Logger::DBI</code>

# **STRING**
# Database source name; specifies the driver and location of the database backend.
$Foswiki::cfg{ActivityStreamPlugin}{DSN} = 'dbi:mysql:foswiki:localhost';

# **STRING**
# Username to access the database for logging
$Foswiki::cfg{ActivityStreamPlugin}{Username} = 'foswiki';

# **PASSWORD 30**
# Password for the database user account
$Foswiki::cfg{ActivityStreamPlugin}{Password} = 'foswiki';

# **SELECTCLASS none,Foswiki::Logger::* **
# Specify a secondary logger that is used as a backup in addition to the DBI logger
$Foswiki::cfg{ActivityStreamPlugin}{SecondaryLogger} = 'Foswiki::Logger::PlainFile';

# **BOOLEAN**
# Enables/disables logging "debug" messages to the database.
# If disabled the log message is # only forwarded to the secondary logger
$Foswiki::cfg{ActivityStreamPlugin}{Debug} = 0;

# **BOOLEAN**
# Enables/disables logging "info" messages to the database.
# If disabled the log message is # only forwarded to the secondary logger
$Foswiki::cfg{ActivityStreamPlugin}{Info} = 1;

# **BOOLEAN**
# Enables/disables logging "warning" messages to the database.
# If disabled the log message is # only forwarded to the secondary logger
$Foswiki::cfg{ActivityStreamPlugin}{Warning} = 0;

# **BOOLEAN**
# Enables/disables logging "error" messages to the database.
# If disabled the log message is # only forwarded to the secondary logger
$Foswiki::cfg{ActivityStreamPlugin}{Error} = 0;

# **BOOLEAN**
# Enables/disables logging "critical" messages to the database.
# If disabled the log message is # only forwarded to the secondary logger
$Foswiki::cfg{ActivityStreamPlugin}{Critical} = 0;

# **BOOLEAN**
# Enables/disables logging "alert" messages to the database.
# If disabled the log message is # only forwarded to the secondary logger
$Foswiki::cfg{ActivityStreamPlugin}{Alert} = 0;

# **BOOLEAN**
# Enables/disables logging "emergency" messages to the database.
# If disabled the log message is # only forwarded to the secondary logger
$Foswiki::cfg{ActivityStreamPlugin}{Emergency} = 0;

1;
