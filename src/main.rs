use std::io;
use std::future::Future;
use std::io::ErrorKind;
use std::path::PathBuf;
use futures::future::{LocalBoxFuture};
use futures::{FutureExt, StreamExt, TryFutureExt};
use futures::stream::FuturesOrdered;
use tokio::sync::Semaphore;

mod fs;

type DynResult = Result<(), Box<dyn std::error::Error>>;

#[cfg(feature = "io-uring")]
fn run<F: Future<Output = DynResult>>(f: F) -> DynResult {
    tokio_uring::start(f)
}

#[cfg(not(feature = "io-uring"))]
fn run<F: Future<Output = DynResult>>(f: F) -> DynResult {
    let rt = tokio::runtime::Builder::new_current_thread().build()?;
    rt.block_on(f)
}

fn main() -> DynResult {
    let dir = std::env::args().nth(1).unwrap_or(".".into());

    run(async {
        let traverse = Traverse::new(256);
        let (count, size) = traverse.traverse_dir(dir.into()).await;
        println!("{count} files, {size} bytes");

        Ok::<(), Box<dyn std::error::Error>>(())
    })
}

struct Traverse {
    semaphore: Semaphore
}

impl Traverse {
    fn new(max_concurrency: usize) -> Self {
        Traverse { semaphore: Semaphore::new(max_concurrency) }
    }

    fn traverse_dir(self: &Self, path: PathBuf) -> LocalBoxFuture<(u64, u64)> {
        let path_copy = path.clone();
        async move {
            let (mut count, mut total_size) = (0u64, 0u64);

            let sem = self.semaphore.acquire().await.map_err(|err| io::Error::new(ErrorKind::Other, err))?;

            let mut sub_dirs = FuturesOrdered::new();
            fs::read_dir(&path, |name, size, is_dir| {
                count += 1;
                total_size += size;
                if is_dir {
                    let mut sub_dir = path.clone();
                    sub_dir.push(name);
                    sub_dirs.push_back(self.traverse_dir(sub_dir));
                }
            }).await?;

            drop(sem);

            Ok(sub_dirs.fold((count, total_size),
                              |(count1, size1), (count2, size2)| async move {
                                  (count1 + count2, size1 + size2)
                              }).await)
        }.unwrap_or_else(move |err: io::Error| {
            eprintln!("{}: {err}", path_copy.display());
            (0, 0)
        }).boxed_local()
    }
}