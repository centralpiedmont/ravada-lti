use warnings;
use strict;

no warnings "experimental::signatures";
use feature qw(signatures);

use Data::Dumper;
use Test::More;

use lib 't/lib';
use Test::Ravada;

use Ravada::Proxmox::API;

$Data::Dumper::Sortkeys = 1;

init('t/etc/ravada_proxmox_nodes.conf');
Ravada::Proxmox::API->new_client(url => 'mock://nodes')->reset();

my $USER = create_user("user_nodes_$$", "pass");

my $rvd = rvd_back();
my $vm = $rvd->search_vm('Proxmox');
ok($vm, "Proxmox virtual manager") or BAIL_OUT("No Proxmox VM");

######################################################################

sub test_add_node_from_front {
    my @vms = rvd_front->list_vms();
    is(scalar(@vms), 1, "only the primary node from the config") or diag(Dumper(\@vms));

    # the admin adds the second node in the nodes page
    my $req = Ravada::Request->connect_node(backend => 'Proxmox', hostname => 'pve2');
    wait_request();
    is($req->error, '', "connect_node without ssh");
    like($req->output, qr/Connection OK/, "connection ok") or diag($req->output);

    $req = Ravada::Request->connect_node(backend => 'Proxmox', hostname => 'pve9');
    wait_request(check_error => 0);
    ok($req->error, "unknown node fails: ".$req->error);

    rvd_front->add_node(vm_type => 'Proxmox', hostname => 'pve2', name => 'Proxmox_pve2');
    wait_request(skip => []);

    my ($node2_data) = grep { $_->{hostname} eq 'pve2' } rvd_front->list_vms();
    ok($node2_data, "node added") or return;
    my $node2 = Ravada::VM->open($node2_data->{id});
    ok($node2, "node opened") or return;
    is($node2->node, 'pve2');
    ok($node2->is_active, "node active");
    ok($node2->_data('connection_args'), "connection settings stored for the new node");
    return $node2;
}

sub test_base_local_storage($node2) {
    my $name = new_domain_name();
    my $req = Ravada::Request->create_domain(name => $name, vm => 'Proxmox'
        , id_iso => search_id_iso('Alpine'), id_owner => user_admin->id
        , disk => 1024 * 1024 * 1024);
    wait_request();
    is($req->error, '');
    my $domain = rvd_back->search_domain($name) or return;

    $req = Ravada::Request->set_base_vm(uid => user_admin->id, id_domain => $domain->id
        , id_vm => $node2->id, value => 1);
    wait_request(check_error => 0);
    like($req->error, qr/local storage/, "base in local storage can not be enabled in other nodes: ".$req->error);
    ok($domain->is_base, "prepared as base anyway");
    is($domain->base_in_vm($node2->id), 0, "not enabled in pve2");
    is($domain->node, 'pve1', "template stays in pve1");

    $req = Ravada::Request->remove_domain(uid => user_admin->id, name => $name);
    wait_request();
    is($req->error, '');
}

