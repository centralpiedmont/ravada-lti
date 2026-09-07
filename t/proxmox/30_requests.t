use warnings;
use strict;
no warnings "experimental::signatures";
use feature qw(signatures);

use Data::Dumper;
use JSON::XS qw(decode_json);
use Test::More;

use lib 't/lib';
use Test::Ravada;

use Ravada::Proxmox::API;

$Data::Dumper::Sortkeys = 1;

init('t/etc/ravada_proxmox.conf');
Ravada::Proxmox::API->new_client(url => 'mock://test')->reset();

my $USER = create_user("user_proxmox_$$", "pass");

my $rvd = rvd_back();
my $vm = $rvd->search_vm('Proxmox');
ok($vm, "Proxmox virtual manager") or BAIL_OUT("No Proxmox VM");

######################################################################
sub test_front_vm_types {
    my $front = rvd_front();
    my $types = $front->list_vm_types();
    ok(grep({ $_ eq 'Proxmox' } @$types), "Proxmox in front vm types ".Dumper($types));

    my @vms = $front->list_vms();
    my ($node1) = grep { $_->{hostname} eq 'localhost' } @vms;
    ok($node1, "primary node listed") or diag(Dumper(\@vms));
    is($node1->{type}, 'Proxmox') if $node1;
    my ($node2) = grep { $_->{hostname} eq 'pve2' } @vms;
    ok($node2, "second node listed from config") or diag(Dumper(\@vms));
}

sub test_list_isos {
    my $req = Ravada::Request->list_isos(vm_type => 'Proxmox');
    rvd_back->_process_all_requests_dont_fork();
    is($req->status, 'done');
    is($req->error, '');
}

sub test_machine_types {
    my $req = Ravada::Request->list_machine_types(uid => user_admin->id, id_vm => $vm->id);
    rvd_back->_process_all_requests_dont_fork();
    is($req->status, 'done');
    is($req->error, '') or return;
    my $out = decode_json($req->output);
    ok($out->{x86_64}, "machine types") or diag(Dumper($out));

    my @models = $vm->get_cpu_model_names();
    ok(scalar(@models), "cpu models");
}

sub test_storage_pools {
    my $req = Ravada::Request->list_storage_pools(uid => user_admin->id, id_vm => $vm->id, data => 1);
    rvd_back->_process_all_requests_dont_fork();
    is($req->error, '');
    my $out = decode_json($req->output);
    my ($local) = grep { $_->{name} eq 'local' } @$out;
    ok($local, "local storage") or diag(Dumper($out));
    ok($local->{available} > 0, "available space") if $local;
}

sub test_create_request {
    my $name = new_domain_name();
    my $req = Ravada::Request->create_domain(
        name => $name
        ,vm => 'Proxmox'
        ,id_iso => search_id_iso('Alpine')
        ,id_owner => user_admin->id
        ,disk => 2 * 1024 * 1024 * 1024
        ,memory => 1024 * 1024
        ,swap => 512 * 1024 * 1024
        ,data => 1024 * 1024 * 1024
    );
    wait_request(debug => 0);
    is($req->status, 'done');
    is($req->error, '') or return;

    my $domain = rvd_back->search_domain($name);
    ok($domain, "domain $name created") or return;
    isa_ok($domain, 'Ravada::Domain::Proxmox');
    ok($domain->vmid >= 100, "vmid ".$domain->vmid);
    is($domain->internal_id, $domain->vmid);

    my @disks = $domain->list_volumes_info(device => 'disk');
    is(scalar(@disks), 3, "system, swap and data disks") or diag(Dumper([map { $_->info } @disks]));
    my ($sys) = grep { $_->info->{target} eq 'scsi0' } @disks;
    is($sys->capacity, 2 * 1024 * 1024 * 1024, "system disk size") if $sys;

    my $info = $domain->info(user_admin);
    is($info->{max_mem}, 1024 * 1024, "max_mem in KB");
    is($info->{memory}, 1024 * 1024, "memory in KB");
    is(scalar(@{$info->{hardware}->{disk}}), 4, "3 disks + cdrom") or diag(Dumper($info->{hardware}->{disk}));
    is(scalar(@{$info->{hardware}->{network}}), 1, "one network") or diag(Dumper($info->{hardware}->{network}));
    is($info->{hardware}->{network}->[0]->{bridge}, 'vmbr0');
    is(scalar(@{$info->{hardware}->{display}}), 1, "one display") or diag(Dumper($info->{hardware}->{display}));
    is($info->{hardware}->{display}->[0]->{driver}, 'spice');

    # front end object
    my $front = Ravada::Front::Domain->open($domain->id);
    isa_ok($front, 'Ravada::Front::Domain::Proxmox');
    is($front->vmid, $domain->vmid, "vmid in front");
    is($front->node, 'pve1', "node in front");
    my @front_nets = $front->_get_controller_network();
    is($front_nets[0]->{bridge}, 'vmbr0', "front network from cached config") or diag(Dumper(\@front_nets));

    return $domain;
}

