//! Clipstar for Windows: screenshots and copies docked round the edge of the
//! screen, against the Milky Way. This side does the system work: the tray,
//! the shortcut, watching the screenshots folder and the clipboard, keeping
//! the list of items. The dock itself is drawn by the page in `src/`.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, State};

mod clip;

#[derive(Clone, Serialize, Deserialize)]
pub struct Item {
    pub id: u64,
    pub path: String,
    /// "image" or "text".
    pub kind: String,
    /// Seconds since 1970, when it was docked.
    pub added: u64,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Settings {
    pub skin: String,
    pub arrival: String,
    /// Percent of the original card, for a 1440 by 900 screen.
    pub size: u32,
    /// How solid the space behind the dock is, 0 to 1.
    pub sky: f64,
    pub dock_images: bool,
    pub dock_text: bool,
    /// Minutes shown text stays unlocked: -1 until the dock closes, 0 until quit.
    pub keep_text: i64,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            skin: "card".into(),
            arrival: "warp".into(),
            size: 150,
            sky: 0.8,
            dock_images: true,
            dock_text: true,
            keep_text: 60,
        }
    }
}

pub struct Store {
    pub items: Mutex<Vec<Item>>,
    pub settings: Mutex<Settings>,
    /// When shown text locks again; 0 locked.
    pub unlocked_until: Mutex<u64>,
    pub dir: PathBuf,
    /// Set while we write to the clipboard ourselves, so it is not docked again.
    pub ignore_clipboard: Arc<AtomicBool>,
}

const MAX_ITEMS: usize = 100;

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

impl Store {
    fn load(dir: PathBuf) -> Store {
        // Files saved by other tools may start with a byte order mark.
        let read = |name: &str| fs::read_to_string(dir.join(name)).ok().map(|s| s.trim_start_matches('\u{feff}').to_string());
        let items: Vec<Item> = read("items.json").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        let items = items.into_iter().filter(|i| Path::new(&i.path).exists()).collect();
        let settings = read("settings.json").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        Store {
            items: Mutex::new(items),
            settings: Mutex::new(settings),
            unlocked_until: Mutex::new(0),
            dir,
            ignore_clipboard: Arc::new(AtomicBool::new(false)),
        }
    }

    fn save(&self) {
        let _ = fs::create_dir_all(&self.dir);
        if let Ok(s) = serde_json::to_string_pretty(&*self.items.lock().unwrap()) {
            let _ = fs::write(self.dir.join("items.json"), s);
        }
        if let Ok(s) = serde_json::to_string_pretty(&*self.settings.lock().unwrap()) {
            let _ = fs::write(self.dir.join("settings.json"), s);
        }
    }

    /// Clipstar's own folder for copied images and text.
    pub fn inbox(&self) -> PathBuf {
        self.dir.join("Clipboard")
    }

    fn in_inbox(&self, path: &str) -> bool {
        Path::new(path).starts_with(self.inbox())
    }
}

/// Adds something to the dock as the newest, once.
pub fn dock(app: &AppHandle, path: PathBuf, kind: &str) {
    let store = app.state::<Store>();
    {
        let mut items = store.items.lock().unwrap();
        let p = path.to_string_lossy().to_string();
        if items.iter().any(|i| i.path == p) {
            return;
        }
        let id = items.iter().map(|i| i.id).max().unwrap_or(0) + 1;
        items.push(Item { id, path: p, kind: kind.into(), added: now() });
        // A full dock lets the oldest go; Clipstar's own copies go to the Recycle Bin.
        while items.len() > MAX_ITEMS {
            let old = items.remove(0);
            if store.in_inbox(&old.path) {
                let _ = trash::delete(&old.path);
            }
        }
    }
    store.save();
    let _ = app.emit("items", store.items.lock().unwrap().clone());
    refresh_tray(app);
}

// MARK: Commands from the page

#[derive(Serialize)]
struct Snapshot {
    items: Vec<Item>,
    settings: Settings,
    unlocked: bool,
}

