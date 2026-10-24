# CBAP OS runtime layer

CBAP OS is DSH OS with a versioned runtime layer:

```text
Debian base (DSH build)
  └── /opt/cbap-os/versions/cbap/<version>
  └── /opt/cbap-os/versions/python/<version>
  └── /opt/cbap-os/current/{cbap,python}     bind mounts
  └── /etc/cbap-os/selection.json            boot/current choice
```

The point is not to install one frozen CBAP. It is to keep multiple immutable
CBAP and Python slots on disk, choose them at boot, and switch them after login
without rebooting.

## Layout

```text
/opt/cbap-os/
  versions/
    cbap/
      v1.0.0/          source slot: kernel/, drivers/, manifest.json
      v1.4.0/
    python/
      3.13/            runtime slot: bin/python3, manifest.json
  current/
    cbap/              bind mount -> selected source slot
    python/            bind mount -> selected runtime slot
  bin/cbap-os          manager
  bin/cbap             run selected CBAP kernel
  bin/cbap-service     systemd entrypoint

/etc/cbap-os/
  selection.json       persisted boot/current selection
  runtime.env          hand/socket/audit paths

/usr/local/bin/
  cbap-os              management CLI
  cbap                 selected CBAP runner
  cbap-python          selected Python runner
  cbap-service         systemd wrapper
```

`current` is a **mount point**, not a copy. A switch remounts the slot after
stopping the CBAP service. The old slot is never modified.

## Boot-time selection

Two mechanisms, in order:

1. **Interactive tty1 menu** (`cbap-os-select.service`, 10 s timeout each
   step). It appears before the CBAP mount unit and writes
   `/etc/cbap-os/selection.json`.
2. **Kernel cmdline** for headless images:

```text
cbap.cbap=v1.4.0 cbap.python=3.13
```

`cbap-os boot` reads the cmdline; explicit `--cbap` / `--python` arguments win.
To suppress the tty1 menu, add `cbap.nomenu` to the kernel command line.

The QEMU boot helper does not currently generate a GRUB menu. The menu is a
systemd oneshot on tty1, so it works with the direct-kernel boot used by this
repo.

## Hot-swap after login

```bash
sudo cbap-os list
sudo cbap-os use --cbap v1.4.0 --python 3.13
sudo cbap-os rollback
```

The command:

```text
validate version slots
stop cbap.service if it is active
unmount/mount current/cbap and current/python
write selection.json atomically
start cbap.service again if it was active
rollback mounts + selection if any step fails
```

Python is an interpreter, so "hot swap" means **control-plane hot swap**:
running CBAP processes are stopped and restarted under the new interpreter.
It is not in-process replacement of a loaded libpython.

## Security / operational rules

```text
version switching requires root (sudo)
slots are directories with validated names; no path traversal
CBAP service runs as user cbap, not root
hand socket is optional; no hand => service is skipped, not crashed
current/ is a bind mount; switching drains the service first
rollback only stores one previous selection
```

The boot menu and `cbap-os` are local root tools. They do not expose a network
API. A future console integration should add authentication and audit; it
should not just shell out to this CLI.

## Install into a DSH rootfs

```bash
sudo bash cbap-os/install.sh \
  --root /path/to/rootfs \
  --cbap-src /path/to/cyberdyne-bridge \
  --cbap-version v1.4.0
```

Add another runtime slot later:

```bash
sudo bash cbap-os/install.sh --root / \
  --cbap-src /path/to/cbap-v1.0 \
  --cbap-version v1.0.0 --force
```

Python slots can point at a self-contained prefix:

```bash
sudo bash cbap-os/install.sh --root / \
  --python-prefix /opt/python-3.11 \
  --python-version 3.11
```

Only the **link** mode is claimed as tested. The default system slot links to
`/usr/bin/python3`; it is a selectable slot, not a second interpreter binary.
For true independent Python runtimes, provide a self-contained prefix. The
optional `--python-mode copy` is experimental because CPython's compiled
prefix is not relocatable without care.

## Tests

```bash
python3 -m unittest -v cbap-os/tests/test_cbap_os.py
bash -n cbap-os/install.sh
```

The host tests use `CBAP_OS_ROOT`, `CBAP_OS_NO_SYSTEMD=1` and symlink mode;
they do not require root, systemd, or a real QEMU image.

## Current limitations

```text
the OS image has not been rebuilt in this change
the systemd boot menu was not exercised in a real QEMU boot
no signed/TPM-attested version slots
no live migration of in-flight CBAP leases across an interpreter switch
python-build-standalone / multi-runtime provisioning is documented, not bundled
```

These are release blockers for a production OS claim, not hidden in the docs.