sub test_start_stop($domain) {
    my $req = Ravada::Request->start_domain(uid => user_admin->id, id_domain => $domain->id
        , remote_ip => '10.1.1.1');
    wait_request();
    is($req->error, '');
    ok($domain->is_active, "active after start request");

    my $front = Ravada::Front::Domain->open($domain->id);
    ok($front->is_active, "front sees active");
    my @displays = $front->_get_controller_display();
    is(scalar(@displays), 1) or diag(Dumper(\@displays));
    is($displays[0]->{driver}, 'spice');
    is($displays[0]->{is_active}, 1, "display active");
    ok($displays[0]->{port}, "display port") or diag(Dumper(\@displays));
    is($displays[0]->{file_extension}, 'vv');

    my $vv = $front->_display_file_spice($displays[0]);
    like($vv, qr/^\[virt-viewer\]/, "front .vv file");
    like($vv, qr/^password=PVESPICE/m, "ticket in file");
    like($vv, qr/^proxy=http:/m, "proxy in file");
    like($vv, qr/^tls-port=\d+/m, "tls port in file");

    my $ip = $domain->ip;
    like($ip, qr/^\d+\.\d+\.\d+\.\d+$/, "ip from guest agent");
    is($domain->info(user_admin)->{ip}, $ip, "ip in info");

    $req = Ravada::Request->pause_domain(uid => user_admin->id, name => $domain->name);
    wait_request();
    is($req->error, '');
    ok($domain->is_paused, "paused");
    ok($domain->is_active, "paused is still active");

    $req = Ravada::Request->resume_domain(uid => user_admin->id, name => $domain->name, remote_ip => '10.1.1.1');
    wait_request();
    is($req->error, '');
    ok(!$domain->is_paused, "resumed");

    $req = Ravada::Request->hibernate(uid => user_admin->id, id_domain => $domain->id);
    wait_request();
    is($req->error, '');
    ok(!$domain->is_active, "hibernated is not active");
    ok($domain->is_hibernated, "hibernated");
    is($domain->_data('status'), 'hibernated');

    $req = Ravada::Request->start_domain(uid => user_admin->id, id_domain => $domain->id);
    wait_request();
    is($req->error, '');
    ok($domain->is_active, "active after hibernate");
    ok(!$domain->is_hibernated, "not hibernated any more");

    $req = Ravada::Request->shutdown_domain(uid => user_admin->id, id_domain => $domain->id, timeout => 5);
    wait_request();
    is($req->error, '');
    ok(!$domain->is_active, "shut down");
    is($domain->_data('status'), 'shutdown');

    @displays = Ravada::Front::Domain->open($domain->id)->_get_controller_display();
    is($displays[0]->{is_active}, 0, "display down");
}

