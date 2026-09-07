package Ravada::Volume::Proxmox;

use warnings;
use strict;

=head1 NAME

Ravada::Volume::Proxmox - Volume of a Proxmox virtual machine

=head1 DESCRIPTION

Proxmox volumes are identified by a volume id like
C<local:100/vm-100-disk-0.qcow2>. Cloning and base preparation are done
at the virtual machine level through the Proxmox API, so the per volume
operations of the other volume classes are not available here.

=cut

use Carp qw(confess);
use Data::Dumper;
use Moose;

extends 'Ravada::Volume';
with 'Ravada::Volume::Class';

no warnings "experimental::signatures";
use feature qw(signatures);

has 'clone_base_after_prepare' => (
    isa => 'Int'
    ,is => 'rw'
    ,default => sub { 0 }
);

sub capacity($self) {
    my $info = $self->info;
    return $info->{capacity} if $info && defined $info->{capacity};
    return 0 if !$self->file || !$self->vm;
    return $self->vm->_volume_size($self->file);
}

sub prepare_base($self) {
    confess "Error: Proxmox volumes are prepared as base converting the machine to a template";
}

sub backing_file($self) {
    my $file = $self->file;
    return if !$file;
    if ($file =~ m{^([^:]+):(\d+)/(base-\d+-[^/]+)/\d+/}) {
        return "$1:$2/$3";
    }
    return;
}

sub clone($self, $file_clone) {
    confess "Error: Proxmox volumes are cloned through the domain clone API";
}

sub spinoff($self) {
    confess "Error: Proxmox volumes are spinned off through the domain API";
}

sub clone_filename($self, $name=undef) {
    return $self->file;
}

sub base_filename($self) {
    return $self->file;
}

sub base_extension($self) {
    return '';
}

sub compact($self, $keep_backup=1) {
    die "Error: compact is not available for Proxmox volumes\n";
}

sub backup($self) {
    die "Error: volume backups are managed by Proxmox\n";
}

sub rebase($self, $new_base) {
    die "Error: rebase is not available for Proxmox volumes\n";
}

1;
