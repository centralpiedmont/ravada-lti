package Ravada::Domain::Proxmox;

use warnings;
use strict;

=head1 NAME

Ravada::Domain::Proxmox - Virtual machine managed through the Proxmox VE API

=cut

use Carp qw(carp cluck confess croak);
use Data::Dumper;
use Hash::Util qw(lock_keys lock_hash unlock_hash);
use JSON::XS;
use Moose;
use Storable qw(dclone);

use Ravada::Proxmox::API;
use Ravada::Volume::Proxmox;

no warnings "experimental::signatures";
use feature qw(signatures);

extends 'Ravada::Front::Domain::Proxmox';
with 'Ravada::Domain';

has 'vmid' => (
    is => 'rw'
    ,isa => 'Int'
    ,required => 1
);

has 'node' => (
    is => 'rw'
    ,isa => 'Str'
    ,required => 1
);

our $CONNECTOR = \$Ravada::CONNECTOR;

our $RE_DISK = $Ravada::Front::Domain::Proxmox::RE_DISK;
our %BUS_ORDER = ( scsi => 0, virtio => 1, sata => 2, ide => 3 );
our $TIMEOUT_SHUTDOWN = 60;

our %CHANGE_HARDWARE_SUB = (
    memory => \&_change_hardware_memory
    ,vcpus => \&_change_hardware_vcpus
    ,cpu => \&_change_hardware_cpu
    ,network => \&_change_hardware_network
    ,disk => \&_change_hardware_disk
    ,display => \&_change_hardware_display
    ,video => \&_change_hardware_video
);

##########################################################################
#
# API helpers
#

sub _api($self) {
    my $api = $self->_vm->vm;
    confess "Error: no connection to the Proxmox API in ".$self->_vm->name if !$api;
    return $api;
}

sub _api_client($self) {
    return $self->_api;
}

sub _path($self, $suffix='') {
    return "/nodes/".$self->node."/qemu/".$self->vmid.$suffix;
}

sub _wait($self, $upid, $timeout=undef) {
    return if !defined $upid || !length($upid);
    return $self->_api->wait_task($self->node, $upid, $timeout);
}

sub _post($self, $suffix, $params={}, $wait=1) {
    my $upid = $self->_api->post($self->_path($suffix), $params);
    $self->_wait($upid) if $wait;
    return $upid;
}

sub _set_config($self, %params) {
    for my $key (keys %params) {
        delete $params{$key} if !defined $params{$key};
    }
    my $upid = $self->_api->put($self->_path('/config'), \%params);
    $self->_wait($upid);
    $self->_vm->_clear_cache();
    return $self->_refresh_config();
}

sub _delete_config($self, @keys) {
    return if !@keys;
    return $self->_set_config( delete => join(",", @keys) );
}

our $CONFIG_CACHE_TIMEOUT = 1;

sub _refresh_config($self) {
    my $config = $self->_api->get($self->_path('/config'));
    delete $config->{digest};
    $self->{_config} = $config;
    $self->{_config_time} = time;
    $self->_store_config($config);
    return $config;
}

sub _store_config($self, $config=undef) {
    return if !$self->is_known || $self->readonly;
    $config = $self->{_config} if !$config;
    return if !$config;
    my $json = JSON::XS->new->canonical->encode($config);
    $self->_data_extra('config', $json);
    $self->_data_extra('vmid', $self->vmid);
    $self->_data_extra('node', $self->node);
}

=head2 pve_config

Returns the current Proxmox configuration of the virtual machine

=cut

sub pve_config($self, $refresh=0) {
    return $self->{_config} if $self->{_config} && !$refresh
        && time - ($self->{_config_time} or 0) < $CONFIG_CACHE_TIMEOUT;
    return $self->_refresh_config();
}

sub _status($self) {
    return $self->_api->get($self->_path('/status/current'));
}

sub _is_missing_error($err) {
    return 0 if !$err;
    return 1 if "$err" =~ /does not exist|no such vm|not found/i;
    return 1 if ref($err) && $err->can('code') && $err->code == 404;
    return 0;
}

##########################################################################
#
# identity
#

sub name($self) {
    return $self->{_name} if $self->{_name};
    return $self->{_data}->{name} if $self->{_data} && $self->{_data}->{name};
    my $name = $self->_vm->_domain_name_by_vmid($self->vmid);
    return $name if $name;
    return $self->pve_config->{name};
}

sub type { return 'Proxmox' }

sub internal_id($self) {
    return $self->vmid;
}

sub is_persistent { return 1 }

sub is_removed($self) {
    my $config;
    eval { $config = $self->_api->get($self->_path('/config')) };
    if ($@) {
        return 1 if _is_missing_error($@);
        die $@;
    }
    return 0;
}

sub _insert_db_extra($self) {
    return if $self->is_known_extra();
    return if $self->{_is_removed} || !$self->is_known();

    my $sth = $$CONNECTOR->dbh->prepare("INSERT INTO domains_proxmox "
        ." ( id_domain, vmid, node ) VALUES (?,?,?) ");
    $sth->execute($self->id, $self->vmid, $self->node);
    $sth->finish;
    $self->_store_config();
}

##########################################################################
#
# state
#

sub is_active($self) {
    my $status;
    eval { $status = $self->_status() };
    if ($@) {
        return 0 if _is_missing_error($@);
        die $@;
    }
    return 1 if ($status->{status} or '') eq 'running';
    return 0;
}

