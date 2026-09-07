package Ravada::Proxmox::API::Mock;

use warnings;
use strict;

=head1 NAME

Ravada::Proxmox::API::Mock - In memory mock of the Proxmox VE REST API

=head1 DESCRIPTION

Emulates the subset of the Proxmox API that L<Ravada::VM::Proxmox> and
L<Ravada::Domain::Proxmox> use. The cluster state is kept in a YAML file
so it survives across processes in the test suite. Select the mock by
using a url like C<mock://name>.

=cut

use Carp qw(confess);
use Data::Dumper;
use Fcntl qw(:flock);
use File::Path qw(make_path);
use Moose;
use Storable qw(dclone);
use YAML qw(Load Dump);

no warnings "experimental::signatures";
use feature qw(signatures);

extends 'Ravada::Proxmox::API';

our $DIR = "/var/tmp/rvd_proxmox_mock/".( getpwuid($>) or $> );
our $GB = 1024 * 1024 * 1024;

my %STORAGE_LINKED = map { $_ => 1 } qw(dir nfs lvmthin zfspool rbd btrfs);
my $RE_DISK = qr/^(scsi|virtio|ide|sata|efidisk|tpmstate)(\d+)$/;

sub is_mock { return 1 }

sub _sleep { }

sub _name($self) {
    my ($name) = $self->url =~ m{^mock://([^/]*)};
    $name = 'default' if !defined $name || !length $name;
    return $name;
}

sub _file($self) {
    return "$DIR/".$self->_name.".yml";
}

=head2 reset

Removes the stored state so the next request starts with a fresh cluster

=cut

sub reset($self) {
    my $file = $self->_file;
    unlink $file if -e $file;
    unlink "$file.lock" if -e "$file.lock";
}

sub _default_state {
    return {
        version => '8.2.4'
        ,nodes => {
            pve1 => { maxmem => 64 * $GB, mem => 8 * $GB, cpus => 16 , address => '192.0.2.11' }
            ,pve2 => { maxmem => 64 * $GB, mem => 4 * $GB, cpus => 16 , address => '192.0.2.12' }
        }
        ,storages => {
            'local' => { type => 'dir', content => 'iso,images,vztmpl,backup'
                , shared => 0, total => 500 * $GB, used => 50 * $GB
                , path => '/var/lib/vz', format => 'qcow2' }
            ,'local-lvm' => { type => 'lvmthin', content => 'images,rootdir'
                , shared => 0, total => 1000 * $GB, used => 100 * $GB, format => 'raw' }
            ,'shared' => { type => 'nfs', content => 'images,iso'
                , shared => 1, total => 2000 * $GB, used => 200 * $GB
                , path => '/mnt/pve/shared', format => 'qcow2' }
        }
        ,content => { 'local' => {}, 'local-lvm' => {}, 'shared' => {} }
        ,bridges => {
            pve1 => [ { iface => 'vmbr0', cidr => '192.0.2.11/24', address => '192.0.2.11' }
                     ,{ iface => 'vmbr1', cidr => '10.0.0.11/24', address => '10.0.0.11' } ]
            ,pve2 => [ { iface => 'vmbr0', cidr => '192.0.2.12/24', address => '192.0.2.12' }
                     ,{ iface => 'vmbr1', cidr => '10.0.0.12/24', address => '10.0.0.12' } ]
        }
        ,vms => {}
        ,tasks => {}
        ,task_count => 0
    };
}

sub _lock($self) {
    if (!-e $DIR) {
        my ($parent) = $DIR =~ m{(.*)/};
        if (!-e $parent) {
            make_path($parent);
            chmod 01777, $parent;
        }
        make_path($DIR);
    }
    open my $lock, ">>", $self->_file.".lock" or die "$! ".$self->_file.".lock";
    flock($lock, LOCK_EX) or die "Cannot lock $!";
    return $lock;
}

sub _load($self) {
    my $file = $self->_file;
    return _default_state() if !-e $file;
    open my $in, "<", $file or die "$! $file";
    local $/;
    my $content = <$in>;
    close $in;
    my $state = Load($content);
    return _default_state() if !$state || !ref($state);
    return $state;
}

sub _save($self, $state) {
    my $file = $self->_file;
    open my $out, ">", "$file.tmp" or die "$! $file.tmp";
    print $out Dump($state);
    close $out;
    rename "$file.tmp", $file or die "$! rename $file.tmp";
}

=head2 state

Returns a copy of the current cluster state, for tests.

=cut

sub state($self) {
    my $lock = $self->_lock();
    my $state = $self->_load();
    flock($lock, LOCK_UN);
    return $state;
}

=head2 modify_state

Runs a code block with the state so tests can tweak it.

    $api->modify_state(sub { my $state = shift; $state->{vms}->{100}->{status}='stopped' });

=cut

sub modify_state($self, $code) {
    my $lock = $self->_lock();
    my $state = $self->_load();
    $code->($state);
    $self->_save($state);
    flock($lock, LOCK_UN);
}

sub request($self, $method, $path, $params = {}) {
    $path = "/$path" if $path !~ m{^/};
    $path =~ s{^/api2/json}{};
    $params = {} if !$params;

    my $lock = $self->_lock();
    my $state = $self->_load();
    my $result;
    eval {
        $result = $self->_dispatch($state, $method, $path, $params);
        $self->_save($state);
    };
    my $err = $@;
    flock($lock, LOCK_UN);
    die $err if $err;
    return $result;
}

sub _error($code, $message, $method = '', $path = '') {
    Ravada::Proxmox::API::Error->throw(
        code => $code, message => $message, method => $method, path => $path
    );
}

sub _dispatch($self, $state, $method, $path, $params) {
    my $mp = "$method $path";

    return { version => $state->{version}, release => '8.2', repoid => 'mock' }
        if $path eq '/version' && $method eq 'GET';

    if ($path eq '/cluster/nextid' && $method eq 'GET') {
        return "".$self->_next_id($state, $params->{vmid});
    }
    if ($path eq '/cluster/resources' && $method eq 'GET') {
        return $self->_cluster_resources($state, $params);
    }
    if ($path eq '/nodes' && $method eq 'GET') {
        return [ map { $self->_node_info($state, $_) } sort keys %{$state->{nodes}} ];
    }

    my ($node, $rest) = $path =~ m{^/nodes/([^/]+)(/.*)?$};
    _error(501, "Not implemented in mock: $mp", $method, $path) if !$node;

    _error(596, "hostname lookup '$node' failed - failed to get address info for: $node", $method, $path)
        if !exists $state->{nodes}->{$node};

    $rest = '' if !defined $rest;

    return $self->_node_info($state, $node) if $rest eq '' || $rest eq '/status';
    return { version => $state->{version} } if $rest eq '/version';

    if ($rest eq '/network') {
        my @list = map { { %$_, type => 'bridge', active => 1, autostart => 1 } }
            @{$state->{bridges}->{$node}};
        return \@list;
    }
    if ($rest eq '/capabilities/qemu/machines') {
        return [
            { id => 'pc', type => 'i440fx', version => '8.2' }
            ,{ id => 'pc-i440fx-8.2', type => 'i440fx', version => '8.2' }
            ,{ id => 'q35', type => 'q35', version => '8.2' }
            ,{ id => 'pc-q35-8.2', type => 'q35', version => '8.2' }
        ];
    }
    if ($rest eq '/capabilities/qemu/cpu') {
        return [ map { { name => $_, vendor => 'default', custom => 0 } }
            qw(host kvm64 qemu64 x86-64-v2-AES x86-64-v3 max) ];
    }
    return [] if $rest =~ m{^/hardware/(pci|usb)$};

    if ($rest =~ m{^/tasks/([^/]+)/(status|log)$}) {
        my $task = $state->{tasks}->{$1}
            or _error(500, "no such task '$1'", $method, $path);
        return $task->{log} if $2 eq 'log';
        return { %$task, log => undef, upid => $1, node => $node };
    }

    if ($rest =~ m{^/storage(/.*)?$}) {
        return $self->_dispatch_storage($state, $node, $method, ($1 or ''), $params, $path);
    }
    if ($rest =~ m{^/qemu(/.*)?$}) {
        return $self->_dispatch_qemu($state, $node, $method, ($1 or ''), $params, $path);
    }

    _error(501, "Not implemented in mock: $mp", $method, $path);
}

##########################################################################
# cluster & nodes

sub _next_id($self, $state, $wanted = undef) {
    if ($wanted) {
        _error(400, "VM $wanted already exists", 'GET', '/cluster/nextid')
        if exists $state->{vms}->{$wanted};
        return $wanted;
    }
    my $id = 100;
    for my $vmid (keys %{$state->{vms}}) {
        $id = $vmid + 1 if $vmid >= $id;
    }
    return $id;
}

sub _node_info($self, $state, $node) {
    my $info = $state->{nodes}->{$node};
    my $used = $info->{mem};
    for my $vm (values %{$state->{vms}}) {
        next if $vm->{node} ne $node || $vm->{status} ne 'running';
        $used += ($vm->{config}->{memory} or 512) * 1024 * 1024;
    }
    return {
        node => $node
        ,status => 'online'
        ,memory => { total => $info->{maxmem}, used => $used
            , free => $info->{maxmem} - $used }
        ,maxmem => $info->{maxmem}
        ,mem => $used
        ,cpuinfo => { cpus => $info->{cpus}, model => 'Mock CPU' }
        ,maxcpu => $info->{cpus}
        ,cpu => 0.1
        ,uptime => 3600
        ,pveversion => 'pve-manager/'.$state->{version}
        ,kversion => 'Linux mock'
    };
}

sub _cluster_resources($self, $state, $params) {
    my @list;
    my $type = ($params->{type} or '');
    if (!$type || $type eq 'vm') {
        for my $vmid (sort { $a <=> $b } keys %{$state->{vms}}) {
            my $vm = $state->{vms}->{$vmid};
            push @list, {
                id => "qemu/$vmid", type => 'qemu', vmid => $vmid+0
                , node => $vm->{node}, name => $vm->{config}->{name}
                , status => $vm->{status}, template => $vm->{template}
                , maxmem => ($vm->{config}->{memory} or 512) * 1024 * 1024
                , maxcpu => ($vm->{config}->{cores} or 1)
            };
        }
    }
    if (!$type || $type eq 'node') {
        push @list, map { { id => "node/$_", type => 'node', node => $_ , status => 'online' } }
            sort keys %{$state->{nodes}};
    }
    if (!$type || $type eq 'storage') {
        for my $node (sort keys %{$state->{nodes}}) {
            for my $sid (sort keys %{$state->{storages}}) {
                push @list, { id => "storage/$node/$sid", type => 'storage'
                    , node => $node, storage => $sid, status => 'available'
                    , shared => $state->{storages}->{$sid}->{shared} };
            }
        }
    }
    return \@list;
}

##########################################################################
# storage

sub _storage_used($self, $state, $sid) {
    my $used = $state->{storages}->{$sid}->{used};
    for my $vol (values %{$state->{content}->{$sid}}) {
        $used += ($vol->{size} or 0);
    }
    return $used;
}

sub _storage_info($self, $state, $node, $sid) {
    my $storage = $state->{storages}->{$sid};
    my $used = $self->_storage_used($state, $sid);
    return {
        storage => $sid
        ,type => $storage->{type}
        ,content => $storage->{content}
        ,shared => $storage->{shared}
        ,active => 1
        ,enabled => 1
        ,total => $storage->{total}
        ,used => $used
        ,avail => $storage->{total} - $used
        ,used_fraction => $used / $storage->{total}
    };
}

sub _dispatch_storage($self, $state, $node, $method, $rest, $params, $path) {
    if ($rest eq '') {
        my @list;
        for my $sid (sort keys %{$state->{storages}}) {
            my $info = $self->_storage_info($state, $node, $sid);
            next if $params->{content}
                && $info->{content} !~ /(^|,)$params->{content}(,|$)/;
            push @list, ($info);
        }
        return \@list;
    }
    my ($sid, $rest2) = $rest =~ m{^/([^/]+)(/.*)?$};
    my $storage = $state->{storages}->{$sid}
        or _error(500, "storage '$sid' does not exist", $method, $path);
    $rest2 = '' if !defined $rest2;

    return $self->_storage_info($state, $node, $sid) if $rest2 eq '' || $rest2 eq '/status';

    if ($rest2 eq '/content' && $method eq 'GET') {
        my @list;
        for my $volid (sort keys %{$state->{content}->{$sid}}) {
            my $vol = $state->{content}->{$sid}->{$volid};
            next if $params->{content} && $vol->{content} ne $params->{content};
            next if $params->{vmid} && (!$vol->{vmid} || $vol->{vmid} != $params->{vmid});
            push @list, { %$vol, volid => $volid };
        }
        return \@list;
    }
    if ($rest2 =~ m{^/content/(.+)$}) {
        my $volid = $1;
        my $vol = $state->{content}->{$sid}->{$volid};
        _error(500, "volume '$volid' does not exist", $method, $path) if !$vol;
        return { %$vol, volid => $volid } if $method eq 'GET';
        if ($method eq 'DELETE') {
            $self->_check_volume_unused($state, $volid, $method, $path);
            delete $state->{content}->{$sid}->{$volid};
            return $self->_new_task($state, $node, 'imgdel', $vol->{vmid});
        }
    }
    if ($rest2 eq '/download-url' && $method eq 'POST') {
        my $content = ($params->{content} or 'iso');
        _error(400, "storage '$sid' does not support content type '$content'", $method, $path)
            if $storage->{content} !~ /(^|,)$content(,|$)/;
        my $filename = $params->{filename}
            or _error(400, "missing filename", $method, $path);
        _error(400, "missing url", $method, $path) if !$params->{url};
        my $volid = "$sid:$content/$filename";
        $state->{content}->{$sid}->{$volid} = {
            content => $content, format => 'iso', size => 150 * 1024 * 1024
            ,url => $params->{url}
        };
        return $self->_new_task($state, $node, 'download', undef);
    }
    _error(501, "Not implemented in mock: $method $path", $method, $path);
}

sub _check_volume_unused($self, $state, $volid, $method, $path) {
    for my $vm (values %{$state->{vms}}) {
        for my $key (keys %{$vm->{config}}) {
            next if $key !~ $RE_DISK && $key !~ /^unused\d+$/;
            my $drive = Ravada::Proxmox::API::parse_key_value($vm->{config}->{$key});
            _error(500, "volume '$volid' is used by VM $vm->{vmid}", $method, $path)
                if ($drive->{_first} or '') eq $volid;
        }
    }
    my ($sid, $vmid, $name) = $volid =~ m{^([^:]+):(\d+)/(base-\d+-[^/]+)$};
    if ($name) {
        for my $other (keys %{$state->{content}->{$sid}}) {
            _error(500, "base volume '$volid' is still in use by linked clone '$other'", $method, $path)
                if $other =~ m{^\Q$sid:$vmid/$name\E/\d+/};
        }
    }
}

sub _alloc_disk($self, $state, $sid, $vmid, $size, $format = undef) {
    my $storage = $state->{storages}->{$sid}
        or _error(500, "storage '$sid' does not exist");
    _error(500, "storage '$sid' does not support VM images")
        if $storage->{content} !~ /(^|,)images(,|$)/;

    $format = $storage->{format} if !$format;
    my $n = 0;
    my $volid;
    for (;;) {
        my $name = "vm-$vmid-disk-$n";
        $name .= ".$format" if $storage->{type} eq 'dir' || $storage->{type} eq 'nfs';
        $volid = "$sid:$vmid/$name";
        $volid = "$sid:$name" if $storage->{type} eq 'lvmthin' || $storage->{type} eq 'zfspool';
        last if !exists $state->{content}->{$sid}->{$volid};
        $n++;
    }
    $state->{content}->{$sid}->{$volid} = {
        content => 'images', format => $format, size => $size, vmid => $vmid+0
    };
    return $volid;
}

sub _free_disk($self, $state, $volid) {
    my ($sid) = $volid =~ /^([^:]+):/;
    return if !$sid || !exists $state->{content}->{$sid};
    delete $state->{content}->{$sid}->{$volid};
}

sub _size_to_bytes($size) {
    return 0 if !defined $size;
    my ($n, $unit) = $size =~ /^([\d\.]+)([KMGT])?$/;
    confess "Invalid size '$size'" if !defined $n;
    my %mult = ( K => 1024, M => 1024**2, G => 1024**3, T => 1024**4 );
    return int($n * ($unit ? $mult{$unit} : 1));
}

sub _bytes_to_size($bytes) {
    for my $unit ( [ T => 1024**4 ], [ G => 1024**3 ], [ M => 1024**2 ], [ K => 1024 ] ) {
        my ($name, $mult) = @$unit;
        if ($bytes >= $mult && $bytes % $mult == 0) {
            return int($bytes / $mult).$name;
        }
    }
    return $bytes;
}

##########################################################################
# qemu

sub _vm($self, $state, $node, $vmid, $method, $path) {
    my $vm = $state->{vms}->{$vmid};
    _error(500, "Configuration file 'nodes/$node/qemu-server/$vmid.conf' does not exist"
        , $method, $path) if !$vm || $vm->{node} ne $node;
    return $vm;
}

sub _new_task($self, $state, $node, $type, $vmid, $exit = 'OK') {
    my $n = ++$state->{task_count};
    my $upid = sprintf("UPID:%s:%08X:%08X:%08X:%s:%s:root\@pam:"
        , $node, $$, $n, time, $type, (defined $vmid ? $vmid : ''));
    $state->{tasks}->{$upid} = {
        status => 'stopped', exitstatus => $exit, type => $type
        ,starttime => time, endtime => time, user => 'root@pam', id => $vmid
        ,log => [ { n => 1, t => "TASK $exit" } ]
    };
    return $upid;
}

sub _new_mac {
    return sprintf("BC:24:11:%02X:%02X:%02X", int(rand(255)), int(rand(255)), int(rand(255)));
}

sub _dispatch_qemu($self, $state, $node, $method, $rest, $params, $path) {
    if ($rest eq '') {
        if ($method eq 'GET') {
            my @list;
            for my $vmid (sort { $a <=> $b } keys %{$state->{vms}}) {
                my $vm = $state->{vms}->{$vmid};
                next if $vm->{node} ne $node;
                push @list, ($self->_vm_status($vm));
            }
            return \@list;
        }
        return $self->_create_vm($state, $node, $params, $method, $path) if $method eq 'POST';
    }
    my ($vmid, $rest2) = $rest =~ m{^/(\d+)(/.*)?$};
    _error(400, "invalid vmid in $path", $method, $path) if !$vmid;
    $rest2 = '' if !defined $rest2;

    my $vm = $self->_vm($state, $node, $vmid, $method, $path);

    if ($rest2 eq '') {
        return $self->_vm_status($vm) if $method eq 'GET';
        return $self->_destroy_vm($state, $vm, $params, $method, $path) if $method eq 'DELETE';
    }
    if ($rest2 eq '/config') {
        return $self->_get_config($vm) if $method eq 'GET';
        $self->_update_config($state, $vm, $params, $method, $path);
        return if $method eq 'PUT';
        return $self->_new_task($state, $node, 'qmconfig', $vmid);
    }
    return $self->_vm_status($vm, 1) if $rest2 eq '/status/current';

    if ($rest2 =~ m{^/status/(start|stop|shutdown|reboot|reset|suspend|resume)$}
        && $method eq 'POST') {
        return $self->_change_status($state, $vm, $1, $params, $method, $path);
    }
    return $self->_clone_vm($state, $vm, $params, $method, $path)
        if $rest2 eq '/clone' && $method eq 'POST';
    return $self->_template_vm($state, $vm, $params, $method, $path)
        if $rest2 eq '/template' && $method eq 'POST';
    return $self->_migrate_vm($state, $vm, $params, $method, $path)
        if $rest2 eq '/migrate' && $method eq 'POST';
    return $self->_resize_disk($state, $vm, $params, $method, $path)
        if $rest2 eq '/resize' && ($method eq 'PUT' || $method eq 'POST');
    return $self->_spiceproxy($state, $vm, $params, $method, $path)
        if $rest2 eq '/spiceproxy' && $method eq 'POST';
    return $self->_vncproxy($state, $vm, $params, $method, $path)
        if $rest2 eq '/vncproxy' && $method eq 'POST';
    if ($rest2 =~ m{^/agent(/(.*))?$}) {
        return $self->_agent($state, $vm, ($2 or $params->{command} or ''), $params, $method, $path);
    }
    if ($rest2 eq '/snapshot') {
        $vm->{snapshots} = {} if !$vm->{snapshots};
        if ($method eq 'GET') {
            my @list = map { { name => $_, %{$vm->{snapshots}->{$_}} } } sort keys %{$vm->{snapshots}};
            push @list, { name => 'current', digest => 'x', running => ($vm->{status} eq 'running' ? 1 : 0) };
            return \@list;
        }
        my $name = $params->{snapname} or _error(400, "missing snapname", $method, $path);
        $vm->{snapshots}->{$name} = { snaptime => time, description => ($params->{description} or '')
            , vmstate => ($params->{vmstate} or 0) };
        return $self->_new_task($state, $node, 'qmsnapshot', $vmid);
    }
    if ($rest2 =~ m{^/snapshot/([^/]+)$} && $method eq 'DELETE') {
        delete $vm->{snapshots}->{$1};
        return $self->_new_task($state, $node, 'qmdelsnapshot', $vmid);
    }

    _error(501, "Not implemented in mock: $method $path", $method, $path);
}

sub _vm_status($self, $vm, $full = 0) {
    my $config = $vm->{config};
    my $status = {
        vmid => $vm->{vmid}+0
        ,name => $config->{name}
        ,status => $vm->{status}
        ,template => ($vm->{template} or 0)
        ,maxmem => ($config->{memory} or 512) * 1024 * 1024
        ,mem => ($vm->{status} eq 'running' ? ($config->{memory} or 512) * 1024 * 1024 / 2 : 0)
        ,cpus => ($config->{cores} or 1) * ($config->{sockets} or 1)
        ,cpu => ($vm->{status} eq 'running' ? 0.05 : 0)
        ,uptime => ($vm->{status} eq 'running' ? time - ($vm->{start_time} or time) : 0)
        ,maxdisk => 0
        ,disk => 0
        ,netin => 0
        ,netout => 0
    };
    $status->{lock} = $vm->{lock} if $vm->{lock};
    if ($full) {
        $status->{qmpstatus} = $vm->{qmpstatus};
        $status->{agent} = ($config->{agent} ? 1 : 0);
        $status->{spice} = 1 if ($config->{vga} or '') =~ /qxl|virtio/;
        $status->{ha} = { managed => 0 };
    }
    return $status;
}

sub _get_config($self, $vm) {
    my %config = %{$vm->{config}};
    $config{digest} = sprintf("%040x", $vm->{digest} || 0);
    $config{template} = 1 if $vm->{template};
    return \%config;
}

sub _parse_size_gb($value) {
    my ($n) = $value =~ /^([\d\.]+)$/;
    return if !defined $n;
    return int($n * $GB);
}

sub _update_config($self, $state, $vm, $params, $method, $path) {
    my %ignore = map { $_ => 1 } qw(digest vmid node force skiplock background_delay revert);

    if ($params->{delete}) {
        for my $key (split /,/, $params->{delete}) {
            if ($key eq 'template') {
                $vm->{template} = 0;
                next;
            }
            next if !exists $vm->{config}->{$key};
            if ($key =~ $RE_DISK) {
                my $drive = Ravada::Proxmox::API::parse_key_value($vm->{config}->{$key});
                my $volid = $drive->{_first};
                if ($volid && $volid ne 'none' && ($drive->{media} or '') ne 'cdrom') {
                    my $n = 0;
                    $n++ while exists $vm->{config}->{"unused$n"};
                    $vm->{config}->{"unused$n"} = $volid;
                }
            } elsif ($key =~ /^unused\d+$/) {
                $self->_free_disk($state, $vm->{config}->{$key});
            }
            delete $vm->{config}->{$key};
        }
    }
    for my $key (sort keys %$params) {
        next if $key eq 'delete' || $ignore{$key};
        my $value = $params->{$key};
        if ($key =~ $RE_DISK) {
            my $drive = Ravada::Proxmox::API::parse_key_value($value);
            my $file = $drive->{_first};
            _error(400, "invalid drive specification '$value'", $method, $path) if !defined $file;
            if ($file =~ /^([^:]+):([\d\.]+)$/) {
                my ($sid, $size) = ($1, _parse_size_gb($2));
                _error(400, "invalid size '$2'", $method, $path) if !defined $size;
                my $volid = $self->_alloc_disk($state, $sid, $vm->{vmid}, $size, $drive->{format});
                $drive->{_first} = $volid;
                $drive->{size} = _bytes_to_size($size);
                delete $drive->{format};
                $value = Ravada::Proxmox::API::format_key_value($drive);
            } elsif ($file eq 'none') {
                # empty cdrom
            } elsif (($drive->{media} or '') eq 'cdrom') {
                my ($sid) = $file =~ /^([^:]+):/;
                _error(500, "volume '$file' does not exist", $method, $path)
                    if !$sid || !exists $state->{content}->{$sid}->{$file};
            } else {
                my ($sid) = $file =~ /^([^:]+):/;
                _error(500, "volume '$file' does not exist", $method, $path)
                    if !$sid || !exists $state->{content}->{$sid}->{$file};
                my $vol = $state->{content}->{$sid}->{$file};
                $drive->{size} = _bytes_to_size($vol->{size}) if !$drive->{size};
                $value = Ravada::Proxmox::API::format_key_value($drive);
                for my $n (0 .. 20) {
                    delete $vm->{config}->{"unused$n"}
                        if ($vm->{config}->{"unused$n"} or '') eq $file;
                }
            }
        } elsif ($key =~ /^net\d+$/) {
            my $net = Ravada::Proxmox::API::parse_key_value($value);
            my $model = $net->{_first};
            if ($model && $model =~ /^([^=]+)=(.*)$/) {
                delete $net->{_first};
                $net->{$1} = $2;
            } elsif ($model && $model !~ /=/) {
                delete $net->{_first};
                $net->{$model} = _new_mac();
            }
            my ($model_key) = grep { /^(virtio|e1000|e1000e|vmxnet3|rtl8139)$/ } keys %$net;
            _error(400, "invalid network model in '$value'", $method, $path) if !$model_key;
            my $mac = delete $net->{$model_key};
            $value = "$model_key=$mac,".Ravada::Proxmox::API::format_key_value($net);
            $value =~ s/,$//;
        } elsif ($key eq 'name') {
            _error(400, "invalid format - value does not look like a valid DNS name", $method, $path)
                if $value !~ /^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?$/;
        } elsif ($key eq 'template') {
            $vm->{template} = ($value ? 1 : 0);
            next;
        }
        $vm->{config}->{$key} = $value;
    }
    $vm->{digest}++;
}

sub _create_vm($self, $state, $node, $params, $method, $path) {
    my $vmid = $params->{vmid} or _error(400, "missing vmid", $method, $path);
    _error(500, "unable to create VM $vmid: config file already exists", $method, $path)
        if exists $state->{vms}->{$vmid};
    my $vm = {
        vmid => $vmid+0, node => $node, status => 'stopped', qmpstatus => 'stopped'
        ,template => 0, config => {}, digest => 1
    };
    my %params = %$params;
    delete $params{vmid};
    $params{name} = "VM$vmid" if !$params{name};
    $state->{vms}->{$vmid} = $vm;
    $self->_update_config($state, $vm, \%params, $method, $path);
    $vm->{config}->{smbios1} = "uuid=".join("-", map { sprintf("%04x", rand(0xffff)) } 1 .. 4);
    return $self->_new_task($state, $node, 'qmcreate', $vmid);
}

sub _vm_disks($self, $vm) {
    my @disks;
    for my $key (sort keys %{$vm->{config}}) {
        next if $key !~ $RE_DISK && $key !~ /^unused\d+$/;
        my $drive = Ravada::Proxmox::API::parse_key_value($vm->{config}->{$key});
        my $volid = $drive->{_first};
        next if !$volid || $volid eq 'none' || ($drive->{media} or '') eq 'cdrom';
        push @disks, ([ $key, $volid, $drive ]);
    }
    return @disks;
}

sub _destroy_vm($self, $state, $vm, $params, $method, $path) {
    _error(500, "VM $vm->{vmid} is running - destroy failed", $method, $path)
        if $vm->{status} eq 'running';
    for my $disk ($self->_vm_disks($vm)) {
        my ($key, $volid) = @$disk;
        $self->_check_volume_unused_by_others($state, $vm, $volid, $method, $path);
    }
    for my $disk ($self->_vm_disks($vm)) {
        $self->_free_disk($state, $disk->[1]);
    }
    if ($params->{'destroy-unreferenced-disks'}) {
        for my $sid (keys %{$state->{content}}) {
            for my $volid (keys %{$state->{content}->{$sid}}) {
                my $vol = $state->{content}->{$sid}->{$volid};
                delete $state->{content}->{$sid}->{$volid}
                    if $vol->{vmid} && $vol->{vmid} == $vm->{vmid} && $vol->{content} eq 'images';
            }
        }
    }
    delete $state->{vms}->{$vm->{vmid}};
    return $self->_new_task($state, $vm->{node}, 'qmdestroy', $vm->{vmid});
}

sub _check_volume_unused_by_others($self, $state, $vm, $volid, $method, $path) {
    my ($sid, $vmid, $name) = $volid =~ m{^([^:]+):(\d+)/(base-\d+-[^/]+)$};
    return if !$name;
    for my $other (keys %{$state->{content}->{$sid}}) {
        _error(500, "base volume '$volid' is still in use by linked clone '$other'", $method, $path)
            if $other =~ m{^\Q$sid:$vmid/$name\E/\d+/};
    }
}

sub _change_status($self, $state, $vm, $action, $params, $method, $path) {
    my $vmid = $vm->{vmid};
    my $running = ($vm->{status} eq 'running');
    if ($action eq 'start') {
        _error(500, "you can't start a vm if it's a template", $method, $path) if $vm->{template};
        _error(500, "VM $vmid already running", $method, $path) if $running;
        $vm->{status} = 'running';
        $vm->{qmpstatus} = 'running';
        $vm->{start_time} = time;
        if (($vm->{lock} or '') eq 'suspended') {
            delete $vm->{lock};
            my $vmstate = delete $vm->{config}->{vmstate};
            $self->_free_disk($state, $vmstate) if $vmstate;
        }
        return $self->_new_task($state, $vm->{node}, 'qmstart', $vmid);
    }
    if ($action eq 'stop' ) {
        $vm->{status} = 'stopped';
        $vm->{qmpstatus} = 'stopped';
        return $self->_new_task($state, $vm->{node}, 'qmstop', $vmid);
    }
    if ($action eq 'shutdown') {
        _error(500, "VM $vmid not running", $method, $path) if !$running;
        if ($vm->{no_acpi}) {
            _error(500, "VM quit/powerdown failed - got timeout", $method, $path)
                if $params->{forceStop} || !$params->{timeout};
            return $self->_new_task($state, $vm->{node}, 'qmshutdown', $vmid, 'VM quit/powerdown failed - got timeout');
        }
        $vm->{status} = 'stopped';
        $vm->{qmpstatus} = 'stopped';
        return $self->_new_task($state, $vm->{node}, 'qmshutdown', $vmid);
    }
    if ($action eq 'reboot' || $action eq 'reset') {
        _error(500, "VM $vmid not running", $method, $path) if !$running;
        $vm->{start_time} = time;
        $vm->{qmpstatus} = 'running';
        return $self->_new_task($state, $vm->{node}, 'qm'.$action, $vmid);
    }
    if ($action eq 'suspend') {
        _error(500, "VM $vmid not running", $method, $path) if !$running;
        if ($params->{todisk}) {
            $vm->{status} = 'stopped';
            $vm->{qmpstatus} = 'stopped';
            $vm->{lock} = 'suspended';
            my ($sid) = 'local';
            my $volid = "$sid:$vmid/vm-$vmid-state-suspend-".time.".raw";
            $state->{content}->{$sid}->{$volid} = { content => 'images', format => 'raw'
                , size => ($vm->{config}->{memory} or 512) * 1024 * 1024, vmid => $vmid+0 };
            $vm->{config}->{vmstate} = $volid;
        } else {
            $vm->{qmpstatus} = 'paused';
        }
        return $self->_new_task($state, $vm->{node}, 'qmsuspend', $vmid);
    }
    if ($action eq 'resume') {
        if (($vm->{lock} or '') eq 'suspended') {
            return $self->_change_status($state, $vm, 'start', $params, $method, $path);
        }
        _error(500, "VM $vmid not running", $method, $path) if !$running;
        $vm->{qmpstatus} = 'running';
        return $self->_new_task($state, $vm->{node}, 'qmresume', $vmid);
    }
    _error(501, "unknown action $action", $method, $path);
}

sub _clone_vm($self, $state, $vm, $params, $method, $path) {
    my $newid = $params->{newid} or _error(400, "missing newid", $method, $path);
    _error(500, "unable to create VM $newid: config file already exists", $method, $path)
        if exists $state->{vms}->{$newid};
    my $target = ($params->{target} or $vm->{node});
    _error(500, "no such node '$target'", $method, $path) if !exists $state->{nodes}->{$target};

    my $full = $params->{full};
    $full = 1 if !$vm->{template};
    $full = 0 if !defined $full;

    _error(500, "VM $vm->{vmid} is running, only templates or stopped VMs can be cloned", $method, $path)
        if $vm->{status} eq 'running' && !$vm->{template};

    my $new = {
        vmid => $newid+0, node => $target, status => 'stopped', qmpstatus => 'stopped'
        ,template => 0, config => dclone($vm->{config}), digest => 1
    };
    delete $new->{config}->{vmstate};
    delete $new->{config}->{template};
    delete $new->{config}->{onboot};
    $new->{config}->{name} = ($params->{name} or "Copy-of-VM-".$vm->{config}->{name});
    $new->{config}->{description} = $params->{description} if $params->{description};
    $new->{config}->{smbios1} = "uuid=".join("-", map { sprintf("%04x", rand(0xffff)) } 1 .. 4);

    for my $key (keys %{$new->{config}}) {
        delete $new->{config}->{$key} if $key =~ /^unused\d+$/;
    }
    for my $disk ($self->_vm_disks($vm)) {
        my ($key, $volid, $drive) = @$disk;
        my ($sid) = $volid =~ /^([^:]+):/;
        my $storage = $state->{storages}->{$sid};
        my $vol = $state->{content}->{$sid}->{$volid}
            or _error(500, "volume '$volid' does not exist", $method, $path);
        my $new_volid;
        if ($full) {
            my $new_sid = ($params->{storage} or $sid);
            _error(500, "cannot clone to a different node with local storage", $method, $path)
                if $target ne $vm->{node} && !$state->{storages}->{$new_sid}->{shared};
            $new_volid = $self->_alloc_disk($state, $new_sid, $newid, $vol->{size}, $params->{format});
        } else {
            _error(500, "linked clone feature is not supported for '$volid'", $method, $path)
                if !$STORAGE_LINKED{$storage->{type}} || $volid !~ m{base-};
            _error(500, "clone to different node with local storage is not possible for linked clones", $method, $path)
                if $target ne $vm->{node} && !$storage->{shared};
            _error(500, "target storage must be the same for linked clones", $method, $path)
                if $params->{storage} && $params->{storage} ne $sid;
            my ($base_name) = $volid =~ m{/([^/]+)$};
            my $clone_name = $base_name;
            $clone_name =~ s/^base-\d+-/vm-$newid-/;
            $new_volid = "$volid/$newid/$clone_name";
            $state->{content}->{$sid}->{$new_volid} = {
                content => 'images', format => $vol->{format}, size => $vol->{size}
                , vmid => $newid+0, parent => $volid
            };
        }
        $drive->{_first} = $new_volid;
        $new->{config}->{$key} = Ravada::Proxmox::API::format_key_value($drive);
    }
    for my $key (keys %{$new->{config}}) {
        next if $key !~ /^net\d+$/;
        my $value = $new->{config}->{$key};
        $value =~ s/^(\w+)=[0-9A-F:]+/"$1="._new_mac()/ei;
        $new->{config}->{$key} = $value;
    }
    $state->{vms}->{$newid} = $new;
    return $self->_new_task($state, $vm->{node}, 'qmclone', $vm->{vmid});
}

sub _template_vm($self, $state, $vm, $params, $method, $path) {
    _error(500, "you can't convert a VM to template if VM is running", $method, $path)
        if $vm->{status} eq 'running';
    _error(500, "VM $vm->{vmid} is already a template", $method, $path) if $vm->{template};
    for my $disk ($self->_vm_disks($vm)) {
        my ($key, $volid, $drive) = @$disk;
        my ($sid, $rest) = $volid =~ /^([^:]+):(.*)$/;
        my $new_volid = $volid;
        $new_volid =~ s{vm-(\d+)-disk}{base-$1-disk};
        $state->{content}->{$sid}->{$new_volid} = delete $state->{content}->{$sid}->{$volid};
        $drive->{_first} = $new_volid;
        $vm->{config}->{$key} = Ravada::Proxmox::API::format_key_value($drive);
    }
    $vm->{template} = 1;
    $vm->{digest}++;
    return $self->_new_task($state, $vm->{node}, 'qmtemplate', $vm->{vmid});
}

sub _migrate_vm($self, $state, $vm, $params, $method, $path) {
    my $target = $params->{target} or _error(400, "missing target", $method, $path);
    _error(500, "no such node '$target'", $method, $path) if !exists $state->{nodes}->{$target};
    _error(500, "target node is the same as source", $method, $path) if $target eq $vm->{node};
    _error(500, "can't migrate running VM without --online", $method, $path)
        if $vm->{status} eq 'running' && !$params->{online};
    for my $disk ($self->_vm_disks($vm)) {
        my ($sid) = $disk->[1] =~ /^([^:]+):/;
        _error(500, "can't migrate VM with local disks without --with-local-disks", $method, $path)
            if !$state->{storages}->{$sid}->{shared} && !$params->{'with-local-disks'};
        _error(500, "can't migrate template with local disks", $method, $path)
            if !$state->{storages}->{$sid}->{shared} && $vm->{template};
    }
    my $source = $vm->{node};
    $vm->{node} = $target;
    return $self->_new_task($state, $source, 'qmigrate', $vm->{vmid});
}

sub _resize_disk($self, $state, $vm, $params, $method, $path) {
    my $key = $params->{disk} or _error(400, "missing disk", $method, $path);
    my $value = $vm->{config}->{$key}
        or _error(500, "disk '$key' does not exist", $method, $path);
    my $drive = Ravada::Proxmox::API::parse_key_value($value);
    my $volid = $drive->{_first};
    my ($sid) = $volid =~ /^([^:]+):/;
    my $vol = $state->{content}->{$sid}->{$volid};
    my $size = $params->{size} or _error(400, "missing size", $method, $path);
    my $new_size;
    if ($size =~ /^\+(.*)/) {
        $new_size = $vol->{size} + _size_to_bytes($1);
    } else {
        $new_size = _size_to_bytes($size);
    }
    _error(500, "shrinking disks is not supported", $method, $path) if $new_size < $vol->{size};
    $vol->{size} = $new_size;
    $drive->{size} = _bytes_to_size($new_size);
    $vm->{config}->{$key} = Ravada::Proxmox::API::format_key_value($drive);
    return $self->_new_task($state, $vm->{node}, 'resize', $vm->{vmid});
}

sub _spice_port($vmid) {
    return 61000 + ($vmid % 100);
}

sub _spiceproxy($self, $state, $vm, $params, $method, $path) {
    _error(500, "VM $vm->{vmid} not running", $method, $path) if $vm->{status} ne 'running';
    _error(500, "VM $vm->{vmid} has no spice display", $method, $path)
        if ($vm->{config}->{vga} or '') !~ /qxl|virtio/;
    my $proxy = ($params->{proxy} or $state->{nodes}->{$vm->{node}}->{address});
    return {
        type => 'spice'
        ,host => sprintf("pvespiceproxy:%x:%d:%s::", time, $vm->{vmid}, $vm->{node})
        ,proxy => "http://$proxy:3128"
        ,'tls-port' => _spice_port($vm->{vmid})
        ,password => "PVESPICE:".join("", map { chr(65 + int(rand(26))) } 1 .. 20)
        ,'host-subject' => "OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=$vm->{node}.mock"
        ,ca => "-----BEGIN CERTIFICATE-----\\nMOCK\\n-----END CERTIFICATE-----\\n"
        ,title => "VM $vm->{vmid} - ".$vm->{config}->{name}
        ,'delete-this-file' => 1
        ,'release-cursor' => 'Ctrl+Alt+R'
        ,'toggle-fullscreen' => 'Shift+F11'
        ,'secure-attention' => 'Ctrl+Alt+Ins'
    };
}

sub _vncproxy($self, $state, $vm, $params, $method, $path) {
    _error(500, "VM $vm->{vmid} not running", $method, $path) if $vm->{status} ne 'running';
    return {
        ticket => "PVEVNC:".join("", map { chr(65 + int(rand(26))) } 1 .. 20)
        ,port => 5900 + ($vm->{vmid} % 100)
        ,upid => $self->_new_task($state, $vm->{node}, 'vncproxy', $vm->{vmid})
        ,user => 'root@pam'
        ,cert => "MOCK"
    };
}

sub _agent($self, $state, $vm, $command, $params, $method, $path) {
    _error(500, "VM $vm->{vmid} is not running", $method, $path) if $vm->{status} ne 'running';
    _error(500, "No QEMU guest agent configured", $method, $path) if !$vm->{config}->{agent};
    if ($command eq 'network-get-interfaces') {
        my @ifaces = ( { name => 'lo', 'hardware-address' => '00:00:00:00:00:00'
            , 'ip-addresses' => [ { 'ip-address' => '127.0.0.1', 'ip-address-type' => 'ipv4', prefix => 8 } ] } );
        my $n = 0;
        for my $key (sort grep { /^net\d+$/ } keys %{$vm->{config}}) {
            my $net = Ravada::Proxmox::API::parse_key_value($vm->{config}->{$key});
            my ($mac) = grep { defined } map { $net->{$_} } qw(virtio e1000 e1000e vmxnet3 rtl8139);
            push @ifaces, {
                name => "eth$n"
                ,'hardware-address' => lc($mac or '00:00:00:00:00:00')
                ,'ip-addresses' => [
                    { 'ip-address' => '198.51.100.'.(($vm->{vmid} + $n) % 250 + 2)
                        , 'ip-address-type' => 'ipv4', prefix => 24 }
                    ,{ 'ip-address' => 'fe80::1', 'ip-address-type' => 'ipv6', prefix => 64 }
                ]
            };
            $n++;
        }
        return { result => \@ifaces };
    }
    return { result => { pid => 1234 } } if $command eq 'exec';
    return { result => {} } if $command eq 'ping';
    return { result => { 'exited' => 1, 'exitcode' => 0, 'out-data' => '' } } if $command eq 'exec-status';
    _error(501, "agent command '$command' not implemented in mock", $method, $path);
}

1;
