# stratisd boot ordering cycle reproduction

Reproduces the dependency cycle reported in [stratisd#3968](https://github.com/stratis-storage/stratisd/issues/3968).

`stratisd.service` ships with `DefaultDependencies=no` and `After=multi-user.target`.
Any service in `multi-user.target` that depends on stratisd creates an ordering cycle:

```
downstream.service → (After) stratisd.service → (After) multi-user.target → (Wants) downstream.service
```

## Background

The `After=multi-user.target` on `stratisd.service` was introduced in
[PR #3826](https://github.com/stratis-storage/stratisd/pull/3826) (changing from
`After=local-fs.target`) as part of fixing Clevis/Tang support in fstab
([#3348](https://github.com/stratis-storage/stratisd/issues/3348)). That PR made
three changes:

1. **Added `stratis-fstab-setup-with-network@.service`** — a new unit for
   network-dependent fstab entries (`After=network-online.target`,
   `Before=remote-fs-pre.target`, `Requires=stratisd-min-postinitrd.service`).
2. **Removed `Before=local-fs-pre.target` from `stratisd-min-postinitrd.service`** —
   decoupled the early-boot daemon from local filesystem ordering.
3. **Changed `stratisd.service` from `After=local-fs.target` to
   `After=multi-user.target`** — pushed the full daemon later in boot.

The Clevis fix is entirely in changes 1 and 2. Change 3 is unrelated to fstab
setup — the full `stratisd` daemon (`Type=dbus`) is a runtime service that has no
role in early-boot filesystem assembly. The fstab path uses `stratisd-min` (a
separate binary communicating over JSON-RPC via Unix socket), not the D-Bus daemon.

## What it proves

1. **Cycle exists** with the current `stratisd.service` unit file
2. **Cycle resolves** by removing `DefaultDependencies=no` and
   `After=multi-user.target` — systemd's default dependencies provide
   `After=basic.target`, which is sufficient (D-Bus is available)
3. **Fstab network ordering path is unaffected** — a simulated service matching
   the ordering constraints of `stratis-fstab-setup-with-network@.service`
   (`DefaultDependencies=no`, `After=network-online.target`,
   `Before=remote-fs-pre.target`) completes successfully after the fix
4. **Downstream services start correctly** after the fix

### Limitations

The `fake-network-fstab.service` simulates the systemd ordering of the
Clevis/Tang fstab path, not the actual Clevis key retrieval. It proves that
the ordering constraints are structurally independent of `stratisd.service` —
not that Clevis itself works. Testing actual Clevis/Tang would require a Tang
server and an encrypted Stratis pool, which is out of scope for this
reproduction.

## Prerequisites

- QEMU with KVM support
- `genisoimage`, `mkisofs`, or `xorrisofs` (for cloud-init ISO)
- Internet access (downloads Fedora Cloud image on first run, ~500 MB cached in `.cache/`)

## Usage

```bash
./run.sh
```

The script boots a Fedora 43 VM, installs stratisd, demonstrates the cycle,
applies the fix, reboots, and verifies all services come up correctly.

## Proposed fix for stratisd

Remove these two lines from `stratisd.service`:

```diff
 [Unit]
 Description=Stratis daemon
 Documentation=man:stratisd(8)
-DefaultDependencies=no
-After=multi-user.target

 [Service]
 ...
```

With `DefaultDependencies=yes` (the default), systemd auto-adds:
- `Requires=sysinit.target` + `After=sysinit.target`
- `After=basic.target`
- `Before=shutdown.target` + `Conflicts=shutdown.target`

`After=basic.target` ensures D-Bus is available. The fstab boot path
(`stratis-fstab-setup@.service`, `stratis-fstab-setup-with-network@.service`)
depends on `stratisd-min-postinitrd.service`, not `stratisd.service`.