sub is_paused($self) {
    my $status;
    eval { $status = $self->_status() };
    if ($@) {
        return 0 if _is_missing_error($@);
        die $@;
    }
    return 1 if ($status->{qmpstatus} or '') eq 'paused';
    return 0;
}

sub is_hibernated($self) {
    my $status;
    eval { $status = $self->_status() };
    if ($@) {
        return 0 if _is_missing_error($@);
        die $@;
    }
    return 0 if ($status->{status} or '') eq 'running';
    return 1 if ($status->{lock} or '') eq 'suspended';
    my $config = $self->pve_config(1);
    return 1 if $config->{vmstate};
    return 0;
}

sub can_hibernate { return 1 }
sub can_hybernate { return 1 }

sub start($self, @args) {
    my %args;
    %args = @args if scalar(@args) % 2 == 0;
    my $request = $args{request};

    my $upid = $self->_api->post($self->_path('/status/start'));
    $self->_wait($upid);
    $self->_refresh_config();
    $self->{_ip} = undef;
    return 1;
}

sub shutdown($self, %args) {
    my $timeout = ($args{timeout} or $self->timeout_shutdown or $TIMEOUT_SHUTDOWN);
    return if !$self->is_active;
    eval {
        $self->_api->post($self->_path('/status/shutdown'), { timeout => $timeout });
    };
    die $@ if $@ && "$@" !~ /not running/i;
    $self->{_ip} = undef;
}

sub shutdown_now($self, $user=undef) {
    return $self->_do_force_shutdown();
}

sub force_shutdown($self, $user=undef) {
    return $self->_do_force_shutdown();
}

sub _do_force_shutdown($self) {
    return if !$self->is_active;
    $self->_post('/status/stop');
    $self->{_ip} = undef;
}

sub reboot($self, %args) {
    return if !$self->is_active;
    my $timeout = ($args{timeout} or $self->timeout_reboot or $TIMEOUT_SHUTDOWN);
    $self->_api->post($self->_path('/status/reboot'), { timeout => $timeout });
}

sub reboot_now($self, $user=undef) {
    return $self->_do_force_reboot();
}

sub force_reboot($self, $user=undef) {
    return $self->_do_force_reboot();
}

sub _do_force_reboot($self) {
    return if !$self->is_active;
    $self->_post('/status/reset');
}

sub pause($self, @) {
    $self->_post('/status/suspend');
}

sub resume($self, @) {
    $self->_post('/status/resume');
}

sub hybernate($self, $user=undef) {
    return $self->hibernate($user);
}

sub hibernate($self, $user=undef) {
    return if !$self->is_active;
    $self->_post('/status/suspend', { todisk => 1 });
    $self->_refresh_config();
}

sub remove($self, $user=undef, @) {
    my $removed = $self->is_removed;
    return if $removed;

    $self->_do_force_shutdown() if $self->is_active;
    my $upid = $self->_api->delete($self->_path()
        , { purge => 1, 'destroy-unreferenced-disks' => 1 });
    $self->_wait($upid);
    $self->{_is_removed} = time;
}

sub rename($self, %args) {
    my $name = $args{name} or confess "Error: missing new name";
    $self->_set_config( name => _pve_name($name) );
    $self->{_name} = $name;
}

=head2 _pve_name

Converts a Ravada machine name to a valid Proxmox VM name

=cut

sub _pve_name($name) {
    my $pve = $name;
    $pve =~ s/[^a-zA-Z0-9\-]/-/g;
    $pve =~ s/^-+//;
    $pve =~ s/-+$//;
    $pve = "vm-$pve" if $pve !~ /^[a-zA-Z0-9]/;
    $pve = "vm" if !length($pve);
    return $pve;
}

sub autostart($self, $value=undef, $user=undef) {
    return $self->_internal_autostart($value);
}

sub _internal_autostart($self, $value=undef) {
    if (defined $value) {
        $self->_set_config( onboot => ($value ? 1 : 0) );
    }
    my $config = $self->pve_config();
    return ($config->{onboot} or 0);
}

sub set_time($self, @) {
    # Proxmox has no guest agent call to set the time, guests are expected
    # to run NTP or the qemu guest agent time sync.
    return;
}

sub can_screenshot { return 0 }

sub screenshot($self, @) {
    die "Error: screenshots are not available in Proxmox virtual machines\n";
}

sub _file_screenshot($self) {
    return;
}

##########################################################################
#
# info
#

sub get_info($self) {
    my $config = $self->pve_config();
    my $status = {};
    eval { $status = $self->_status() };
    warn $@ if $@ && !_is_missing_error($@);

    my $memory = ($config->{memory} or 512);
    my $balloon = ($config->{balloon} or $memory);
    $balloon = $memory if $balloon > $memory;
    my $cores = ($config->{cores} or 1) * ($config->{sockets} or 1);
    my $vcpus = ($config->{vcpus} or $cores);

    my $mac;
    for my $key (sort grep { /^net\d+$/ } keys %$config) {
        my %net = Ravada::Front::Domain::Proxmox::_parse_net($config->{$key});
        $mac = $net{mac};
        last if $mac;
    }
    my $state = ($status->{status} or 'unknown');
    $state = 'paused' if ($status->{qmpstatus} or '') eq 'paused';

    my $info = {
        max_mem => $memory * 1024
        ,memory => $balloon * 1024
        ,cpu_time => int(($status->{cpu} or 0) * 100)
        ,n_virt_cpu => $vcpus
        ,max_virt_cpu => $cores
        ,state => $state
        ,mac => $mac
        ,time => time
        ,ip => undef
    };
    $info->{ip} = $self->ip if $state eq 'running';
    return $info;
}