#[tauri::command]
fn state(store: State<Store>) -> Snapshot {
    Snapshot {
        items: store.items.lock().unwrap().clone(),
        settings: store.settings.lock().unwrap().clone(),
        unlocked: *store.unlocked_until.lock().unwrap() > now(),
    }
}

#[tauri::command]
fn copy_item(id: u64, store: State<Store>) -> Result<(), String> {
    let item = store.items.lock().unwrap().iter().find(|i| i.id == id).cloned().ok_or("gone")?;
    store.ignore_clipboard.store(true, Ordering::SeqCst);
    let r = if item.kind == "text" {
        clip::set_text(&fs::read_to_string(&item.path).map_err(|e| e.to_string())?)
    } else {
        clip::set_image(&item.path)
    };
    // Long enough for the watcher to see our own change and let it pass.
    let flag = store.ignore_clipboard.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(1500));
        flag.store(false, Ordering::SeqCst);
    });
    r
}

/// Takes it out of the dock; Clipstar's own copies go to the Recycle Bin.
#[tauri::command]
fn remove_item(id: u64, app: AppHandle, store: State<Store>) {
    let gone = {
        let mut items = store.items.lock().unwrap();
        let gone: Vec<Item> = items.iter().filter(|i| i.id == id).cloned().collect();
        items.retain(|i| i.id != id);
        gone
    };
    for g in gone {
        if store.in_inbox(&g.path) {
            let _ = trash::delete(&g.path);
        }
    }
    store.save();
    let _ = app.emit("items", store.items.lock().unwrap().clone());
    refresh_tray(&app);
}

#[tauri::command]
fn clear_all(app: AppHandle, store: State<Store>) {
    let all = std::mem::take(&mut *store.items.lock().unwrap());
    let own: Vec<String> = all.iter().filter(|i| store.in_inbox(&i.path)).map(|i| i.path.clone()).collect();
    std::thread::spawn(move || {
        let _ = trash::delete_all(own);
    });
    store.save();
    let _ = app.emit("items", Vec::<Item>::new());
    refresh_tray(&app);
}

#[tauri::command]
fn open_item(id: u64, store: State<Store>) {
    if let Some(item) = store.items.lock().unwrap().iter().find(|i| i.id == id) {
        if item.kind == "text" && *store.unlocked_until.lock().unwrap() <= now() {
            return;
        }
        let _ = open::that_detached(&item.path);
    }
}

#[tauri::command]
fn reveal_item(id: u64, store: State<Store>) {
    if let Some(item) = store.items.lock().unwrap().iter().find(|i| i.id == id) {
        #[cfg(windows)]
        let _ = std::process::Command::new("explorer").arg(format!("/select,{}", item.path)).spawn();
        #[cfg(target_os = "macos")]
        let _ = std::process::Command::new("open").args(["-R", &item.path]).spawn();
    }
}

/// Copied text, only while it is unlocked.
#[tauri::command]
fn read_text(id: u64, store: State<Store>) -> Result<String, String> {
    if *store.unlocked_until.lock().unwrap() <= now() {
        return Err("locked".into());
    }
    let item = store.items.lock().unwrap().iter().find(|i| i.id == id).cloned().ok_or("gone")?;
    fs::read_to_string(&item.path).map_err(|e| e.to_string())
}

/// How long text is, and the length of its first few lines, to draw
/// asterisks in its shape without showing it.
#[tauri::command]
fn text_shape(id: u64, store: State<Store>) -> Result<(usize, Vec<usize>), String> {
    let item = store.items.lock().unwrap().iter().find(|i| i.id == id).cloned().ok_or("gone")?;
    let text = fs::read_to_string(&item.path).map_err(|e| e.to_string())?;
    let lines = text.lines().filter(|l| !l.trim().is_empty()).take(4).map(|l| l.chars().count()).collect();
    Ok((text.chars().count(), lines))
}