sub _reopen($domain) {
    return Ravada::Domain->open($domain->id);
}

sub test_hardware($domain) {
    my $req = Ravada::Request->change_hardware(uid => user_admin->id, id_domain => $domain->id
        , hardware => 'memory', data => { max_mem => 2 * 1024 * 1024, memory => 1024 * 1024 });
    wait_request();
    is($req->error, '');
    is($domain->pve_config(1)->{memory}, 2048, "memory in MB") or diag(Dumper($domain->pve_config));
    is($domain->pve_config->{balloon}, 1024, "balloon in MB");
    is($domain->get_info->{max_mem}, 2 * 1024 * 1024);

    $req = Ravada::Request->change_hardware(uid => user_admin->id, id_domain => $domain->id
        , hardware => 'vcpus', data => { n_virt_cpu => 2, max_virt_cpu => 4 });
    wait_request();
    is($req->error, '');
    is($domain->pve_config(1)->{cores}, 4, "cores");
    is($domain->pve_config->{vcpus}, 2, "vcpus");
    is($domain->get_info->{n_virt_cpu}, 2);
    is($domain->get_info->{max_virt_cpu}, 4);

    $req = Ravada::Request->add_hardware(uid => user_admin->id, id_domain => $domain->id
        , name => 'network', data => { driver => 'e1000', bridge => 'vmbr1' });
    wait_request();
    is($req->error, '');
    my @nets = _reopen($domain)->_get_controller_network();
    is(scalar(@nets), 2, "two networks") or diag(Dumper(\@nets));
    is($nets[1]->{driver}, 'e1000') if $nets[1];
    is($nets[1]->{bridge}, 'vmbr1') if $nets[1];

    $req = Ravada::Request->change_hardware(uid => user_admin->id, id_domain => $domain->id
        , hardware => 'network', index => 1, data => { driver => 'virtio', bridge => 'vmbr0' });
    wait_request();
    is($req->error, '');
    @nets = _reopen($domain)->_get_controller_network();
    is($nets[1]->{driver}, 'virtio') if $nets[1];
    is($nets[1]->{bridge}, 'vmbr0') if $nets[1];

    $req = Ravada::Request->remove_hardware(uid => user_admin->id, id_domain => $domain->id
        , name => 'network', index => 1);
    wait_request();
    is($req->error, '');
    @nets = _reopen($domain)->_get_controller_network();
    is(scalar(@nets), 1, "network removed") or diag(Dumper(\@nets));

    my @disks_before = $domain->list_volumes_info(device => 'disk');
    $req = Ravada::Request->add_hardware(uid => user_admin->id, id_domain => $domain->id
        , name => 'disk', data => { size => 1024 * 1024 * 1024, type => 'data' });
    wait_request();
    is($req->error, '');
    my @disks = _reopen($domain)->list_volumes_info(device => 'disk');
    is(scalar(@disks), scalar(@disks_before) + 1, "disk added") or diag(Dumper([map { $_->info } @disks]));

    my $index = $#disks;
    my @all = _reopen($domain)->_disks_info();
    ($index) = grep { $all[$_]->{file} eq $disks[-1]->file } 0 .. $#all;
    $req = Ravada::Request->change_hardware(uid => user_admin->id, id_domain => $domain->id
        , hardware => 'disk', index => $index, data => { capacity => '3G' });
    wait_request();
    is($req->error, '');
    @disks = _reopen($domain)->list_volumes_info(device => 'disk');
    is($disks[-1]->capacity, 3 * 1024 * 1024 * 1024, "disk resized") or diag(Dumper($disks[-1]->info));

    my $file = $disks[-1]->file;
    $req = Ravada::Request->remove_hardware(uid => user_admin->id, id_domain => $domain->id
        , name => 'disk', index => $index);
    wait_request();
    is($req->error, '');
    @disks = _reopen($domain)->list_volumes_info(device => 'disk');
    is(scalar(@disks), scalar(@disks_before), "disk removed") or diag(Dumper([map { $_->info } @disks]));
    ok(!$vm->file_exists($file), "volume $file destroyed");

    $req = Ravada::Request->change_hardware(uid => user_admin->id, id_domain => $domain->id
        , hardware => 'display', index => 0, data => { driver => 'vnc' });
    wait_request();
    is($req->error, '');
    is($domain->pve_config(1)->{vga}, 'std', "vnc display uses std vga");
    my ($display) = $domain->display_info(user_admin);
    is($display->{driver}, 'vnc');
    $req = Ravada::Request->change_hardware(uid => user_admin->id, id_domain => $domain->id
        , hardware => 'display', index => 0, data => { driver => 'spice' });
    wait_request();
    is($req->error, '');
    is($domain->pve_config(1)->{vga}, 'qxl');
}