sub set_max_mem($self, $value) {
    my $mb = int($value / 1024);
    $mb = 16 if $mb < 16;
    my $config = $self->pve_config();
    my %params = ( memory => $mb );
    $params{balloon} = $mb if $config->{balloon} && $config->{balloon} > $mb;
    $self->_set_config(%params);
}

sub set_memory($self, $value) {
    my $mb = int($value / 1024);
    $mb = 16 if $mb < 16;
    my $config = $self->pve_config();
    my $max = ($config->{memory} or 512);
    if ($mb >= $max) {
        $self->_set_config( memory => $mb, balloon => undef );
        $self->_delete_config('balloon') if exists $config->{balloon};
    } else {
        $self->_set_config( balloon => $mb );
    }
}

sub get_max_mem($self) {
    return ($self->pve_config->{memory} or 512) * 1024;
}

sub ip($self) {
    return $self->{_ip} if $self->{_ip};
    my $info = $self->ip_info();
    return if !$info;
    $self->{_ip} = $info->{addr};
    return $info->{addr};
}

sub ip_info($self) {
    return if !$self->is_active;
    my $data;
    eval { $data = $self->_api->get($self->_path('/agent/network-get-interfaces')) };
    if ($@) {
        return if "$@" =~ /agent|not running/i;
        die $@;
    }
    my $result = ($data->{result} or []);
    for my $iface (@$result) {
        next if ($iface->{name} or '') =~ /^(lo|docker|virbr)/;
        for my $addr (@{ $iface->{'ip-addresses'} or [] }) {
            next if ($addr->{'ip-address-type'} or '') ne 'ipv4';
            my $ip = $addr->{'ip-address'};
            next if !$ip || $ip =~ /^(127\.|169\.254\.)/;
            my $info = {
                addr => $ip
                ,hwaddr => $iface->{'hardware-address'}
                ,name => $iface->{name}
                ,prefix => $addr->{prefix}
                ,type => 'bridge'
            };
            return $info;
        }
    }
    return;
}

sub _check_port($self, @args) {
    return 1 if $self->is_active;
    return 0;
}

sub has_nat_interfaces { return 0 }

##########################################################################
#
# display
#

sub _has_builtin_display($self) {
    return 1;
}

sub _is_display_builtin($self, $index=undef, $data=undef) {
    if (defined $index && $index !~ /^\d+$/) {
        return 1 if $index =~ /spice|vnc/;
        return 0;
    }
    return 1 if defined $data && exists $data->{driver} && $data->{driver} =~ /spice|vnc/;
    return 1 if defined $index && $index == 0;
    return 0;
}

sub _set_displays_ip($self, $password=undef, $listen_ip=undef) {
    # Displays are reached through the Proxmox spice proxy, nothing to set
    return;
}

sub _add_iptable($self, @args) {
    # Access to the display is authorized with a short lived ticket issued
    # by the Proxmox API, no firewall rule is needed on the node
    return;
}

sub _close_exposed_port($self, $internal_port_req=undef) {
    # Nothing to close in the node firewall when no ports were exposed,
    # the rvd_back host does not need iptables to run Proxmox machines
    if (!$self->list_ports) {
        $self->_data('ports_exposed', 0) if $self->is_known();
        return;
    }
    return Ravada::Domain::_close_exposed_port($self, $internal_port_req);
}

sub _spice_port($self) {
    return if !$self->is_active;
    my $data;
    eval { $data = $self->spice_proxy_data() };
    return if $@ || !$data;
    return $data->{'tls-port'};
}

sub display_info($self, $user=undef) {
    my $config = $self->pve_config();
    my $vga = ($config->{vga} or 'std');
    my $driver = 'vnc';
    $driver = 'spice' if $vga =~ /qxl|virtio/;

    my $port;
    $port = $self->_spice_port() if $driver eq 'spice';
    my $display = {
        driver => $driver
        ,ip => $self->_vm->_node_address
        ,port => $port
        ,password => undef
        ,is_builtin => 1
        ,n_order => 0
        ,extra => { proxy => $self->_vm->_node_address.":3128", vga => $vga }
    };
    lock_hash(%$display);
    return $display if !wantarray;
    return ($display);
}

sub _display_file_spice($self, $display, $tls=0) {
    return Ravada::Front::Domain::Proxmox::_display_file_spice($self, $display, $tls);
}

##########################################################################
#
# volumes
#

sub _sort_disk_keys(@keys) {
    my @sorted = sort {
        my ($ba, $na) = $a =~ $RE_DISK;
        my ($bb, $nb) = $b =~ $RE_DISK;
        ($BUS_ORDER{$ba} <=> $BUS_ORDER{$bb}) || ($na <=> $nb)
    } grep { $_ =~ $RE_DISK } @keys;
    return @sorted;
}

sub _parse_drive($value) {
    my $drive = Ravada::Proxmox::API::parse_key_value($value);
    my $file = delete $drive->{_first};
    $file = '' if !defined $file || $file eq 'none';
    $drive->{file} = $file;
    return $drive;
}

sub _size_to_bytes($size) {
    return 0 if !defined $size;
    my ($n, $unit) = $size =~ /^([\d\.]+)([KMGT])?$/;
    return 0 if !defined $n;
    my %mult = ( K => 1024, M => 1024**2, G => 1024**3, T => 1024**4 );
    return int($n * ($unit ? $mult{$unit} : 1));
}