/// Windows Hello: a face, a fingerprint or the PIN; then text shows for as
/// long as Keep text shown says. Answers "ok", or why it did not unlock.
#[tauri::command]
async fn unlock_text(app: AppHandle) -> String {
    #[cfg(windows)]
    let owner = app.get_webview_window("dock").and_then(|w| w.hwnd().ok()).map(|h| h.0 as isize).unwrap_or(0);
    #[cfg(not(windows))]
    let owner = 0isize;
    let answer = tauri::async_runtime::spawn_blocking(move || verify(owner)).await.unwrap_or_else(|_| "failed".into());
    trace(&app, format!("unlock: {answer}"));
    let ok = answer == "ok";
    if ok {
        let store = app.state::<Store>();
        let keep = store.settings.lock().unwrap().keep_text;
        let until = match keep {
            k if k > 0 => now() + (k as u64) * 60,
            _ => u64::MAX,
        };
        *store.unlocked_until.lock().unwrap() = until;
    }
    answer
}

#[tauri::command]
fn lock_text(store: State<Store>) {
    *store.unlocked_until.lock().unwrap() = 0;
}

/// Asks Windows Hello, as the dock window, so its prompt shows in front.
/// A desktop app has to name its window; the plain call only works in
/// Store apps.
#[cfg(windows)]
fn verify(owner: isize) -> String {
    use windows::core::{factory, HSTRING};
    use windows::Foundation::IAsyncOperation;
    use windows::Security::Credentials::UI::{
        UserConsentVerificationResult as R, UserConsentVerifier, UserConsentVerifierAvailability as A,
    };
    use windows::Win32::Foundation::HWND;
    use windows::Win32::System::WinRT::IUserConsentVerifierInterop;
    match UserConsentVerifier::CheckAvailabilityAsync().and_then(|op| op.get()) {
        Ok(A::Available) => {}
        Ok(A::NotConfiguredForUser) => return "not set up".into(),
        Ok(A::DisabledByPolicy) => return "turned off by policy".into(),
        Ok(_) => return "no device".into(),
        Err(e) => return format!("unavailable: {e}"),
    }
    let interop = match factory::<UserConsentVerifier, IUserConsentVerifierInterop>() {
        Ok(i) => i,
        Err(e) => return format!("no interop: {e}"),
    };
    let op: windows::core::Result<IAsyncOperation<R>> = unsafe {
        interop.RequestVerificationForWindowAsync(HWND(owner as *mut _), &HSTRING::from("Show your copied text"))
    };
    match op.and_then(|op| op.get()) {
        Ok(R::Verified) => "ok".into(),
        Ok(R::Canceled) => "cancelled".into(),
        Ok(other) => format!("not verified: {}", other.0),
        Err(e) => format!("failed: {e}"),
    }
}

#[cfg(not(windows))]
fn verify(_owner: isize) -> String {
    // Only for trying the app out on a Mac.
    "ok".into()
}

/// A line for display.log, from the page, for checking sizes.
#[tauri::command]
fn note(text: String, app: AppHandle) {
    trace(&app, text);
}

/// The page has played the way out; the window goes.
#[tauri::command]
fn hide_dock(app: AppHandle) {
    let store = app.state::<Store>();
    if store.settings.lock().unwrap().keep_text == -1 {
        *store.unlocked_until.lock().unwrap() = 0;
    }
    if let Some(w) = app.get_webview_window("dock") {
        let _ = w.hide();
    }
}

#[tauri::command]
fn set_setting(key: String, value: serde_json::Value, app: AppHandle, store: State<Store>) {
    {
        let mut s = store.settings.lock().unwrap();
        match key.as_str() {
            "skin" => s.skin = value.as_str().unwrap_or("card").into(),
            "arrival" => s.arrival = value.as_str().unwrap_or("warp").into(),
            "size" => s.size = value.as_u64().unwrap_or(150) as u32,
            "sky" => s.sky = value.as_f64().unwrap_or(0.8),
            "dock_images" => s.dock_images = value.as_bool().unwrap_or(true),
            "dock_text" => s.dock_text = value.as_bool().unwrap_or(true),
            "keep_text" => s.keep_text = value.as_i64().unwrap_or(60),
            _ => return,
        }
    }
    store.save();
    let _ = app.emit("settings", store.settings.lock().unwrap().clone());
    refresh_tray(&app);
}

