//! The clipboard: copied images and text dock, unless they are marked
//! private, and Clipstar can put an item back on it.

use crate::{dock, Store};
use clipboard_rs::common::RustImage;
use clipboard_rs::{
    Clipboard, ClipboardContext, ClipboardHandler, ClipboardWatcher, ClipboardWatcherContext, ContentFormat, RustImageData,
};
use std::fs;
use std::sync::atomic::Ordering;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager};

/// Formats password managers and similar apps add to say "do not keep this".
const PRIVATE: [&str; 5] = [
    "ExcludeClipboardContentFromMonitorProcessing",
    "CanIncludeInClipboardHistory",
    "Clipboard Viewer Ignore",
    "org.nspasteboard.ConcealedType",
    "org.nspasteboard.TransientType",
];

struct Handler {
    app: AppHandle,
    ctx: ClipboardContext,
    last_text: String,
}

impl ClipboardHandler for Handler {
    fn on_clipboard_change(&mut self) {
        let store = self.app.state::<Store>();
        if store.ignore_clipboard.load(Ordering::SeqCst) {
            return;
        }
        let (images, text) = {
            let s = store.settings.lock().unwrap();
            (s.dock_images, s.dock_text)
        };
        let formats = self.ctx.available_formats().unwrap_or_default();
        if formats.iter().any(|f| PRIVATE.iter().any(|p| f.contains(p))) {
            return;
        }
        let inbox = store.inbox();
        let _ = fs::create_dir_all(&inbox);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
        if images && self.ctx.has(ContentFormat::Image) {
            if let Ok(img) = self.ctx.get_image() {
                let path = inbox.join(format!("Clipboard {stamp}.png"));
                if img.save_to_path(&path.to_string_lossy()).is_ok() {
                    dock(&self.app, path, "image");
                }
            }
            return;
        }
        if text && self.ctx.has(ContentFormat::Text) {
            if let Ok(t) = self.ctx.get_text() {
                if t.trim().is_empty() || t.len() > 1_000_000 || t == self.last_text {
                    return;
                }
                self.last_text = t.clone();
                let path = inbox.join(format!("Clipboard {stamp}.txt"));
                if fs::write(&path, t).is_ok() {
                    dock(&self.app, path, "text");
                }
            }
        }
    }
}

pub fn watch(app: AppHandle) {
    std::thread::spawn(move || {
        let Ok(ctx) = ClipboardContext::new() else { return };
        let Ok(mut watcher) = ClipboardWatcherContext::new() else { return };
        watcher.add_handler(Handler { app, ctx, last_text: String::new() });
        watcher.start_watch();
    });
}

pub fn set_text(text: &str) -> Result<(), String> {
    ClipboardContext::new().map_err(|e| e.to_string())?.set_text(text.to_string()).map_err(|e| e.to_string())
}

pub fn set_image(path: &str) -> Result<(), String> {
    let img = RustImageData::from_path(path).map_err(|e| e.to_string())?;
    ClipboardContext::new().map_err(|e| e.to_string())?.set_image(img).map_err(|e| e.to_string())
}