sub _volume_type($self, $volid) {
    my $type = $self->{_volume_types}->{$volid};
    return $type if $type;
    return 'sys';
}

sub _disks_info($self) {
    my $config = $self->pve_config();
    my @disks;
    my $n_order = 0;
    my $boot = Ravada::Proxmox::API::parse_key_value($config->{boot} or '');
    my %boot_order;
    my $n_boot = 1;
    for my $item (split /;/, ($boot->{order} or '')) {
        $boot_order{$item} = $n_boot++;
    }
    for my $key (_sort_disk_keys(keys %$config)) {
        my $drive = _parse_drive($config->{$key});
        my ($bus) = $key =~ /^([a-z]+)/;
        my $device = 'disk';
        $device = 'cdrom' if ($drive->{media} or '') eq 'cdrom';
        my $file = $drive->{file};
        my ($storage) = ($file =~ /^([^:]+):/);
        my ($name) = ($file =~ m{([^/]+)$});
        $name = $key if !$name;
        my $format = ($drive->{format} or ($file =~ /\.(\w+)$/ ? $1 : 'raw'));
        $format = 'iso' if $device eq 'cdrom';
        my $info = {
            name => $name
            ,file => $file
            ,target => $key
            ,device => $device
            ,bus => $bus
            ,n_order => $n_order++
            ,driver => { type => $format }
            ,capacity => _size_to_bytes($drive->{size})
            ,storage_pool => ($storage or '')
        };
        $info->{boot} = $boot_order{$key} if $boot_order{$key};
        $info->{backing} = $self->_backing_of($file) if $file;
        push @disks, ($info);
    }
    return @disks;
}

sub _backing_of($self, $file) {
    return if $file !~ m{^([^:]+):(\d+)/(base-\d+-[^/]+)/\d+/};
    return "$1:$2/$3";
}

sub list_volumes($self, $attribute=undef, $value=undef) {
    my @volumes;
    for my $info ($self->_disks_info) {
        next if defined $attribute
            && (!exists $info->{$attribute} || $info->{$attribute} ne $value);
        push @volumes, ($info->{file});
    }
    return @volumes;
}

sub list_volumes_info($self, $attribute=undef, $value=undef) {
    my @volumes;
    for my $info ($self->_disks_info) {
        next if defined $attribute
            && (!exists $info->{$attribute} || $info->{$attribute} ne $value);
        my $vol = Ravada::Volume::Proxmox->new(
            file => $info->{file}
            ,info => $info
            ,domain => $self
            ,vm => $self->_vm
        );
        push @volumes, ($vol);
    }
    return @volumes;
}

sub disk_device($self) {
    return $self->list_volumes();
}

sub list_disks($self) {
    return $self->list_volumes( device => 'disk');
}

sub disk_size($self) {
    my ($disk) = $self->list_volumes_info( device => 'disk');
    return 0 if !$disk;
    return $disk->capacity;
}

sub _new_target_dev($self, $bus='scsi') {
    my $config = $self->pve_config();
    my $max = 30;
    $max = 5 if $bus eq 'sata';
    $max = 3 if $bus eq 'ide';
    $max = 15 if $bus eq 'virtio';
    for my $n (0 .. $max) {
        my $key = "$bus$n";
        return $key if !exists $config->{$key};
    }
    confess "Error: no free $bus slot in ".$self->name;
}

sub _bytes_to_gb($bytes) {
    my $gb = $bytes / (1024 ** 3);
    $gb = 0.001 if $gb < 0.001;
    return sprintf("%.3f", $gb) + 0;
}

sub add_volume($self, %args) {
    my $device = (delete $args{device} or 'disk');
    my $type = (delete $args{type} or '');
    my $swap = delete $args{swap};
    $type = 'swap' if $swap;
    $type = 'sys' if !$type || $type eq 'file';
    my $file = delete $args{file};
    $file = delete $args{path} if !$file && $args{path};
    my $target = delete $args{target};
    my $storage = (delete $args{storage} or $self->_vm->default_storage_pool_name);
    my $size = delete $args{size};
    $size = delete $args{capacity} if !defined $size && exists $args{capacity};
    my $boot = delete $args{boot};
    my $bus = delete $args{bus};
    my $name = delete $args{name};
    my $format = delete $args{format};
    delete @args{qw(allocation vm xml)};

    confess "Error: unknown args ".Dumper(\%args) if keys %args;

    my $config = $self->pve_config();
    my $key;
    if ($device eq 'cdrom') {
        $bus = 'ide' if !$bus;
        $key = $target;
        $key = $self->_new_target_dev($bus) if !$key || exists $config->{$key};
        $file = '' if !defined $file || $file eq '<NONE>';
        my $value = ($file ? $file : 'none').",media=cdrom";
        $self->_set_config( $key => $value );
    } else {
        $bus = 'scsi' if !$bus || $bus !~ /^(scsi|virtio|sata|ide)$/;
        $key = $target;
        $key = $self->_new_target_dev($bus) if !$key || $key !~ $RE_DISK || exists $config->{$key};
        my $value;
        if ($file) {
            $value = $file;
        } else {
            $size = 1024 * 1024 * 1024 if !$size;
            $value = "$storage:"._bytes_to_gb($size);
            $value .= ",format=$format" if $format;
        }
        $value .= ",cache=none" if $type eq 'swap';
        $self->_set_config( $key => $value );
        $self->_set_boot_order($key, $boot) if $boot;
    }
    $config = $self->pve_config();
    my $drive = _parse_drive($config->{$key});
    $self->{_volume_types}->{$drive->{file}} = $type if $drive->{file};
    $self->list_volumes_info();
    return $drive->{file} if $drive->{file};
    return $key;
}

