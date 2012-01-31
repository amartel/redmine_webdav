package Apache::Authn::RedmineAdvanced;

=head1 Apache::Authn::RedmineAdvanced

Redmine - a mod_perl module to authenticate webdav subversion users
against redmine database

=head1 SYNOPSIS

This module allow anonymous users to browse public project and
registred users to browse and commit their project. Authentication is
done against the redmine database or the LDAP configured in redmine.

This method is far simpler than the one with pam_* and works with all
database without an hassle but you need to have apache/mod_perl on the
svn server.

=head1 INSTALLATION

For this to automagically work, you need to have a recent reposman.rb
(after r860) and if you already use reposman, read the last section to
migrate.

Sorry ruby users but you need some perl modules, at least mod_perl2,
DBI and DBD::mysql (or the DBD driver for you database as it should
work on allmost all databases).

On debian/ubuntu you must do :

  aptitude install libapache-dbi-perl libapache2-mod-perl2 libdbd-mysql-perl

If your Redmine users use LDAP authentication, you will also need
Authen::Simple::LDAP (and IO::Socket::SSL if LDAPS is used):

  aptitude install libauthen-simple-ldap-perl libio-socket-ssl-perl

=head1 CONFIGURATION

   ## This module has to be in your perl path
   ## eg:  /usr/lib/perl5/Apache/Authn/RedmineAdvanced.pm
   PerlLoadModule Apache::Authn::RedmineAdvanced
   <Location /svn>
     DAV svn
     SVNParentPath "/var/svn"

     AuthType Basic
     AuthName redmine
     Require valid-user

     PerlAccessHandler Apache::Authn::RedmineAdvanced::access_handler
     PerlAuthenHandler Apache::Authn::RedmineAdvanced::authen_handler
  
     ## for mysql
     RedmineDSN "DBI:mysql:database=databasename;host=my.db.server"
     ## for postgres
     # RedmineDSN "DBI:Pg:dbname=databasename;host=my.db.server"

     RedmineDbUser "redmine"
     RedmineDbPass "password"
     ## Optional where clause (fulltext search would be slow and
     ## database dependant).
     # RedmineDbWhereClause "and members.role_id IN (1,2)"
     ## Optional credentials cache size
     # RedmineCacheCredsMax 50
     ## Optional RedmineAuthenticationOnly (value doesn't matter, only presence is checked)
     # RedmineAuthenticationOnly on
     ## Optional ProjectIdentifier to bind access rights on a specific project
     # RedmineProjectId myproject
     ## Optional Permissions to allow read
     # RedmineReadPermissions :browse_repository
     ## Optional Permissions to allow write
     # RedmineWritePermissions :commit_access
     
  </Location>

To be able to browse repository inside redmine, you must add something
like that :

   <Location /svn-private>
     DAV svn
     SVNParentPath "/var/svn"
     Order deny,allow
     Deny from all
     # only allow reading orders
     <Limit GET PROPFIND OPTIONS REPORT>
       Allow from redmine.server.ip
     </Limit>
   </Location>

and you will have to use this reposman.rb command line to create repository :

  reposman.rb --redmine my.redmine.server --svn-dir /var/svn --owner www-data -u http://svn.server/svn-private/

=head1 MIGRATION FROM OLDER RELEASES

