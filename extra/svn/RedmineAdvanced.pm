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
);

sub RedmineProjectId          { set_val( 'RedmineProjectId',          @_ ); }
sub RedmineAuthenticationOnly { set_val( 'RedmineAuthenticationOnly', @_ ); }

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

sub printlog {
   my $string = shift;
   my $r      = shift;
   $r->log->debug($string);
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
   if ( !anonymous_denied($r) ) {
      my $project_id = get_project_identifier($r);
      my $project_pub = is_public_project( $project_id, $r );
      if ( $project_pub < 0 ) {

         #Unknown project => only read access is granted
         $r->set_handlers( PerlAuthenHandler => [ \&OK ] )
           if
            defined $read_only_methods{ $r->method };  #anonymous access allowed
      }
      elsif ( $project_pub > 0 ) {

         #public project, so we check anonymous permissions
         my $perm = get_anonymous_permissions($r);
         $r->set_handlers( PerlAuthenHandler => [ \&OK ] )
           if check_permission( $perm, $cfg, $r );     #anonymous access allowed
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

   #1. Check cache if available
   my $usrprojpass;
   my $pass_digest = Digest::SHA1::sha1_hex($redmine_pass);
   if ( $cfg->{RedmineCacheCredsMax} ) {
      $usrprojpass =
        $cfg->{RedmineCacheCreds}->get( $r->user . ":" . $project_id );
      return OK
        if ( defined $usrprojpass and ( $usrprojpass eq $pass_digest ) );
   }

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
            update_redmine_cache( $r->user, $project_id, $pass_digest, $cfg );
            return OK if check_permission( $perm, $cfg, $r );
         }
      }

   }
   elsif ( $project_pub > 0 ) {

      #public project so we check permissions for non-members
      my $perm2 = get_nonmember_permission($r);
      return OK if check_permission( $perm2, $cfg, $r );
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
   my $r = shift;

   my $dbh = connect_database($r);
   my $sth = $dbh->prepare("SELECT permissions FROM roles WHERE roles.id=2");

   $sth->execute();
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

   my $dbh = connect_database($r);
   my $sth = $dbh->prepare(
"SELECT hashed_password, auth_source_id FROM users WHERE users.status=1 AND login=? "
   );

   $sth->execute($redmine_user);
   while ( my ( $hashed_password, $auth_source_id, $permissions ) =
      $sth->fetchrow_array )
   {

      #Check authentication
      unless ($auth_source_id) {
         if ( $hashed_password eq $pass_digest ) {
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
   if ( defined $read_only_methods{ $r->method } ) {
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
   my $r = shift;

   my $dbh = connect_database($r);
   my $sth = $dbh->prepare("SELECT permissions FROM roles WHERE roles.id=1");

   $sth->execute();
   my ($ret) = $sth->fetchrow_array;
   $sth->finish();
   $dbh->disconnect();

   $ret;
}

sub update_redmine_cache {
   my $redmine_user = shift;
   my $project_id   = shift;
   my $redmine_pass = shift;
   my $cfg          = shift;

   my $pass_digest = Digest::SHA1::sha1_hex($redmine_pass);
   if ( $cfg->{RedmineCacheCredsMax} ) {
      my $usrprojpass =
        $cfg->{RedmineCacheCreds}->get( $redmine_user . ":" . $project_id );
      if ( defined $usrprojpass ) {
         $cfg->{RedmineCacheCreds}
           ->set( $redmine_user . ":" . $project_id, $pass_digest );
      }
      else {
         if ( $cfg->{RedmineCacheCredsCount} < $cfg->{RedmineCacheCredsMax} ) {
            $cfg->{RedmineCacheCreds}
              ->set( $redmine_user . ":" . $project_id, $pass_digest );
            $cfg->{RedmineCacheCredsCount}++;
         }
         else {
            $cfg->{RedmineCacheCreds}->clear();
            $cfg->{RedmineCacheCredsCount} = 0;
         }
      }
   }
}

sub anonymous_denied {
   my $r = shift;

   my $dbh = connect_database($r);
   my $sth =
     $dbh->prepare("SELECT value FROM settings WHERE name='login_required'");

   $sth->execute();
   my ($ret) = $sth->fetchrow_array;
   $sth->finish();
   $dbh->disconnect();

   $ret;
}

1;
