############## OO Interface to LAB data #############
#
# OO style management of LAB

package LML::Lab;

use strict;
use warnings;

use LML::VM;
use LML::Common;
use Carp;
use Data::Dumper;
use File::NFSLock;
use Clone 'clone';
use Time::HiRes qw(time gettimeofday);
use Sys::Syslog;
use Array::Compare;

# new object, takes LAB hash or filename to read from.
sub new {
    my ( $class, $arg, $readwrite ) = @_;
    my $self;
    my $filename;
    my $lock;
    my $lockwait     = 0.0;
    my $created_time = time();
    if ( ref($arg) eq "HASH" and !defined($readwrite) ) {
        # arg is hashref and we don't need to write the lab file
        $self = clone($arg);
    }
    elsif ( ref($arg) eq "" ) {
        # arg is not a reference but a scalar, should be file name of lab file
        my $LAB = {
                    "HOSTS"      => {},
                    "ESXHOSTS"   => {},
                    "NETWORKS"   => {},
                    "DATASTORES" => {},
                    "FOLDERS"    => {},
        };
        $filename = $arg;
        {
            local $/ = undef;

            # shared lock good enough for read-only, read-write Lab needs exclusive lock.
            # according to http://docstore.mik.ua/orelly/perl/cookbook/ch07_12.htm this
            # is the meaning of LOCK_EX and LOCK_SH.
            my $locktype = defined $readwrite ? File::NFSLock::LOCK_EX : File::NFSLock::LOCK_SH;

            # first try non-blocking lock, then blocking and report the wait time.
            unless (
                $lock = new File::NFSLock( {
                      file               => $filename,
                      lock_type          => File::NFSLock::LOCK_NB | $locktype,
                      stale_lock_timeout => 2 * 60,                               # seconds
                    } ) )
            {
                # need to wait for lock
                if (
                    $lock = new File::NFSLock( {
                          file               => $filename,
                          lock_type          => $locktype,
                          blocking_timeout   => 30,                               # seconds
                          stale_lock_timeout => 2 * 60,                           # seconds
                        } ) )
                {
                    $lockwait = time() - $created_time;
                }
                else {
                    croak "I could not get a lock for '$filename': [$File::NFSLock::errstr]";
                }
            }
            if ( -r $filename ) {
                open( LAB_CONF, "<", $filename ) || croak "Could not open $filename for reading.\n";
                binmode LAB_CONF;
                eval <LAB_CONF> || croak "Could not parse $filename:\n$@\n";
                close(LAB_CONF);
            }
            if ( !defined $readwrite ) {
                # read-write stays locked.
                $lock->unlock();
                undef $lock;    # make sure that lock is gone
            }
        }
        if ( ref($LAB) eq "HASH" and scalar( %{$LAB} ) ) {
            # make sure that LAB is a non-empty hashref
            $self = $LAB;
            $self->{filename} = $filename;    # keep filename if we read the data from a file
        }
        else {
            croak '$LAB is not a hashref (with read-only Lab) or empty, your $filename file must be broken.\n';
        }

    }
    else {
        croak "Parameter to " . ( caller(0) )[3] . " should be hashref with LAB data or filename of LAB file and not " . ref($arg) . "\n";
    }
    $self->{vms_to_update} = [];    # list of uuids for whom the DHCP data changed
    $self->{runtime} = {
               lock         => $lock,                                 # keep lock for unlocking in write_file
               readwrite    => $readwrite,
               lockwait     => $lockwait,
               created_time => $created_time,                         # store object creation time to track how long Lab object is in scope.
               created_by   => join( ":", ( caller(0) )[ 1, 2 ] ),    # store from where object was created.
    };
    bless( $self, $class );
    return $self;
}

sub DESTROY {
    my $self = shift;
    # in some test cases we use fake lab objects
    # report timings only for writable instances of Lab
    return unless ( defined $self->{runtime} and defined $self->{runtime}->{readwrite} );
    openlog( "lab-manager-light", 'nofatal', 'user' );
    syslog( 'info',
            "LML::Lab |%s|%.0f|%.0f milliseconds",
            $self->{runtime}->{created_by},
            ( time() - $self->{runtime}->{created_time} ) * 1000,
            $self->{runtime}->{lockwait} * 1000 );
    closelog();
}

