// Native Kitty graphics protocol implementation.
//
// Strategy: Unicode placeholder mode (a=t, U=1).
//   1. Transmit image bytes once with `a=t f=100 i=ID U=1 q=2` (chunked)
//   2. Frontend (Lua) renders Unicode placeholder chars (U+10EEEE) in the
//      buffer with foreground color encoding the image ID.
//   3. Kitty/Ghostty intercepts placeholders at render time and draws the
//      image. Survives Neovim redraws because placeholders ARE buffer text.
//
// We open /dev/tty for direct write — bypasses Neovim's TUI multiplexing.

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use parking_lot::Mutex;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

static NEXT_IMAGE_ID: AtomicU32 = AtomicU32::new(1);

pub fn alloc_id() -> u32 {
    NEXT_IMAGE_ID.fetch_add(1, Ordering::Relaxed)
}

pub struct KittyTty {
    inner: Arc<Mutex<KittyTtyInner>>,
}

struct KittyTtyInner {
    path: PathBuf,
    in_tmux: bool,
}

impl KittyTty {
    pub fn open(path: Option<PathBuf>) -> Result<Self> {
        let p = path.unwrap_or_else(|| PathBuf::from("/dev/tty"));
        OpenOptions::new()
            .write(true)
            .open(&p)
            .with_context(|| format!("cannot open tty {}", p.display()))?;
        let in_tmux = std::env::var_os("TMUX").is_some()
            && std::env::var_os("JOVIAN_DISABLE_TMUX_PASSTHROUGH").is_none();
        Ok(Self {
            inner: Arc::new(Mutex::new(KittyTtyInner { path: p, in_tmux })),
        })
    }

    fn write(&self, bytes: &[u8]) -> Result<()> {
        let inner = self.inner.lock();
        let mut f = OpenOptions::new()
            .write(true)
            .open(&inner.path)
            .map_err(|e| anyhow!("tty open: {e}"))?;
        if inner.in_tmux {
            let mut wrapped = Vec::with_capacity(bytes.len() * 2 + 16);
            wrapped.extend_from_slice(b"\x1bPtmux;");
            for &b in bytes {
                wrapped.push(b);
                if b == 0x1b {
                    wrapped.push(0x1b);
                }
            }
            wrapped.extend_from_slice(b"\x1b\\");
            f.write_all(&wrapped)
                .map_err(|e| anyhow!("tty write: {e}"))?;
        } else {
            f.write_all(bytes).map_err(|e| anyhow!("tty write: {e}"))?;
        }
        f.flush().ok();
        Ok(())
    }

    pub fn transmit_png(&self, png: &[u8], cols: u32, rows: u32) -> Result<u32> {
        let id = alloc_id();
        self.transmit_png_with_id(id, png, cols, rows)?;
        Ok(id)
    }

    /// Transmit a PNG and register a VIRTUAL placement so subsequent
    /// Unicode placeholder characters anchor to it. The `cols × rows`
    /// values are the grid the image will be scaled to fit; Kitty
    /// needs these up front — `a=t,U=1` alone (transmit only) is not
    /// enough to make placeholders renderable. We use `a=T,U=1,c=N,r=N`
    /// (capital T = transmit AND create placement) just like jupynvim.
    pub fn transmit_png_with_id(&self, id: u32, png: &[u8], cols: u32, rows: u32) -> Result<()> {
        let b64 = base64::engine::general_purpose::STANDARD.encode(png);
        let chunk = 4096;
        let mut pos = 0;
        let total = b64.len();
        let mut first = true;
        let mut buf = String::with_capacity(8192);
        while pos < total {
            let end = (pos + chunk).min(total);
            let part = &b64[pos..end];
            let more = if end < total { 1 } else { 0 };
            buf.clear();
            if first {
                buf.push_str(&format!(
                    "\x1b_Ga=T,U=1,f=100,i={},c={},r={},q=2,m={};{}\x1b\\",
                    id, cols, rows, more, part
                ));
                first = false;
            } else {
                buf.push_str(&format!("\x1b_Gm={},q=2;{}\x1b\\", more, part));
            }
            self.write(buf.as_bytes())?;
            pos = end;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alloc_ids_unique() {
        let a = alloc_id();
        let b = alloc_id();
        assert_ne!(a, b);
    }

    #[test]
    fn open_nonexistent_tty_fails() {
        let r = KittyTty::open(Some(PathBuf::from("/nonexistent/tty")));
        assert!(r.is_err());
    }
}