sub test_rename($domain) {
    my $new_name = new_domain_name();
    my $req = Ravada::Request->rename_domain(uid => user_admin->id, id_domain => $domain->id
        , name => $new_name);
    wait_request();
    is($req->error, '');
    my $domain2 = rvd_back->search_domain($new_name);
    ok($domain2, "renamed domain found") or return;
    is($domain2->vmid, $domain->vmid);
    like($domain2->pve_config->{name}, qr/^[a-zA-Z0-9\-]+$/, "pve name ".$domain2->pve_config->{name});
    return $domain2;
}

sub test_autostart($domain) {
    my $req = Ravada::Request->domain_autostart(uid => user_admin->id, id_domain => $domain->id, value => 1);
    wait_request();
    is($req->error, '');
    is($domain->pve_config(1)->{onboot}, 1, "onboot set");
    is($domain->autostart, 1);
    $req = Ravada::Request->domain_autostart(uid => user_admin->id, id_domain => $domain->id, value => 0);
    wait_request();
    is($domain->pve_config(1)->{onboot}, 0, "onboot cleared");
}

sub test_base_and_clones($domain) {
    my $req = Ravada::Request->prepare_base(uid => user_admin->id, id_domain => $domain->id);
    wait_request();
    is($req->error, '');
    ok($domain->is_base, "is base");
    is($domain->pve_config(1)->{template}, 1, "template in proxmox");
    my @files = $domain->list_files_base;
    ok(scalar(@files) >= 1, "base files") or diag(Dumper(\@files));
    like($files[0], qr/base-\d+-disk/, "base volume name");

    my $req_start = Ravada::Request->start_domain(uid => user_admin->id, id_domain => $domain->id);
    wait_request(check_error => 0);
    like($req_start->error, qr/template|base/i, "bases can't be started");

    $domain->is_public(1);
    my $name = new_domain_name();
    $req = Ravada::Request->clone(uid => $USER->id, id_domain => $domain->id, name => $name
        , remote_ip => '10.1.1.2');
    wait_request();
    is($req->error, '');
    my $clone = rvd_back->search_domain($name);
    ok($clone, "clone $name") or return;
    is($clone->id_base, $domain->id);
    is($clone->id_owner, $USER->id);
    my ($disk) = $clone->list_volumes_info(device => 'disk');
    like($disk->file, qr{base-\d+-disk-0[^/]*/\d+/vm-\d+-disk}, "linked clone volume ".$disk->file);
    is($disk->backing_file, $files[0], "backing file");

    $req = Ravada::Request->start_domain(uid => $USER->id, id_domain => $clone->id, remote_ip => '10.1.1.2');
    wait_request();
    is($req->error, '');
    ok($clone->is_active, "clone running");

    # volatile clones
    $domain->volatile_clones(1);
    my $name_v = new_domain_name();
    $req = Ravada::Request->clone(uid => $USER->id, id_domain => $domain->id, name => $name_v
        , remote_ip => '10.1.1.3');
    wait_request();
    is($req->error, '');
    my $volatile = rvd_back->search_domain($name_v);
    ok($volatile, "volatile clone") or return;
    ok($volatile->is_active, "volatile clone started on creation");
    ok($volatile->is_volatile, "is volatile");
    my $vmid_v = $volatile->vmid;
    $req = Ravada::Request->shutdown_domain(uid => $USER->id, id_domain => $volatile->id, timeout => 2);
    wait_request(check_error => 0);
    ok(!$volatile->is_active, "volatile clone down");
    ok(rvd_back->search_domain($name_v), "volatile clone kept during the grace period");
    # simulate the end of the grace period, the backend then requests a
    # shutdown of stopped volatile machines which removes them
    $req = Ravada::Request->refresh_machine(uid => user_admin->id, id_domain => $volatile->id);
    wait_request(check_error => 0);
    $volatile->_data('date_status_change' => '2000-01-01 00:00:00');
    $req = Ravada::Request->shutdown_domain(uid => user_admin->id, id_domain => $volatile->id);
    wait_request(check_error => 0);
    my $gone = rvd_back->search_domain($name_v);
    ok(!$gone, "volatile clone removed after shutdown");
    my $api = $vm->vm;
    eval { $api->get("/nodes/pve1/qemu/$vmid_v/config") };
    like("$@", qr/does not exist/, "volatile vm destroyed in proxmox");
    $domain->volatile_clones(0);

    # spinoff / dettach
    $req = Ravada::Request->shutdown_domain(uid => $USER->id, id_domain => $clone->id, timeout => 2);
    wait_request();
    my $vmid_clone = $clone->vmid;
    my $pve_name_clone = $clone->pve_config->{name};
    $req = Ravada::Request->dettach(uid => user_admin->id, id_domain => $clone->id);
    wait_request();
    is($req->error, '');
    my $dettached = rvd_back->search_domain($name);
    ok(!$dettached->id_base, "dettached has no base") or diag($dettached->id_base);
    isnt($dettached->vmid, $vmid_clone, "full clone has a new vmid");
    ($disk) = $dettached->list_volumes_info(device => 'disk');
    unlike($disk->file, qr{/\d+/vm-}, "not linked any more ".$disk->file);
    ok(!$disk->backing_file, "no backing file");
    is($dettached->pve_config->{name}, $pve_name_clone, "name kept");

    $req = Ravada::Request->remove_domain(uid => user_admin->id, name => $name);
    wait_request();
    is($req->error, '');

    # can't remove base while it has clones ... it has none now
    $req = Ravada::Request->remove_base(uid => user_admin->id, id_domain => $domain->id);
    wait_request();
    is($req->error, '');
    ok(!$domain->is_base, "not base");
    ok(!$domain->pve_config(1)->{template}, "not a template");
}

