# AI Coding Agent Guide — FolderWatcher

This repo is a Windows-only PowerShell utility that manages folder change watchers and runs user-defined commands when changes occur. There are two UIs over the same core behavior: a WPF window (primary) and a legacy WinForms tray app (deprecated, kept for reference). Watcher configs persist to `watchers.ini` alongside the scripts.

Important: Everything under `deprecated/` is off-limits for evaluation and modification. Treat it as historical reference only.

## Big Picture
- entry point: `FolderWatcherWpf.ps1` (WPF window).
- Core: `.NET FileSystemWatcher` per configured folder with `IncludeSubdirectories = $true`, events `Created` and `Changed`, and a 2s debounce per file path.
- Actions: user-provided command line, with optional token `{{FOLDER}}` replaced by the watched folder path.
- Persistence: one line per watcher in `watchers.ini` using `Folder|Command` format.

## Key Files
- `FolderWatcherWpf.ps1`: Loads `FolderWatcher.xaml`, binds controls, manages watchers and persistence.
- `FolderWatcher.xaml`: WPF layout (ListView + Add/Edit/Remove/Exit buttons with names matched in the script).
- `watchers.ini`: Saved/loaded at runtime (created if missing).
- `folder-watch.ico` / `folder-watch.png`: Tray/UI assets used by the WinForms app.

## Run & Debug
- WPF window:
  - `pwsh -ExecutionPolicy Bypass -File .\FolderWatcherWpf.ps1`

Tray behavior (WPF): the WPF app creates a system tray icon using `folder-watch.ico`. Closing the window hides it and keeps the tray active; left-clicking the tray shows the window; tray context menu offers a single `Exit` command.
- Requires Windows PowerShell/PowerShell with .NET Desktop; uses `PresentationFramework`, `System.Windows.Forms`, and `Microsoft.VisualBasic`.

## Data Flow
- UI Add/Edit → `Add-Watcher` → create `FileSystemWatcher` → `Register-ObjectEvent` for `Created`/`Changed` → action scriptblock → `Start-Process` runs the command.
- In WPF, items are shown as objects with properties `{ Folder; Command }`; in WinForms, as `ListViewItem` with subitems.
- Watchers and their event subscriptions are tracked in parallel arrays: `$global:watchers` and `$global:watcherEvents` (two subscriptions per watcher).

## Conventions & Patterns
- INI format: each line `C:\Path\To\Folder|"C:\Path To\app.exe" --arg "{{FOLDER}}"`.
- Token replacement: only `{{FOLDER}}` is supported; it is replaced with the quoted folder path.
- Command parsing: the command is split into `exe` and `args` at the first space. Quote paths with spaces in the `exe` section.
- Debounce: 2000 ms per `FullPath`, implemented with a synchronized hashtable.
- Events: only `Created` and `Changed` are subscribed; `NotifyFilter` is `FileName, LastWrite`.
- WPF control binding is by `Name` via `FindName` (e.g., `WatcherList`, `AddButton`). Names must remain consistent with the XAML.

## Extending
- Add more events as needed (e.g., `Deleted`, `Renamed`) by registering additional `Register-ObjectEvent` subscriptions mirroring the existing pattern.
- Support more tokens (e.g., `{{PATH}}`, `{{NAME}}`) by extending the action scriptblock before `Start-Process`.
- Make debounce configurable by promoting `debounceMs` to a per-watcher or global setting and persisting it in the INI (would require a format change).

## Gotchas
- Event scriptblocks run in separate runspaces; interact with UI via the UI thread only (WPF: use `Dispatcher.Invoke` if needed). Current actions do not touch UI.
- Use `$using:` scope to capture variables inside event actions. The existing pattern uses `$using:command`; apply the same if you add more captured variables.
- When removing/editing watchers, the code removes two event subscriptions per watcher and compacts arrays by index. Keep these arrays in sync if you modify the structure.

## Useful Commands
- List event subscribers: `Get-EventSubscriber`
- Unsubscribe by Id: `Unregister-Event -SubscriptionId <Id>`
- Clear all subscribers from this session: `Get-EventSubscriber | Unregister-Event`
- INI location at runtime: `Join-Path $PSScriptRoot 'watchers.ini'`

## Examples
- INI line example: `C:\Data\Ingest|"C:\Program Files\7-Zip\7z.exe" a "{{FOLDER}}\archive.7z" "{{FOLDER}}\*"`
- Add a `Renamed` event in `Add-Watcher`:
  ```powershell
  $renamed = Register-ObjectEvent $watcher 'Renamed' -Action $action
  $global:watcherEvents += $renamed
  ```
