# btrfs-auto-snapshot

Automatic, rotating snapshots for btrfs, modeled on
[zfs-auto-snapshot](https://github.com/zfsonlinux/zfs-auto-snapshot).
It has the same command-line options, snapshot naming and
frequent/hourly/daily/weekly/monthly schedule.

```
btrfs-auto-snapshot [options] [-l label] <'//' | subvolume> [subvolume...]
```

## How it works

- A snapshot of subvolume `SUBVOL` is written to
  `SUBVOL/.btrfs-auto-snapshot/btrfs-auto-snap_<label>-YYYY-MM-DD-HHMM`.
  The snapshot directory is itself a subvolume, so it never ends up inside
  later snapshots of its parent.
- Snapshots are **read-only** by default (`--writable` turns this off).
- After each snapshot, only the newest `--keep` snapshots with the same
  prefix and label are kept. Snapshots with other labels, and anything the
  script did not create, are left alone.
- `//` means every mounted btrfs subvolume. If a subvolume is mounted twice,
  it is snapshotted once. Subvolumes that hold an active swap file are
  skipped, because btrfs cannot snapshot them.
- `--recursive` also snapshots every nested subvolume below the given
  paths. Btrfs snapshots are not recursive, so each nested subvolume gets its
  own snapshot.
- Runs take an `flock` lock, so overlapping cron or timer runs wait for each
  other.

### Default retention

| label    | schedule      | keep |
|----------|---------------|------|
| frequent | every 15 min  | 4    |
| hourly   | hourly        | 24   |
| daily    | daily         | 31   |
| weekly   | weekly        | 8    |
| monthly  | monthly       | 12   |

These limits apply when `--keep` is not given. A label not in this table keeps
every snapshot.

## Keeping snapshots out of sight (`--snaproot`)

By default, snapshots live inside each subvolume (`/home/.btrfs-auto-snapshot/`).
That means `ls -a`, `find`, `locate`, `du` and backup tools all see them.
Use `--snaproot` to keep them somewhere else:

- **Relative**, e.g. `--snaproot=@snapshots`. This creates a `@snapshots`
  subvolume at the **top level** of each btrfs filesystem, next to `@` and
  `@home`. On each run, the script mounts the top level (subvolid=5) in a
  private mount namespace, takes and prunes snapshots, and unmounts it again.
  Nothing else on the system ever sees the mount, so the snapshots are
  invisible until you mount the top level yourself. Needs root and `unshare`.
- **Absolute**, e.g. `--snaproot=/srv/snapshots`. This must be an existing
  directory on the same btrfs filesystem as the subvolumes. Subvolumes on other
  filesystems are skipped with a warning.

Inside the snapshot root, snapshots are grouped by the subvolume's path from
the filesystem top level, for example
`@snapshots/@home/btrfs-auto-snap_daily-2026-11-17-0000`. Subvolumes inside
the snapshot root are never snapshotted.

To switch the timers over, set this in `/etc/default/btrfs-auto-snapshot`:

```bash
BTRFS_AUTO_SNAPSHOT_OPTS="--snaproot=@snapshots"
```

Existing snapshots in `.btrfs-auto-snapshot/` aren't moved, and they're no
longer pruned once you switch. Delete them by hand when you no longer need them.

To browse or restore from a relative snapshot root:

```bash
sudo mount -o subvolid=5 /dev/mapper/cryptroot /mnt
```

```bash
ls /mnt/@snapshots/@home/
```

```bash
sudo umount /mnt
```

## Opting subvolumes in or out

ZFS uses the `com.sun:auto-snapshot` property for this. Here the same job is
done by extended attributes on the subvolume root. Reading them needs
`getfattr` from the `attr` package.

```bash
setfattr -n user.auto-snapshot -v false /var/cache          # never snapshot
setfattr -n user.auto-snapshot:frequent -v false /home      # skip only 'frequent'
setfattr -n user.auto-snapshot -v true /data                # needed with --default-exclude
```

A label-specific attribute takes priority over the generic one.

## Install

```bash
sudo make install-systemd
```

```bash
sudo systemctl daemon-reload
```

```bash
sudo systemctl enable --now btrfs-auto-snapshot-{frequent,hourly,daily,weekly,monthly}.timer
```

To use cron instead, run `sudo make install-cron`. Install either the timers
or the cron file, not both.

The targets and extra options for the timers are set in
`/etc/default/btrfs-auto-snapshot` (default target: `//`).

## Options

| option | meaning |
|---|---|
| `-l, --label=LAB` | label, e.g. `hourly` (default `regular`) |
| `-k, --keep=NUM` | keep NUM newest snapshots of this label |
| `-r, --recursive` | include nested subvolumes |
| `-n, --dry-run` | print what would be done |
| `-v, --verbose` / `-q, --quiet` / `-d, --debug` | verbosity |
| `-g, --syslog` | log to syslog; `-e, --event=NAME` sets the event tag |
| `-p, --prefix=PRE` | name prefix (default `btrfs-auto-snap`) |
| `--sep=CHAR` | separator between prefix and label (default `_`) |
| `-u, --utc` | use UTC timestamps |
| `-s, --snapdir=DIR` | snapshot directory name inside each subvolume |
| `-S, --snaproot=ROOT` | keep snapshots in ROOT instead (see above) |
| `-w, --writable` | create writable snapshots |
| `--default-exclude` | only snapshot subvolumes marked `user.auto-snapshot=true` |
| `--destroy-only` | only prune old snapshots |
| `--pre-snapshot=CMD`, `--post-snapshot=CMD` | hooks, called as `CMD SUBVOL SNAPNAME` |
| `--lockfile=FILE` | lock file (default `/run/lock/btrfs-auto-snapshot.lock`) |

## Restoring

Snapshots are plain directories, so you can copy files out of them:

```bash
cp -a /home/.btrfs-auto-snapshot/btrfs-auto-snap_hourly-2026-11-17-1400/a/file ~/file
```

Or you can make a writable copy of a whole snapshot:

```bash
sudo btrfs subvolume snapshot /home/.btrfs-auto-snapshot/btrfs-auto-snap_daily-2026-11-17-0000 /home-restored
```

## Differences from zfs-auto-snapshot

- Btrfs has no `zfs list -t snapshot`. Snapshots are found by name inside the
  snapshot directory.
- `--fast` and `--min-size` do not apply to btrfs and are not implemented.
- `//` covers mounted subvolumes only. To include unmounted nested
  subvolumes, use `-r` on their parent.

## Tests

```bash
sudo TEST_DIR=/path/on/btrfs make test
```
