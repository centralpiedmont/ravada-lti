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

init('t/etc/ravada_proxmox_sdn.conf');
Ravada::Proxmox::API->new_client(url => 'mock://sdn')->reset();

my $rvd = rvd_back();
my $vm = $rvd->search_vm('Proxmox');
ok($vm, "Proxmox virtual manager") or BAIL_OUT("No Proxmox VM");

######################################################################

sub test_networks {
    ok($vm->has_networking, "networking with a sdn zone");
    my @nets = $vm->list_virtual_networks();
    is(scalar(@nets), 0, "no vnets yet") or diag(Dumper(\@nets));

    my $req = Ravada::Request->new_network(uid => user_admin->id, id_vm => $vm->id, name => 'lab');
    wait_request();
    is($req->error, '');
    my $new = decode_json($req->output);
    like($new->{name}, qr/^lab\d*$/, "proposed name $new->{name}") or diag(Dumper($new));
    like($new->{ip_address}, qr/^10\.\d+\.0\.1$/, "proposed ip");
    is($new->{ip_netmask}, '255.255.255.0');

    $req = Ravada::Request->create_network(uid => user_admin->id, id_vm => $vm->id
        , data => { %$new, forward_mode => 'nat', is_public => 1 });
    wait_request();
    is($req->error, '');
    my $out = decode_json($req->output);
    ok($out->{id_network}, "network id") or diag(Dumper($out));

    @nets = $vm->list_virtual_networks();
    is(scalar(@nets), 1, "one vnet") or diag(Dumper(\@nets));
    my $net = $nets[0];
    is($net->{name}, $new->{name});
    is($net->{bridge}, $new->{name}, "bridge is the vnet");
    is($net->{ip_address}, $new->{ip_address});
    is($net->{forward_mode}, 'nat');
    like($net->{dhcp_start}, qr/^10\.\d+\.0\.2$/, "dhcp start");
    like($net->{dhcp_end}, qr/^10\.\d+\.0\.254$/, "dhcp end");

    my $api = $vm->vm;
    my $vnets = $api->get('/cluster/sdn/vnets');
    is($vnets->[0]->{zone}, 'ravada', "vnet in the zone");
    my $subnets = $api->get("/cluster/sdn/vnets/$net->{bridge}/subnets");
    is(scalar(@$subnets), 1, "subnet") and is($subnets->[0]->{snat}, 1, "snat");
    ok($vm->_is_ip_nat($new->{ip_address}), "ip is nat");
    ok(!$vm->_is_ip_nat('192.0.2.5'), "bridge ip is not nat");

    my @front = @{ rvd_front->list_networks($vm->id, user_admin->id) };
    my ($front_net) = grep { $_->{name} eq $new->{name} } @front;
    ok($front_net, "network in the front") or diag(Dumper(\@front));

    # a machine in the virtual network
    my $name = new_domain_name();
    $req = Ravada::Request->create_domain(name => $name, vm => 'Proxmox'
        , id_iso => search_id_iso('Alpine'), id_owner => user_admin->id
        , disk => 1024 * 1024 * 1024, options => { network => $net->{bridge} });
    wait_request();
    is($req->error, '');
    my $domain = rvd_back->search_domain($name) or return;
    like($domain->pve_config->{net0}, qr/bridge=$net->{bridge}/, "machine in the vnet");
    my @ifaces = $domain->_get_controller_network();
    is($ifaces[0]->{type}, 'nat', "interface is nat") or diag(Dumper(\@ifaces));
    is($ifaces[0]->{network}, $net->{name}, "interface network name");
    $domain->_fetch_networking_mode();
    is($domain->_data('networking'), 'nat', "networking mode");

    # change dhcp range and forward mode
    my $data = { %$front_net, dhcp_start => "$1.10", dhcp_end => "$1.100", forward_mode => 'none' }
        if $net->{ip_address} =~ /^(10\.\d+\.0)\./;
    $req = Ravada::Request->change_network(uid => user_admin->id, data => $data);
    wait_request();
    is($req->error, '');
    @nets = $vm->list_virtual_networks();
    like($nets[0]->{dhcp_start}, qr/\.10$/, "dhcp start changed") or diag(Dumper(\@nets));
    is($nets[0]->{forward_mode}, 'none', "isolated now");
    $domain->_fetch_networking_mode();
    is($domain->_data('networking'), 'isolated', "networking mode isolated");

    # the vnet is in use, remove the machine first
    $req = Ravada::Request->remove_network(uid => user_admin->id, id => $front_net->{id});
    wait_request(check_error => 0);
    like($req->error, qr/used by VM/, "network in use");

    $req = Ravada::Request->remove_domain(uid => user_admin->id, name => $name);
    wait_request();
    is($req->error, '');

    $req = Ravada::Request->remove_network(uid => user_admin->id, id => $front_net->{id});
    wait_request();
    is($req->error, '');
    @nets = $vm->list_virtual_networks();
    is(scalar(@nets), 0, "vnet removed") or diag(Dumper(\@nets));
    $vnets = $api->get('/cluster/sdn/vnets');
    is(scalar(@$vnets), 0, "vnet removed in proxmox");
}

sub test_snapshots {
    my $name = new_domain_name();
    my $req = Ravada::Request->create_domain(name => $name, vm => 'Proxmox'
        , id_iso => search_id_iso('Alpine'), id_owner => user_admin->id
        , disk => 1024 * 1024 * 1024);
    wait_request();
    my $domain = rvd_back->search_domain($name) or return;
    is(scalar($domain->list_snapshots), 0, "no snapshots");
    $domain->create_snapshot('clean', 'fresh install');
    my @snaps = $domain->list_snapshots;
    is(scalar(@snaps), 1, "one snapshot") or diag(Dumper(\@snaps));
    is($snaps[0]->{name}, 'clean');
    eval { $domain->create_snapshot('1bad') };
    like("$@", qr/invalid snapshot name/, "snapshot name checked");
    $domain->start(user_admin);
    $domain->rollback_snapshot('clean');
    ok(!$domain->is_active, "rolled back machine is down");
    $domain->remove_snapshot('clean');
    is(scalar($domain->list_snapshots), 0, "snapshot removed");

    # browser console helpers
    $domain->start(user_admin);
    my $front = Ravada::Front::Domain->open($domain->id);
    my $vnc = $front->vnc_proxy_data();
    ok($vnc->{ticket}, "vnc ticket") or diag(Dumper($vnc));
    ok($vnc->{port}, "vnc port");
    my ($url, $headers, $options) = $front->console_websocket();
    like($url, qr{^wss://.*/nodes/pve1/qemu/\d+/vncwebsocket\?}, "websocket url $url");
    like($url, qr/vncticket=/, "ticket in url");
    like($url, qr/port=\d+/, "port in url");
    is(ref($headers), 'HASH', "auth headers");
    ok(exists $options->{insecure}, "tls options");

    $req = Ravada::Request->remove_domain(uid => user_admin->id, name => $name);
    wait_request();
    is($req->error, '');
}

######################################################################

test_networks();
test_snapshots();

end();
done_testing();
