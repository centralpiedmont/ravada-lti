use warnings;
use strict;

no warnings "experimental::signatures";
use feature qw(signatures);

use Data::Dumper;
use Test::More;

use lib 't/lib';
use Test::Ravada;

use Ravada::Proxmox::API;
use Ravada::HostDevice;
use Ravada::HostDevice::Templates;

$Data::Dumper::Sortkeys = 1;

init('t/etc/ravada_proxmox.conf');
Ravada::Proxmox::API->new_client(url => 'mock://test')->reset();

my $rvd = rvd_back();
my $vm = $rvd->search_vm('Proxmox');
ok($vm, "Proxmox virtual manager") or BAIL_OUT("No Proxmox VM");

######################################################################

sub test_templates {
    my $templates = Ravada::HostDevice::Templates::list_templates($vm->type);
    ok(scalar(@$templates), "templates for Proxmox");
    my @names = map { $_->{name} } @$templates;
    ok(grep({ $_ eq 'PCI' } @names), "PCI template") or diag(Dumper(\@names));
    ok(grep({ /USB/ } @names), "USB template");

    my ($out, $err) = $vm->run_command('pve-list-pci');
    is($err, '');
    my @lines = grep { /\S/ } split /\n/, $out;
    is(scalar(@lines), 3, "pci devices without the host bridge") or diag($out);
    like($lines[0], qr/^0000:01:00\.0 10de:1c82 NVIDIA/, "lspci like line") or diag($out);

    ($out, $err) = $vm->run_command('pve-list-usb');
    @lines = grep { /\S/ } split /\n/, $out;
    is(scalar(@lines), 2, "usb devices without the hub") or diag($out);
    like($lines[0], qr/^Bus 001 Device 003: ID 0781:5567 SanDisk/, "lsusb like line");

    ($out, $err) = $vm->run_command('pve-list-mdev');
    @lines = grep { /\S/ } split /\n/, $out;
    is(scalar(@lines), 2, "mediated device types") or diag($out);
    like($lines[0], qr/^0000:01:00\.0 mdev=nvidia-63/, "mdev line");
}

sub test_pci($template, $expected_devices, $re_config) {
    my $id_hd = $vm->add_host_device(template => $template);
    ok($id_hd, "host device $template added") or return;
    my $hd = Ravada::HostDevice->search_by_id($id_hd);
    my @devices = $hd->list_devices();
    is(scalar(@devices), $expected_devices, "$template devices") or diag(Dumper(\@devices));

    my $base_name = new_domain_name();
    my $req = Ravada::Request->create_domain(name => $base_name, vm => 'Proxmox'
        , id_iso => search_id_iso('Alpine'), id_owner => user_admin->id
        , disk => 1024 * 1024 * 1024);
    wait_request();
    is($req->error, '');
    my $domain = rvd_back->search_domain($base_name) or return;
    $domain->add_host_device($hd);
    my @hds = $domain->list_host_devices();
    is(scalar(@hds), 1, "host device in domain");

    $req = Ravada::Request->start_domain(uid => user_admin->id, id_domain => $domain->id, remote_ip => '10.1.1.1');
    wait_request();
    is($req->error, '');
    my $domain2 = rvd_back->search_domain($base_name);
    ok($domain2->is_active, "started with host device");
    my $config = $domain2->pve_config(1);
    my ($key) = grep { /^(hostpci|usb)\d+$/ } keys %$config;
    ok($key, "device attached in the config") or diag(Dumper($config));
    like($config->{$key}, $re_config, "config value $config->{$key}") if $key;
    my @attached = $domain2->list_host_devices_attached();
    is(scalar(@attached), 1, "one device attached") or diag(Dumper(\@attached));
    my @available = $hd->list_available_devices();
    is(scalar(@available), $expected_devices - 1, "one device locked") or diag(Dumper(\@available));

    # a second machine with the same device takes the second one
    my $name2 = new_domain_name();
    $req = Ravada::Request->create_domain(name => $name2, vm => 'Proxmox'
        , id_iso => search_id_iso('Alpine'), id_owner => user_admin->id
        , disk => 1024 * 1024 * 1024);
    wait_request();
    my $other = rvd_back->search_domain($name2);
    $other->add_host_device($hd);
    $req = Ravada::Request->start_domain(uid => user_admin->id, id_domain => $other->id, remote_ip => '10.1.1.1');
    wait_request(check_error => 0);
    if ($expected_devices > 1) {
        is($req->error, '', "second machine gets the second device");
        my $config2 = rvd_back->search_domain($name2)->pve_config(1);
        my ($key2) = grep { /^(hostpci|usb)\d+$/ } keys %$config2;
        ok($key2 && $config2->{$key2} ne $config->{$key}, "different device ".($config2->{$key2} or ''))
            or diag(Dumper($config2));
    } else {
        like($req->error, qr/No available devices/, "no more devices");
    }

    # shutdown releases the device and cleans the config, locks are kept
    # for a while after a shutdown so we age them here
    my $sth = connector->dbh->prepare("UPDATE host_devices_domain_locked SET time_changed=0 WHERE id_domain=?");
    $sth->execute($domain->id);
    $req = Ravada::Request->shutdown_domain(uid => user_admin->id, id_domain => $domain->id, timeout => 2);
    wait_request();
    is($req->error, '');
    $domain2 = rvd_back->search_domain($base_name);
    ok(!$domain2->is_active, "shut down");
    $config = $domain2->pve_config(1);
    my @keys = grep { /^(hostpci|usb)\d+$/ } keys %$config;
    is(scalar(@keys), 0, "device removed from the config on shutdown") or diag(Dumper($config));
    is(scalar($domain2->list_host_devices_attached(1)), 0, "no device locked");
    is(scalar($hd->list_available_devices()), $expected_devices - ($expected_devices > 1 ? 1 : 0)
        , "device released") or diag(Dumper([$hd->list_available_devices()]));

    for my $name ($base_name, $name2) {
        $req = Ravada::Request->remove_domain(uid => user_admin->id, name => $name);
        wait_request();
        is($req->error, '');
    }
    $hd->remove();
}

######################################################################

test_templates();
test_pci('PCI', 3, qr/^0000:0[123]:00\.0$/);
test_pci('USB device', 2, qr/^host=[0-9a-f]{4}:[0-9a-f]{4}$/);
test_pci('GPU Mediated Device', 2, qr/^0000:0[12]:00\.0,mdev=nvidia-63$/);

end();
done_testing();