sub test_migrate($domain) {
    my ($node2_data) = grep { $_->{hostname} eq 'pve2' } rvd_front->list_vms();
    ok($node2_data, "node pve2 in the nodes list") or return;
    my $node2 = Ravada::VM->open($node2_data->{id});
    ok($node2, "node pve2") or return;
    is($node2->node, 'pve2');
    is($node2->is_local, 0);
    ok($node2->is_active, "pve2 active");
    ok($node2->free_memory > 0, "free memory in pve2");

    # local storage: offline migration copies the local disks
    my $req = Ravada::Request->migrate(uid => user_admin->id, id_domain => $domain->id, id_node => $node2->id);
    wait_request();
    is($req->error, '');
    my $moved = rvd_back->search_domain($domain->name);
    is($moved->node, 'pve2', "machine with local disks migrated offline");
    $req = Ravada::Request->migrate(uid => user_admin->id, id_domain => $domain->id, id_node => $vm->id);
    wait_request();
    is($req->error, '');
    is(rvd_back->search_domain($domain->name)->node, 'pve1', "migrated back");

    # create a machine on shared storage and migrate it
    my $name = new_domain_name();
    $req = Ravada::Request->create_domain(name => $name, vm => 'Proxmox'
        , id_iso => search_id_iso('Alpine'), id_owner => user_admin->id
        , storage => 'shared', disk => 1024 * 1024 * 1024);
    wait_request();
    is($req->error, '');
    my $shared = rvd_back->search_domain($name) or return;
    my ($disk) = $shared->list_volumes_info(device => 'disk');
    like($disk->file, qr/^shared:/, "disk on shared storage");

    $req = Ravada::Request->migrate(uid => user_admin->id, id_domain => $shared->id, id_node => $node2->id);
    wait_request();
    is($req->error, '');
    my $migrated = rvd_back->search_domain($name);
    is($migrated->node, 'pve2', "migrated to pve2");
    is($migrated->_vm->id, $node2->id, "id_vm updated");
    is(Ravada::Front::Domain->open($migrated->id)->node, 'pve2', "node in front");

    $req = Ravada::Request->start_domain(uid => user_admin->id, id_domain => $migrated->id, remote_ip => '10.1.1.4');
    wait_request();
    is($req->error, '');
    ok($migrated->is_active, "started in pve2");
    my ($display) = $migrated->display_info(user_admin);
    is($display->{ip}, '192.0.2.12', "display on pve2 address") or diag(Dumper($display));

    my $vmid = $migrated->vmid;
    $req = Ravada::Request->remove_domain(uid => user_admin->id, name => $name);
    wait_request();
    is($req->error, '');
    ok(!rvd_back->search_domain($name), "removed from ravada");
    eval { $vm->vm->get("/nodes/pve2/qemu/$vmid/config") };
    like("$@", qr/does not exist/, "removed from pve2");
}

