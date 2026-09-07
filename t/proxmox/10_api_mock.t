use warnings;
use strict;

use Data::Dumper;
use Test::More;

use lib 'lib';

use_ok('Ravada::Proxmox::API');
use_ok('Ravada::Proxmox::API::Mock');

my $api = Ravada::Proxmox::API->new_client(url => 'mock://t10');
isa_ok($api, 'Ravada::Proxmox::API::Mock');
$api->reset();

my $version = $api->get('/version');
ok($version->{version}, "version");

my $nodes = $api->get('/nodes');
is(scalar(@$nodes), 2, "two nodes");

my $storages = $api->get('/nodes/pve1/storage');
ok(scalar(@$storages) >= 2, "storages");

my $vmid = $api->get('/cluster/nextid');
is($vmid, 100, "first vmid");

my $upid = $api->post('/nodes/pve1/qemu', {
    vmid => $vmid, name => 'test-vm', memory => 512, cores => 1
    , scsi0 => 'local:1', net0 => 'virtio,bridge=vmbr0', vga => 'qxl', agent => 1
});
like($upid, qr/^UPID:pve1:/, "create returns a upid");
my $status = $api->wait_task('pve1', $upid);
is($status->{exitstatus}, 'OK');

my $config = $api->get("/nodes/pve1/qemu/$vmid/config");
like($config->{scsi0}, qr{^local:100/vm-100-disk-0.qcow2,size=1G$}, "disk allocated") or diag(Dumper($config));
like($config->{net0}, qr{^virtio=[0-9A-F:]+,bridge=vmbr0$}, "mac generated") or diag(Dumper($config));

my $content = $api->get('/nodes/pve1/storage/local/content', { content => 'images' });
is(scalar(@$content), 1, "one image in local");

my $current = $api->get("/nodes/pve1/qemu/$vmid/status/current");
is($current->{status}, 'stopped');

eval { $api->post("/nodes/pve1/qemu/$vmid/spiceproxy") };
like("$@", qr/not running/, "spiceproxy needs a running vm");
is($@->code, 500, "error code");

$api->wait_task('pve1', $api->post("/nodes/pve1/qemu/$vmid/status/start"));
$current = $api->get("/nodes/pve1/qemu/$vmid/status/current");
is($current->{status}, 'running');

