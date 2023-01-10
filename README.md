# Experimental support for `getdents` via `io_uring`

Asynchronous runtimes like `tokio` or also `libuv` mostly focus on networking.
For File I/O, those just issue blocking calls on a thread pool.

With [`io_uring`](https://man.archlinux.org/man/extra/liburing/io_uring.7.en), a powerful new interface has been introduced to the linux kernel
supporting ever more commands. Through its submit- and completion-queue (two ring buffers, which give `io_uring` its name),
the overhead of many syscalls can be significantly reduced.

One syscall that is still missing is [`getdents`](https://man.archlinux.org/man/getdents.2.en).
This is the syscall used by [`readdir`](https://man.archlinux.org/man/readdir.3.en) under the hoods
and given a directory, it fills a buffer provided by the user with the directory entries.

Reading directory entries benefits particularly well from `io_uring`,
since these are relatively cheap operations where the overhead due to
syscalls can be quite significant.

Also, there are many use cases for traversing large directory structures
where asynchronous, concurrent directory traversal can yield significant performance gains.

## `io_uring` support for `getdents` in the kernel

The patches for the kernel that add support for `getdents` in `io_uring` are heavily
based on previous work from Stefan Roesch and subsequent feedback from Al Viro (see [this thread](https://lore.kernel.org/io-uring/20211221164004.119663-1-shr@fb.com/) on the io-uring mailing list).

## Rust implementation

We also provide support for this `io_uring` command to the rust libraries [`tokio-uring`](https://docs.rs/tokio-uring/latest/tokio_uring/) and [`io-uring`](https://docs.rs/io-uring/latest/io_uring/), which can be used in the following manner:
```rust
use tokio_uring::fs::Dir;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tokio_uring::start(async {
        // Open a directory
        let mut dir = Dir::open(".").await?;

        // Read directory entries
        while let Some(result) = dir.next().await {
            let entry = result?;
            println!("entry: {}", entry.file_name())
        }

        // Close the directory
        dir.close().await?;

        Ok(())
    })
}
```

The patches can be found in the corresponding git submodules of this repository.

Run `cargo doc --open` within them for details on how to use it. Especially have a look at `tokio_uring::fs::Dir` in the `tokio-uring` crate.

## Benchmarking

As an example, we calculate the number of files and the cumulative size of a directory,
in this case, the linux source.

With the `io_uring`-based Rust implementation, we are about 70% faster than `du -bs`
and more than 3x faster than with `tokio` without `io_uring`.

For our test setup, we used a [QEMU microvm](https://qemu-project.gitlab.io/qemu/system/i386/microvm.html) with an ext2 disk image with host caching disabled.

```bash
$ hyperfine -N --prepare 'sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"' \
    'traverse /usr/local/src/linux' \
    'traverse-iouring /usr/local/src/linux' \
    'du -bs /usr/local/src/linux'`
Benchmark 1: /usr/local/bin/traverse /usr/local/src/linux
  Time (mean ± σ):      1.201 s ±  0.090 s    [User: 1.095 s, System: 0.949 s]
  Range (min … max):    1.070 s …  1.325 s    10 runs
 
Benchmark 2: /usr/local/bin/traverse-iouring /usr/local/src/linux
  Time (mean ± σ):     366.1 ms ±   8.5 ms    [User: 72.3 ms, System: 447.4 ms]
  Range (min … max):   350.1 ms … 375.4 ms    10 runs
 
Benchmark 3: /usr/bin/du -bs /usr/local/src/linux
  Time (mean ± σ):     635.0 ms ±  21.5 ms    [User: 19.9 ms, System: 216.3 ms]
  Range (min … max):   608.8 ms … 676.7 ms    10 runs
 
Summary
  '/usr/local/bin/traverse-iouring /usr/local/src/linux' ran
    1.73 ± 0.07 times faster than '/usr/bin/du -bs /usr/local/src/linux'
    3.28 ± 0.26 times faster than '/usr/local/bin/traverse /usr/local/src/linux'
```

A single run produces the following output:
```bash
$ traverse /usr/local/src/linux
83796 files, 1316815149 bytes
```

## QEMU microvm setup

To test the patched kernel, we use a qemu microvm using an ext2 disk image
generated from a Dockerfile.

As init process, we use a simple script, which mounts `/proc` and `/sys` and then
execs into `tini`, which we also patched, so that it can reboot the microvm instead
of just exiting (which would trigger a kernel panic). The reboot leads to a clean
shutdown and lets us use it like a simple container.