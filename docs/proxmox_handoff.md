# Proxmox Backend Handoff

Everything below is on `main` (pull requests #1 and #2 of this fork). This
note is for continuing the work on a machine with access to a real Proxmox
VE cluster. The design and the per feature status are in
`docs/proxmox_backend.md`; this file is about where the code is, how to
run it, what has only been checked against the mock, and what to verify
first against real nodes.

## What Exists

New modules, all under `lib/Ravada/`:

| File | Role |
|---|---|
| `Proxmox/API.pm` | REST client over `Mojo::UserAgent`. API token or user and password, task polling (`wait_task`), GET retry, `websocket_url` and `auth_headers` for the console relay. `new_client(url => 'mock://name')` returns the mock. |
| `Proxmox/API/Mock.pm` | In-process emulation of a two node cluster (`pve1`, `pve2`), three storages (`local` dir, `local-lvm`, `shared` nfs), bridges, hardware lists, an SDN zone `ravada`, templates and linked clones, migration, spiceproxy and vncproxy tickets, guest agent, snapshots. State in `/var/tmp/rvd_proxmox_mock/<user>/<name>.yml`. |
| `VM/Proxmox.pm` | One virtual manager per node. Connection settings, storage, ISO download, machine creation, node lookup of templates, SDN networks, hardware listing for host devices. |
| `Domain/Proxmox.pm` | Machine lifecycle, volumes as config keys, hardware changes, base as template, dettach and spinoff as full clones, migration, host device config editing, snapshots. |
| `Front/Domain/Proxmox.pm` | Read only view for `rvd_front`: cached config, network controller, SPICE `.vv` from `spiceproxy`, VNC ticket and websocket address for the console. |
| `Volume/Proxmox.pm` | Volume ids instead of files. |
| `HostDevice/Templates.pm` | `@TEMPLATES_PROXMOX` (USB, PCI, GPU mediated device). |

Core edits: backend registration and `proxmox` config schema in
`lib/Ravada.pm`, generic class resolution in `lib/Ravada/Front/Domain.pm`,
backend handling in `script/rvd_front` (new machine form, console routes),
driver seed rows, the `domains_proxmox` table, `connect_node` without ssh,
`remove_domain` falling back to the machine's node, `_check_vms`
reconnecting any local backend.

Tests in `t/proxmox/` with configs in `t/etc/ravada_proxmox*.conf`:

| Test | Covers |
|---|---|
| `10_api_mock.t` | The mock itself |
| `20_domain.t` | Direct object use: create, start, display file, pause, hibernate, volumes, memory, base, clone, rename, remove |
| `30_requests.t` | The same through requests, plus swap and data disks, hardware changes, volatile clones, dettach, migration, discover and import, frontend objects |
| `40_nodes.t` | Adding a node from the front, bases on local versus shared storage, clones on the second node, balancing, `nodes: all` |
| `50_host_devices.t` | PCI, USB and mediated device templates, locking, detach on shutdown |
| `60_networks.t` | SDN networks, networking mode, snapshots, console helpers |

## Running The Tests Locally

Perl packages are the ones the CI workflow installs
(`.github/workflows/github-action-test.yml`), plus `iproute2`, `net-tools`,
`bind9-host`, `iptables` and `gettext`, which some core paths shell out to
even with this backend. The tests use SQLite and need no cluster.

Run them as a normal user, not root: the harness's `end()` tries to unload
the nbd kernel module when it runs as root, and the Void tests create
per-user directories under `/var/tmp`.

```
prove -lr t/proxmox
prove -l t/30_request.t t/vm/60_new_args.t t/critic.t t/pod_coverage.t t/17_templates.t t/90_pos.t
```

The timezone warning from `timedatectl` is harmless. The mock state is
reset at the start of every test file; to inspect it after a failure read
the YAML file named above, or from Perl:

```perl
my $api = Ravada::Proxmox::API->new_client(url => 'mock://test');
my $state = $api->state;     # copy of the whole cluster
$api->modify_state(sub { my $s = shift; ... });
```

To trace API calls against a real cluster add a `warn "$method $path ".
Dumper($params)` at the top of `Ravada::Proxmox::API::_request`.

## Pointing It At A Real Cluster

Create the role, user and token on any node:

```
pveum role add Ravada -privs "VM.Allocate VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt VM.Console VM.Audit VM.Migrate VM.Snapshot VM.Snapshot.Rollback Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Sys.Audit"
pveum user add ravada@pve
pveum user token add ravada@pve rvd --privsep 0
pveum acl modify / --roles Ravada --users ravada@pve
```

`--privsep 0` makes the token inherit the user's permissions. Add
`SDN.Allocate SDN.Use Sys.Modify` to the role if you set `sdn_zone`, and
`Mapping.Use` if the cluster uses resource mappings for host devices.

Then in `/etc/ravada.conf`:

```yaml
vm:
  - Proxmox
proxmox:
  url: https://pve1.example.edu:8006
  token_id: ravada@pve!rvd
  token_secret: <secret printed by pveum>
  node: pve1
  nodes: all            # or a list, or omit for a single node
  storage: local        # storage for machine disks and ISO images
  bridge: vmbr0
  insecure: 1           # or ca: /path/to/pve-root-ca.pem
  # sdn_zone: ravada    # a simple zone with DHCP, for virtual networks
  # display_host: pve1.example.edu
```

`rvd_back` can run unprivileged on any host that reaches port 8006 of the
nodes; nothing needs ssh. Clients need port 3128 of each node (the spice
proxy) or of `display_host`. The first `rvd_back` start creates the `vms`
rows (the configured node as `localhost`, the others by name) and stores
the connection settings in `vms.connection_args`; edit that column or the
config file if the endpoint changes.

Order of first checks against a real cluster:

1. `rvd_back --debug` starts, the Nodes page lists the nodes as active,
   the storage list shows the Proxmox storages.
2. Create a machine from an ISO. The ISO is fetched with the storage
   `download-url` call, which needs the node itself to reach the internet.
   The disk spec sent is `storage:<GB as float>`; check the created disk
   size and that `ostype`, `vga: qxl` and `agent: 1` are set.
3. Start it, download the `.vv` file, connect with remote-viewer. The file
   is exactly what Proxmox's own GUI produces.
4. Wait for the guest agent, check the IP appears in the machine page.
5. Prepare it as a base (it becomes a template) and clone it. Linked
   clones need a storage that supports base images (dir with qcow2, LVM
   thin, ZFS, RBD, BTRFS); on others the code falls back to a full clone
   when the API refuses the linked one. Then start the clone.
6. Remove the base. The code sends `delete=template` to the config
   endpoint; Proxmox may refuse this on some versions. If it does, the
   documented alternative is a full clone of the template into a new VMID.
7. Hardware changes on a stopped machine: memory (sets `memory` and
   `balloon`), vCPUs (`cores` and `vcpus`), a second disk, a second
   interface, disk resize (size sent with a `K` suffix).
8. Migration to another node, offline with local disks (the code passes
   `with-local-disks`) and online with shared storage.
9. If there is a GPU or a USB device to test, add a host device from the
   admin page and start a machine with it. The API field names of
   `/nodes/<node>/hardware/pci` and `/hardware/usb` were taken from the
   documentation, not observed.
10. With `sdn_zone` set, create a network from the admin page and put a
    machine on it. Check the subnet `dhcp-range` format and that `PUT
    /cluster/sdn` returns a task id.
11. Open the browser console from the machine page. This is the least
    validated path: the relay in `script/rvd_front` (`/ws/console/<id>`)
    opens a websocket to `vncwebsocket` with the API token header and the
    `vncticket`. If Proxmox rejects the token on the websocket upgrade, the
    relay has to log in with user and password to get a `PVEAuthCookie`
    instead (the client already supports that authentication mode, it is
    only a matter of which headers `auth_headers` returns for websockets).

## Things Written From Documentation Only

These are the spots most likely to need a small correction once observed
against a real API:

- Error texts. `Ravada::Domain::Proxmox::_is_missing_error` matches "does
  not exist", "no such vm" and "not found" to decide a machine is gone.
- The `template` config key and `delete=template` (step 6 above).
- Linked clone volume ids: the code expects the `storage:<base vmid>/base-
  <n>-disk-<n>.<fmt>/<vmid>/vm-...` shape to detect a backing file; on LVM
  thin and ZFS the id has no path and `backing_file` returns nothing, which
  only affects the dettach and spinoff shortcuts.
- `hostpciN` and `usbN` value syntax, and the mediated device listing
  (`/hardware/pci/<id>/mdev`).
- SDN: subnet ids (`<zone>-<network>-<prefix>`), `dhcp-range` as a list of
  `start-address=...,end-address=...` strings, SNAT flag.
- `spiceproxy` returns the whole `.vv` content; `vncproxy` with
  `websocket=1`.
- Timing: every mutation waits for its task with `wait_task` (default
  timeout 600 seconds, 3600 for migrations). `shutdown` is sent with the
  Ravada timeout and not waited for, Ravada polls `is_active` itself.

## Design Decisions To Keep In Mind

- The configured node is the `localhost` row so Ravada's "local" logic
  applies to it. Other nodes are ordinary remote rows without ssh.
- `search_domain` on a node returns only machines on that node; the
  primary node finds templates on other nodes through `search_base` when
  cloning. Keep it that way, a cluster-wide search confused Ravada's
  instance tracking.
- Volatile clones are removed by Ravada's usual refresh path after the
  grace period (`$Ravada::Domain::TTL_REMOVE_VOLATILE`), not on shutdown,
  because the machine persists in Proxmox after it stops.
- Host device locks are kept for the same grace period after a shutdown;
  the test ages them by hand.
- Running machines always report their viewer as connected; the "shutdown
  when disconnected" option is a no-op for this backend.
- Caches: `Ravada::VM::Proxmox::$CACHE_TIMEOUT` (5 s) for node, storage
  and machine lists; `Ravada::Domain::Proxmox::$CONFIG_CACHE_TIMEOUT` (1 s)
  for the machine config. Storage content and SDN data are not cached
  because other objects and processes change them.

## Suggested Next Work

- A real cluster CI job on the self hosted runner: a second workflow that
  writes the config from repository secrets, uses a dedicated resource pool
  and a `tst_` name prefix, and runs `prove -lr t/proxmox` against
  `url: https://...` instead of `mock://`. The tests already avoid
  anything mock specific except the hardware lists and the SDN zone name.
- Screenshots through the VNC websocket (an RFB client requesting one raw
  frame), see the discussion in the session history; `can_screenshot`
  returns 0 today.
- Snapshot requests and UI; the domain methods exist.
- Packaging: `Makefile.PL` and `debian/control-*` still list `Sys::Virt`
  and libvirt as hard dependencies. `Ravada.pm` already loads
  `Sys::Virt` inside `eval`, so they can become optional.
- Real API observation of the items in the previous section, then trim
  the mock where it was too permissive (for example it accepts removing the
  template flag).