// MARK: Opening the dock

/// A line in display.log, in Clipstar's data folder, for sorting out how a
/// display is measured.
fn trace(app: &AppHandle, text: String) {
    use std::io::Write;
    let path = app.state::<Store>().dir.join("display.log");
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{text}");
    }
}

/// Opens the dock on the display under the pointer, or closes it. The
/// window covers that display's work area, the taskbar left clear.
pub fn toggle(app: &AppHandle) {
    let Some(w) = app.get_webview_window("dock") else { return };
    if w.is_visible().unwrap_or(false) {
        let _ = app.emit("close", ());
        return;
    }
    let cursor = app.cursor_position();
    let monitors = w.available_monitors().unwrap_or_default();
    trace(app, format!("open: cursor {:?}, {} monitors", cursor, monitors.len()));
    let under = cursor.as_ref().ok().and_then(|c| {
        monitors.iter().find(|m| {
            let p = m.position();
            let s = m.size();
            c.x >= p.x as f64 && c.x < p.x as f64 + s.width as f64 && c.y >= p.y as f64 && c.y < p.y as f64 + s.height as f64
        })
    });
    let monitor = under
        .cloned()
        .or_else(|| w.current_monitor().ok().flatten())
        .or_else(|| w.primary_monitor().ok().flatten())
        .or_else(|| monitors.first().cloned());
    match monitor {
        Some(m) => {
            let area = m.work_area();
            let r1 = w.set_position(PhysicalPosition::new(area.position.x, area.position.y));
            let r2 = w.set_size(PhysicalSize::new(area.size.width, area.size.height));
            trace(app, format!(
                "monitor {:?} {:?} scale {} work {:?} {:?} -> {:?} {:?}; window {:?} {:?} scale {:?}",
                m.position(), m.size(), m.scale_factor(), area.position, area.size, r1.err(), r2.err(),
                w.outer_position().ok(), w.inner_size().ok(), w.scale_factor().ok()
            ));
        }
        None => trace(app, "no monitor found".into()),
    }
    let _ = w.show();
    let _ = w.set_focus();
    let _ = app.emit("open", ());
}

// MARK: Tray

const SKINS: [(&str, &str); 10] = [
    ("card", "Card"), ("starfighter", "Starfighter"), ("shuttle", "Shuttle"), ("freighter", "Freighter"),
    ("rocket", "Rocket"), ("satellite", "Satellite"), ("xwing", "X-Wing"), ("capsule", "Capsule"),
    ("module", "Station Module"), ("stealth", "Stealth"),
];
const ARRIVALS: [(&str, &str); 7] = [
    ("warp", "Warp In"), ("deep", "From Deep Space"), ("formation", "Formation"), ("reentry", "Re-entry"),
    ("wormhole", "Wormhole"), ("orbit", "Orbit"), ("hyperjump", "Hyperspace Jump"),
];
const SIZES: [u32; 5] = [100, 125, 150, 175, 200];
const SKIES: [(f64, &str); 4] = [(0.95, "Solid"), (0.8, "Dim"), (0.6, "Light"), (0.4, "Faint")];
const KEEPS: [(i64, &str); 5] = [(-1, "Until the dock closes"), (15, "15 minutes"), (60, "1 hour"), (240, "4 hours"), (0, "Until Clipstar quits")];