my $spice = $api->post("/nodes/pve1/qemu/$vmid/spiceproxy");
ok($spice->{'tls-port'}, "tls port") or diag(Dumper($spice));
ok($spice->{password}, "password");
like($spice->{proxy}, qr{^http://.*:3128$}, "proxy");

my $ifaces = $api->get("/nodes/pve1/qemu/$vmid/agent/network-get-interfaces");
my ($eth0) = grep { $_->{name} eq 'eth0' } @{$ifaces->{result}};
ok($eth0, "eth0") and like($eth0->{'ip-addresses'}->[0]->{'ip-address'}, qr/^\d+\.\d+\.\d+\.\d+$/);

# templates and clones
eval { $api->post("/nodes/pve1/qemu/$vmid/template") };
like("$@", qr/running/, "no template while running");

$api->wait_task('pve1', $api->post("/nodes/pve1/qemu/$vmid/status/suspend", { todisk => 1 }));
$current = $api->get("/nodes/pve1/qemu/$vmid/status/current");
is($current->{status}, 'stopped');
is($current->{lock}, 'suspended', "hibernated");
$api->wait_task('pve1', $api->post("/nodes/pve1/qemu/$vmid/status/resume"));
$current = $api->get("/nodes/pve1/qemu/$vmid/status/current");
is($current->{status}, 'running');
ok(!$current->{lock}, "lock cleared");

$api->wait_task('pve1', $api->post("/nodes/pve1/qemu/$vmid/status/stop"));
$api->wait_task('pve1', $api->post("/nodes/pve1/qemu/$vmid/template"));
$config = $api->get("/nodes/pve1/qemu/$vmid/config");
is($config->{template}, 1, "template");
like($config->{scsi0}, qr{base-100-disk-0}, "base disk") or diag($config->{scsi0});

eval { $api->post("/nodes/pve1/qemu/$vmid/status/start") };
like("$@", qr/template/, "can't start template");

my $newid = $api->get('/cluster/nextid');
is($newid, 101);
$api->wait_task('pve1', $api->post("/nodes/pve1/qemu/$vmid/clone"
        , { newid => $newid, name => 'clone-1', full => 0 }));
my $config_clone = $api->get("/nodes/pve1/qemu/$newid/config");
like($config_clone->{scsi0}, qr{^local:100/base-100-disk-0.qcow2/101/vm-101-disk-0.qcow2}, "linked clone")
    or diag($config_clone->{scsi0});
isnt($config_clone->{net0}, $config->{net0}, "new mac");

eval { $api->delete("/nodes/pve1/qemu/$vmid", { purge => 1 }) };
like("$@", qr/linked clone/, "template in use");

# full clone to another node needs shared storage
eval { $api->post("/nodes/pve1/qemu/$vmid/clone", { newid => 102, full => 1, target => 'pve2' }) };
like("$@", qr/local storage/, "no clone to other node with local storage");

$api->wait_task('pve1', $api->post("/nodes/pve1/qemu/$vmid/clone"
        , { newid => 102, full => 1, target => 'pve2', storage => 'shared' }));
my $config_102 = $api->get("/nodes/pve2/qemu/102/config");
like($config_102->{scsi0}, qr{^shared:102/vm-102-disk-0}, "full clone on shared storage") or diag(Dumper($config_102));

# resize and remove disks
$api->wait_task('pve1', $api->put("/nodes/pve1/qemu/$newid/resize", { disk => 'scsi0', size => '+1G' }));
$config_clone = $api->get("/nodes/pve1/qemu/$newid/config");
like($config_clone->{scsi0}, qr{size=2G}, "resized") or diag($config_clone->{scsi0});

$api->put("/nodes/pve1/qemu/$newid/config", { scsi1 => 'local:0.5' });
$config_clone = $api->get("/nodes/pve1/qemu/$newid/config");
like($config_clone->{scsi1}, qr{^local:101/vm-101-disk-0.qcow2,size=512M$}, "second disk") or diag($config_clone->{scsi1});
$api->put("/nodes/pve1/qemu/$newid/config", { delete => 'scsi1' });
$config_clone = $api->get("/nodes/pve1/qemu/$newid/config");
ok(!$config_clone->{scsi1}, "disk detached");
is($config_clone->{unused0}, 'local:101/vm-101-disk-0.qcow2', "disk unused") or diag(Dumper($config_clone));
$api->put("/nodes/pve1/qemu/$newid/config", { delete => 'unused0' });
$content = $api->get('/nodes/pve1/storage/local/content', { content => 'images' });
ok(!grep({ $_->{volid} eq 'local:101/vm-101-disk-0.qcow2' } @$content), "disk destroyed");

# migrate
eval { $api->post("/nodes/pve1/qemu/$newid/migrate", { target => 'pve2' }) };
like("$@", qr/local disks/, "linked clone on local storage can't migrate");

# download iso
$api->wait_task('pve1', $api->post("/nodes/pve1/storage/local/download-url"
    , { content => 'iso', filename => 'alpine.iso', url => 'http://example.com/alpine.iso' }));
$content = $api->get('/nodes/pve1/storage/local/content', { content => 'iso' });
is($content->[0]->{volid}, 'local:iso/alpine.iso', "iso downloaded");

# destroy clone, then template
$api->wait_task('pve1', $api->delete("/nodes/pve1/qemu/$newid", { purge => 1, 'destroy-unreferenced-disks' => 1 }));
$api->wait_task('pve1', $api->delete("/nodes/pve1/qemu/$vmid", { purge => 1, 'destroy-unreferenced-disks' => 1 }));
my $list = $api->get('/nodes/pve1/qemu');
is(scalar(@$list), 0, "pve1 empty") or diag(Dumper($list));

eval { $api->get("/nodes/pve1/qemu/$vmid/config") };
like("$@", qr/does not exist/, "removed vm");

# state survives a new client
my $api2 = Ravada::Proxmox::API->new_client(url => 'mock://t10');
$list = $api2->get('/nodes/pve2/qemu');
is(scalar(@$list), 1, "102 in pve2");
$api2->reset();

done_testing();