sub test_base_shared_storage($node2) {
    my $name = new_domain_name();
    my $req = Ravada::Request->create_domain(name => $name, vm => 'Proxmox'
        , id_iso => search_id_iso('Alpine'), id_owner => user_admin->id
        , disk => 1024 * 1024 * 1024, storage => 'shared');
    wait_request();
    is($req->error, '');
    my $base = rvd_back->search_domain($name) or return;

    $req = Ravada::Request->set_base_vm(uid => user_admin->id, id_domain => $base->id
        , id_vm => $node2->id, value => 1);
    wait_request();
    is($req->error, '');
    ok($base->is_base, "prepared as base");
    is($base->pve_config(1)->{template}, 1, "template");
    is($base->base_in_vm($node2->id), 1, "enabled in pve2");
    is($base->base_in_vm($vm->id), 1, "enabled in pve1");
    is($base->node, 'pve1', "template not moved");
    ok($base->_base_files_in_vm($node2), "base volumes visible from pve2");
    $base->is_public(1);

    # a clone created from the second node is a linked clone with target
    my $name_clone = new_domain_name();
    my $clone = $node2->create_domain(name => $name_clone, id_base => $base->id
        , id_owner => $USER->id);
    ok($clone, "clone created from pve2") or return;
    is($clone->node, 'pve2', "clone lives in pve2");
    is($clone->_vm->id, $node2->id);
    my ($disk) = $clone->list_volumes_info(device => 'disk');
    like($disk->file, qr{^shared:\d+/base-\d+-disk-0[^/]*/\d+/vm-}, "linked clone in shared storage ".$disk->file);
    $clone->start(user => $USER, remote_ip => '10.1.1.2');
    ok($clone->is_active, "clone active in pve2");
    my ($display) = $clone->display_info($USER);
    is($display->{ip}, '192.0.2.12', "display in pve2");
    $clone->shutdown_now($USER);

    # a volatile clone is balanced to the node with more free memory
    $base->volatile_clones(1);
    my $name_v = new_domain_name();
    $req = Ravada::Request->clone(uid => $USER->id, id_domain => $base->id, name => $name_v
        , remote_ip => '10.1.1.3');
    wait_request();
    is($req->error, '');
    my $volatile = rvd_back->search_domain($name_v);
    ok($volatile, "volatile clone") or return;
    ok($volatile->is_active, "volatile clone running");
    is($volatile->node, 'pve2', "balanced to the node with more free memory") or diag($volatile->node);
    is(Ravada::Front::Domain->open($volatile->id)->node, 'pve2', "node stored");
    $req = Ravada::Request->shutdown_domain(uid => user_admin->id, id_domain => $volatile->id, timeout => 2);
    wait_request(check_error => 0);
    $req = Ravada::Request->refresh_machine(uid => user_admin->id, id_domain => $volatile->id);
    wait_request(check_error => 0);
    $volatile->_data('date_status_change' => '2000-01-01 00:00:00');
    $req = Ravada::Request->shutdown_domain(uid => user_admin->id, id_domain => $volatile->id);
    wait_request(check_error => 0);
    ok(!rvd_back->search_domain($name_v), "volatile clone removed");
    $base->volatile_clones(0);

    # migrate the clone back and forth, linked clones on shared storage can move
    $req = Ravada::Request->migrate(uid => user_admin->id, id_domain => $clone->id, id_node => $vm->id);
    wait_request();
    is($req->error, '');
    is(rvd_back->search_domain($name_clone)->node, 'pve1', "clone migrated to pve1");

    # migrate and start a clone in a chosen node
    $req = Ravada::Request->migrate(uid => user_admin->id, id_domain => $clone->id
        , id_node => $node2->id, start => 1, remote_ip => '10.1.1.2');
    wait_request();
    is($req->error, '');
    my $started = rvd_back->search_domain($name_clone);
    ok($started->is_active, "clone started");
    is($started->node, 'pve2', "started in the chosen node") or diag($started->node);

    # ports can not be exposed
    eval { $started->expose(port => 22, name => 'ssh') };
    like("$@", qr/not available/, "expose refused");

    $req = Ravada::Request->remove_domain(uid => user_admin->id, name => $name_clone);
    wait_request();
    is($req->error, '');

    $req = Ravada::Request->remove_base_vm(uid => user_admin->id, id_domain => $base->id, id_vm => $node2->id);
    wait_request();
    is($req->error, '');
    is($base->base_in_vm($node2->id), 0, "disabled in pve2");
    ok($base->is_base, "still a base");

    $req = Ravada::Request->remove_domain(uid => user_admin->id, name => $name);
    wait_request();
    is($req->error, '');
}

sub test_nodes_all {
    my $api = Ravada::Proxmox::API->new_client(url => 'mock://nodes_all');
    $api->reset();
    local %Ravada::VM::Proxmox::CONFIG;
    my $vm_all = Ravada::VM::Proxmox->new_from_config({
        url => 'mock://nodes_all', node => 'pve1', nodes => 'all', storage => 'local'
    });
    ok($vm_all, "primary node from config with nodes: all");
    my @vms = rvd_front->list_vms('Proxmox');
    my ($pve2) = grep { $_->{hostname} eq 'pve2' } @vms;
    ok($pve2, "all nodes discovered") or diag(Dumper(\@vms));
    $api->reset();
}

######################################################################

my $node2 = test_add_node_from_front();
if ($node2) {
    test_base_local_storage($node2);
    test_base_shared_storage($node2);
}
test_nodes_all();

end();
done_testing();
