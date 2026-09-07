package Ravada::VM::Proxmox;

use warnings;
use strict;

=head1 NAME

Ravada::VM::Proxmox - Proxmox VE node managed through the REST API

=head1 DESCRIPTION

Each node of the Proxmox cluster is a virtual manager. The node
configured as C<node> in the C<proxmox> section of the config file is
stored with hostname C<localhost> so Ravada treats it as the main
node. Other nodes are added with their node name as hostname.

    proxmox:
      url: https://pve.example.com:8006
      token_id: ravada@pve!rvd
      token_secret: 00000000-0000-0000-0000-000000000000
      node: pve1
      nodes: [ pve2 ]
      storage: local
      bridge: vmbr0

=cut

use Carp qw(carp croak confess);
use Data::Dumper;
use JSON::XS;
use Moose;
use Storable qw(dclone);

use Ravada::Proxmox::API;
use Ravada::Domain::Proxmox;

no warnings "experimental::signatures";
use feature qw(signatures);

with 'Ravada::VM';

has 'type' => (
    is => 'ro'
    ,isa => 'Str'
    ,default => 'Proxmox'
);

has 'vm' => (
    is => 'rw'
    ,isa => 'Any'
    ,builder => '_connect'
    ,lazy => 1
);

use Socket qw(inet_aton inet_ntoa);

# the role attribute would override a plain method, so it is redefined
# here with a builder that checks the SDN zone
has 'has_networking' => (
    isa => 'Bool'
    , is => 'ro'
    , lazy => 1
    , builder => '_build_has_networking'
);


our $CONNECTOR = \$Ravada::CONNECTOR;

# Connection settings set by new_from_config, used when the vms table
# has no connection_args for a node
our %CONFIG;

our $CACHE_TIMEOUT = 5;

##########################################################################
#
# connection
#

=head2 new_from_config

Creates the virtual manager from the C<proxmox> section of the config
file and stores the connection settings in the database.

=cut

sub new_from_config($class, $config=undef) {
    $config = {} if !$config;
    my %conn = %$config;
    confess "Error: missing url in proxmox config section" if !$conn{url};
    %CONFIG = %conn;

    my $vm = $class->new();
    $vm->_store_connection_args(\%conn);

    my $client;
    eval { $client = $vm->vm };
    warn $@ if $@;
    return if !$client;

    my @nodes;
    my $nodes = $conn{nodes};
    if (defined $nodes && !ref($nodes) && $nodes =~ /^(all|\*)$/i) {
        my $list = $client->get('/nodes');
        @nodes = map { $_->{node} } @$list;
    } elsif (ref($nodes) eq 'ARRAY') {
        @nodes = @$nodes;
    } elsif (defined $nodes) {
        @nodes = split /\s*,\s*/, $nodes;
    }
    for my $node (@nodes) {
        next if !$node || $node eq $vm->node;
        my $other = $class->new( host => $node );
        $other->_store_connection_args(\%conn);
    }

    return $vm;
}

sub _store_connection_args($self, $conn) {
    return if !$self->store;
    my %store = %$conn;
    delete $store{nodes};
    delete $store{node} if !$self->is_local;
    $self->_data('connection_args' => JSON::XS->new->canonical->encode(\%store));
    my $default = $self->_data('default_storage');
    if ($conn->{storage} && (!$default || $default eq 'default')) {
        $self->_data('default_storage' => $conn->{storage});
    }
}

sub _conn($self) {
    return $self->{_conn} if $self->{_conn};
    my $conn;
    if ($self->store) {
        my $json;
        eval { $json = $self->_data('connection_args') };
        if ($json) {
            $conn = eval { decode_json($json) };
            $conn = undef if $conn && (ref($conn) ne 'HASH' || !$conn->{url});
        }
    }
    $conn = { %CONFIG } if !$conn && $CONFIG{url};
    $conn = { %{$Ravada::CONFIG->{proxmox}} }
        if !$conn && $Ravada::CONFIG && $Ravada::CONFIG->{proxmox}
            && $Ravada::CONFIG->{proxmox}->{url};
    confess "Error: no Proxmox connection settings for ".$self->name
        ." add them in the proxmox section of the config file"
        if !$conn;
    $self->{_conn} = $conn;
    return $conn;
}

=head2 node

Returns the Proxmox node name of this virtual manager

=cut

sub node($self) {
    return $self->{_node} if $self->{_node};
    my $host = ($self->host or 'localhost');
    if ($host eq 'localhost' || $host eq '127.0.0.1') {
        my $conn = $self->_conn;
        $host = ($conn->{node} or '');
        if (!$host) {
            my $nodes;
            $nodes = eval { $self->vm->get('/nodes') } if $self->vm;
            $host = $nodes->[0]->{node} if $nodes && @$nodes;
        }
        confess "Error: I can't find the Proxmox node name, set it in the config" if !$host;
    }
    $self->{_node} = $host;
    return $host;
}

sub _connect($self) {
    my $conn = $self->_conn;
    my $client;
    eval {
        $client = Ravada::Proxmox::API->new_client(%$conn);
        $client->get('/version');
    };
    if ($@) {
        warn "Error connecting to Proxmox API at $conn->{url}: $@";
        $self->_data('cached_down' => time) if $self->store && !$self->is_local;
        return;
    }
    # nodes added from the frontend have no connection settings stored yet
    if ($self->store) {
        my $stored;
        eval { $stored = $self->_data('connection_args') };
        $self->_store_connection_args($conn) if !$stored;
    }
    return $client;
}