sub _set_boot_order($self, $key, $position=undef) {
    my $config = $self->pve_config();
    my $boot = Ravada::Proxmox::API::parse_key_value($config->{boot} or '');
    my @order = grep { $_ ne $key } split /;/, ($boot->{order} or '');
    if (defined $position && $position > 0 && $position <= scalar(@order)) {
        splice @order, $position - 1, 0, $key;
    } else {
        push @order, ($key);
    }
    $self->_set_config( boot => "order=".join(";", @order) );
}

sub _key_of_volume($self, $file) {
    my $config = $self->pve_config(1);
    for my $key (keys %$config) {
        next if $key !~ $RE_DISK && $key !~ /^unused\d+$/;
        my $drive = _parse_drive($config->{$key});
        return $key if $drive->{file} eq $file;
    }
    return;
}

sub remove_volume($self, $file) {
    confess "Error: missing file" if !defined $file || !length($file);
    if ($self->{_is_removed} || $self->is_removed) {
        # the machine is gone, remove the volume if it was left behind
        $self->_vm->remove_file($file) if $file !~ /\.iso$/i;
        return 1;
    }
    my $key = $self->_key_of_volume($file);
    return if !$key;
    my $config = $self->pve_config();
    my $drive = _parse_drive($config->{$key});
    my $is_cdrom = (($drive->{media} or '') eq 'cdrom');
    $self->_delete_config($key);
    return if $is_cdrom;

    my $unused = $self->_key_of_volume($file);
    $self->_delete_config($unused) if $unused && $unused =~ /^unused/;

    my $sth = $$CONNECTOR->dbh->prepare("DELETE FROM volumes WHERE id_domain=? AND file=?");
    $sth->execute($self->id, $file) if $self->is_known;
}

sub remove_disks($self) {
    for my $file ($self->list_disks) {
        $self->remove_volume($file);
    }
}

sub _volume_key_by_index($self, $index) {
    my @disks = $self->_disks_info();
    my $disk = $disks[$index]
        or die "Error: volume $index not found, only ".scalar(@disks)." found.\n";
    return $disk;
}

##########################################################################
#
# bases and clones
#

=head2 prepare_base

Converts the virtual machine in a Proxmox template. Returns the list
of base volumes and targets.

=cut

sub prepare_base($self, $with_cd=undef) {
    my $config = $self->pve_config(1);
    if (!$config->{template}) {
        my $upid = $self->_api->post($self->_path('/template'));
        $self->_wait($upid);
        $config = $self->_refresh_config();
    }
    my @base_img;
    for my $info ($self->_disks_info) {
        next if $info->{device} eq 'cdrom' && (!$with_cd || !$info->{file});
        next if !$info->{file};
        push @base_img, ([ $info->{file}, $info->{target} ]);
    }
    $self->post_prepare_base();
    return @base_img;
}

sub _do_remove_base($self, $user) {
    return
        if $self->is_base && $self->is_local
        && $self->_cascade_remove_base_in_nodes();

    # The base volumes are the template disks, they stay with the machine
    $self->is_base(0) if $self->is_local;
}

sub _post_remove_base_domain($self) {
    my $config = $self->pve_config(1);
    return if !$config->{template};
    eval { $self->_delete_config('template') };
    if ($@) {
        die "Error: Proxmox templates can not be converted back to virtual machines,"
        ." clone it instead.\n$@";
    }
    $self->_refresh_config();
}

sub _replace_with_full_clone($self) {
    my $api = $self->_api;
    my $newid = $api->get('/cluster/nextid');
    my $config = $self->pve_config(1);
    my $name = $config->{name};
    my $upid = $api->post($self->_path('/clone'), {
        newid => $newid, name => "$name-tmp", full => 1
    });
    $self->_wait($upid);
    my $old_path = $self->_path();
    $upid = $api->delete($old_path, { purge => 1, 'destroy-unreferenced-disks' => 1 });
    $self->_wait($upid);
    $self->vmid($newid);
    $self->_set_config( name => $name );
    my $sth = $$CONNECTOR->dbh->prepare("UPDATE domains set internal_id=? WHERE id=?");
    $sth->execute($newid, $self->id) if $self->is_known;
    $self->_store_config();
}

sub spinoff($self, @) {
    $self->_check_has_clones();
    $self->_do_force_shutdown() if $self->is_active;
    my @backing = grep { $_->backing_file } $self->list_volumes_info( device => 'disk');
    return if !@backing;
    $self->_replace_with_full_clone();
}

sub dettach($self, $user=undef) {
    my @backing = grep { $_->backing_file } $self->list_volumes_info( device => 'disk');
    return if !@backing;
    $self->_do_force_shutdown() if $self->is_active;
    $self->_replace_with_full_clone();
}

=head2 _client_connection_status

The viewer connects through the Proxmox spice proxy in the node, the
established connections are not visible from the Ravada backend. Running
machines are reported as connected so they are never shut down for a
false disconnection.

=cut

sub _client_connection_status($self, $force=undef) {
    return 'connected';
}

=head2 rsync

Nothing to synchronize, the Proxmox API moves the disks on migration

=cut

sub rsync($self, @args) {
    return;
}

sub _rsync_volumes_back($self, $node, $request=undef) {
    return;
}

sub has_non_shared_storage($self, $node=undef) {
    return 0;
}

