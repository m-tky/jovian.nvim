// jovian-core — Jupyter backend for jovian.nvim.
//
// Speaks msgpack-rpc over stdio to the Lua frontend.
// Speaks Jupyter wire protocol (ZMQ + HMAC-SHA256) to kernels.
// Owns `# %%`-based source parsing and sidecar JSON output persistence.

use anyhow::Result;
use std::path::PathBuf;
use tracing_subscriber::EnvFilter;

mod ipynb;
mod kernel;
mod kernelspec;
mod kitty;
mod notebook;
mod protocol;
mod rpc;
mod session;

#[tokio::main]
async fn main() -> Result<()> {
    init_logging()?;
    tracing::info!("jovian-core starting (v{})", env!("CARGO_PKG_VERSION"));

    let server = rpc::Server::new();
    server.run_stdio().await?;

    tracing::info!("jovian-core exiting cleanly");
    Ok(())
}

fn init_logging() -> Result<()> {
    let log_dir = dirs::cache_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("jovian");
    std::fs::create_dir_all(&log_dir)?;

    let file_appender = tracing_appender::rolling::never(&log_dir, "core.log");
    let env = EnvFilter::try_from_env("JOVIAN_LOG").unwrap_or_else(|_| EnvFilter::new("info"));

    tracing_subscriber::fmt()
        .with_env_filter(env)
        .with_writer(file_appender)
        .with_ansi(false)
        .with_target(true)
        .with_thread_ids(false)
        .init();

    Ok(())
}