sub set_filename {
    my ( $self, $filename ) = @_;
    croak( "Must give filename in " . ( caller(0) )[3] . "\n" ) unless ($filename);
    $self->{filename} = $filename;
}

sub filename {
    my $self = shift;
    return $self->{filename} if ( exists $self->{filename} );
    return undef;
}

# return single vm given by uuid or name
sub get_vm {
    my ( $self, $search_vm ) = @_;
    croak( "Must give VM uuid or name as first parameter in " . ( caller(0) )[3] . "\n" ) unless ($search_vm);
    if ( exists $self->{HOSTS}{$search_vm} ) {
        # try to access VM by uuid
        return new LML::VM( $self->{HOSTS}{$search_vm} );
    }
    else {
        # try to find VM by name, name is possibly not unique
        my @vms = grep { defined( $_->{NAME} ) and $_->{NAME} eq $search_vm } values( %{ $self->{HOSTS} } );
        if ( scalar(@vms) > 1 ) {
            croak("Found more than one VM matching '$search_vm', please make sure that VM names are unique ");
        }
        elsif ( scalar(@vms) == 1 ) {
            return new LML::VM( $vms[0] );
        }
        else {
            # try to load VM from backend, put it into our Lab data
            if ( my $new_VM = new LML::VM($search_vm) ) {
                $self->update_vm($new_VM);
                return $new_VM;
            }
        }
    }
    return undef;    # we found nothing
}

# return list of all vms or the ones given as args
sub get_vms {
    my ( $self, @search_vms ) = @_;
    if (@search_vms) {
        return map { $self->get_vm($_) } @search_vms;
    }
    else {
        # everything we have
        return map { new LML::VM($_) } values %{ $self->{HOSTS} };
    }
}

# return Virtualisation Host
sub get_host {
    my ( $self, $search_host ) = @_;
    croak( "Must give host moref or name as first parameter in " . ( caller(0) )[3] . "\n" ) unless ($search_host);
    # first try to lookup by name
    return $self->{ESXHOSTS}->{$search_host} if ( exists( $self->{ESXHOSTS}->{$search_host} ) );
    # then search for a host with this ref
    my @results = grep { $_->{id} eq $search_host } values( %{ $self->{ESXHOSTS} } );
    # cannot be more than one result because ESXHOSTS is ATM a hash with name as key
    # even though vSphere probably supports different ESX servers with the same name (who would do that...)
    return scalar(@results) ? $results[0] : undef;
}

# return list of all hosts
sub get_hosts {
    my $self = shift;
    return values %{ $self->{ESXHOSTS} };

}

# return datastore given by reference or by name
# NOTE: datastore Names are NOT unique in vSphere! If we find that we abort!
sub get_datastore {
    my ( $self, $search_datastore ) = @_;
    croak( "Must give datastore moref or name as first parameter in " . ( caller(0) )[3] . "\n" ) unless ($search_datastore);
    # first try to lookup by moref
    return $self->{DATASTORES}->{$search_datastore} if ( exists( $self->{DATASTORES}->{$search_datastore} ) );
    # then search for a datastore with this name, this could yield to more than one result!
    my @results = grep { $_->{name} eq $search_datastore } values( %{ $self->{DATASTORES} } );
    if ( scalar(@results) > 1 ) {
        croak(   "Datastore names must be unique in"
               . ( caller(0) )[3]
               . ", $search_datastore has several results : \n"
               . Data::Dumper->Dump( \@results )
               . "\n" );
    }
    elsif ( scalar(@results) == 1 ) {
        return $results[0];
    }
    else {
        return undef;
    }
}

# return a list of datastores
sub get_datastores {
    my $self = shift;
    return values %{ $self->{DATASTORES} };
}

# translate datastore id to name
# handle single or multiple args
sub get_datastore_names {
    my ( $self, @ids ) = @_;
    @ids = @{ $ids[0] } if ( ref( $ids[0] ) eq "ARRAY" );    # support arrays and array refs as input
    my @names = map { $self->get_datastore($_)->{name} } @ids;
    return scalar(@ids) == 1 ? $names[0] : @names;
}