sub _local_storage_volumes($self) {
    my @local;
    for my $vol ($self->list_volumes_info( device => 'disk' )) {
        my ($storage) = $vol->file =~ /^([^:]+):/;
        next if !$storage;
        push @local, ($vol->file) if !$self->_vm->_storage_is_shared($storage);
    }
    return @local;
}

=head2 set_base_vm

Enables or disables this base in a node of the cluster. A template can
be cloned from any node when its disks are in shared storage, nothing
is copied.

=cut

sub set_base_vm($self, %args) {
    my $id_vm = delete $args{id_vm};
    my $value = delete $args{value};
    my $user  = delete $args{user};
    my $vm    = delete $args{vm};
    my $node  = delete $args{node};
    my $request = delete $args{request};

    confess "ERROR: Unknown arguments, valid are id_vm, value, user, node and vm "
        .Dumper(\%args) if keys %args;
    confess "ERROR: Supply either id_vm or vm argument"
        if (!$id_vm && !$vm && !$node) || ($id_vm && $vm) || ($id_vm && $node)
            || ($vm && $node);
    confess "ERROR: user required"  if !$user;

    $vm = $node if $node;
    $vm = Ravada::VM->open($id_vm)  if !$vm;
    die "Error: VM ".Ravada::VM::_search_name($id_vm)." not available\n"
        if !$vm || !$vm->is_active || !$vm->vm;

    $value = 1 if !defined $value;
    my $id_request;
    $id_request = $request->id if $request;
    $request->status("working") if $request;

    if ($vm->node eq $self->node) {
        if (!$value) {
            $self->remove_base($user) if $self->is_base;
        } else {
            $self->prepare_base($user) if !$self->is_base;
        }
    } elsif ($value) {
        $self->prepare_base($user) if !$self->is_base;
        my @local = $self->_local_storage_volumes();
        die "Error: base ".$self->name." has volumes in local storage: "
            .join(", ", @local).". It can not be cloned from node ".$vm->node
            .", move the disks to a shared storage.\n" if @local;
        $self->_check_all_parents_in_node($vm);
    }
    $self->_set_base_vm_db($vm->id, $value, $id_request);
    return $self->_set_base_vm_db($vm->id, $value);
}

=head2 expose

Port exposure is done with NAT rules in the hypervisor, it is not
available for Proxmox machines. They are reachable through the bridge.

=cut

sub expose($self, @args) {
    die "Error: exposing ports is not available for Proxmox virtual machines,"
        ." they are reachable through the bridge network.\n";
}

sub open_exposed_ports($self, $remote_ip=undef) {
    return;
}

sub migrate($self, $node, $request=undef) {
    my $api = $self->_api;
    my $target = $node->node;
    return if $target eq $self->node;
    my %params = ( target => $target );
    $params{online} = 1 if $self->is_active;
    my @local;
    for my $vol ($self->list_volumes_info( device => 'disk' )) {
        my ($storage) = $vol->file =~ /^([^:]+):/;
        push @local, ($vol->file) if $storage && !$self->_vm->_storage_is_shared($storage);
    }
    $params{'with-local-disks'} = 1 if @local;
    my $upid = $api->post($self->_path('/migrate'), \%params);
    $self->_wait($upid, 3600);
    $self->node($target);
    $self->_store_config();
}

##########################################################################
#
# hardware
#

sub set_driver($self, $name, $value) {
    confess "Error: missing value for driver $name" if !defined $value;
    my $config = $self->pve_config();
    if ($name eq 'network') {
        my ($key) = sort grep { /^net\d+$/ } keys %$config;
        return $self->set_controller('network', undef, { driver => $value }) if !$key;
        return $self->_change_hardware_network(0, { driver => $value });
    }
    return $self->_set_config( vga => _vga_of($value) ) if $name eq 'video';
    return $self->_set_config( cpu => $value ) if $name eq 'cpu';
    if ($name eq 'disk') {
        my @disks = $self->_disks_info();
        return if !@disks;
        return $self->_change_hardware_disk(0, { bus => $value });
    }
    return $self->_set_config( $name => $value );
}

sub _vga_of($driver) {
    return 'qxl' if $driver =~ /spice|qxl/i;
    return 'virtio' if $driver =~ /virtio/i;
    return 'std' if $driver =~ /vnc|std|vga/i;
    return $driver;
}

sub set_controller($self, $name, $number=undef, $data=undef) {
    $data = {} if !$data;
    if ($name eq 'disk') {
        return $self->add_volume(%$data);
    }
    if ($name eq 'network') {
        my $key = $self->_new_target_dev('net');
        my $driver = ($data->{driver} or 'virtio');
        my $bridge = ($data->{bridge} or $data->{network} or $data->{name}
            or $self->_vm->_default_bridge);
        return $self->_set_config( $key => "$driver,bridge=$bridge" );
    }
    if ($name eq 'display') {
        my $driver = ($data->{driver} or 'spice');
        return $self->_set_config( vga => _vga_of($driver) );
    }
    if ($name eq 'usb') {
        return $self->_set_config( usb0 => 'spice' );
    }
    if ($name eq 'sound') {
        return $self->_set_config( audio0 => 'device=ich9-intel-hda,driver=spice' );
    }
    die "Error: I don't know how to add hardware '$name' in Proxmox\n";
}