If you use an older reposman.rb (r860 or before), you need to change
rights on repositories to allow the apache user to read and write
S<them :>

  sudo chown -R www-data /var/svn/*
  sudo chmod -R u+w /var/svn/*

And you need to upgrade at least reposman.rb (after r860).

=head1 GIT SMART HTTP SUPPORT

Git's smart HTTP protocol (available since Git 1.7.0) will not work with the
above settings. Redmine.pm normally does access control depending on the HTTP
method used: read-only methods are OK for everyone in public projects and
members with read rights in private projects. The rest require membership with
commit rights in the project.

However, this scheme doesn't work for Git's smart HTTP protocol, as it will use
POST even for a simple clone. Instead, read-only requests must be detected using
the full URL (including the query string): anything that doesn't belong to the
git-receive-pack service is read-only.

To activate this mode of operation, add this line inside your <Location /git>
block:

  RedmineGitSmartHttp yes

Here's a sample Apache configuration which integrates git-http-backend with
a MySQL database and this new option:

   SetEnv GIT_PROJECT_ROOT /var/www/git/
   SetEnv GIT_HTTP_EXPORT_ALL
   ScriptAlias /git/ /usr/libexec/git-core/git-http-backend/
   <Location /git>
       Order allow,deny
       Allow from all

       AuthType Basic
       AuthName Git
       Require valid-user

       PerlAccessHandler Apache::Authn::RedmineAdvanced::access_handler
       PerlAuthenHandler Apache::Authn::RedmineAdvanced::authen_handler
       # for mysql
       RedmineDSN "DBI:mysql:database=redmine;host=127.0.0.1"
       RedmineDbUser "redmine"
       RedmineDbPass "xxx"
       RedmineGitSmartHttp yes
    </Location>

Make sure that all the names of the repositories under /var/www/git/ have a
matching identifier for some project: /var/www/git/myproject and
/var/www/git/myproject.git will work. You can put both bare and non-bare
repositories in /var/www/git, though bare repositories are strongly
recommended. You should create them with the rights of the user running Redmine,
like this:

  cd /var/www/git
  sudo -u www-data mkdir myproject
  cd myproject
  sudo -u www-data git init --bare

Once you have activated this option, you have three options when cloning a
repository:

- Cloning using "http://user@host/git/repo(.git)" works, but will ask for the password
  all the time.

- Cloning with "http://user:pass@host/git/repo(.git)" does not have this problem, but
  this could reveal accidentally your password to the console in some versions
  of Git, and you would have to ensure that .git/config is not readable except
  by the owner for each of your projects.

- Use "http://host/git/repo(.git)", and store your credentials in the ~/.netrc
  file. This is the recommended solution, as you only have one file to protect
  and passwords will not be leaked accidentally to the console.

  IMPORTANT NOTE: It is *very important* that the file cannot be read by other
  users, as it will contain your password in cleartext. To create the file, you
  can use the following commands, replacing yourhost, youruser and yourpassword
  with the right values:

    touch ~/.netrc
    chmod 600 ~/.netrc
    echo -e "machine yourhost\nlogin youruser\npassword yourpassword" > ~/.netrc


=cut

use strict;
use warnings FATAL => 'all', NONFATAL => 'redefine';

use DBI;
use Digest::SHA1;

# optional module for LDAP authentication
my $CanUseLDAPAuth = eval("use Authen::Simple::LDAP; 1");

use Apache2::Module;
use Apache2::Access;
use Apache2::ServerRec qw();
use Apache2::RequestRec qw();
use Apache2::RequestUtil qw();
use Apache2::Connection qw();
use Apache2::Const qw(:common :override :cmd_how);
use APR::Pool  ();
use APR::Table ();

# use Apache2::Directive qw();

my @directives = (
   {
      name         => 'RedmineDSN',
      req_override => OR_AUTHCFG,
      args_how     => TAKE1,
      errmsg =>
'Dsn in format used by Perl DBI. eg: "DBI:Pg:dbname=databasename;host=my.db.server"',
   },
   {
      name         => 'RedmineProjectId',
      req_override => OR_AUTHCFG,
      args_how     => TAKE1,
      errmsg =>
        'Project identifiant to bind authorization only on a specific project',
   },
   {
      name         => 'RedmineAuthenticationOnly',
      req_override => OR_AUTHCFG,
      args_how     => TAKE1,
      errmsg       => 'On if no authorization check',
   },
   {
      name         => 'RedmineReadPermissions',
      req_override => OR_AUTHCFG,
      args_how     => ITERATE,
      errmsg       => 'list of permissions to allow read access',
   },
   {
      name         => 'RedmineWritePermissions',
      req_override => OR_AUTHCFG,
      args_how     => ITERATE,
      errmsg       => 'list of permissions to allow other than read access',
   },
   {
      name         => 'RedmineDbUser',
      req_override => OR_AUTHCFG,
      args_how     => TAKE1,
   },
   {
      name         => 'RedmineDbPass',
      req_override => OR_AUTHCFG,
      args_how     => TAKE1,
   },
   {
      name         => 'RedmineDbWhereClause',
      req_override => OR_AUTHCFG,
      args_how     => TAKE1,
   },
   {
      name         => 'RedmineCacheCredsMax',
      req_override => OR_AUTHCFG,
      args_how     => TAKE1,
      errmsg       => 'RedmineCacheCredsMax must be decimal number',
   },
   {
      name         => 'RedmineCheckAdmin',
      req_override => OR_AUTHCFG,
      args_how     => TAKE1,
      errmsg => 'regexp matched by IP address for admin user to be granted',
   },
   {
      name         => 'RedmineGitSmartHttp',
      req_override => OR_AUTHCFG,
      args_how     => TAKE1,
   },
);

sub RedmineProjectId          { set_val( 'RedmineProjectId',          @_ ); }
sub RedmineAuthenticationOnly { set_val( 'RedmineAuthenticationOnly', @_ ); }
sub RedmineCheckAdmin         { set_val( 'RedmineCheckAdmin',         @_ ); }

sub RedmineReadPermissions {
   my ( $self, $parms, $arg ) = @_;
   push @{ $self->{RedmineReadPermissions} }, $arg;
}

sub RedmineWritePermissions {
   my ( $self, $parms, $arg ) = @_;
   push @{ $self->{RedmineWritePermissions} }, $arg;
}

sub RedmineDSN {
   my ( $self, $parms, $arg ) = @_;
   $self->{RedmineDSN} = $arg;
   my $query = "SELECT 
              permissions
              FROM members, projects, users, roles, member_roles
              WHERE 
                projects.id=members.project_id 
                AND member_roles.member_id=members.id
                AND users.id=members.user_id 
                AND roles.id=member_roles.role_id
                AND login=? 
                AND identifier=? ";
   $self->{RedmineQuery} = trim($query);
}
sub RedmineDbUser { set_val( 'RedmineDbUser', @_ ); }
sub RedmineDbPass { set_val( 'RedmineDbPass', @_ ); }

sub RedmineDbWhereClause {
   my ( $self, $parms, $arg ) = @_;
   $self->{RedmineQuery} =
     trim( $self->{RedmineQuery} . ( $arg ? $arg : "" ) . " " );
}

sub RedmineCacheCredsMax {
   my ( $self, $parms, $arg ) = @_;
   if ($arg) {
      $self->{RedmineCachePool} = APR::Pool->new;
      $self->{RedmineCacheCreds} =
        APR::Table::make( $self->{RedmineCachePool}, $arg );
      $self->{RedmineCacheCredsCount} = 0;
      $self->{RedmineCacheCredsMax}   = $arg;
   }
}

sub RedmineGitSmartHttp {
   my ( $self, $parms, $arg ) = @_;
   $arg = lc $arg;

   if ( $arg eq "yes" || $arg eq "true" ) {
      $self->{RedmineGitSmartHttp} = 1;
   }
   else {
      $self->{RedmineGitSmartHttp} = 0;
   }
}

sub printlog {
   my $string = shift;
   my $r      = shift;
   $r->log->error($string);
}

sub trim {
   my $string = shift;
   $string =~ s/\s{2,}/ /g;
   return $string;
}

sub set_val {
   my ( $key, $self, $parms, $arg ) = @_;
   $self->{$key} = $arg;
}

Apache2::Module::add( __PACKAGE__, \@directives );

my %read_only_methods = map { $_ => 1 } qw/GET PROPFIND REPORT OPTIONS/;

sub request_is_read_only {
  my ($r) = @_;
  my $cfg = Apache2::Module::get_config(__PACKAGE__, $r->server, $r->per_dir_config);

  # Do we use Git's smart HTTP protocol, or not?
  if (defined $cfg->{RedmineGitSmartHttp} and $cfg->{RedmineGitSmartHttp}) {
    my $uri = $r->unparsed_uri;
    my $location = $r->location;
    my $is_read_only = $uri !~ m{^$location/*[^/]+/+(info/refs\?service=)?git\-receive\-pack$}o;
    return $is_read_only;
  } else {
    # Old behaviour: check the HTTP method
    my $method = $r->method;
    return defined $read_only_methods{$method};
  }
}


sub access_handler {
   my $r = shift;

   my $cfg =
     Apache2::Module::get_config( __PACKAGE__, $r->server, $r->per_dir_config );

   unless ( $r->some_auth_required ) {
      $r->log_reason("No authentication has been configured");
      return FORBIDDEN;
   }

   return OK
     if $cfg->{RedmineAuthenticationOnly};    #anonymous access not allowed

   #check public project AND anonymous access is allowed
   my $project_id = get_project_identifier($r);
   my $ano_access = get_redmine_cache( "", $project_id, $r, $cfg );
   if ( defined $ano_access ) {
      $r->set_handlers( PerlAuthenHandler => [ \&OK ] )
        if ( ( $ano_access + 0 ) > 0 );       #anonymous access allowed
      return OK;
   }

   if ( !anonymous_denied($r) ) {
      my $project_pub = is_public_project( $project_id, $r );
      if ( $project_pub < 0 ) {

         #Unknown project => only read access is granted
         $r->set_handlers( PerlAuthenHandler => [ \&OK ] )
           if request_is_read_only($r)
            #defined $read_only_methods{ $r->method };  #anonymous access allowed
      }
      elsif ( $project_pub > 0 ) {

         #public project, so we check anonymous permissions
         my $perm = get_anonymous_permissions( $r, $project_id );
         if ( check_permission( $perm, $cfg, $r ) ) {
            update_redmine_cache( "", $project_id, "1", $r, $cfg );
            $r->set_handlers( PerlAuthenHandler => [ \&OK ] );
         }
         else {
            update_redmine_cache( "", $project_id, "-1", $r, $cfg );
         }
      }
   }

   return OK;
}

sub authen_handler {
   my $r = shift;

   my ( $res, $redmine_pass ) = $r->get_basic_auth_pw();
   return $res unless $res == OK;

   my $method = $r->method;

   my $cfg =
     Apache2::Module::get_config( __PACKAGE__, $r->server, $r->per_dir_config );

   my $project_id = get_project_identifier($r);

   #0. Check admin IP adresse if requested
   if ( $cfg->{RedmineCheckAdmin} && $r->user =~ m/^admin$/i ) {
      my $ipreg = $cfg->{RedmineCheckAdmin};
      if ( !( $r->connection->remote_ip =~ m/($ipreg)/ ) ) {
         $r->note_auth_failure();
         return AUTH_REQUIRED;
      }
   }

   #1. Check cache if available
   my $pass_digest = Digest::SHA1::sha1_hex($redmine_pass);
   my $usrprojpass = get_redmine_cache( $r->user, $project_id, $r, $cfg );
   return OK
     if ( defined $usrprojpass and ( $usrprojpass eq $pass_digest ) );

   #2. Then authenticate user
   if ( !authenticate_user( $r->user, $redmine_pass, $r ) ) {

      #wrong credentials
      $r->note_auth_failure();
      return AUTH_REQUIRED;
   }

   #Authentication only, no permissions check
   return OK if $cfg->{RedmineAuthenticationOnly};

   my $project_pub = is_public_project( $project_id, $r );

   #if project doesn't exist then administrator is required
   if ( $project_pub < 0 ) {
      if ( is_admin( $r->user, $r ) ) {
         update_redmine_cache( $r->user, $project_id, $pass_digest, $r, $cfg );
         return OK;
      }
      else {
         $r->note_auth_failure();
         return AUTH_REQUIRED;
      }
   }

   #Check permissions if user is a project member
   my @perms = get_user_permissions( $r->user, $project_id, $cfg, $r );
   if (@perms) {
      for my $perm (@perms) {
         if ( check_permission( $perm, $cfg, $r ) ) {
            update_redmine_cache( $r->user, $project_id, $pass_digest, $r,
               $cfg );
            return OK;
         }
      }

   }
   elsif ( $project_pub > 0 ) {

      #public project so we check permissions for non-members
      my $perm2 = get_nonmember_permission( $r, $project_id );
      if ( check_permission( $perm2, $cfg, $r ) ) {
         update_redmine_cache( $r->user, $project_id, $pass_digest, $r, $cfg );
         return OK;
      }
   }

   $r->note_auth_failure();
   return AUTH_REQUIRED;
}

sub is_public_project {
   my $project_id = shift;
   my $r          = shift;

   my $dbh = connect_database($r);
   my $sth = $dbh->prepare(
      "SELECT is_public FROM projects WHERE projects.identifier=?");

   $sth->execute($project_id);
   my ($ret) = $sth->fetchrow_array;
   $sth->finish();
   $dbh->disconnect();

   if ( defined $ret ) {
      return ( $ret ? 1 : 0 );
   }
   else {
      return -1;    #project doesn't exist
   }
}

# perhaps we should use repository right (other read right) to check public access.
# it could be faster BUT it doesn't work for the moment.
# sub is_public_project_by_file {
#     my $project_id = shift;
#     my $r = shift;

#     my $tree = Apache2::Directive::conftree();
#     my $node = $tree->lookup('Location', $r->location);
#     my $hash = $node->as_hash;

#     my $svnparentpath = $hash->{SVNParentPath};
#     my $repos_path = $svnparentpath . "/" . $project_id;
#     return 1 if (stat($repos_path))[2] & 00007;
# }

sub get_project_identifier {
   my $r = shift;

   my $identifier;
   my $cfg =
     Apache2::Module::get_config( __PACKAGE__, $r->server, $r->per_dir_config );

   if ( $cfg->{RedmineProjectId} ) {
      $identifier = $cfg->{RedmineProjectId};
   }
   else {
      my $location = $r->location;
      ($identifier) = $r->uri =~ m{$location/*([^/]+)};
      if (defined $cfg->{RedmineGitSmartHttp} and $cfg->{RedmineGitSmartHttp}) {
         $identifier =~ s/\.git//;
      }
   }

   $identifier;
}

sub connect_database {
   my $r = shift;

   my $cfg =
     Apache2::Module::get_config( __PACKAGE__, $r->server, $r->per_dir_config );
   return DBI->connect( $cfg->{RedmineDSN}, $cfg->{RedmineDbUser},
      $cfg->{RedmineDbPass} );
}

sub get_anonymous_permissions {
   my $r          = shift;
   my $project_id = shift;

   my $dbh = connect_database($r);

   #Test if plugin BIOPROJ redefines permission for anonymous access...
   my $sthrole = $dbh->prepare(
"select project_id from enabled_modules INNER JOIN projects ON projects.id = enabled_modules.project_id AND projects.identifier= ? WHERE enabled_modules.name = 'bioproj' ;"
   );

   $sthrole->execute($project_id);
   my $role = 2;
   if ( my @row = $sthrole->fetchrow_array ) {
      my $sthroleid = $dbh->prepare(
         "select anonymous_role_id from bioproj_settings WHERE project_id = ?;"
      );

      $sthroleid->execute( $row[0] );

      if ( my @row2 = $sthroleid->fetchrow_array ) {
         if ( $row2[0] > 0 ) {
            $role = $row2[0] - 2;
         }
      }
      $sthroleid->finish();
   }
   $sthrole->finish();

   my $sth = $dbh->prepare("SELECT permissions FROM roles WHERE roles.id=?");

   $sth->execute($role);
   my ($ret) = $sth->fetchrow_array;
   $sth->finish();
   $dbh->disconnect();

   $ret;
}

sub authenticate_user {
   my $redmine_user = shift;
   my $redmine_pass = shift;
   my $r            = shift;

   my $pass_digest = Digest::SHA1::sha1_hex($redmine_pass);
   my $ret;

   my $cfg =
     Apache2::Module::get_config( __PACKAGE__, $r->server, $r->per_dir_config );

   my $dbh = connect_database($r);
   my $sth = $dbh->prepare(
"SELECT hashed_password, salt, auth_source_id, id FROM users WHERE users.status=1 AND login=? "
   );

   $sth->execute($redmine_user);
   while ( my ( $hashed_password, $salt, $auth_source_id, $user_id ) =
      $sth->fetchrow_array )
   {

      #Check authentication
      unless ($auth_source_id) {
         my $salted_password = Digest::SHA1::sha1_hex( $salt . $pass_digest );
         if ( $hashed_password eq $salted_password ) {
            $ret = 1;
         }
      }
      elsif ($CanUseLDAPAuth) {
         my $sthldap = $dbh->prepare(
"SELECT host,port,tls,account,account_password,base_dn,attr_login from auth_sources WHERE id = ?;"
         );
         $sthldap->execute($auth_source_id);
         while ( my @rowldap = $sthldap->fetchrow_array ) {
            my $ldap = Authen::Simple::LDAP->new(
               host => ( $rowldap[2] == 1 || $rowldap[2] eq "t" )
               ? "ldaps://$rowldap[0]"
               : $rowldap[0],
               port   => $rowldap[1],
               basedn => $rowldap[5],
               binddn => $rowldap[3] ? $rowldap[3] : "",
               bindpw => $rowldap[4] ? $rowldap[4] : "",
               filter => "(" . $rowldap[6] . "=%s)"
            );
            $ret = 1
              if ( $ldap->authenticate( $redmine_user, $redmine_pass ) );
         }
         $sthldap->finish();
      }
   }
   $sth->finish();

   $dbh->disconnect();

   $ret;
}

sub is_admin {
   my $redmine_user = shift;
   my $r            = shift;

   my $dbh = connect_database($r);
   my $sth = $dbh->prepare("SELECT admin FROM users WHERE login=?");

   $sth->execute($redmine_user);
   my ($ret) = $sth->fetchrow_array;
   $sth->finish();
   $dbh->disconnect();

   $ret;
}


sub check_permission() {
   my $perm = shift;
   my $cfg  = shift;
   my $r    = shift;

   my $ret;
   my @listperms;
   if ( defined $perm ) {
      if ( request_is_read_only($r)) {
      #if ( defined $read_only_methods{ $r->method } ) {
         @listperms =
           $cfg->{RedmineReadPermissions}
           ? @{ $cfg->{RedmineReadPermissions} }
           : (':browse_repository');
      }
      else {
         @listperms =
           $cfg->{RedmineWritePermissions}
           ? @{ $cfg->{RedmineWritePermissions} }
           : (':commit_access');
      }
      for my $p (@listperms) {
         if ( $perm =~ /$p/ ) {
            $ret = 1;
         }
      }
   }
   $ret;
}

sub get_user_permissions {
   my $redmine_user = shift;
   my $project_id   = shift;
   my $cfg          = shift;
   my $r            = shift;

   #$self->{RedmineQuery}
   my $dbh = connect_database($r);
   my $sth = $dbh->prepare( $cfg->{RedmineQuery} );

   $sth->execute( $redmine_user, $project_id );
   my @ret;
   while ( my ($it) = $sth->fetchrow_array ) {
      push( @ret, $it );
   }
   $sth->finish();
   $dbh->disconnect();

   @ret;
}

sub get_nonmember_permission {
   my $r          = shift;
   my $project_id = shift;

   my $dbh = connect_database($r);

   #Test if plugin BIOPROJ redefines permission for anonymous access...
   my $sthrole = $dbh->prepare(
"select project_id from enabled_modules INNER JOIN projects ON projects.id = enabled_modules.project_id AND projects.identifier= ? WHERE enabled_modules.name = 'bioproj' ;"
   );

   $sthrole->execute($project_id);
   my $role = 1;
   if ( my @row = $sthrole->fetchrow_array ) {
      my $sthroleid = $dbh->prepare(
         "select non_member_role_id from bioproj_settings WHERE project_id = ?;"
      );

      $sthroleid->execute( $row[0] );

      if ( my @row2 = $sthroleid->fetchrow_array ) {
         if ( $row2[0] > 0 ) {
            $role = $row2[0] - 2;
         }
      }
      $sthroleid->finish();
   }
   $sthrole->finish();

   my $sth = $dbh->prepare("SELECT permissions FROM roles WHERE roles.id=?");

   $sth->execute($role);
   my ($ret) = $sth->fetchrow_array;
   $sth->finish();
   $dbh->disconnect();

   $ret;
}

sub update_redmine_cache {
   my $redmine_user = shift;
   my $project_id   = shift;
   my $redmine_pass = shift;
   my $r            = shift;
   my $cfg          = shift;

   my $access = "W";
   #$access = "R" if ( defined $read_only_methods{ $r->method } );
   $access = "R" if ( request_is_read_only($r) );
   

   my $cdate = time;

   if (   ( defined $redmine_user )
      and ( defined $project_id )
      and ( defined $access ) )
   {
      my $key = $redmine_user . ":" . $project_id . ":" . $access;
      if ( $cfg->{RedmineCacheCredsMax} ) {
         my $value = $cfg->{RedmineCacheCreds}->get($key);
         if ( defined $value ) {
            $cfg->{RedmineCacheCreds}
              ->set( $key, $cdate . ":::" . $redmine_pass );
         }
         else {
            if ( $cfg->{RedmineCacheCredsCount} < $cfg->{RedmineCacheCredsMax} )
            {
               $cfg->{RedmineCacheCreds}
                 ->set( $key, $cdate . ":::" . $redmine_pass );
               $cfg->{RedmineCacheCredsCount}++;
            }
            else {
               $cfg->{RedmineCacheCreds}->clear();
               $cfg->{RedmineCacheCredsCount} = 0;
            }
         }
      }
   }
}

sub get_redmine_cache {
   my $redmine_user = shift;
   my $project_id   = shift;
   my $r            = shift;
   my $cfg          = shift;

   my $access = "W";
   #$access = "R" if ( defined $read_only_methods{ $r->method } );
   $access = "R" if ( request_is_read_only($r) );

   my $cdate = time;
   if (   ( defined $redmine_user )
      and ( defined $project_id )
      and ( defined $access ) )
   {
      my $key = $redmine_user . ":" . $project_id . ":" . $access;
      my $retpwd;

      if ( $cfg->{RedmineCacheCredsMax} ) {
         my $value = $cfg->{RedmineCacheCreds}->get($key);
         if ( defined $value ) {
            my @toks = split( /:::/, $value );
            if ( ( $toks[0] + 5 ) > $cdate ) {
               $retpwd = $toks[1];
            }
         }
      }

   }
}

sub anonymous_denied {
   my $r = shift;

   my $dbh = connect_database($r);
   my $sth = $dbh->prepare(
      "SELECT value FROM settings where settings.name = 'login_required';");

   $sth->execute();
   my $ret;
   if ( my @row = $sth->fetchrow_array ) {
      if ( $row[0] eq "1" || $row[0] eq "t" ) {
         $ret = 1;
      }
   }
   $sth->finish();
   undef $sth;

   $dbh->disconnect();
   undef $dbh;
   $ret;

}

1;
