package Ravada::Proxmox::API;

use warnings;
use strict;

=head1 NAME

Ravada::Proxmox::API - Minimal client for the Proxmox VE REST API

=head1 SYNOPSIS

    my $api = Ravada::Proxmox::API->new_client(
        url => 'https://pve.example.com:8006'
        ,token_id => 'ravada@pve!rvd'
        ,token_secret => '....'
    );
    my $nodes = $api->get('/nodes');
    my $upid = $api->post("/nodes/pve1/qemu/100/status/start");
    $api->wait_task('pve1', $upid);

When the url starts with C<mock://> an in-process mock of the API is
returned instead. It is used by the test suite.

=cut

use Carp qw(confess croak);
use Data::Dumper;
use Mojo::URL;
use Moose;

no warnings "experimental::signatures";
use feature qw(signatures);

has 'url' => ( is => 'ro', isa => 'Str', required => 1 );
has 'token_id' => ( is => 'ro', isa => 'Maybe[Str]' );
has 'token_secret' => ( is => 'ro', isa => 'Maybe[Str]' );
has 'user' => ( is => 'ro', isa => 'Maybe[Str]' );
has 'password' => ( is => 'ro', isa => 'Maybe[Str]' );
has 'insecure' => ( is => 'ro', isa => 'Bool', default => 0 );
has 'ca' => ( is => 'ro', isa => 'Maybe[Str]' );
has 'timeout' => ( is => 'ro', isa => 'Int', default => 30 );
has 'task_timeout' => ( is => 'rw', isa => 'Int', default => 600 );
has 'retries' => ( is => 'rw', isa => 'Int', default => 2 );

our %VALID_ARGS = map { $_ => 1 }
    qw(url token_id token_secret user password insecure ca timeout task_timeout);

=head2 new_client

Returns a client for the API. Unknown arguments are ignored so the whole
C<proxmox> section of the config file can be passed.

=cut