sub remove_controller($self, $name, $index=0, $attribute=undef, $value=undef) {
    if ($name eq 'disk') {
        my $disk = $self->_volume_key_by_index($index);
        return $self->remove_volume($disk->{file}) if $disk->{file};
        return $self->_delete_config($disk->{target});
    }
    if ($name eq 'network') {
        my @nets = $self->_get_controller_network();
        my $net = $nets[$index]
            or die "Error: network $index not found, only ".scalar(@nets)." found\n";
        return $self->_delete_config($net->{_key});
    }
    if ($name eq 'display') {
        return $self->_set_config( vga => 'none' );
    }
    return $self->_delete_config('usb0') if $name eq 'usb';
    return $self->_delete_config('audio0') if $name eq 'sound';
    die "Error: I don't know how to remove hardware '$name' in Proxmox\n";
}

sub change_hardware($self, $hardware, $index, $data) {
    my $sub = $CHANGE_HARDWARE_SUB{$hardware}
        or die "Error: I don't know how to change hardware '$hardware' in Proxmox\n";
    $data = dclone($data) if ref($data);
    unlock_hash(%$data) if ref($data) eq 'HASH';
    return $sub->($self, $index, $data);
}

sub _change_hardware_memory($self, $index, $data) {
    my $memory = delete $data->{memory};
    my $max_mem = delete $data->{max_mem};
    $self->set_max_mem($max_mem) if defined $max_mem;
    $self->set_memory($memory) if defined $memory;
}

sub _change_hardware_vcpus($self, $index, $data) {
    my $n = delete $data->{n_virt_cpu};
    my $max = delete $data->{max_virt_cpu};
    my %params;
    $params{cores} = $max if defined $max;
    $params{vcpus} = $n if defined $n && defined $max && $n < $max;
    if (defined $n && (!defined $max || $n >= $max)) {
        $params{cores} = $n if !defined $max;
        $self->_delete_config('vcpus') if exists $self->pve_config->{vcpus};
    }
    $self->_set_config(%params) if keys %params;
    $self->needs_restart(1) if $self->is_known && $self->is_active;
}

sub _change_hardware_cpu($self, $index, $data) {
    my $cpu = $data->{cpu};
    $cpu = $data->{model} if !$cpu && $data->{model};
    $cpu = $cpu->{model} if ref($cpu) eq 'HASH';
    $self->_set_config( cpu => $cpu ) if $cpu;
    $self->_change_hardware_vcpus($index, { n_virt_cpu => $data->{vcpu} })
        if $data->{vcpu};
}

sub _change_hardware_network($self, $index, $data) {
    my @nets = $self->_get_controller_network();
    my $net = $nets[$index]
        or die "Error: network $index not found, only ".scalar(@nets)." found\n";
    my $config = $self->pve_config();
    my %current = Ravada::Front::Domain::Proxmox::_parse_net($config->{$net->{_key}});
    my $model = ($data->{driver} or $current{model} or 'virtio');
    my $mac = ($data->{hwaddr} or $current{mac});
    my $bridge = ($data->{bridge} or $data->{network} or $data->{name} or $current{bridge});
    delete @current{qw(model mac bridge)};
    my $value = "$model=$mac";
    $value = $model if !$mac;
    $value .= ",bridge=$bridge" if $bridge;
    for my $key (sort keys %current) {
        $value .= ",$key=$current{$key}" if defined $current{$key};
    }
    $self->_set_config( $net->{_key} => $value );
}

sub _change_hardware_disk($self, $index, $data) {
    my $disk = $self->_volume_key_by_index($index);
    my $key = $disk->{target};
    if (exists $data->{bus} && $data->{bus} && $data->{bus} ne $disk->{bus}) {
        my $config = $self->pve_config();
        my $value = $config->{$key};
        my $new_key = $self->_new_target_dev($data->{bus});
        $self->_delete_config($key);
        $self->_set_config( $new_key => $value );
        $self->_set_boot_order($new_key, $disk->{boot}) if $disk->{boot};
        $key = $new_key;
    }
    if (exists $data->{capacity} && $data->{capacity}) {
        my $capacity = Ravada::Utils::size_to_number($data->{capacity});
        if ($capacity > $disk->{capacity}) {
            my $upid = $self->_api->put($self->_path('/resize')
                , { disk => $key, size => int($capacity / 1024)."K" });
            $self->_wait($upid);
            $self->_refresh_config();
        }
    }
    if (exists $data->{file} && $disk->{device} eq 'cdrom') {
        my $file = $data->{file};
        $file = 'none' if !defined $file || !length($file);
        $self->_set_config( $key => "$file,media=cdrom" );
    }
    $self->_set_boot_order($key, $data->{boot}) if exists $data->{boot} && $data->{boot};
    $self->list_volumes_info();
}

sub _change_hardware_display($self, $index, $data) {
    my $driver = ($data->{driver} or 'spice');
    $self->_set_config( vga => _vga_of($driver) );
}

sub _change_hardware_video($self, $index, $data) {
    my $type = ($data->{type} or $data->{driver} or $data->{model} or 'qxl');
    $self->_set_config( vga => _vga_of($type) );
}

##########################################################################
#
# config editing protocol used by host devices and copy_config
#

sub get_config($self) {
    return dclone($self->pve_config(1));
}

sub get_config_txt($self) {
    return JSON::XS->new->canonical->pretty->encode($self->pve_config(1));
}

sub reload_config($self, $data) {
    $data = decode_json($data) if !ref($data);
    my $current = $self->pve_config(1);
    my %set;
    my @delete;
    for my $key (keys %$data) {
        next if $key eq 'digest' || $key eq 'template';
        my $value = $data->{$key};
        $value = JSON::XS->new->canonical->encode($value) if ref($value);
        next if defined $current->{$key} && $current->{$key} eq $value;
        $set{$key} = $value;
    }
    for my $key (keys %$current) {
        next if $key eq 'digest' || $key eq 'template';
        push @delete, ($key) if !exists $data->{$key};
    }
    $self->_set_config(%set, ( @delete ? ( delete => join(",", @delete)) : () ))
        if keys %set || @delete;
}

