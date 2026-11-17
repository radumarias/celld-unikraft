# Running celld on Unikraft

This fork runs a celld node as a [Unikraft](https://unikraft.org) unikernel: one VM, one process
(celld on Unikraft's Linux-compatible ELF loader), and the fleet bucket outside it.

celld fits a unikernel well. A node is already one process, and every cell's durable state lives in
the bucket, so a unikernel can stop, boot again or be replaced, and the data stays.

## Quickstart (macOS or Linux)

You need Docker, KraftKit and QEMU:

```sh
brew install unikraft/cli/kraftkit qemu   # macOS
unikraft/run-local.sh                      # boots examples/counter
```

When celld logs that it serves, call the application:

```sh
$ curl http://127.0.0.1:8080/
{"n":1,"url":"http://127.0.0.1:8080/"}
```

Stop it with Ctrl-C, run the script again with `SKIP_BUILD=1 KEEP_S3=1`, and the counter
continues from where it was. To run another application, pass its directory:
`unikraft/run-local.sh path/to/app`.

## What the script does

1. Docker builds celld for linux/amd64 from this fork's source. It cross-compiles, so Apple
   silicon builds at native speed. Set `EMULATED_BUILD=1` to compile inside an emulated
   container instead.
2. The image's file system (Debian's glibc, CA certificates and celld) is packed into
   `unikraft/.build/rootfs.cpio`, the initrd that `unikraft/Kraftfile` boots on
   `unikraft.org/base`.
3. A local S3 starts in Docker on `127.0.0.1:9000`. It's moto's server, which passes
   `celld diagnose`'s conditional-write check. MinIO no longer publishes public images.
4. `celld deploy` writes the application into the bucket from a container, so the host needs
   neither celld nor esbuild.
5. `kraft run` boots the unikernel with `-p 8080:8080`. The guest reaches the bucket at
   `10.0.2.2`, QEMU's address for the host.

To use a real bucket instead, set `CELLD_BUCKET`, `S3_ENDPOINT`, `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` (and `AWS_REGION` if needed). The script then starts no local S3.

## What changed from upstream

| Change | Why |
| --- | --- |
| `CELLD_SQLITE_VFS` makes a built-in SQLite VFS the default for every connection | Each cell runs SQLite in WAL mode with several connections. The default `unix` VFS shares the WAL index through a writable `MAP_SHARED` mapping of the `-shm` file, and Unikraft refuses writable shared file mappings, so every cell would fail with `SQLITE_IOERR_SHMMAP`. `unix-excl` keeps the WAL index in heap memory, shared by the connections of the one process, which is all a unikernel has. The Kraftfile sets it. |
| The machine's memory falls back to `sysconf(_SC_PHYS_PAGES)` when `/proc/meminfo` is missing | Unikraft has no procfs, but it answers `sysinfo(2)`, so memory-pressure shedding still knows the machine's size. |
| `unikraft/` holds the Dockerfile, the Kraftfile and `run-local.sh` | Packaging only. |

Without `CELLD_SQLITE_VFS`, celld behaves exactly as upstream does.

## What was checked, and how

On Linux, without Unikraft:

- A celld node serving `examples/counter` from a clean environment against an S3 bucket ran as
  exactly one process. `strace` showed a single `execve` and threads only.
- With `CELLD_SQLITE_VFS=unix-excl` the node opened no `-shm` file and made no writable shared
  file mapping. Without it, it made both. The counter kept counting across node restarts.
- The node also served with `/proc` and `/sys` replaced by empty file systems.
- `crates/celld/tests/sqlite_vfs.rs` checks that `unix-excl` keeps WAL readers and writers in
  step without a `-shm` file, and that an unknown VFS name is refused.

## Known limits

- `unikraft.org/base` is x86_64 only. On Apple silicon, QEMU emulates the guest without
  acceleration, so it runs slower than native.
- One node per unikernel. A second node on the same bucket needs its own advertised address
  (`CELLD_ADVERTISE`) that the first can reach.
- The Containers and Sandbox bindings need a Docker socket and don't work in the guest.
- `celld dev` supervises a child process and stays a host tool. In the guest, celld runs as a
  fleet node.
- The cross-compile and the Unikraft boot haven't been run yet. If the guest stops on a missing
  syscall, `kraft run` prints a warning for it. That warning is where to look first.