sub new_client($class, %args) {
    my $url = $args{url} or confess "Error: missing Proxmox API url";
    my %valid = map { $_ => $args{$_} } grep { $VALID_ARGS{$_} } keys %args;
    for my $field (keys %valid) {
        delete $valid{$field} if !defined $valid{$field};
    }
    if ($url =~ m{^mock://}) {
        require Ravada::Proxmox::API::Mock;
        return Ravada::Proxmox::API::Mock->new(%valid);
    }
    return $class->new(%valid);
}

sub is_mock { return 0 }

sub _ua($self) {
    return $self->{_ua} if $self->{_ua};
    require Mojo::UserAgent;
    my $ua = Mojo::UserAgent->new(
        connect_timeout => 10
        ,request_timeout => $self->timeout
        ,max_redirects => 0
    );
    $ua->insecure(1) if $self->insecure;
    $ua->ca($self->ca) if $self->ca;
    $self->{_ua} = $ua;
    return $ua;
}

sub _base_url($self) {
    my $base = $self->url;
    $base =~ s{/+$}{};
    $base = "https://$base" if $base !~ m{^\w+://};
    $base .= ":8006" if $base !~ m{^\w+://[^/]+:\d+};
    $base .= "/api2/json" if $base !~ m{/api2/json$};
    return $base;
}

sub _full_url($self, $path) {
    $path = "/$path" if $path !~ m{^/};
    return $self->_base_url().$path;
}

sub _login($self) {
    confess "Error: missing user or password for Proxmox API"
    if !defined $self->user || !defined $self->password;

    my $tx = $self->_ua->post($self->_full_url('/access/ticket')
        => { Accept => 'application/json' }
        => form => { username => $self->user, password => $self->password }
    );
    my $res = $tx->result;
    Ravada::Proxmox::API::Error->throw(
        code => $res->code, message => "login failed: ".$res->message
        ,method => 'POST', path => '/access/ticket'
    ) if !$res->is_success;

    my $data = $res->json->{data};
    $self->{_ticket} = $data->{ticket};
    $self->{_csrf} = $data->{CSRFPreventionToken};
    $self->{_ticket_time} = time;
}

=head2 auth_headers

Returns the HTTP headers that authenticate a request, for example to
open a websocket to the API from another client.

=cut

sub auth_headers($self, $method='GET') {
    return $self->_headers($method);
}

=head2 websocket_url

Returns the websocket url of an API path with its query parameters

=cut

sub websocket_url($self, $path, $params={}) {
    my $url = Mojo::URL->new($self->_full_url($path));
    $url->query(%$params) if keys %$params;
    my $scheme = $url->scheme;
    $scheme = 'wss' if $scheme eq 'https';
    $scheme = 'ws' if $scheme eq 'http';
    $scheme = 'wss' if $scheme eq 'mock';
    $url->scheme($scheme);
    return $url->to_string;
}

sub _headers($self, $method) {
    my %headers = ( Accept => 'application/json' );
    if ($self->token_id) {
        confess "Error: missing token_secret for token ".$self->token_id
        if !defined $self->token_secret;
        $headers{Authorization} = "PVEAPIToken=".$self->token_id."=".$self->token_secret;
    } else {
        $self->_login()
        if !$self->{_ticket} || time - $self->{_ticket_time} > 3600;
        $headers{Cookie} = "PVEAuthCookie=".$self->{_ticket};
        $headers{CSRFPreventionToken} = $self->{_csrf} if $method ne 'GET';
    }
    return \%headers;
}

=head2 request

Sends a request to the API and returns the C<data> field of the answer.
Dies with a L<Ravada::Proxmox::API::Error> on failure.

=cut

sub request($self, $method, $path, $params = {}) {
    my $tries = 1;
    $tries += $self->retries if $method eq 'GET';
    my $result;
    for my $try ( 1 .. $tries ) {
        eval { $result = $self->_request($method, $path, $params) };
        my $err = $@;
        return $result if !$err;
        # retry only when there was no answer at all from the server
        die $err if $try == $tries || !ref($err) || $err->code;
        $self->_sleep(1);
    }
    return $result;
}

sub _request($self, $method, $path, $params = {}) {
    my $ua = $self->_ua;
    my $headers = $self->_headers($method);
    my $url = Mojo::URL->new($self->_full_url($path));

    my $tx;
    if ($method eq 'GET' || $method eq 'DELETE') {
        $url->query(%$params) if keys %$params;
        $tx = $ua->build_tx($method => $url => $headers);
    } else {
        $tx = $ua->build_tx($method => $url => $headers => form => $params);
    }
    $tx = $ua->start($tx);
    if (my $err = $tx->error) {
        Ravada::Proxmox::API::Error->throw(
            code => ($err->{code} or 0)
            ,message => ($self->_error_message($tx) or $err->{message})
            ,method => $method, path => $path
        );
    }
    my $json = $tx->result->json;
    return if !$json;
    return $json->{data};
}

sub _error_message($self, $tx) {
    my $res = $tx->res;
    my $message = $res->message;
    my $json = eval { $res->json };
    if ($json && ref($json) eq 'HASH' && $json->{errors}) {
        my $errors = $json->{errors};
        if (ref($errors) eq 'HASH') {
            $message .= " : ".join(", ", map { "$_ ".$errors->{$_} } sort keys %$errors);
        } else {
            $message .= " : $errors";
        }
    }
    return $message;
}

sub get($self, $path, $params = {})    { return $self->request('GET', $path, $params) }
sub post($self, $path, $params = {})   { return $self->request('POST', $path, $params) }
sub put($self, $path, $params = {})    { return $self->request('PUT', $path, $params) }
sub delete($self, $path, $params = {}) { return $self->request('DELETE', $path, $params) }

=head2 wait_task

Waits until an asynchronous task finishes. Dies if the task failed.

    $api->wait_task($node, $upid);

=cut

sub wait_task($self, $node, $upid, $timeout = undef) {
    return if !defined $upid || $upid !~ /^UPID:/;

    $node = node_of_upid($upid) if !$node;
    $timeout = $self->task_timeout if !defined $timeout;

    my $t0 = time;
    for (;;) {
        my $status = $self->get("/nodes/$node/tasks/$upid/status");
        if ( ($status->{status} or '') eq 'stopped' ) {
            my $exit = ($status->{exitstatus} or '');
            return $status if $exit eq 'OK';
            my $log = '';
            eval { $log = $self->task_log($node, $upid) };
            Ravada::Proxmox::API::Error->throw(
                code => 500
                ,message => "task $status->{type} failed: $exit\n$log"
                ,method => 'TASK', path => $upid
            );
        }
        Ravada::Proxmox::API::Error->throw(
            code => 504
            ,message => "timeout waiting for task"
            ,method => 'TASK', path => $upid
        ) if time - $t0 > $timeout;

        $self->_sleep(1);
    }
}

sub _sleep($self, $seconds) {
    sleep $seconds;
}

sub task_log($self, $node, $upid) {
    my $lines = $self->get("/nodes/$node/tasks/$upid/log", { limit => 50 });
    return join("\n", map { $_->{t} } @$lines);
}

=head2 node_of_upid

Returns the node name encoded in a task id

=cut

sub node_of_upid($upid) {
    my ($node) = $upid =~ /^UPID:([^:]+):/;
    return $node;
}

=head2 parse_key_value

Parses a Proxmox property string like C<virtio=AA:BB,bridge=vmbr0> into
a hash. The first item without a key is returned as C<_first>.

=cut

sub parse_key_value($string) {
    my %data;
    return \%data if !defined $string;
    my $n = 0;
    for my $item (split /,/, $string) {
        if ($item =~ /^([^=]+)=(.*)$/) {
            $data{$1} = $2;
        } elsif ($n == 0) {
            $data{_first} = $item;
        }
        $n++;
    }
    return \%data;
}

=head2 format_key_value

Reverse of parse_key_value

=cut

sub format_key_value($data) {
    my @items;
    push @items, ($data->{_first}) if defined $data->{_first};
    for my $key (sort keys %$data) {
        next if $key eq '_first';
        next if !defined $data->{$key};
        push @items, ("$key=$data->{$key}");
    }
    return join(",", @items);
}

package Ravada::Proxmox::API::Error;

use overload '""' => \&stringify, fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}

sub throw {
    my $class = shift;
    die $class->new(@_);
}

sub code    { return $_[0]->{code} }
sub message { return $_[0]->{message} }

sub stringify {
    my $self = shift;
    return "Proxmox API error ".($self->{code} or '')
        .": ".($self->{message} or '')
        ." [".($self->{method} or '')." ".($self->{path} or '')."]\n";
}

1;