fn build_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let store = app.state::<Store>();
    let s = store.settings.lock().unwrap().clone();
    let count = store.items.lock().unwrap().len();
    let open = MenuItem::with_id(app, "open", "Open dock\tCtrl+Alt+H", true, None::<&str>)?;
    let clear = MenuItem::with_id(app, "clear", "Undock everything", count > 0, None::<&str>)?;
    let images = CheckMenuItem::with_id(app, "images", "Dock copied images", true, s.dock_images, None::<&str>)?;
    let text = CheckMenuItem::with_id(app, "text", "Dock copied text", true, s.dock_text, None::<&str>)?;
    let check = |id: String, title: &str, on: bool| CheckMenuItem::with_id(app, id, title, true, on, None::<&str>);
    let skins = Submenu::with_id(app, "skins", "Skin", true)?;
    for (k, t) in SKINS {
        skins.append(&check(format!("skin:{k}"), t, s.skin == k)?)?;
    }
    let arrivals = Submenu::with_id(app, "arrivals", "Arrival", true)?;
    for (k, t) in ARRIVALS {
        arrivals.append(&check(format!("arrival:{k}"), t, s.arrival == k)?)?;
    }
    let sizes = Submenu::with_id(app, "sizes", "Size", true)?;
    for n in SIZES {
        sizes.append(&check(format!("size:{n}"), &format!("{n}%"), s.size == n)?)?;
    }
    let skies = Submenu::with_id(app, "skies", "Background", true)?;
    for (v, t) in SKIES {
        skies.append(&check(format!("sky:{v}"), t, (s.sky - v).abs() < 0.01)?)?;
    }
    let keeps = Submenu::with_id(app, "keeps", "Keep text shown", true)?;
    for (v, t) in KEEPS {
        keeps.append(&check(format!("keep:{v}"), t, s.keep_text == v)?)?;
    }
    let folder = MenuItem::with_id(app, "folder", "Open screenshots folder", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Clipstar", true, None::<&str>)?;
    Menu::with_items(app, &[
        &open, &clear, &PredefinedMenuItem::separator(app)?,
        &images, &text, &PredefinedMenuItem::separator(app)?,
        &skins, &arrivals, &sizes, &skies, &keeps, &PredefinedMenuItem::separator(app)?,
        &folder, &PredefinedMenuItem::separator(app)?, &quit,
    ])
}

fn refresh_tray(app: &AppHandle) {
    if let (Some(tray), Ok(menu)) = (app.tray_by_id("main"), build_menu(app)) {
        let _ = tray.set_menu(Some(menu));
        let n = app.state::<Store>().items.lock().unwrap().len();
        let _ = tray.set_tooltip(Some(if n == 0 { "Clipstar: the dock is empty".to_string() } else { format!("Clipstar: {n} docked") }));
    }
}

fn on_menu(app: &AppHandle, id: &str) {
    let store = app.state::<Store>();
    let set = |k: &str, v: serde_json::Value| set_setting(k.into(), v, app.clone(), app.state::<Store>());
    match id {
        "open" => toggle(app),
        "clear" => clear_all(app.clone(), store),
        "images" => set("dock_images", (!store.settings.lock().unwrap().dock_images).into()),
        "text" => set("dock_text", (!store.settings.lock().unwrap().dock_text).into()),
        "folder" => {
            let _ = open::that_detached(screenshots_folder());
        }
        "quit" => app.exit(0),
        other => {
            if let Some((k, v)) = other.split_once(':') {
                match k {
                    "skin" | "arrival" => set(k, v.into()),
                    "size" => set("size", v.parse::<u64>().unwrap_or(150).into()),
                    "sky" => set("sky", v.parse::<f64>().unwrap_or(0.8).into()),
                    "keep" => set("keep_text", v.parse::<i64>().unwrap_or(60).into()),
                    _ => {}
                }
            }
        }
    }
}

