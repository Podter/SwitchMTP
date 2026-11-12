# SwitchMTP

**SwitchMTP** is a native macOS MTP (Media Transfer Protocol) explorer built specifically for the Nintendo Switch's **"Copy to a Computer via USB Connection"** mode.

Because macOS does not mount MTP devices in Finder natively, SwitchMTP communicates directly with the Nintendo Switch over USB Bulk pipes using Apple's native `IOKit` and `IOUSBHost` frameworks—with **zero external dependencies** (no `libmtp`, Homebrew, or kernel extensions required).

> [!WARNING]
> **Disclaimer — Vibecoded by AI (Use at Your Own Risk)**
>
> This project was **vibecoded by AI**. It is provided **"AS IS"**, without warranty of any kind, express or implied. While it only uses standard read-only MTP commands (`GetDeviceInfo`, `GetStorageIDs`, `GetStorageInfo`, `GetObjectHandles`, `GetObjectInfo`, `GetObject`, `GetThumb`), it directly interacts with low-level macOS USB interfaces (`IOUSBHost`) and terminates competing background processes (`ptpcamerad`) to claim the USB interface. **Use at your own risk.**

## Features

- **Zero External Dependencies**: Built entirely with native macOS frameworks (`SwiftUI`, `AppKit`, `AVKit`, `IOKit`, and `IOUSBHost`).
- **Automatic USB Hotplug & Interface Claiming**: Automatically detects the Nintendo Switch when plugged in and handles macOS's built-in `ptpcamerad` daemon so you don't get stuck on connecting screens.
- **Library & Per-Game Browsing**:
  - Browse **All Media**, **Screenshots**, **Videos**, or filter by **Game** folder.
  - Search by filename or game title, and sort by Date, Name, or Size.
- **Finder-Style Grid & List Views**:
  - **16:9 Thumbnail Grid** with adjustable thumbnail sizes and rubber-band marquee selection.
  - **Multi-column List View** with sortable columns and rubber-band selection.
- **Built-in Media Preview & Lightbox**:
  - Double-click or press `Space` to preview full-resolution screenshots and play `.mp4` captures directly over USB.
  - Right-hand **Inspector Pane** displaying capture metadata, dimensions, file size, and storage details.
- **Seamless Export**:
  - **Drag and Drop** screenshots or videos directly from SwitchMTP into Finder or other macOS apps.
  - **Quick Save** (`⌘S`) directly to `~/Downloads`.
  - **Export Selected / Export All** (`⇧⌘E` / `⌥⌘E`) to any folder, with optional **Organize by Game Folder** support.
  - **Copy Image to Clipboard** (`⇧⌘C`) for quick sharing.

## How to Use

1. Launch **SwitchMTP** on your Mac.
2. Connect your Nintendo Switch to your Mac using a USB-C data cable.
3. On your Nintendo Switch, go to:
   **System Settings → Data Management → Manage Screenshots and Videos → Copy to a Computer via USB Connection**
4. SwitchMTP will automatically detect your Switch, open an MTP session, and load your Album.

## Building from Source

### Requirements

- **macOS** (Apple Silicon or Intel)
- **Xcode** (Swift 6 / macOS SDK)

### Build with Xcode

1. Open `SwitchMTP.xcodeproj` in Xcode.
2. Select the **SwitchMTP** scheme and your Mac as the run destination.
3. Build and run (`⌘R`).

> **Note on App Sandbox & Code Signing**:
> `ENABLE_APP_SANDBOX` must remain `NO` so SwitchMTP can claim the USB MTP interface and export files to user-selected folders. Do not add restricted DriverKit or USB entitlements when signing with a Personal Team, or macOS `amfid` will block launch.

### Build from Command Line

```bash
xcodebuild -project SwitchMTP.xcodeproj -scheme SwitchMTP -configuration Debug -destination "platform=macOS" build
```

## How It Works

If you want to understand how SwitchMTP works under the hood—including its architecture, Swift 6 concurrency model, USB Bulk pipe communication, and Nintendo Switch MTP protocol quirks (such as split 12-byte Data container headers, 512-byte Bulk IN buffer alignment, `0x201E` stale session recovery, and `ptpcamerad` USB interface claiming)—check out **[AGENTS.md](./AGENTS.md)**, which serves as a comprehensive technical deep-dive and protocol reference.

## License

This project is licensed under the **MIT License**.