# return network given by reference or by name
# NOTE: network Names are NOT unique in vSphere! If we find that we abort!
sub get_network {
    my ( $self, $search_network ) = @_;
    croak( "Must give network moref or name as first parameter in " . ( caller(0) )[3] . " and not '$search_network' \n" )
      unless ($search_network);
    # first try to lookup by moref
    return $self->{NETWORKS}->{$search_network} if ( exists( $self->{NETWORKS}->{$search_network} ) );
    # then search for a datastore with this name, this could yield to more than one result!
    my @results = grep { $_->{name} eq $search_network } values( %{ $self->{NETWORKS} } );
    if ( scalar(@results) > 1 ) {
        croak(   "Network names must be unique in "
               . ( caller(0) )[3]
               . ", $search_network has several results : \n"
               . Data::Dumper->Dump( \@results )
               . "\n" );
    }
    elsif ( scalar(@results) == 1 ) {
        return $results[0];
    }
    else {
        return undef;
    }
}

# return a list of networks
sub get_networks {
    my $self = shift;
    return values %{ $self->{NETWORKS} };
}

# translate network ids to name
# handle single or multiple args
sub get_network_names {
    my ( $self, @ids ) = @_;
    @ids = @{ $ids[0] } if ( ref( $ids[0] ) eq "ARRAY" );    # support arrays and array refs as input
    my @names = map { $self->get_network($_)->{name} } @ids;
    return scalar(@ids) == 1 ? $names[0] : @names;
}

# return list of folders
sub get_folders {
    my $self = shift;
    return values %{ $self->{FOLDERS} };
}

# return sorted list of folder paths
sub get_folder_paths {
    my ( $self, $filter ) = @_;
    my $regex = defined $filter ? qr(^$filter$) : qr();    # default filter is match all
    return sort grep { /$regex/ } map { $_->{path} } $self->get_folders;
}

# return single folder, access by id or by path
sub get_folder {
    my ( $self, $search_folder ) = @_;
    croak( "Must give folder id or path in " . ( caller(0) )[3] . "\n" ) unless ( defined $search_folder );
    # try direct access by id
    return $self->{FOLDERS}->{$search_folder} if ( defined $self->{FOLDERS}->{$search_folder} );
    # try to find by path
    my @folders = grep { $_->{path} eq $search_folder } $self->get_folders;
    if ( scalar(@folders) > 1 ) {
        croak "Found more than one folder matching search path '$search_folder' : " . join( ", ", map { $_->{id} } @folders ) . "\n";
    }
    elsif ( scalar(@folders) == 1 ) {
        return $folders[0];
    }
    # found nothing
    return undef;
}

sub remove {
    my ( $self, $uuid ) = @_;
    croak( "Must give UUID to remove " . ( caller(0) )[3] ) unless ($uuid);
    if ( defined( $self->{HOSTS}->{$uuid}->{MACS} ) and scalar( @{ $self->{HOSTS}->{$uuid}->{MACS} } ) ) {
        # this VM has network cards in the [dhcp] managed_network networks, remove from DHCP as well
        push( @{ $self->{vms_to_update} }, $uuid );
    }
    if ( delete $self->{HOSTS}{$uuid} ) {
        Debug("Removing $uuid from LAB");
    }

    return 1;
}

# update the list of ESX hosts
sub update_hosts {
    my ( $self, $hosts ) = @_;
    $self->{ESXHOSTS} = $hosts;
}

# update the list of networks
sub update_networks {
    my ( $self, $networks ) = @_;
    $self->{NETWORKS} = $networks;
}

# update the list of datastores
sub update_datastores {
    my ( $self, $datastores ) = @_;
    $self->{DATASTORES} = $datastores;
}

# update the list of folders
sub update_folders {
    my ( $self, $folders ) = @_;
    $self->{FOLDERS} = $folders;
}

