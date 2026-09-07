use warnings;
use strict;

use Data::Dumper;
use Test::More;

use lib 't/lib';
use Test::Ravada;

use Ravada::Proxmox::API;

$Data::Dumper::Sortkeys = 1;

init('t/etc/ravada_proxmox.conf');
Ravada::Proxmox::API->new_client(url => 'mock://test')->reset();

my $rvd = rvd_back();
my $vm = $rvd->search_vm('Proxmox');
ok($vm, "search_vm Proxmox") or BAIL_OUT("No Proxmox virtual manager");

isa_ok($vm, 'Ravada::VM::Proxmox');
is($vm->node, 'pve1', "node from config");
is($vm->host, 'localhost', "primary node is localhost");
ok($vm->is_alive, "alive");
ok($vm->is_local, "primary node is local");
is($vm->needs_ssh, 0, "no ssh needed");
ok($vm->get_library_version > 8000000, "library version ".$vm->get_library_version);

my @pools = $vm->list_storage_pools;
ok(grep({ $_ eq 'local' } @pools), "local storage pool") or diag(Dumper(\@pools));
is($vm->default_storage_pool_name, 'local', "default storage from config");
is($vm->_storage_path('local'), 'local', "storage path is the storage id");
ok($vm->free_memory > 0, "free memory");
ok($vm->free_disk > 0, "free disk");
ok($vm->free_disk('shared') > 0, "free disk in shared");
ok($vm->shared_storage(undef, 'shared'), "shared storage flag");
ok(!$vm->shared_storage(undef, 'local'), "local storage flag");

my %machines = $vm->list_machine_types();
ok(scalar(@{$machines{x86_64}}), "machine types");
ok(scalar($vm->get_cpu_model_names), "cpu models");
my @bridges = $vm->list_network_interfaces('bridge');
ok(grep({ $_ eq 'vmbr0' } @bridges), "bridges") or diag(Dumper(\@bridges));
my @nat = $vm->list_network_interfaces('nat');
is(scalar(@nat), 0, "no nat networks");

# ISO handling
my $id_iso = search_id_iso('Alpine');
my $iso = $vm->_search_iso($id_iso);
ok($iso->{has_cd}, "alpine has cd");
my $device = $vm->_iso_name($iso);
like($device, qr{^local:iso/.*\.iso$}, "iso downloaded to storage: $device");
ok($vm->file_exists($device), "iso exists in storage");
is($vm->_iso_name($vm->_search_iso($id_iso)), $device, "iso found second time");
like($vm->search_volume_path_re(qr(.*\.iso$)), qr/\.iso$/, "iso listed");

# create a machine from the ISO
my $name = new_domain_name();
my $domain = $vm->create_domain(name => $name, id_iso => $id_iso
    , id_owner => user_admin->id, disk => 1024 * 1024 * 1024, memory => 1024 * 1024);
ok($domain, "create_domain") or BAIL_OUT("No domain created");
isa_ok($domain, 'Ravada::Domain::Proxmox');
is($domain->type, 'Proxmox');
is($domain->name, $name);
ok($domain->vmid >= 100, "vmid ".$domain->vmid);
is($domain->node, 'pve1');
ok($domain->is_known, "known in the database");
ok($domain->is_known_extra, "known in domains_proxmox");
is($domain->_data_extra('vmid'), $domain->vmid, "vmid stored");
is($domain->_data_extra('node'), 'pve1', "node stored");

my $config = $domain->pve_config;
is($config->{memory}, 1024, "memory in MB");
like($config->{scsi0}, qr/^local:\d+\/vm-\d+-disk-\d+\.qcow2,size=1G$/, "system disk") or diag(Dumper($config));
like($config->{ide2}, qr/^local:iso\/.*,media=cdrom$/, "cdrom");
like($config->{net0}, qr/^virtio=[0-9A-F:]+,bridge=vmbr0$/, "network");
is($config->{vga}, 'qxl', "spice capable display");
is($config->{agent}, 1, "guest agent enabled");
like($config->{name}, qr/^[a-zA-Z0-9\-]+$/, "proxmox name $config->{name}");

ok(!$domain->is_active, "not active");
ok(!$domain->is_removed, "not removed");
is($domain->is_hibernated, 0);
is($domain->is_paused, 0);

my @vols = $domain->list_volumes_info;
is(scalar(@vols), 2, "disk and cdrom");
my ($disk) = grep { $_->info->{device} eq 'disk' } @vols;
isa_ok($disk, 'Ravada::Volume::Proxmox');
is($disk->capacity, 1024 * 1024 * 1024, "capacity");
is($disk->info->{target}, 'scsi0');
is($disk->info->{storage_pool}, 'local');
ok(!$disk->backing_file, "no backing file");
is($domain->disk_size, 1024 * 1024 * 1024);
my @disks = $domain->list_disks;
is(scalar(@disks), 1, "one disk");