sub connect($self) {
    return $self->vm if $self->vm;
    return $self->vm($self->_connect);
}

sub disconnect($self) {
    $self->vm(undef);
    delete $self->{_cache};
}

sub reconnect($self) {
    $self->disconnect();
    return $self->connect();
}

sub is_alive($self) {
    my $vm = $self->vm or return 0;
    my $ok = 0;
    eval {
        $vm->get('/nodes/'.$self->node.'/status');
        $ok = 1;
    };
    return $ok;
}

sub needs_ssh { return 0 }

sub _do_ping($self, $host, $debug=0) {
    my $ok = 0;
    eval {
        my $vm = $self->vm;
        if ($vm) {
            my $status = $vm->get('/nodes/'.$self->node.'/status');
            $ok = 1 if $status && ($status->{status} or 'online') eq 'online';
        }
    };
    warn $@ if $@ && $debug;
    return $ok;
}

sub _store_mac_address($self, $force=0) {
    return;
}

our %PSEUDO_COMMAND = map { $_ => 1 } qw(pve-list-pci pve-list-usb pve-list-mdev);

sub run_command($self, @command) {
    my ($command0) = @command;
    if (defined $command0 && $command0 =~ m{(^|/)(pve-list-(pci|usb|mdev))$}) {
        return ($self->_list_hardware($3), '');
    }
    return $self->_run_command_local(@command) if $self->is_local;
    my $ssh;
    eval { $ssh = $self->_ssh };
    die "Error: running commands on the Proxmox node ".$self->node
        ." requires ssh access which is not configured\n" if !$ssh;
    my ($exec, @args) = @command;
    my ($out, $err) = $ssh->capture2({ timeout => 10 }, join(" ", $exec, @args));
    return ($out, $err);
}

sub _fetch_dir_cert { return '' }

sub _which($self, $command) {
    return $command if $PSEUDO_COMMAND{$command};
    return Ravada::VM::_which($self, $command);
}

=head2 _list_hardware

Lists the PCI, USB or mediated devices of the node in a text format
similar to lspci and lsusb, used by the host device templates.

=cut

sub _list_hardware($self, $type) {
    my $node = $self->node;
    my @lines;
    if ($type eq 'pci' || $type eq 'mdev') {
        my $list = $self->vm->get("/nodes/$node/hardware/pci");
        for my $dev (@$list) {
            my $class = ($dev->{class} or '');
            next if $class =~ /^0x06/;
            my $vendor = ($dev->{vendor} or '');
            my $device = ($dev->{device} or '');
            s/^0x// for ($vendor, $device);
            if ($type eq 'pci') {
                push @lines, join(" ", $dev->{id}, "$vendor:$device"
                    , ($dev->{vendor_name} or ''), ($dev->{device_name} or ''));
                next;
            }
            next if !$dev->{mdev};
            my $types = eval { $self->vm->get("/nodes/$node/hardware/pci/$dev->{id}/mdev") };
            next if !$types;
            for my $mdev (@$types) {
                next if defined $mdev->{available} && !$mdev->{available};
                push @lines, join(" ", $dev->{id}, "mdev=".$mdev->{type}
                    , ($mdev->{name} or ''), "available=".($mdev->{available} or 0));
            }
        }
    } elsif ($type eq 'usb') {
        my $list = $self->vm->get("/nodes/$node/hardware/usb");
        for my $dev (@$list) {
            next if defined $dev->{class} && $dev->{class} == 9;
            push @lines, sprintf("Bus %03d Device %03d: ID %s:%s %s %s"
                , $dev->{busnum}, $dev->{devnum}, $dev->{vendid}, $dev->{prodid}
                , ($dev->{manufacturer} or ''), ($dev->{product} or ''));
        }
    }
    return join("\n", @lines)."\n";
}

=head2 iptables_list

Ravada manages no firewall rules in Proxmox nodes, returns an empty list

=cut

sub iptables_list($self) {
    return {};
}

sub get_library_version($self) {
    my $data = $self->_cached('version', sub { $self->vm->get('/version') });
    my ($n1, $n2, $n3) = ($data->{version} or '0.0.0') =~ /(\d+)\.(\d+)(?:\.(\d+))?/;
    return ($n1 or 0) * 1000000 + ($n2 or 0) * 1000 + ($n3 or 0);
}

sub _cached($self, $key, $code) {
    my $cache = $self->{_cache}->{$key};
    return $cache->{value} if $cache && time - $cache->{time} < $CACHE_TIMEOUT;
    my $value = $code->();
    $self->{_cache}->{$key} = { time => time, value => $value };
    return $value;
}

sub _clear_cache($self) {
    delete $self->{_cache};
}

##########################################################################
#
# node information
#

sub _node_status($self) {
    return $self->_cached('node_status', sub { $self->vm->get('/nodes/'.$self->node.'/status') });
}

sub free_memory($self) {
    my $status = $self->_node_status();
    my $free = $status->{memory}->{free};
    return int($free / 1024);
}

