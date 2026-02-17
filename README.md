# stratisd boot ordering cycle reproduction

Reproduces the dependency cycle reported in [stratisd#3968](https://github.com/stratis-storage/stratisd/issues/3968).

`stratisd.service` ships with `DefaultDependencies=no` and `After=multi-user.target`.
Any service in `multi-user.target` that depends on stratisd creates an ordering cycle:

```
downstream.service → (After) stratisd.service → (After) multi-user.target → (Wants) downstream.service
```

## What it proves

1. **Cycle exists** with the current `stratisd.service` unit file
2. **Cycle resolves** by removing `DefaultDependencies=no` and `After=multi-user.target` — systemd's default dependencies provide `After=basic.target`, which is sufficient (D-Bus is available)
3. **Clevis/network fstab path is unaffected** — those use `stratisd-min-postinitrd`, not `stratisd.service`
4. **Downstream services start correctly** after the fix

## Prerequisites

- QEMU with KVM support
- `sshpass`
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