my $info = $domain->get_info;
is($info->{max_mem}, 1024 * 1024, "max_mem KB");
is($info->{memory}, 1024 * 1024, "memory KB");
is($info->{n_virt_cpu}, 1);
like($info->{mac}, qr/^[0-9A-F:]+$/i, "mac");

# start and display
$domain->start(user => user_admin, remote_ip => '127.0.0.1');
ok($domain->is_active, "active");
$info = $domain->info(user_admin);
like($info->{ip}, qr/^\d+\.\d+\.\d+\.\d+$/, "ip");
is($info->{display}->{driver}, 'spice');
ok($info->{display}->{port}, "display port");
is($info->{display}->{ip}, '192.0.2.11', "display ip is the node address");

my $vv = $domain->_display_file_spice($info->{display});
like($vv, qr/^\[virt-viewer\]\ntype=spice\n/, ".vv file");
like($vv, qr/^proxy=http:\/\/192\.0\.2\.11:3128$/m, "spice proxy");
like($vv, qr/^password=PVESPICE:/m, "spice ticket");
like($vv, qr/^delete-this-file=1$/m);

# pause, hibernate
$domain->pause(user_admin);
ok($domain->is_paused, "paused");
$domain->resume(user_admin);
ok(!$domain->is_paused, "resumed");
$domain->hibernate(user_admin);
ok(!$domain->is_active, "hibernated not active");
ok($domain->is_hibernated, "hibernated");
$domain->start(user => user_admin);
ok($domain->is_active, "resumed from hibernation");
ok(!$domain->is_hibernated);

$domain->shutdown_now(user_admin);
ok(!$domain->is_active, "shutdown");

# add and remove volumes
my $file_data = $domain->add_volume(size => 512 * 1024 * 1024, type => 'data');
like($file_data, qr/^local:\d+\/vm-\d+-disk-1/, "data volume $file_data");
ok($vm->file_exists($file_data), "data volume in storage");
is(scalar($domain->list_disks), 2, "two disks");
$domain->remove_volume($file_data);
is(scalar($domain->list_disks), 1, "data disk removed");
ok(!$vm->file_exists($file_data), "data volume destroyed");

# memory and cpus
$domain->set_max_mem(2 * 1024 * 1024);
is($domain->pve_config(1)->{memory}, 2048);
$domain->set_memory(1024 * 1024);
is($domain->pve_config(1)->{balloon}, 1024);
$domain->change_hardware('vcpus', 0, { n_virt_cpu => 2, max_virt_cpu => 2 });
is($domain->pve_config(1)->{cores}, 2);

# base and clone
$domain->prepare_base(user => user_admin);
ok($domain->is_base, "is base");
is($domain->pve_config(1)->{template}, 1, "template");
my @base = $domain->list_files_base_target;
is(scalar(@base), 1, "one base volume");
like($base[0]->[0], qr/base-\d+-disk-0/, "base volume ".$base[0]->[0]);
is($base[0]->[1], 'scsi0', "target");

my $clone = $domain->clone(name => new_domain_name(), user => user_admin);
ok($clone, "clone") or BAIL_OUT("no clone");
is($clone->id_base, $domain->id);
my ($clone_disk) = $clone->list_volumes_info(device => 'disk');
is($clone_disk->backing_file, $base[0]->[0], "linked clone backing file");
$clone->start(user_admin);
ok($clone->is_active, "clone active");
$clone->shutdown_now(user_admin);

eval { $domain->remove(user_admin) };
like("$@", qr/clones/i, "can't remove base with clones");

$clone->remove(user_admin);
ok($clone->is_removed, "clone removed");
$domain->remove_base(user_admin);
ok(!$domain->is_base, "not base");
ok(!$domain->pve_config(1)->{template}, "not a template");
$domain->start(user_admin);
ok($domain->is_active, "former base starts again");
$domain->shutdown_now(user_admin);

# rename
my $new_name = new_domain_name();
$domain->rename(name => $new_name, user => user_admin);
is($domain->name, $new_name);
ok(rvd_back->search_domain($new_name), "found by new name");
$domain = rvd_back->search_domain($new_name);

$domain->remove(user_admin);
ok($domain->is_removed, "removed");
ok(!rvd_back->search_domain($new_name), "not found any more");

end();
done_testing();