sub test_discover_import {
    my $api = $vm->vm;
    my $vmid = $api->get('/cluster/nextid');
    $api->wait_task('pve1', $api->post('/nodes/pve1/qemu', { vmid => $vmid, name => 'imported-vm'
        , memory => 256, scsi0 => 'local:1', net0 => 'virtio,bridge=vmbr0', vga => 'qxl' }));
    my @found = $vm->discover();
    ok(grep({ $_ eq 'imported-vm' } @found), "discovered") or diag(Dumper(\@found));

    my $domain = rvd_back->import_domain(name => 'imported-vm', vm => 'Proxmox', user => user_admin->name);
    ok($domain, "imported") or return;
    is($domain->vmid, $vmid);
    ok($domain->is_known, "imported is known");
    @found = $vm->discover();
    ok(!grep({ $_ eq 'imported-vm' } @found), "not discovered any more");

    my $req = Ravada::Request->remove_domain(uid => user_admin->id, name => 'imported-vm');
    wait_request();
    is($req->error, '');
}

sub test_remove($domain) {
    my $vmid = $domain->vmid;
    my $req = Ravada::Request->remove_domain(uid => user_admin->id, name => $domain->name);
    wait_request();
    is($req->error, '');
    ok(!rvd_back->search_domain($domain->name), "removed from ravada");
    eval { $vm->vm->get("/nodes/pve1/qemu/$vmid/config") };
    like("$@", qr/does not exist/, "removed from proxmox");
    my $content = $vm->vm->get('/nodes/pve1/storage/local/content', { content => 'images' });
    ok(!grep({ $_->{vmid} && $_->{vmid} == $vmid } @$content), "no leftover volumes") or diag(Dumper($content));
}

######################################################################

test_front_vm_types();
test_list_isos();
test_machine_types();
test_storage_pools();

my $domain = test_create_request();
if ($domain) {
    test_start_stop($domain);
    test_hardware($domain);
    $domain = test_rename($domain);
    test_autostart($domain);
    test_base_and_clones($domain);
    test_migrate($domain);
    test_remove($domain);
}
test_discover_import();

end();
done_testing();