/// The pointer resting on the tray icon for a moment opens the dock, like
/// pointing at the menu bar icon on a Mac; a left click opens it too.
static HOVER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn on_tray(app: &AppHandle, event: tauri::tray::TrayIconEvent) {
    use tauri::tray::{MouseButton, MouseButtonState, TrayIconEvent};
    match event {
        TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } => {
            HOVER.fetch_add(1, Ordering::SeqCst);
            toggle(app);
        }
        TrayIconEvent::Enter { .. } => {
            let ticket = HOVER.fetch_add(1, Ordering::SeqCst) + 1;
            let app = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(400));
                if HOVER.load(Ordering::SeqCst) != ticket {
                    return;
                }
                let shown = app.get_webview_window("dock").map(|w| w.is_visible().unwrap_or(false)).unwrap_or(false);
                if !shown {
                    let a = app.clone();
                    let _ = app.run_on_main_thread(move || toggle(&a));
                }
            });
        }
        TrayIconEvent::Leave { .. } => {
            HOVER.fetch_add(1, Ordering::SeqCst);
        }
        _ => {}
    }
}

// MARK: Watching for screenshots

/// Where Windows 11 saves screenshots (Print Screen, Win+Print Screen,
/// Snipping Tool); on a Mac, for trying it out, the Desktop.
fn screenshots_folder() -> PathBuf {
    #[cfg(windows)]
    {
        dirs::picture_dir().unwrap_or_default().join("Screenshots")
    }
    #[cfg(not(windows))]
    {
        dirs::desktop_dir().unwrap_or_default()
    }
}

fn is_image(p: &Path) -> bool {
    matches!(p.extension().and_then(|e| e.to_str()).map(|e| e.to_ascii_lowercase()).as_deref(), Some("png" | "jpg" | "jpeg"))
}

fn watch_screenshots(app: AppHandle) {
    use notify::{EventKind, RecursiveMode, Watcher};
    let folder = screenshots_folder();
    let _ = fs::create_dir_all(&folder);
    std::thread::spawn(move || {
        let (tx, rx) = std::sync::mpsc::channel();
        let Ok(mut watcher) = notify::recommended_watcher(tx) else { return };
        if watcher.watch(&folder, RecursiveMode::NonRecursive).is_err() {
            return;
        }
        for event in rx.into_iter().flatten() {
            if !matches!(event.kind, EventKind::Create(_) | EventKind::Modify(notify::event::ModifyKind::Name(_))) {
                continue;
            }
            for p in event.paths {
                let hidden = p.file_name().and_then(|n| n.to_str()).map(|n| n.starts_with('.')).unwrap_or(true);
                if is_image(&p) && !hidden && p.exists() {
                    // Let the screenshot finish writing.
                    std::thread::sleep(Duration::from_millis(120));
                    dock(&app, p, "image");
                }
            }
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};
    let shortcut = Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyH);
    tauri::Builder::default()
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |app, s, event| {
                    if s == &shortcut && event.state() == ShortcutState::Pressed {
                        toggle(app);
                    }
                })
                .build(),
        )
        .setup(move |app| {
            let dir = app.path().app_data_dir()?;
            app.manage(Store::load(dir));
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let menu = build_menu(app.handle())?;
            TrayIconBuilder::with_id("main")
                .icon(tauri::image::Image::from_bytes(include_bytes!("../icons/tray.png"))?)
                .menu(&menu)
                .show_menu_on_left_click(false)
                .tooltip("Clipstar")
                .on_menu_event(|app, e| on_menu(app, e.id().as_ref()))
                .on_tray_icon_event(|tray, event| on_tray(tray.app_handle(), event))
                .build(app)?;
            refresh_tray(app.handle());
            // Taken by another app: the tray menu still opens the dock.
            if let Err(e) = app.global_shortcut().register(shortcut) {
                eprintln!("Clipstar: Ctrl+Alt+H is taken: {e}");
            }
            watch_screenshots(app.handle().clone());
            clip::watch(app.handle().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            state, copy_item, remove_item, clear_all, open_item, reveal_item, read_text, text_shape,
            unlock_text, lock_text, hide_dock, set_setting, note
        ])
        .run(tauri::generate_context!())
        .expect("Clipstar could not start");
}