sub _node_address($self) {
    my $conn = $self->_conn;
    return $self->display_ip if $self->display_ip;
    return $self->public_ip if $self->public_ip;
    return $conn->{display_host} if $conn->{display_host};
    my $address = $self->_cached('node_address', sub {
        my $bridges = $self->vm->get('/nodes/'.$self->node.'/network', { type => 'any_bridge' });
        my $default = $self->_default_bridge;
        my ($bridge) = grep { $_->{iface} eq $default } @$bridges;
        $bridge = $bridges->[0] if !$bridge;
        my $addr = ($bridge->{address} or '');
        if (!$addr && $bridge->{cidr}) {
            ($addr) = $bridge->{cidr} =~ m{^(.*)/};
        }
        return $addr;
    });
    return $address if $address;
    return $self->node;
}

sub listen_ip($self, $remote_ip=undef) {
    return $self->_node_address;
}

sub interface_ip($self, $remote_ip=undef) {
    return $self->_node_address;
}

sub _interface_ip($self, $remote_ip=undef) {
    return $self->_node_address;
}

sub _default_bridge($self) {
    my $conn = $self->_conn;
    return ($conn->{bridge} or 'vmbr0');
}

sub list_machine_types($self) {
    my $list = $self->_cached('machines', sub {
        $self->vm->get('/nodes/'.$self->node.'/capabilities/qemu/machines');
    });
    my @ids = map { $_->{id} } @$list;
    return ( x86_64 => \@ids, i686 => \@ids );
}

sub get_cpu_model_names($self, $arch='x86_64') {
    my $list = $self->_cached('cpus', sub {
        $self->vm->get('/nodes/'.$self->node.'/capabilities/qemu/cpu');
    });
    return map { $_->{name} } @$list;
}

sub can_list_cpu_models { return 1 }

##########################################################################
#
# networking
#

sub _bridges($self) {
    return $self->_cached('bridges', sub {
        $self->vm->get('/nodes/'.$self->node.'/network', { type => 'any_bridge' });
    });
}

sub _list_bridges($self) {
    return map { $_->{iface} } @{$self->_bridges};
}

sub list_network_interfaces($self, $type) {
    return $self->_list_bridges() if $type eq 'bridge';
    return $self->_list_nat_interfaces() if $type eq 'nat';
    confess "Error: Unknown interface type $type";
}

sub _list_nat_interfaces($self) {
    return ();
}

sub _list_qemu_bridges($self) {
    return ();
}

=head2 has_networking

Virtual networks are available when a SDN zone is configured in the
C<sdn_zone> setting of the proxmox config section.

=cut

sub _build_has_networking($self) {
    return 1 if $self->_sdn_zone;
    return 0;
}

sub _sdn_zone($self) {
    return ($self->_conn->{sdn_zone} or '');
}

sub _vnets($self) {
    return [] if !$self->_sdn_zone;
    my $zone = $self->_sdn_zone;
    # not cached, networks are changed from other objects and processes
    my $list = $self->vm->get('/cluster/sdn/vnets');
    return [ grep { ($_->{zone} or '') eq $zone } @$list ];
}

sub _subnets($self, $vnet) {
    return $self->vm->get("/cluster/sdn/vnets/$vnet/subnets");
}

