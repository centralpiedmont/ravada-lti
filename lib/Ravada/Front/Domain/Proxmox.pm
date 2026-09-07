package Ravada::Front::Domain::Proxmox;

use warnings;
use strict;

=head1 NAME

Ravada::Front::Domain::Proxmox - Frontend view of a Proxmox virtual machine

=head1 DESCRIPTION

Read only access to a virtual machine managed in a Proxmox VE cluster.
The hardware information comes from the last configuration stored in
the database by the backend. The SPICE display file is requested to
the Proxmox API directly because the ticket it contains is only valid
for a few seconds.

=cut

use Carp qw(confess croak);
use Data::Dumper;
use JSON::XS;
use Moose;

use Ravada::Proxmox::API;

no warnings "experimental::signatures";
use feature qw(signatures);

extends 'Ravada::Front::Domain';

our %GET_CONTROLLER_SUB = (
    disk => \&_get_controller_disk
    ,display => \&_get_controller_display
    ,network => \&_get_controller_network
);

our $RE_DISK = qr/^(scsi|virtio|ide|sata)(\d+)$/;
our @NET_MODELS = qw(virtio e1000 e1000e vmxnet3 rtl8139);

sub list_controllers {
    return %GET_CONTROLLER_SUB;
}

sub get_controller_by_name($self, $name) {
    return $GET_CONTROLLER_SUB{$name};
}

sub _get_controller_disk($self) {
    return Ravada::Front::Domain::_get_controller_disk($self);
}

sub _get_controller_display(@args) {
    return Ravada::Front::Domain::_get_controller_display(@args);
}

=head2 pve_config

Returns the Proxmox configuration of the virtual machine as a hash.
In the frontend it is the last copy stored in the database.

=cut

sub pve_config($self) {
    my $config = $self->_data_extra('config');
    return {} if !$config;
    my $data = eval { decode_json($config) };
    return {} if !$data || ref($data) ne 'HASH';
    return $data;
}

=head2 vmid

Returns the Proxmox vmid of this virtual machine

=cut

sub vmid($self) {
    return $self->_data_extra('vmid');
}

=head2 node

Returns the Proxmox node where this virtual machine is defined

=cut

sub node($self) {
    return $self->_data_extra('node');
}

sub _parse_net($value) {
    my $net = Ravada::Proxmox::API::parse_key_value($value);
    my ($model, $mac);
    for my $key (@NET_MODELS) {
        next if !exists $net->{$key};
        ($model, $mac) = ($key, $net->{$key});
        delete $net->{$key};
    }
    if (!$model && $net->{_first}) {
        $model = $net->{_first};
    }
    delete $net->{_first};
    return ( model => $model, mac => $mac, %$net );
}

sub _get_controller_network($self) {
    my $config = $self->pve_config();
    my @networks;
    my $n = 0;
    for my $key (sort keys %$config) {
        next if $key !~ /^net(\d+)$/;
        my %net = _parse_net($config->{$key});
        my $bridge = ($net{bridge} or '');
        push @networks, {
            _key => $key
            ,n_order => $n++
            ,driver => $net{model}
            ,hwaddr => $net{mac}
            ,type => 'bridge'
            ,bridge => $bridge
            ,name => $bridge
            ,_name => $bridge
            ,network => $bridge
            ,address => ''
            ,_can_edit => 1
            ,_can_remove => 1
        };
    }
    return @networks;
}

=head2 get_driver

Returns the driver of a hardware item ( network, video, cpu, disk )

=cut

sub get_driver($self, $name) {
    my $config = $self->pve_config();
    if ($name eq 'network') {
        my ($key) = sort grep { /^net\d+$/ } keys %$config;
        return if !$key;
        my %net = _parse_net($config->{$key});
        return $net{model};
    }
    return ($config->{vga} or 'std') if $name eq 'video';
    return ($config->{cpu} or 'kvm64') if $name eq 'cpu';
    if ($name eq 'disk') {
        my ($key) = sort grep { /^(scsi|virtio|sata)\d+$/ } keys %$config;
        return if !$key;
        my ($bus) = $key =~ /^([a-z]+)/;
        return $bus;
    }
    return $config->{$name} if exists $config->{$name};
    return;
}

sub _api_client($self) {
    return $self->{_api_client} if $self->{_api_client};
    my $args = $self->_api_connection_args();
    $self->{_api_client} = Ravada::Proxmox::API->new_client(%$args);
    return $self->{_api_client};
}

sub _api_connection_args($self) {
    my $id_vm = $self->_data('id_vm');
    if ($id_vm) {
        my $sth = $self->_dbh->prepare("SELECT connection_args FROM vms WHERE id=?");
        $sth->execute($id_vm);
        my ($json) = $sth->fetchrow;
        $sth->finish;
        if ($json) {
            my $args = eval { decode_json($json) };
            return $args if $args && ref($args) eq 'HASH' && $args->{url};
        }
    }
    return $Ravada::CONFIG->{proxmox}
    if $Ravada::CONFIG && $Ravada::CONFIG->{proxmox} && $Ravada::CONFIG->{proxmox}->{url};

    confess "Error: no Proxmox API connection information found for ".$self->name;
}

=head2 spice_proxy_data

Requests a new SPICE ticket to the Proxmox API and returns the data
for a virt-viewer file.

=cut

sub spice_proxy_data($self, $proxy=undef) {
    my $vmid = $self->vmid or confess "Error: unknown vmid for ".$self->name;
    my $node = $self->node or confess "Error: unknown node for ".$self->name;
    my %args;
    $args{proxy} = $proxy if $proxy;
    return $self->_api_client->post("/nodes/$node/qemu/$vmid/spiceproxy", \%args);
}

sub _display_file_spice($self, $display, $tls=0) {
    my $proxy;
    if (ref($display) && ref($display) ne 'HASH') {
        $display = undef;
    }
    $proxy = $display->{hostname} if $display && exists $display->{hostname} && $display->{hostname};
    my $data = $self->spice_proxy_data($proxy);
    my $ret = "[virt-viewer]\n";
    for my $key (qw(type host proxy tls-port password host-subject ca title
        delete-this-file release-cursor toggle-fullscreen secure-attention)) {
        next if !exists $data->{$key} || !defined $data->{$key};
        $ret .= "$key=".$data->{$key}."\n";
    }
    for my $key (sort keys %$data) {
        next if $ret =~ /^\Q$key\E=/m;
        $ret .= "$key=".$data->{$key}."\n";
    }
    $ret .= "fullscreen=1\n" if $ret !~ /^fullscreen=/m;
    return $ret;
}

sub _display_file_tls($self, $display=undef) {
    return $self->_display_file_spice($display, 1);
}

1;
