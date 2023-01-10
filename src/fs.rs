use std::ffi::OsStr;
use std::path::Path;
use std::io;

#[cfg(feature = "io-uring")]
pub async fn read_dir<F: FnMut(&OsStr, u64, bool)>(path: impl AsRef<Path>, mut f: F) -> io::Result<()> {
    use futures::StreamExt;
    use tokio_uring::fs::{Dir, FileType};

    let mut dir = Dir::open(path).await?;
    while let Some(res) = dir.next().await {
        let entry = res?;
        let metadata = dir.metadata(&entry).await?;
        f(entry.file_name(), metadata.len(), metadata.file_type() == FileType::Dir)
    }
    dir.close().await
}

#[cfg(not(feature = "io-uring"))]
pub async fn read_dir<F: FnMut(&OsStr, u64, bool) -> ()>(path: impl AsRef<Path>, mut f: F) -> io::Result<()> {
    use tokio::fs;

    let mut dir = fs::read_dir(path).await?;
    while let Some(entry) = dir.next_entry().await? {
        let metadata = entry.metadata().await?;
        f(entry.file_name().as_os_str(), metadata.len(), metadata.is_dir());
    }
    Ok(())
}