sub copy_config($self, $domain) {
    my $config = $domain->get_config();
    my $current = $self->pve_config(1);
    for my $key (keys %$config) {
        delete $config->{$key} if $key =~ $RE_DISK || $key =~ /^(unused\d+|vmstate|template|name|smbios1|net\d+|digest)$/;
    }
    for my $key (grep { $_ =~ $RE_DISK || /^(name|smbios1|net\d+)$/ } keys %$current) {
        $config->{$key} = $current->{$key};
    }
    $self->reload_config($config);
}

sub _config_walk($data, $path) {
    my $found = $data;
    my $parent;
    my $last;
    for my $item (split m{/}, $path) {
        next if !length $item;
        $parent = $found;
        $last = $item;
        $found = $found->{$item} if ref($found) eq 'HASH';
    }
    return ($found, $parent, $last);
}

sub add_config_node($self, $path, $content, $data) {
    my $content_hash = $content;
    $content_hash = decode_json($content) if !ref($content);
    my ($found, $parent, $last) = _config_walk($data, $path);
    if (ref($found) eq 'ARRAY') {
        push @$found, ($content_hash);
    } elsif (ref($found) eq 'HASH') {
        for my $key (keys %$content_hash) {
            $found->{$key} = $content_hash->{$key};
        }
    } else {
        $parent->{$last} = $content_hash;
    }
    return;
}

our %HOSTDEV_MAX = ( hostpci => 15, usb => 4 );

sub _hostdev_key($path) {
    my ($prefix) = $path =~ m{^/?(hostpci|usb)$};
    return $prefix;
}

sub _hostdev_same($a, $b) {
    my ($id_a) = split /,/, $a;
    my ($id_b) = split /,/, $b;
    return $id_a eq $id_b;
}

sub add_config_unique_node($self, $path, $content, $data) {
    my $prefix = _hostdev_key($path);
    return $self->add_config_node($path, $content, $data) if !$prefix;

    my $content_hash = $content;
    $content_hash = decode_json($content) if !ref($content);
    my $value = $content_hash->{$prefix};
    confess "Error: missing $prefix in ".Dumper($content_hash) if !defined $value;

    for my $key (grep { /^$prefix\d+$/ } keys %$data) {
        return if _hostdev_same($data->{$key}, $value);
    }
    for my $n (0 .. $HOSTDEV_MAX{$prefix}) {
        my $key = "$prefix$n";
        next if exists $data->{$key};
        $data->{$key} = $value;
        return;
    }
    die "Error: no free $prefix slot in ".$self->name."\n";
}

sub set_config_node($self, $path, $content, $data) {
    my ($found, $parent, $last) = _config_walk($data, $path);
    $parent->{$last} = $content;
}

sub remove_config_node($self, $path, $content, $data) {
    my $content_hash = $content;
    $content_hash = decode_json($content) if !ref($content);
    my $prefix = _hostdev_key($path);
    if ($prefix) {
        my $value = $content_hash->{$prefix};
        for my $key (grep { /^$prefix\d+$/ } keys %$data) {
            delete $data->{$key} if defined $value && _hostdev_same($data->{$key}, $value);
        }
        return;
    }
    my ($found, $parent, $last) = _config_walk($data, $path);
    return if !ref($parent);
    if (ref($found) eq 'HASH') {
        delete $found->{$_} for keys %$content_hash;
    } else {
        delete $parent->{$last};
    }
}

sub change_config_attribute($self, $path, $content, $data) {
    return $self->set_config_node($path, $content, $data);
}

sub change_namespace { }
sub remove_namespace { }

sub can_host_devices { return 1 }

=head2 list_snapshots

Returns the snapshots of the virtual machine

=cut

sub list_snapshots($self) {
    my $list = $self->_api->get($self->_path('/snapshot'));
    return grep { $_->{name} ne 'current' } @$list;
}

=head2 create_snapshot

Creates a snapshot of the virtual machine

    $domain->create_snapshot($name, $description, $vmstate);

=cut

sub create_snapshot($self, $name, $description='', $vmstate=0) {
    die "Error: invalid snapshot name '$name'\n" if $name !~ /^[a-zA-Z][a-zA-Z0-9_\-]*$/;
    my %params = ( snapname => $name, description => $description );
    $params{vmstate} = 1 if $vmstate;
    $self->_post('/snapshot', \%params);
}

=head2 remove_snapshot

Removes a snapshot

=cut

sub remove_snapshot($self, $name) {
    my $upid = $self->_api->delete($self->_path("/snapshot/$name"));
    $self->_wait($upid);
}

=head2 rollback_snapshot

Restores the virtual machine to a snapshot. It is shut down first.

=cut

sub rollback_snapshot($self, $name, $start=0) {
    $self->_do_force_shutdown() if $self->is_active;
    my %params;
    $params{start} = 1 if $start;
    $self->_post("/snapshot/$name/rollback", \%params);
    $self->_refresh_config();
}

sub remove_host_devices($self, @) {
    my $config = $self->pve_config(1);
    my @keys = grep { /^(hostpci|usb)\d+$/ } keys %$config;
    $self->_delete_config(@keys) if @keys;
}

sub config_files($self) {
    return ();
}

1;
