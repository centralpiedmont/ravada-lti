# Running Ravada With Proxmox VE As The Backend

This document records what it would take to run this fork of Ravada against a
Proxmox VE cluster instead of libvirt/KVM. It is the result of a read through
of the backend abstraction, the KVM implementation, and every place outside the
backend classes that assumes KVM. Line numbers refer to the tree at the time of
writing (upstream Ravada 1.8.0).

## Short Answer

Ravada was built with pluggable hypervisors in mind, and the plumbing mostly
holds up: virtual managers and machines are Moose roles (`Ravada::VM`,
`Ravada::Domain`) with per-hypervisor classes resolved by name from the
`vms.vm_type` column, and all of the request queue, users, grants, bookings,
display bookkeeping and port exposure is hypervisor neutral. There is no
Proxmox backend today, upstream has an open request for one
([UPC/ravada#932](https://github.com/UPC/ravada/issues/932)) and a wiki page of
notes, but no code.

Adding Proxmox means writing three new classes (`Ravada::VM::Proxmox`,
`Ravada::Domain::Proxmox`, `Ravada::Front::Domain::Proxmox`) against the
Proxmox REST API, plus a few hundred lines of changes to the core where KVM is
hardcoded. The Void backend, which is a fake hypervisor used by the test suite,
is the right template: it implements the same contract in about 2,200 lines
without libvirt or XML. The KVM backend is about 7,700 lines, but roughly two
thirds of that is libvirt XML manipulation that has no Proxmox equivalent.

The parts that do not map cleanly are the display path (Proxmox hands out
short-lived SPICE proxy tickets rather than a fixed host:port with a password),
the base/clone model (Proxmox templates are one way, and linked clones must
stay on the same storage), volumes (Ravada works with file paths and
`qemu-img`, Proxmox works with `storage:volid` handles), and host devices
(Ravada's templates are libvirt XML fragments). Each is solvable, and each is
discussed below.

## Implementation Status

The backend described below is implemented in this branch and exercised
against an in-process mock of the Proxmox API in `t/proxmox/`. What works
today:

- `Ravada::VM::Proxmox`, `Ravada::Domain::Proxmox`,
  `Ravada::Front::Domain::Proxmox` and `Ravada::Volume::Proxmox`, plus the
  API client `Ravada::Proxmox::API` (API token or user and password
  authentication, task polling) and its mock `Ravada::Proxmox::API::Mock`.
- One `vms` row per cluster node. The node named in the `proxmox` section is
  stored as `localhost` so Ravada treats it as the main node; nodes listed in
  `nodes` get their own row. Connection settings are stored in
  `vms.connection_args`.
- Creating machines from an ISO (ISO download through the storage
  `download-url` call), system, swap and data disks, memory and CPU changes,
  network interfaces on bridges, disk resize, display driver switch between
  SPICE (`vga: qxl`) and VNC.
- Lifecycle: start, ACPI shutdown, forced stop, reboot, pause, resume,
  hibernate (suspend to disk), rename, autostart, remove.
- SPICE access through the Proxmox `spiceproxy` ticket. The `.vv` file is
  requested from the API when the user downloads it, in `rvd_front`, using the
  connection settings stored for the node. No firewall rule is opened on the
  node.
- Bases as templates and clones as linked clones, with a full clone fallback
  when the storage does not support linked clones. `remove_base` removes the
  template flag. Dettach and spinoff replace the machine by a full clone.
  Volatile clones are removed by the usual refresh path after the grace
  period.
- Migration between nodes through the API, online when the machine is
  running, copying local disks when the storage is not shared. Nothing is
  rsynced, and a migration request with `start` starts the machine in the
  chosen node.
- Multi-node: a template whose disks are on shared storage can be enabled
  in other nodes (the Nodes tab of the base, `set_base_vm`), clones are then
  created directly in the node picked by Ravada's balancing as linked clones
  with a target node. A template on local storage is refused with a message
  saying which volumes to move. Nodes can be added from the Nodes page of the
  admin with only the node name, the connection check does not need ssh, and
  `nodes: all` in the config registers every node of the cluster.
- Discovery and import of machines that already exist in the cluster.
- The guest IP through the QEMU guest agent.

Not implemented yet: host devices (PCI, USB, mediated devices), Proxmox
SDN networks (bridges only, `has_networking` is off), screenshots, backups
and compaction (both are Proxmox features), snapshots, port exposure
(machines are on a bridge, `expose` refuses with a message) and the
client connection check (running machines always report as connected, so
"shutdown when disconnected" does not apply).

Configuration example:

```yaml
vm:
  - Proxmox
proxmox:
  url: https://pve.example.com:8006
  token_id: ravada@pve!rvd
  token_secret: 00000000-0000-0000-0000-000000000000
  node: pve1
  nodes:
    - pve2
  storage: local
  bridge: vmbr0
  insecure: 0
  ca: /etc/ssl/certs/pve-ca.pem
```

`user` and `password` can be used instead of the token. `insecure: 1`
skips the TLS verification of the API certificate. `nodes` accepts a list
of node names or `all`. `display_host` overrides the address written in
the SPICE file when clients reach the nodes through another name. The token needs
`VM.Allocate`, `VM.Clone`, `VM.Config.*`, `VM.PowerMgmt`, `VM.Console`,
`VM.Audit`, `VM.Migrate`, `Datastore.AllocateSpace`,
`Datastore.AllocateTemplate`, `Datastore.Audit` and `Sys.Audit`.

The tests run with `prove -lr t/proxmox`. The mock keeps its state in
`/var/tmp/rvd_proxmox_mock/<user>/<name>.yml`, selected by a url like
`mock://name` in the config.

## How The Backend Abstraction Works Today

`Ravada::VM` (`lib/Ravada/VM.pm`) is the virtual manager role. It declares 13
required methods (`connect`, `disconnect`, `create_domain`, `search_domain`,
`list_domains`, `create_volume`, `list_storage_pools`, `import_domain`,
`is_alive`, `free_memory`, `free_disk`, `_fetch_dir_cert`, `remove_file`) and
supplies everything else: the `vms` table access, node balancing, ssh and
`run_command` to remote nodes, iptables helpers, shared storage detection,
network CRUD wrappers, and TLS certificate caching.

`Ravada::Domain` (`lib/Ravada/Domain.pm`) is the machine role. It declares 39
required methods covering lifecycle (`start`, `shutdown`, `pause`,
`hibernate`, ...), volumes (`add_volume`, `list_volumes_info`, ...), hardware
(`change_hardware`, `set_controller`, `get_driver`, ...) and `display_info`.
It supplies `prepare_base`, `clone`, `remove_base`, `set_base_vm`, port
exposure, display persistence in `domain_displays`, the `.vv` and `.rdp` file
generators, backups, and the request side effects around every operation.

Beyond the declared `requires`, both roles call a second, undeclared set of
methods on the concrete class. For the VM these include `dir_img`,
`_storage_path`, `file_exists`, `search_volume_path_re`, `_search_iso`,
`_iso_name`, `list_virtual_networks`, `discover`, `get_library_version`,
`list_machine_types` and `get_cpu_model_names`. For the domain they include
`ip`, `ip_info`, `list_disks`, `remove_disks`, `type`, `internal_id`,
`can_screenshot`, `can_hibernate`, `can_host_devices`,
`_has_builtin_display`, `_is_display_builtin`, `_set_displays_ip`, and the
config editing protocol (`get_config`, `reload_config`, `add_config_node`,
`add_config_unique_node`, `set_config_node`, `remove_config_node`,
`change_config_attribute`). `lib/Ravada/Domain/Void.pm` is the canonical list
of what a minimal backend has to provide.

Class resolution is by string. `Ravada::VM->open(id)` blesses into
`"Ravada::VM::$vm_type"` (`lib/Ravada/VM.pm:236`), `Ravada::Domain->open`
gets its concrete object from `$vm->search_domain` (`lib/Ravada/Domain.pm:2033`),
and `Ravada::Front::Domain->open` is a hardcoded if/elsif on `KVM` and `Void`
(`lib/Ravada/Front/Domain.pm:56`). `Ravada::search_vm` uppercases the type
before comparing class names (`lib/Ravada.pm:6949`), which only works for
`KVM`.

The backend list is fixed at load time in `lib/Ravada.pm:40` (`%VALID_VM`,
populated by `require`ing `Ravada::VM::KVM` and `Ravada::VM::Void` inside
`eval`), filtered by the `vm:` list in `/etc/ravada.conf`, and instantiated by
a hardcoded dispatch hash in `_create_vm` (`lib/Ravada.pm:3431`).

## Concept Mapping

| Ravada / libvirt concept | Proxmox VE equivalent | Notes |
|---|---|---|
| `Sys::Virt` connection `qemu+ssh://root@host/system` | HTTPS REST client to `https://cluster:8006/api2/json`, API token auth | One endpoint serves the whole cluster. Store endpoint and token in `vms.connection_args` (exists, unused) or `ravada.conf`. |
| One `vms` row per hypervisor host | One `vms` row per PVE node, `hostname` = node name | Keeps node balancing, `domain_instances` and `bases_vm` working unchanged. |
| Domain XML | VM config hash from `GET /nodes/{node}/qemu/{vmid}/config` | Key/value, e.g. `memory`, `cores`, `net0`, `scsi0`, `vga`, `agent`. Written back with `PUT`/`POST .../config`. |
| Libvirt UUID (`domains.internal_id`) | Integer VMID | Allocate with `GET /cluster/nextid`. Store in `internal_id` and in a new `domains_proxmox` side table. |
| Storage pool (dir of files) | Storage ID (`local`, `local-lvm`, `ceph`, ...) | `GET /nodes/{node}/storage` gives type, `shared`, `content`, `avail`. |
| Volume file path `/var/lib/libvirt/images/x.qcow2` | Volume ID `local:100/vm-100-disk-0.qcow2` | Ravada stores this string in `volumes.file`. |
| Base machine with `.ro.` files + `base_xml` | VM converted to a template (`POST .../template`) | One way in Proxmox. See below. |
| Clone with qcow2 backing file (`qemu-img create -b`) | Linked clone (`POST .../clone`, `full=0`) | Only from a template, same storage, storage must support base images (dir with qcow2, LVM thin, ZFS, RBD, BTRFS). |
| `spinoff` / `dettach` (flatten backing chain) | Full clone (`full=1`) or `move_disk` | |
| SPICE `<graphics>` with autoport + passwd + listen IP | `POST .../spiceproxy` returns a complete `.vv` payload with a ticket valid for about 30 seconds | Connection goes through `spiceproxy` on port 3128 of the node, TLS, no per VM port. |
| VNC | `POST .../vncproxy` (+ `websocket=1`) and `.../vncwebsocket` | Enables an in browser noVNC console, which Ravada does not have today. |
| iptables rule per client IP per display port | Not needed | The proxy ticket is the authorization. |
| `managed_save` (hibernate) | `POST .../status/suspend` with `todisk=1` | `resume` wakes it. |
| `set_time` via guest agent | `POST .../agent/exec` | No dedicated time call; run `date`/`w32tm` through the agent, or rely on NTP. |
| IP from DHCP leases / guest agent | `GET .../agent/network-get-interfaces` | Requires the QEMU guest agent in the guest, as today for the agent path. |
| Migration = define on target + rsync disks | `POST .../migrate` (`target`, `online`, `with-local-disks`) | Cluster handles it. Live migration comes for free. |
| `free_memory` from `get_node_memory_stats` | `GET /nodes/{node}/status` | |
| `list_machine_types` / `get_cpu_model_names` | `GET /nodes/{node}/capabilities/qemu/machines` and `.../cpu` | |
| Virtual networks (libvirt NAT with dnsmasq) | Bridges (`GET /nodes/{node}/network`) and SDN zones/vnets | Simplest first step: `has_networking => 0`, bridges only. |
| Host devices via libvirt `<hostdev>` XML templates | `hostpci0`, `usb0`, `mdev=` config keys, lists from `GET /nodes/{node}/hardware/{pci,usb}` | Needs a new template set in `Ravada::HostDevice::Templates`. |
| ISO download with `wget` into the pool | `POST /nodes/{node}/storage/{storage}/download-url` with `checksum` | ISO listing from `.../storage/{storage}/content?content=iso`. |
| Screenshot via `Sys::Virt::Stream` | No API | Return `can_screenshot => 0`. |
| Synchronous libvirt calls | Most writes return a UPID; poll `GET /nodes/{node}/tasks/{upid}/status` until `status=stopped` and check `exitstatus` | The client needs a `wait_task` helper used by nearly every mutation. |

## New Code To Write

### API client

Nothing in the tree talks HTTP with authentication, so a small client is
needed. Options are `Net::Proxmox::VE` from CPAN (supports API tokens, not
packaged in Debian) or a thin wrapper around `Mojo::UserAgent`, which is
already a dependency and is what the ISO downloader uses. A wrapper of
roughly 150 lines is enough: base URL, `Authorization: PVEAPIToken=...`
header, JSON decode, `ca`/`insecure` handling for the self signed API
certificate, and `wait_task($node, $upid, $timeout)`.

### `Ravada::VM::Proxmox`

Model on `lib/Ravada/VM/Void.pm`. The `vm` attribute holds the API client
instead of `Sys::Virt`. Methods and the API calls behind them:

| Method | Implementation |
|---|---|
| `connect` / `disconnect` / `is_alive` | build client, `GET /version`, `GET /nodes/{node}/status` |
| `list_domains` | `GET /nodes/{node}/qemu` (or `GET /cluster/resources?type=vm` filtered by node) |
| `search_domain($name)` | look up VMID in `domains.internal_id`/`domains_proxmox`, fall back to matching the `name` config key; return `Ravada::Domain::Proxmox` |
| `create_domain` | from ISO: `POST /nodes/{node}/qemu` with `vmid`, `name`, `memory`, `cores`, `scsi0=storage:size`, `ide2=storage:iso/file,media=cdrom`, `net0=virtio,bridge=vmbr0`, `vga=qxl`, `agent=1`, `ostype`, `bios`/`machine` from the ISO options; from base: `POST .../clone` with `full=0`, `newid`, `name`, then `POST .../config` for memory and network overrides |
| `create_volume` | `PUT .../config` adding `scsiN=storage:size` (Proxmox allocates the volume) |
| `list_storage_pools($data)` | `GET /nodes/{node}/storage` mapped to `{name,is_active,path,size,available,used,pc_used}` |
| `_storage_path`, `dir_img`, `dir_base`, `dir_clone` | return storage IDs, not paths; `dir_base` should honour `base_storage` |
| `free_memory`, `free_disk` | `GET /nodes/{node}/status`, `GET /nodes/{node}/storage/{id}/status` |
| `remove_file`, `file_exists`, `search_volume*`, `list_volumes`, `list_used_volumes` | `GET/DELETE /nodes/{node}/storage/{id}/content[/volid]`; `search_volume_path_re(qr(.*\.iso$))` is what the ISO list uses |
| `_search_iso`, `_iso_name`, `_download_file_external` | reuse the `iso_images` table; download with `download-url`, poll the UPID |
| `import_domain`, `discover` | `discover` lists VMIDs on the node absent from `domains` |
| `list_virtual_networks`, `list_network_interfaces('bridge')` | `GET /nodes/{node}/network?type=any_bridge`; set `has_networking => 0` initially and make `create_network`/`change_network`/`remove_network` die with a clear message |
| `list_machine_types`, `get_cpu_model_names`, `can_list_cpu_models` | `GET /nodes/{node}/capabilities/qemu/{machines,cpu}` |
| `get_library_version` | `GET /version` |
| `_fetch_dir_cert` | return `''` (TLS material comes inside the spiceproxy payload) |
| `run_command`, `write_file`, `read_file`, `shared_storage` | the role's ssh versions still work against a PVE node if root ssh is set up; overriding `shared_storage` to read the storage's `shared` flag avoids the temp file probe |
| `migrate` support | see domain |

### `Ravada::Domain::Proxmox`

Model on `lib/Ravada/Domain/Void.pm`. Keep `(node, vmid)` in the object and
cache the config hash the way KVM caches XML in `domains_extra`.

| Method | Implementation |
|---|---|
| `is_active`, `is_paused`, `is_hibernated`, `is_removed` | `GET .../status/current` (`status`, `qmpstatus`, `lock`); hibernated = `lock=suspended` or config `vmstate` present |
| `start`, `shutdown`, `shutdown_now`, `force_shutdown`, `reboot`, `force_reboot`, `pause`, `resume`, `hibernate` | `POST .../status/{start,shutdown,stop,reboot,reset,suspend,resume}`, each followed by `wait_task` |
| `remove` | `DELETE .../qemu/{vmid}?purge=1&destroy-unreferenced-disks=1` |
| `rename` | `PUT .../config name=` |
| `display_info` | one builtin display `{driver=>'spice', ip=>node_ip, port=>3128, is_builtin=>1}` so the UI has something to show; optionally a `vnc` entry for noVNC |
| `_display_file_spice` (override) | `POST .../spiceproxy` and return the body as `[virt-viewer]` lines; this replaces the role's generator and its `%s` password substitution |
| `_has_builtin_display` | return 1 for the SPICE entry, but override `_add_iptable` to a no-op (or set `port`-less display) so the role does not try to open iptables on the node |
| `_set_displays_ip`, `spice_password` | no-ops |
| `get_info` | `status/current` plus config (`memory`, `cores`, `sockets`), guest IP via agent |
| `set_memory`, `set_max_mem`, `_change_hardware_vcpus` | `PUT .../config memory=`, `cores=`; hot changes work on running VMs when `hotplug` is enabled |
| `list_volumes`, `list_volumes_info`, `disk_device`, `disk_size` | parse `scsiN`/`virtioN`/`ideN`/`sataN` keys; sizes from `GET .../storage/{id}/content/{volid}` |
| `add_volume`, `remove_volume`, `remove_disks` | `PUT .../config scsiN=storage:size` / `PUT .../config delete=scsiN` then `DELETE .../unlink` or delete the volume |
| `prepare_base` (override the role) | `POST .../template`; record each disk volid as `[file_base, target]` in `file_base_images` and a JSON snapshot of the config in `base_xml`; skip the role's per volume `qemu-img` path |
| `remove_base` hooks | Proxmox cannot untemplate. Either refuse while linked clones exist (Proxmox refuses too) and full clone the template back into a VM, or keep the template and hide it. Decide in phase 2. |
| `dettach`, `spinoff` | full clone into a new VMID, swap `internal_id`, delete the old one |
| `migrate($node)` | `POST .../migrate` with `target`, `online` if running, `with-local-disks` if storage is not shared; skip the role's rsync |
| `autostart` | `PUT .../config onboot=` |
| `set_time` | `POST .../agent/exec` or no-op |
| `ip`, `ip_info` | `GET .../agent/network-get-interfaces`, skipping `lo` and link local |
| `get_driver`, `set_driver`, `list_controllers`, `get_controller_by_name`, `set_controller`, `remove_controller`, `change_hardware` | operate on config keys: `disk` (`scsiN`), `network` (`netN` model/bridge), `display` (`vga`), `cpu` (`cpu`), `memory`, `vcpus`, `usb` (`usbN`), `sound` (`audio0`), `features` (`acpi`, `kvm`, `tablet`) |
| `get_config`, `reload_config`, `add_config_node`, `set_config_node`, `remove_config_node`, `add_config_unique_node`, `change_config_attribute` | implement over the config hash with dotted keys; this is the seam host device templates use |
| `screenshot`, `can_screenshot` | `can_screenshot` returns 0 |
| `can_hibernate`, `can_host_devices`, `has_nat_interfaces`, `is_persistent`, `internal_id`, `type` | trivial; `type` must return `'Proxmox'` |

### `Ravada::Front::Domain::Proxmox`

The read only view used by `rvd_front`. `Ravada::Domain::Proxmox` should
`extends` it the way the KVM class does, so `list_controllers`,
`get_controller_by_name` and `get_driver` are written once over the cached
config and work in both processes.

### Volumes

`Ravada::Volume` reblesses by file extension into `QCOW2`/`RAW`/`ISO`
(`lib/Ravada/Volume.pm:104`) and defaults to `QCOW2` for remote VMs. Its
`clone_filename` requires the `.ro.` marker (`lib/Ravada/Volume.pm:180`) and
`QCOW2` shells out to `qemu-img`. Two options:

1. Add `Ravada::Volume::Proxmox` (`prepare_base`, `clone`, `backing_file`,
   `spinoff` over the API) and teach `Volume::BUILD` to pick it when the VM
   type is Proxmox.
2. Override `prepare_base` and `clone` in `Ravada::Domain::Proxmox` so the
   role never reaches per volume operations, and make `list_volumes_info`
   return lightweight `Ravada::Volume` objects only for display.

Option 2 is less code and is what the phased plan below assumes. `compact`,
`purge`, `backup` and `restore_backup` are file based and should be disabled
for this type (they already check `can_*` style flags in places; add one
where they do not).

## Changes Required In Existing Code

### Hard blockers (nothing works without these)

| File | Change |
|---|---|
| `lib/Ravada.pm:40` | Add an `eval { require Ravada::VM::Proxmox }` block populating `$VALID_VM{Proxmox}` and `$ERROR_VM{Proxmox}` |
| `lib/Ravada.pm:3431` | Add `Proxmox => \&_create_vm_proxmox` to the `%create` dispatch; the constructor reads endpoint, token and node list from `$CONFIG->{proxmox}` and inserts one `vms` row per node on first run |
| `lib/Ravada.pm:6949` | Replace `'Ravada::VM::'.uc($type)` with the type as given (only `KVM` survives `uc`) |
| `lib/Ravada/Front/Domain.pm:56` | Replace the `KVM`/`Void` if/elsif with `"Ravada::Front::Domain::".$domain->type` |
| `script/rvd_front:4091` and `:4126` | `backend or 'KVM'` default and `id_iso ... if $vm eq 'KVM'` drop the ISO for any other backend |
| `templates/ng-templates/new_machine_template.html.ep:24,97,109,161,188` | `ng-show="backend == 'KVM' || backend == 'Void'"` hides the ISO selector, swap and data disk rows; switch to a capability flag from `/list_vm_types.json` or add `Proxmox` |
| `lib/Ravada/WebSocket.pm:107,114` and `script/rvd_front:1104` | ISO list channels default to `'KVM'` |
| `lib/Ravada.pm:1161` | `_add_domain_drivers_display` and the `_update_domain_drivers_types` seed data only have `KVM` and `Void` branches; add `Proxmox` rows (display `spice`, `vnc`, `rdp`; network `virtio`, `e1000`, `vmxnet3`; video `qxl`, `std`, `virtio`; cpu models) or the hardware page is empty |

### Functional gaps (the basic flow works, features degrade)

| File | Change |
|---|---|
| `lib/Ravada/VM.pm:1266` | `_insert_vm_db` only stores `name, vm_type, hostname, public_ip`; extend it (and `Front::add_node` at `lib/Ravada/Front.pm:1449`) to accept `connection_args` for endpoint and token |
| `lib/Ravada/VM.pm:704` | `_define_spice_password` runs for every backend; harmless but pointless, gate on a `can_spice_password` flag |
| `lib/Ravada/VM.pm:2676` | `_fetch_tls` is gated `type ne 'KVM'`; fine for Proxmox since the proxy payload carries the CA, just be aware `Domain::_tls` returns `''` |
| `lib/Ravada/Domain.pm:1262` | `_check_cpu_usage` calls `$self->_vm->vm->list_domains()` on the raw libvirt handle; route it through `$self->_vm->list_domains(active=>1)` |
| `lib/Ravada/Domain.pm:1177` and `:5176` | explicit `type eq 'KVM'` tests around `_set_volumes_backing_store` and `_os_type_machine`; already skip for other types |
| `lib/Ravada/Domain.pm:2761` | matches on the string `libvirt error code: 38`; add the HTTP equivalent or make the backend throw the same shape |
| `lib/Ravada.pm:5489` | `_cmd_download` falls back to `search_vm('KVM')`; fall back to the first configured backend instead |
| `lib/Ravada.pm:1100` | `_scheduled_fedora_releases` only runs with KVM present; irrelevant for Proxmox but should not die |
| `lib/Ravada/HostDevice/Templates.pm:289` | `%TEMPLATES` has `KVM` and `Void` only; host device pages are empty until a Proxmox set exists |
| `lib/Ravada/Volume.pm:99,180` | `QCOW2` default and `.ro.` regex, see Volumes above |
| `lib/Ravada.pm:2379` | add a `domains_proxmox` side table (`id_domain`, `vmid`, `node`, `config` JSON) alongside `domains_kvm` |
| `templates/main/vm_monitoring.html.ep:10` | netdata chart names assume `cgroup_qemu_qemu_<uuid>`; Proxmox cgroups are `qemu.slice/<vmid>.scope` |
| `openapi.yaml:1037` | `vm_type` enum lists `KVM, LXC, Void` |
| `Makefile.PL:18`, `debian/control-*`, `.github/workflows/github-action-test.yml`, `dockerfy/` | `Sys::Virt`, `XML::LibXML`, `libvirt-daemon-system`, `qemu-kvm` are hard dependencies; `Sys::Virt` is already loaded inside `eval` so it can become optional; the back container installs and runs `libvirtd` |
| `t/lib/Test/Ravada.pm:145,153,547` | add `Proxmox` to `%ARG_CREATE_DOM` and `%VM_VALID` so `vm_names()` includes it |

## Design Decisions Worth Settling Early

### Where `rvd_back` runs and who needs ssh

With KVM, `rvd_back` runs as root on the hypervisor and treats `localhost`
specially (`is_local`). With Proxmox it should run on a separate VM or
container, unprivileged, talking only HTTPS. Anything in the role that shells
out to a node (`run_command`, `write_file`, `iptables`, `shared_storage`,
`_store_mac_address`, `connect_node`'s `/bin/true` probe at
`lib/Ravada.pm:6128`) still expects root ssh to the node. The pragmatic
approach is to keep ssh optional: override `shared_storage` and
`_store_mac_address` in the Proxmox VM class, make `connect_node` skip the ssh
probe when the backend reports `needs_ssh => 0`, and leave `run_command`
available for admins who do configure ssh keys.

### Display access and security

Today Ravada protects a running desktop by opening an iptables rule on the
hypervisor for the client IP only, plus a four character SPICE password. With
Proxmox the `.vv` file returned by `spiceproxy` contains a ticket that expires
in about 30 seconds and is bound to the VM, and the connection is TLS to the
node's `spiceproxy`. This is stronger than the current scheme, and the
iptables step can be dropped for this backend. Two consequences: the `.vv`
must be generated at download time (`GET /machine/display/spice/<id>.vv`),
not cached, and the `spiceproxy` port 3128 on every node must be reachable
from client networks. The `proxy` parameter of the API lets you point clients
at a public name or a reverse proxy per node.

The `domain_displays` table has `unique(id_vm, port)` (`lib/Ravada.pm:1725`).
Storing port 3128 for every machine on a node violates it, so store the
display with `port` NULL, or store `5900 + vmid` as a nominal value.

### Bases, templates and linked clones

Ravada's base is a set of read only `.ro.` files plus the inactive XML; the
original VM keeps running on a fresh clone of its own base, and `remove_base`
puts things back. Proxmox's template is the VM itself, converted in place,
and cannot be started again or converted back through the API. Two workable
models:

The first keeps Proxmox semantics: `prepare_base` converts the VM to a
template, the machine is marked `is_base` and becomes unstartable, and
`remove_base` full clones the template into a fresh VMID and deletes the
template if no linked clones remain. This matches what admins expect from
Proxmox and is the least code.

The second preserves Ravada semantics: `prepare_base` full clones the VM into
a new VMID, converts that clone into the template, and records the template's
VMID as the base. The original VM keeps running. `remove_base` deletes the
template. This costs one full copy per base, which is what KVM does today
with `qemu-img convert`.

Either way, linked clones must live on the same storage as the template and
that storage must support base images. `base_storage` and `clone_storage` on
the node therefore collapse to one value, and `set_base_vm` to another node
only makes sense when the storage is shared (Proxmox will reject a linked
clone to another node otherwise). `bases_vm` can be filled from the storage's
`shared` flag and the list of nodes that see it.

### Naming and identity

Proxmox VM names are not unique and must be valid DNS labels. Ravada names
already go through `_set_ascii_name`. Use the VMID as the identity everywhere
(`domains.internal_id`) and treat the `name` config key as a label; never
search by name after creation.

### Networking and port exposure

Ravada's virtual networks are libvirt NAT networks with DHCP. Proxmox VMs
normally sit on a bridge with the physical network. Start with
`has_networking => 0`, offer bridges from `/nodes/{node}/network`, and have
`_is_ip_nat` return false so `expose` and `open_exposed_ports` (DNAT on the
hypervisor) are skipped. Proxmox SDN with a simple zone and DHCP can be
mapped onto `list_virtual_networks` later if NAT isolation per user is
needed.

### Asynchronous tasks

Almost every Proxmox mutation returns immediately with a UPID. Ravada's
request handlers assume that when `start` returns the machine is running (it
polls `is_active` afterwards, but `create_domain` and `clone` continue
immediately). Every wrapper must call `wait_task` and translate a non `OK`
`exitstatus` into a `die` with the task log, so errors surface in the
request's `error` column the way libvirt errors do.

## Suggested Phasing

Phase 0 makes the core backend agnostic without changing behaviour for KVM:
the eight hard blockers above, a `Proxmox` entry in the test harness, and a
stub `Ravada::VM::Proxmox` that connects and lists nodes. This is a small,
reviewable change on its own and is worth landing first.

Phase 1 covers read and lifecycle: `list_domains`, `search_domain`,
`import_domain`, `discover`, `is_active` and friends, `start`, `shutdown`,
`force_shutdown`, `reboot`, `pause`, `resume`, `hibernate`, `remove`,
`get_info`, `ip`, `display_info` and the `spiceproxy` based `.vv`. At the
end of this phase existing Proxmox VMs can be imported and handed to users
through the Ravada portal.

Phase 2 covers creation: ISO listing and download through the storage API,
`create_domain` from ISO, `prepare_base` as template, `create_domain` from
base as linked clone, `add_volume`, `list_volumes_info`, `disk_size`. This is
where the base model decision is implemented, and where volatile clones and
pools start working.

Phase 3 covers hardware editing and drivers: `change_hardware`,
`set_controller`, `remove_controller`, `set_driver`, the driver seed rows,
and the config editing protocol.

Phase 4 covers multi node: one `vms` row per node, `free_memory` for
balancing, `migrate` through the API, `set_base_vm` from shared storage
flags, `connect_node` without ssh.

Phase 5 is optional: host devices (PCI, USB, mdev), SDN backed virtual
networks, snapshots (Ravada has none today; Proxmox makes them cheap), and a
noVNC console through `vncwebsocket`.

A rough size for phases 0 to 4 is 2,500 to 3,500 lines of new Perl plus about
300 lines of core edits, against 2,200 lines for the Void backend and 7,700
for KVM.

## Testing

The suite iterates `vm_names()` from `t/lib/Test/Ravada.pm:289`, so adding
`Proxmox` to `%ARG_CREATE_DOM` runs every `t/vm/*.t` and `t/*.t` loop
against the new backend. A self hosted GitHub Actions runner with network
access to a Proxmox server is available for this fork, so integration tests
can run against a real cluster on every pull request rather than only against
a mock.

The existing workflow (`.github/workflows/github-action-test.yml`) runs on
`ubuntu-latest`, installs MariaDB and a 389 directory server, and runs the
Void backend tests. A second job, or a second workflow, should target the
self hosted runner (`runs-on: [self-hosted, proxmox]` or whatever label the
runner carries) and:

- write `/etc/ravada.conf` with `vm: [Proxmox]` and a `proxmox:` section
  holding the API URL, node name, storage ID and bridge, taken from repository
  secrets and variables (`PROXMOX_API_URL`, `PROXMOX_TOKEN_ID`,
  `PROXMOX_TOKEN_SECRET`, `PROXMOX_NODE`, `PROXMOX_STORAGE`,
  `PROXMOX_BRIDGE`), never from the tree;
- use an API token scoped to a dedicated resource pool (for example
  `ravada-ci`) with `PVEVMAdmin` plus `Datastore.AllocateSpace`,
  `Datastore.AllocateTemplate`, `Datastore.Audit` and `Sys.Audit` on the
  test storage and node, so a runaway test cannot touch production VMs;
- keep a small ISO such as Alpine already present on the test storage, or
  let the first run fetch it through `download-url`, which the test harness
  already tolerates through `$Ravada::VM::KVM::VERIFY_ISO = 0` style flags;
- create test machines with the harness's `tst_` name prefix and a
  reserved VMID range (`GET /cluster/nextid` accepts a lower bound), and add
  a cleanup step in `Test::Ravada::_remove_old_domains_vm` that deletes any
  VM or template in the pool whose name matches the prefix, running both
  before and after the job so a failed run never leaks machines;
- run the phase appropriate subset first (`t/vm/60_new_args.t`,
  `t/30_request.t`, then `t/vm/*.t`) with `prove -l`, and gate the job on
  the label so forks without the runner still get the Void job;
- use dir backed qcow2 storage (`local`) for the linked clone path, and a
  second job or matrix entry on LVM thin or ZFS once phase 2 lands, since
  those exercise the non file storage code.

A mocked API client is still worth having for the fast unit path on
`ubuntu-latest`, since it lets `t/00_libs.t`, `t/pod_coverage.t` and
`t/critic.t` load the new modules and keeps the request dispatch tests
runnable without network access. It can be a hash of routes to canned JSON
selected when the configured URL starts with `mock://`.

## The Alternative: Libvirt On Proxmox Nodes

The Proxmox forum thread on Ravada
([forum.proxmox.com/threads/49537](https://forum.proxmox.com/threads/ravada-vdi-on-proxmox-discussion-problems-development.49537/))
describes people installing `libvirt-daemon-system` on PVE nodes and pointing
the existing KVM backend at them. It works in the narrow sense: Ravada
manages its own libvirt domains next to Proxmox's, using the same `/dev/kvm`.
Those VMs are invisible to the Proxmox UI, backups and HA, storage and bridge
ownership is shared by convention only, Proxmox upgrades can break libvirt
packaging, and the two SPICE stacks conflict on ports. It is a way to try
Ravada on existing hardware in an afternoon, not a way to run it as the
Proxmox backend the title of this document asks for.

## Sources

Upstream notes and discussion:
[UPC/ravada wiki, Proxmox](https://github.com/UPC/ravada/wiki/Proxmox),
[UPC/ravada#932](https://github.com/UPC/ravada/issues/932),
[Proxmox forum thread on Ravada](https://forum.proxmox.com/threads/ravada-vdi-on-proxmox-discussion-problems-development.49537/).
Client library: [Net::Proxmox::VE](https://metacpan.org/pod/Net::Proxmox::VE).
API reference: the `pve-docs/api-viewer` shipped with every PVE node and
[Proxmox VE API](https://pve.proxmox.com/wiki/Proxmox_VE_API).