# update data about single host from given VM object
sub update_vm {
    my ( $self, $VM ) = @_;
    croak( "Must give LML:VM object as first parameter in " . ( caller(0) )[3] . " and not " . Data::Dumper->Dump( [$VM], ["VM"] ) . "\n " )
      unless ( ref($VM) eq "LML::VM" );
    my $uuid        = $VM->uuid;
    my $name        = $VM->name;
    my @vm_lab_macs = $VM->get_filtered_macs;

    Debug( "Updating LAB for '$name' with '" . join( ", ", @vm_lab_macs ) . "'" );

    # add timestamp so that we know when the host was last time updated with fresh data

    # create HOSTS record for DHCP if it has changed (name or networking)
    # ~~ compares array since perl 5.10!!
    #
    # NOTE: Hostname and MACs are relevant for DHCP servers
    my $comp = Array::Compare->new;
    my $update_dhcp = (
                        not(     exists( $self->{HOSTS}->{$uuid}->{HOSTNAME} )
                             and exists( $self->{HOSTS}->{$uuid}->{MACS} ) )
                          or not $name eq $self->{HOSTS}->{$uuid}->{HOSTNAME}
                          or not $comp->simple_compare(\@vm_lab_macs,$self->{HOSTS}->{$uuid}->{MACS} )
                      ) ? 1 : 0;    # set to 0 or 1
    if ($update_dhcp) {
        push( @{ $self->{vms_to_update} }, $uuid );
    }
    my $old_ip = defined($self->{HOSTS}->{$uuid}->{CLIENT_IP}) ? $self->{HOSTS}->{$uuid}->{CLIENT_IP} : undef;
    $self->{HOSTS}->{$uuid} = {
        UPDATED         => ( gettimeofday() )[0],                                # time is from Time::HiRes and gives (seconds,milliseconds)
        UPDATED_DISPLAY => POSIX::strftime( "%Y-%m-%d %H:%M:%S", localtime ),
        UUID            => $uuid,
        HOSTNAME        => $name,
        NAME            => $name,
        DNS_DOMAIN      => $VM->dns_domain,
        MACS            => \@vm_lab_macs,
        VM_ID           => $VM->vm_id,
        MAC             => $VM->mac,
        CUSTOMFIELDS    => $VM->customfields,
        PATH            => $VM->path,
        HOST            => $VM->host,
        BOOTORDER       => $VM->bootorder,
        # update client ip if we have one, otherwise keep previous data
        CLIENT_IP       => defined $ENV{REMOTE_ADDR} ? $ENV{REMOTE_ADDR} : $old_ip,
    };
    return $update_dhcp;
}

sub vms_to_update {
    my ($self) = @_;
    return wantarray ? @{ $self->{vms_to_update} } : scalar( @{ $self->{vms_to_update} } );
}

sub write_file {
    my ( $self, @comments ) = @_;
    confess("LML::Lab instance created in $self->{runtime}->{created_by} is not writable") unless ( defined $self->{runtime}->{readwrite} );
    my $filename = $self->filename;
    croak("No filename associated with LML::Lab object \n") unless ($filename);
    confess("Cannot get lock for '$filename'!") unless ( defined $self->{runtime}->{lock} );
    open( LAB_CONF, ">", $filename ) || croak "Could not open '$filename' for writing : $! \n";
    print LAB_CONF "# " . POSIX::strftime( "%Y-%m-%d %H:%M:%S", localtime() ) . " " . join( ", ", @comments ) . "\n";
    my $LAB = {};
    # copy just relevant parts (by reference)
    $LAB->{HOSTS}      = $self->{HOSTS};
    $LAB->{ESXHOSTS}   = $self->{ESXHOSTS};
    $LAB->{NETWORKS}   = $self->{NETWORKS};
    $LAB->{DATASTORES} = $self->{DATASTORES};
    $LAB->{FOLDERS}    = $self->{FOLDERS};
    print LAB_CONF Data::Dumper->Dump( [$LAB], [qw(LAB)] ) or croak "Could not write to '$filename': $!\n";
    my $bytes_written = tell LAB_CONF;
    close(LAB_CONF);
    $self->{runtime}->{lock}->unlock();
    undef $self->{runtime}->{lock};
    return $bytes_written;
}

1;