sub _prefix_to_netmask($prefix) {
    return inet_ntoa(pack("N", $prefix ? (0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF : 0));
}

sub _netmask_to_prefix($netmask) {
    return 24 if !$netmask;
    return $netmask if $netmask =~ /^\d+$/;
    my $bits = unpack("B32", inet_aton($netmask));
    return length(($bits =~ /^(1*)/)[0]);
}

sub _parse_dhcp_range($range) {
    return (undef, undef) if !$range;
    $range = $range->[0] if ref($range) eq 'ARRAY';
    return (undef, undef) if !$range;
    my ($start) = $range =~ /start-address=([^,]+)/;
    my ($end) = $range =~ /end-address=([^,]+)/;
    return ($start, $end);
}

sub _vnet_network($self, $vnet) {
    my $name = $vnet->{vnet};
    my $subnets = $self->_subnets($name);
    my ($subnet) = @$subnets;
    my %net = (
        name => ($vnet->{alias} && $vnet->{alias} =~ /^[a-zA-Z0-9_\-]+$/ ? $vnet->{alias} : $name)
        ,bridge => $name
        ,internal_id => $name
        ,is_active => 1
        ,autostart => 1
        ,forward_mode => 'none'
        ,ip_address => ''
        ,ip_netmask => ''
        ,id_vm => $self->id
    );
    if ($subnet) {
        my ($ip, $prefix) = ($subnet->{cidr} or '') =~ m{^(.*)/(\d+)$};
        $net{ip_address} = ($subnet->{gateway} or $ip or '');
        $net{ip_netmask} = _prefix_to_netmask($prefix) if defined $prefix;
        $net{forward_mode} = 'nat' if $subnet->{snat};
        my ($start, $end) = _parse_dhcp_range($subnet->{'dhcp-range'});
        $net{dhcp_start} = $start if $start;
        $net{dhcp_end} = $end if $end;
    }
    return \%net;
}

sub list_virtual_networks($self) {
    my @list;
    if ($self->_sdn_zone) {
        for my $vnet (@{$self->_vnets}) {
            push @list, ($self->_vnet_network($vnet));
        }
        return @list;
    }
    for my $bridge (@{$self->_bridges}) {
        my $address = ($bridge->{address} or '');
        ($address) = $bridge->{cidr} =~ m{^(.*)/} if !$address && $bridge->{cidr};
        push @list, {
            name => $bridge->{iface}
            ,bridge => $bridge->{iface}
            ,internal_id => $bridge->{iface}
            ,is_active => 1
            ,autostart => 1
            ,forward_mode => 'bridge'
            ,ip_address => $address
            ,ip_netmask => ($bridge->{netmask} or '')
            ,id_vm => $self->id
        };
    }
    return @list;
}

sub list_routes { return () }

sub _is_ip_nat($self, $ip) {
    return 0 if !$self->_sdn_zone || !$ip;
    my $n_ip = unpack("N", inet_aton($ip));
    for my $vnet (@{$self->_vnets}) {
        for my $subnet (@{$self->_subnets($vnet->{vnet})}) {
            next if !$subnet->{snat};
            my ($net, $prefix) = ($subnet->{cidr} or '') =~ m{^(.*)/(\d+)$};
            next if !$net;
            my $mask = $prefix ? (0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF : 0;
            return 1 if ((unpack("N", inet_aton($net)) & $mask) == ($n_ip & $mask));
        }
    }
    return 0;
}

sub _vnet_name($name) {
    my $vnet = lc($name);
    $vnet =~ s/[^a-z0-9]//g;
    $vnet = "n$vnet" if $vnet !~ /^[a-z]/;
    return substr($vnet, 0, 8);
}

sub _find_vnet($self, $name) {
    for my $vnet (@{$self->_vnets}) {
        return $vnet if $vnet->{vnet} eq $name
            || ($vnet->{alias} && $vnet->{alias} eq $name)
            || $vnet->{vnet} eq _vnet_name($name);
    }
    return;
}

sub _apply_sdn($self) {
    my $upid = $self->vm->put('/cluster/sdn');
    $self->vm->wait_task($self->node, $upid) if $upid;
    $self->_clear_cache();
}

sub new_network($self, $name='net') {
    die "Error: no SDN zone configured for virtual networks\n" if !$self->_sdn_zone;
    my @networks = $self->list_virtual_networks();
    my %used_name = map { $_->{name} => 1, $_->{bridge} => 1 } @networks;
    my %used_ip = map { $_->{ip_address} => 1 } @networks;
    my $n = 0;
    my $new_name;
    for ( 0 .. 255 ) {
        $new_name = _vnet_name($name.$n);
        last if !$used_name{$new_name};
        $n++;
    }
    my $ip;
    for my $i ( 0 .. 255 ) {
        $ip = "10.$i.0.1";
        last if !$used_ip{$ip};
    }
    return {
        name => $new_name
        ,bridge => $new_name
        ,ip_address => $ip
        ,ip_netmask => '255.255.255.0'
    };
}

sub create_network($self, $data, $id_owner=undef, $request=undef) {
    my $zone = $self->_sdn_zone
        or die "Error: no SDN zone configured for virtual networks\n";
    my $name = _vnet_name($data->{name});
    die "Error: network $data->{name} already exists\n" if $self->_find_vnet($name);

    my $api = $self->vm;
    $api->post('/cluster/sdn/vnets', { vnet => $name, zone => $zone, alias => $data->{name} });

    my $ip = $data->{ip_address} or die "Error: missing ip address";
    my $prefix = _netmask_to_prefix($data->{ip_netmask});
    my $mask = $prefix ? (0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF : 0;
    my $network = inet_ntoa(pack("N", unpack("N", inet_aton($ip)) & $mask));
    my %subnet = (
        subnet => "$network/$prefix"
        ,type => 'subnet'
        ,gateway => $ip
        ,snat => ( ($data->{forward_mode} or 'nat') eq 'nat' ? 1 : 0 )
    );
    $subnet{'dhcp-range'} = "start-address=$data->{dhcp_start},end-address=$data->{dhcp_end}"
        if $data->{dhcp_start} && $data->{dhcp_end};
    eval { $api->post("/cluster/sdn/vnets/$name/subnets", \%subnet) };
    if ($@) {
        my $err = $@;
        eval { $api->delete("/cluster/sdn/vnets/$name") };
        die $err;
    }
    $self->_apply_sdn();

    $data->{internal_id} = $name;
    $data->{bridge} = $name;
    $data->{is_active} = 1;
    $data->{autostart} = 1;
    return $data;
}

sub remove_network($self, $name) {
    my $vnet = $self->_find_vnet($name) or return;
    my $api = $self->vm;
    for my $subnet (@{$self->_subnets($vnet->{vnet})}) {
        $api->delete("/cluster/sdn/vnets/$vnet->{vnet}/subnets/$subnet->{subnet}");
    }
    $api->delete("/cluster/sdn/vnets/$vnet->{vnet}");
    $self->_apply_sdn();
}

sub change_network($self, $data) {
    my $id = ($data->{internal_id} or $data->{bridge} or $data->{name})
        or confess "Error: missing internal_id ".Dumper($data);
    my $vnet = $self->_find_vnet($id) or die "Error: network $id not found\n";
    my ($current) = $self->_vnet_network($vnet);

    die "Error: network can not be renamed\n"
        if $data->{name} && $data->{name} ne $current->{name}
            && $data->{name} ne $vnet->{vnet};

    my ($subnet) = @{$self->_subnets($vnet->{vnet})};
    my %params;
    if ($subnet) {
        $params{snat} = ($data->{forward_mode} eq 'nat' ? 1 : 0)
            if $data->{forward_mode} && $data->{forward_mode} ne $current->{forward_mode};
        my $start = ($data->{dhcp_start} or $current->{dhcp_start});
        my $end = ($data->{dhcp_end} or $current->{dhcp_end});
        $params{'dhcp-range'} = "start-address=$start,end-address=$end"
            if $start && $end && ( ($data->{dhcp_start} or '') ne ($current->{dhcp_start} or '')
                || ($data->{dhcp_end} or '') ne ($current->{dhcp_end} or '') );
    }
    return 0 if !keys %params;
    $self->vm->put("/cluster/sdn/vnets/$vnet->{vnet}/subnets/$subnet->{subnet}", \%params);
    $self->_apply_sdn();
    return 1;
}

##########################################################################
#
# storage
#

sub _storages($self) {
    return $self->_cached('storages', sub {
        $self->vm->get('/nodes/'.$self->node.'/storage');
    });
}

sub _storage($self, $name) {
    my ($storage) = grep { $_->{storage} eq $name } @{$self->_storages};
    return $storage;
}

sub _storage_is_shared($self, $name) {
    my $storage = $self->_storage($name);
    return 0 if !$storage;
    return ($storage->{shared} or 0);
}

sub list_storage_pools($self, $info=0) {
    my @list;
    for my $storage (@{$self->_storages}) {
        next if ($storage->{content} or '') !~ /(^|,)(images|iso)(,|$)/;
        my $total = ($storage->{total} or 0);
        my $used = ($storage->{used} or 0);
        my $avail = ($storage->{avail} or 0);
        push @list, {
            name => $storage->{storage}
            ,path => $storage->{storage}
            ,is_active => ($storage->{active} ? 1 : 0)
            ,size => int($total / 1024 / 1024 / 1024)
            ,available => int($avail / 1024 / 1024 / 1024)
            ,used => int($used / 1024 / 1024 / 1024)
            ,pc_used => ($total ? int($used * 100 / $total) : 0)
            ,shared => ($storage->{shared} or 0)
            ,type => $storage->{type}
            ,content => $storage->{content}
        };
    }
    return @list if $info;
    return map { $_->{name} } @list;
}

sub _storage_path($self, $storage) {
    confess "Error: undefined storage" if !defined $storage;
    return $storage;
}

sub default_storage_pool_name($self, $value=undef) {
    my $current;
    if (defined $value) {
        $self->_data('default_storage' => $value);
        $current = $value;
    } else {
        $current = $self->_data('default_storage');
    }
    return $current if $current && $current ne 'default' && $self->_storage($current);
    my $conn = $self->_conn;
    return $conn->{storage} if $conn->{storage};
    return $current if $current && $self->_storage($current);
    my ($first) = grep { ($_->{content} or '') =~ /images/ } @{$self->_storages};
    return $first->{storage} if $first;
    return 'local';
}

sub dir_img($self) {
    return $self->default_storage_pool_name();
}

sub _iso_storage($self) {
    my $default = $self->default_storage_pool_name;
    my $storage = $self->_storage($default);
    return $default if $storage && ($storage->{content} or '') =~ /iso/;
    my ($first) = grep { ($_->{content} or '') =~ /iso/ } @{$self->_storages};
    return $first->{storage} if $first;
    return $default;
}

sub free_disk($self, $storage_pool=undef) {
    $storage_pool = $self->default_storage_pool_name if !$storage_pool;
    my $storage = $self->_storage($storage_pool)
        or die "Error: unknown storage '$storage_pool' in ".$self->node."\n";
    return ($storage->{avail} or 0);
}

sub _content($self, $storage, $type=undef) {
    my %params;
    $params{content} = $type if $type;
    # not cached, volumes change often and other objects may have changed them
    return $self->vm->get('/nodes/'.$self->node."/storage/$storage/content", \%params);
}

sub _all_content($self, $type=undef) {
    my @list;
    for my $storage ($self->list_storage_pools) {
        my $content = eval { $self->_content($storage, $type) };
        warn $@ if $@;
        push @list, @$content if $content;
    }
    return @list;
}

sub _volume_size($self, $volid) {
    my ($storage) = $volid =~ /^([^:]+):/;
    return 0 if !$storage;
    my ($vol) = grep { $_->{volid} eq $volid } @{$self->_content($storage)};
    return ($vol->{size} or 0) if $vol;
    return 0;
}

sub file_exists($self, $file) {
    return 1 if $PSEUDO_COMMAND{$file};
    return -e $file if $file =~ m{^/};
    my ($storage) = $file =~ /^([^:]+):/;
    return 0 if !$storage;
    my $content = eval { $self->_content($storage) };
    return 0 if !$content;
    return 1 if grep { $_->{volid} eq $file } @$content;
    return 0;
}

sub search_volume($self, $pattern) {
    for my $vol ($self->_all_content) {
        my ($name) = $vol->{volid} =~ m{([^/]+)$};
        return $vol->{volid} if $name eq $pattern || $vol->{volid} eq $pattern;
    }
    return;
}

sub search_volume_path($self, $pattern) {
    return $self->search_volume($pattern);
}

sub search_volume_re($self, $pattern) {
    for my $vol ($self->_all_content) {
        my ($name) = $vol->{volid} =~ m{([^/]+)$};
        return $vol->{volid} if $name =~ $pattern;
    }
    return;
}

sub search_volume_path_re($self, $pattern) {
    return $self->search_volume_re($pattern);
}

sub list_volumes($self) {
    return map { $_->{volid} } $self->_all_content;
}

sub list_used_volumes($self) {
    my @used;
    for my $domain ($self->list_domains) {
        push @used, ($domain->list_volumes);
    }
    return @used;
}

sub remove_file($self, @files) {
    for my $file (@files) {
        next if !defined $file || !length($file);
        my ($storage, $rest) = $file =~ /^([^:]+):(.*)/;
        if (!$storage) {
            unlink $file if -e $file;
            next;
        }
        my $upid;
        eval {
            $upid = $self->vm->delete('/nodes/'.$self->node."/storage/$storage/content/$file");
            $self->vm->wait_task($self->node, $upid) if $upid;
        };
        die $@ if $@ && "$@" !~ /does not exist|not found/i;
    }
    $self->_clear_cache();
}

sub refresh_storage($self) {
    $self->_clear_cache();
}

sub refresh_storage_pools($self) {
    $self->_clear_cache();
}

sub create_storage_pool($self, $name, $dir) {
    die "Error: storage is managed in Proxmox\n";
}

sub remove_storage_pool($self, $name) {
    die "Error: storage is managed in Proxmox\n";
}

sub active_storage_pool($self, $name, $value) {
    die "Error: storage is managed in Proxmox\n";
}

sub create_volume($self, %args) {
    confess "Error: volumes are created attached to a virtual machine, use add_volume";
}

sub copy_file_storage($self, $file, $storage) {
    die "Error: moving volumes between storages is done in Proxmox\n";
}

sub shared_storage($self, $node, $dir) {
    return $self->_storage_is_shared($dir);
}

sub _check_equal_storage_pools($self, $vm2) {
    my %mine = map { $_ => 1 } $self->list_storage_pools;
    for my $name ($vm2->list_storage_pools) {
        next if $mine{$name};
        die "Error: storage '$name' of ".$vm2->node." is missing in ".$self->node."\n";
    }
    return 1;
}

##########################################################################
#
# ISO images
#

sub _search_iso($self, $id, $device=undef) {
    my $sth = $$CONNECTOR->dbh->prepare("SELECT * FROM iso_images WHERE id=?");
    $sth->execute($id);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    die "Error: iso id=$id not found\n" if !$row || !keys %$row;
    $row->{device} = $device if defined $device;
    if ($row->{options} && !ref($row->{options})) {
        $row->{options} = eval { decode_json($row->{options}) } || {};
    }
    return $row;
}

sub _iso_filename($iso) {
    my $name = ($iso->{rename_file} or $iso->{file_re});
    if (!$name && $iso->{url}) {
        ($name) = $iso->{url} =~ m{([^/]+)$};
    }
    $name = $iso->{name} if !$name;
    $name =~ s/(.*)\.\*(.*)/$1$2/;
    $name =~ s/(.*)\.\+(.*)/$1.$2/;
    $name =~ s/(.*)\[\\d.*?\]\+(.*)/${1}1$2/;
    $name =~ s/(.*)\\d\+(.*)/${1}1$2/;
    $name =~ s/\\\././g;
    $name =~ s/[\$\^]//g;
    $name =~ s/[^a-zA-Z0-9\.\-_]/_/g;
    $name .= ".iso" if $name !~ /\.iso$/i;
    return $name;
}

sub _iso_name($self, $iso, $request=undef, $verbose=0) {
    return '' if !$iso->{has_cd};

    if ($iso->{device} && $self->file_exists($iso->{device})) {
        return $iso->{device};
    }
    my $storage = $self->_iso_storage;
    my $filename = _iso_filename($iso);
    my $volid = "$storage:iso/$filename";

    if (!$self->file_exists($volid) && $iso->{file_re}) {
        my $found = $self->search_volume_re(qr($iso->{file_re}));
        $volid = $found if $found;
    }
    if (!$self->file_exists($volid)) {
        die "Error: ISO $iso->{name} has no download url\n" if !$iso->{url};
        my $url = $self->_search_url_file($iso->{url});
        $request->status('downloading', "Downloading $url to $volid") if $request;
        my %params = ( content => 'iso', filename => $filename, url => $url );
        $self->_download_file_external($url, $volid, \%params);
        $self->_clear_cache();
    }
    my $sth = $$CONNECTOR->dbh->prepare("UPDATE iso_images SET device=? WHERE id=?");
    $sth->execute($volid, $iso->{id});
    $sth->finish;
    return $volid;
}

sub _search_url_file($self, $url) {
    return $url if $url !~ /[\*\+\[\]\\\$]/;
    my ($dir, $file_re) = $url =~ m{(.*)/(.*)};
    if ($self->vm && $self->vm->is_mock) {
        my $file = _iso_filename({ file_re => $file_re });
        return "$dir/$file";
    }
    require Mojo::UserAgent;
    my $ua = Mojo::UserAgent->new(max_redirects => 3);
    my $res = $ua->get("$dir/")->result;
    die "Error: I can't fetch $dir/ : ".$res->code." ".$res->message."\n"
        if !$res->is_success;
    my @found;
    for my $link ($res->dom->find('a')->each) {
        my $href = $link->attr('href') or next;
        my ($name) = $href =~ m{([^/]+)/?$};
        push @found, ($name) if $name && $name =~ /^$file_re$/;
    }
    die "Error: no file matching $file_re in $dir/\n" if !@found;
    return "$dir/".$found[-1];
}

sub _download_file_external($self, $url, $device, $params=undef) {
    my ($storage, $rest) = $device =~ /^([^:]+):(.*)/;
    my ($filename) = $rest =~ m{([^/]+)$};
    $params = { content => 'iso', filename => $filename, url => $url } if !$params;
    my $upid = $self->vm->post('/nodes/'.$self->node."/storage/$storage/download-url", $params);
    $self->vm->wait_task($self->node, $upid, 3600);
}

##########################################################################
#
# domains
#

sub _domain_name_by_vmid($self, $vmid) {
    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT name FROM domains WHERE internal_id=? AND vm='Proxmox'"
    );
    $sth->execute($vmid);
    my ($name) = $sth->fetchrow;
    $sth->finish;
    return $name;
}

sub _vmid_by_name($self, $name) {
    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT internal_id FROM domains WHERE name=? AND vm='Proxmox'"
    );
    $sth->execute($name);
    my ($vmid) = $sth->fetchrow;
    $sth->finish;
    return $vmid;
}

sub _list_vms($self) {
    return $self->_cached('vms', sub { $self->vm->get('/nodes/'.$self->node.'/qemu') });
}

sub _new_domain($self, $vmid, $node=undef, $name=undef) {
    $node = $self->node if !$node;
    $name = $self->_domain_name_by_vmid($vmid) if !$name;
    my %args;
    $args{name} = $name if $name;
    return Ravada::Domain::Proxmox->new(
        vmid => $vmid
        ,node => $node
        ,_vm => $self
        ,readonly => $self->readonly
        ,%args
    );
}

sub list_domains($self, %args) {
    my $active = delete $args{active};
    my $read_only = delete $args{read_only};
    confess "Error: unknown args ".Dumper(\%args) if keys %args;

    my @domains;
    for my $vm (@{$self->_list_vms}) {
        next if $active && ($vm->{status} or '') ne 'running';
        my $name = $self->_domain_name_by_vmid($vm->{vmid});
        $name = $vm->{name} if !$name;
        push @domains, ($self->_new_domain($vm->{vmid}, $self->node, $name));
    }
    return @domains;
}

sub search_domain($self, $name, $force=undef) {
    confess "Error: missing name" if !defined $name;

    my $vmid = $self->_vmid_by_name($name);
    if (!$vmid) {
        for my $vm (@{$self->_list_vms}) {
            next if !$vm->{name} || $vm->{name} ne $name;
            next if $self->_domain_name_by_vmid($vm->{vmid});
            $vmid = $vm->{vmid};
            last;
        }
    }
    return if !$vmid;

    # do not trust the cached list, the machine may have been migrated
    my $node = $self->_node_of_vmid($vmid);
    return if !$node || $node ne $self->node;

    my $domain = $self->_new_domain($vmid, $node, $name);
    $domain->_insert_db_extra() if $domain->is_known && !$domain->is_known_extra;
    return $domain;
}

sub _node_of_vmid($self, $vmid) {
    my $found;
    eval { $found = $self->vm->get('/nodes/'.$self->node."/qemu/$vmid/config") };
    return $self->node if $found;
    die $@ if $@ && !Ravada::Domain::Proxmox::_is_missing_error($@);

    my $resources = $self->vm->get('/cluster/resources', { type => 'vm' });
    for my $item (@$resources) {
        next if ($item->{type} or '') ne 'qemu';
        return $item->{node} if $item->{vmid} == $vmid;
    }
    return;
}

sub discover($self) {
    my @list;
    for my $vm (@{$self->_list_vms}) {
        next if $self->_domain_name_by_vmid($vm->{vmid});
        push @list, ($vm->{name} or "vm-".$vm->{vmid});
    }
    return @list;
}

sub import_domain($self, $name, $user, $spinoff=undef) {
    my $vmid;
    if ($name =~ /^\d+$/) {
        $vmid = $name;
    } else {
        my ($found) = grep { ($_->{name} or '') eq $name } @{$self->_list_vms};
        $vmid = $found->{vmid} if $found;
    }
    die "Error: virtual machine $name not found in ".$self->node."\n" if !$vmid;

    my $domain = $self->_new_domain($vmid, $self->node, $name);
    return $domain;
}

=head2 search_base

Returns a base domain wherever it is in the cluster. Templates in
shared storage can be cloned from any node.

=cut

sub search_base($self, $id_base) {
    my $base = $self->search_domain_by_id($id_base);
    return $base if $base;

    my $sth = $$CONNECTOR->dbh->prepare(
        "SELECT name, internal_id FROM domains WHERE id=?"
    );
    $sth->execute($id_base);
    my ($name, $vmid) = $sth->fetchrow;
    $sth->finish;
    return if !$name || !$vmid;

    my $node = $self->_node_of_vmid($vmid) or return;
    return $self->_new_domain($vmid, $node, $name);
}

sub _next_vmid($self) {
    my $vmid = $self->vm->get('/cluster/nextid');
    return $vmid + 0;
}

sub _ostype($iso) {
    return 'l26' if !$iso;
    my $name = ($iso->{name} or '');
    return 'win11' if $name =~ /windows.*11/i;
    return 'win10' if $name =~ /windows.*10/i;
    return 'win8' if $name =~ /windows.*8/i;
    return 'win7' if $name =~ /windows.*7/i;
    return 'wxp' if $name =~ /windows.*xp/i;
    return 'l26';
}

sub create_domain($self, %args) {
    my $name = $args{name} or confess "Error: missing name";
    my $id_owner = delete $args{id_owner} or confess "Error: id_owner is mandatory";
    my $user = Ravada::Auth::SQL->search_by_id($id_owner)
        or confess "Error: user id $id_owner doesn't exist";

    my $id_base = delete $args{id_base};
    my $id_iso = delete $args{id_iso};
    my $iso_file = delete $args{iso_file};
    my $memory = delete $args{memory};
    my $disk = delete $args{disk};
    my $volatile = delete $args{volatile};
    my $active = delete $args{active};
    my $description = delete $args{description};
    my $id = delete $args{id};
    my $storage = (delete $args{storage} or $self->default_storage_pool_name);
    my $options = (delete $args{options} or {});
    my $request = delete $args{request};
    my $config = delete $args{config};
    delete @args{qw(name remote_ip spice_password listen_ip swap alias vm start
        data enable_host_devices remove_cpu id_template)};
    confess "Error: unknown args ".Dumper(\%args) if keys %args;

    die "Error: restoring a machine from a config file is not supported in Proxmox\n"
        if $config;

    my $vmid = $self->_next_vmid;
    my $pve_name = Ravada::Domain::Proxmox::_pve_name($name);
    my $bridge = ($options->{network} or $self->_default_bridge);

    my $domain;
    if ($id_base) {
        my $base = $self->search_base($id_base)
            or confess "Error: I can't find base domain id=$id_base in the cluster";
        my %params = ( newid => $vmid, name => $pve_name );
        $params{description} = $description if $description;
        $params{target} = $self->node if $base->node ne $self->node;
        my $api = $self->vm;
        my $base_path = "/nodes/".$base->node."/qemu/".$base->vmid;
        my $upid;
        eval {
            $upid = $api->post("$base_path/clone", { %params, full => 0 });
            $api->wait_task($base->node, $upid);
        };
        if ($@) {
            die $@ if "$@" !~ /linked clone|not supported|full clone/i;
            $upid = $api->post("$base_path/clone", { %params, full => 1 });
            $api->wait_task($base->node, $upid);
        }
        $domain = $self->_new_domain($vmid, $self->node, $name);
        my %set;
        $set{memory} = int($memory / 1024) if $memory;
        $set{net0} = "virtio,bridge=$bridge" if $options->{network};
        $set{onboot} = 0;
        $domain->_set_config(%set);
    } else {
        my $iso;
        $iso = $self->_search_iso($id_iso, $iso_file) if $id_iso;
        my $cdrom = $iso_file;
        $cdrom = $self->_iso_name($iso, $request) if $iso && !$cdrom;
        $cdrom = '' if !defined $cdrom || $cdrom eq '<NONE>';

        my $mb = 512;
        $mb = int($memory / 1024) if $memory;
        $mb = 16 if $mb < 16;
        my $gb = Ravada::Domain::Proxmox::_bytes_to_gb($disk or 1024 * 1024 * 1024);

        my %params = (
            vmid => $vmid
            ,name => $pve_name
            ,memory => $mb
            ,cores => 1
            ,sockets => 1
            ,ostype => _ostype($iso)
            ,scsihw => 'virtio-scsi-pci'
            ,scsi0 => "$storage:$gb"
            ,net0 => "virtio,bridge=$bridge"
            ,vga => 'qxl'
            ,agent => 1
            ,onboot => 0
            ,boot => 'order=scsi0;ide2'
        );
        $params{description} = $description if $description;
        $params{ide2} = "$cdrom,media=cdrom" if $cdrom;
        if ($options->{uefi} || ($iso && $iso->{options} && $iso->{options}->{uefi})) {
            $params{bios} = 'ovmf';
            $params{efidisk0} = "$storage:1,efitype=4m,pre-enrolled-keys=0";
        }
        my $machine = ($options->{machine} or ($iso && $iso->{options} ? $iso->{options}->{machine} : undef));
        $params{machine} = 'q35' if $machine && $machine =~ /q35/;
        if ($iso && $iso->{options} && $iso->{options}->{hardware}) {
            my $hw = $iso->{options}->{hardware};
            $params{ostype} = $hw->{ostype} if $hw->{ostype};
        }

        my $upid = $self->vm->post('/nodes/'.$self->node.'/qemu', \%params);
        $self->vm->wait_task($self->node, $upid);
        $domain = $self->_new_domain($vmid, $self->node, $name);
    }
    delete $self->{_cache}->{vms};

    $domain->_insert_db(
        name => $name
        ,id_owner => $user->id
        ,id => $id
        ,id_vm => $self->id
        ,id_base => $id_base
        ,description => $description
    ) unless $domain->is_known();

    $domain->_refresh_config();
    $domain->list_volumes_info();
    return $domain;
}

1;
