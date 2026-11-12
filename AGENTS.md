# AGENTS.md

## Project Overview

**SwitchMTP** is a native macOS MTP (Media Transfer Protocol) explorer built specifically for the Nintendo Switch's **"Copy to a Computer via USB Connection"** mode (as well as standard USB Still Image / MTP devices). Because macOS does not mount MTP devices in Finder natively, SwitchMTP communicates directly with the Nintendo Switch over USB Bulk pipes using Apple's `IOKit` and `IOUSBHost` frameworks—with zero external dependencies (`libmtp` or Homebrew are not required).

### Key Technologies & Frameworks

- **Language**: Swift (Swift 6 approachable concurrency / default `@MainActor` isolation enabled)
- **UI**: SwiftUI + AppKit (`NavigationSplitView`, `.inspector`, `Table`, `NSOpenPanel`, `NSPasteboard`, `NSWorkspace`)
- **Video Playback**: `AVFoundation` + `AVKit` (`AVPlayerView` wrapped via `NSViewRepresentable` in `MacVideoPlayerView`)
- **USB & MTP Transport**: `IOKit` and `IOUSBHost` (`IOUSBHostInterface`, `IOUSBHostPipe`)

### Architecture & File Organization

- `SwitchMTP/SwitchMTPApp.swift`: Application entry point (`Window("SwitchMTP", id: "main")` with `1120×740` default size, `860×540` min size, and `.unified` toolbar style) and `AppDelegate` enforcing single-instance launch, terminating when the last window closes, and disabling macOS window tabbing (`NSWindow.allowsAutomaticWindowTabbing = false` and removing tab menu items).
- `SwitchMTP/MTPModels.swift`: `nonisolated`, `Sendable` protocol constants and data models (`MTPContainerType`, `MTPOperationCode`, `MTPResponseCode`, `MTPObjectFormat`, `MTPDeviceDetails`, `MTPStorage`, `MTPObjectItem`, `MTPError`, and `MTPDateParser`).
- `SwitchMTP/MTPUSBClient.swift`: Low-level USB device discovery and MTP session/container engine. Runs all synchronous `IOUSBHostPipe` bulk transfers on a dedicated serial `DispatchQueue` (`me.podter.SwitchMTP.usbQueue`) bridged to Swift `async`/`await`.
- `SwitchMTP/MTPViewModel.swift`: `@Observable` main-actor view model managing USB hotplug polling (every 2 seconds), directory & breadcrumb navigation, progressive `All Media` indexing, in-memory folder and thumbnail caching (`GetThumb`), full-resolution image/video previewing, clipboard copy, Quick Save to `~/Downloads`, and single/batch file or folder export.
- `SwitchMTP/ContentView.swift`: Native macOS split-view explorer UI (`NavigationSplitView` + `.inspector`) featuring a Sidebar (`Library` filters: `All Media`, `Screenshots`, `Videos`, `All Games`; `Games` folder list; and bottom `DeviceStatusFooter` with device info popover), unified toolbar (back navigation, title/subtitle, search, Grid/List segmented picker, Filter/Sort/Thumbnail Size menu, Save/Export menu, and Info inspector toggle), 16:9 Thumbnail Grid view (`MediaGridView`), multi-column Table view (`MediaTableView`), right-hand Inspector pane (`InspectorPane`), and full-size Media Lightbox sheet (`MediaLightboxSheet`).

---

## Setup & Build Commands

### Inside Xcode (MCP Tools — Preferred)

When running inside Xcode's coding assistant environment, prefer Xcode MCP tools over shell commands:

- **Quick file diagnostics**: Use `XcodeRefreshCodeIssuesInFile` on any modified `.swift` file.
- **Full build**: Use `BuildProject` to compile and link `SwitchMTP.app`.
- **Run app**: Use `RunProject` (`attachDebugger: false`) and inspect runtime logs with `GetConsoleOutput`.

### Command Line (`xcodebuild`)

- **Build Debug configuration**:
  ```bash
  xcodebuild -project SwitchMTP.xcodeproj -scheme SwitchMTP -configuration Debug -destination "platform=macOS" build
  ```
- **Clean build folder**:
  ```bash
  xcodebuild -project SwitchMTP.xcodeproj -scheme SwitchMTP clean
  ```

### Sandbox & Signing Configuration

- `ENABLE_APP_SANDBOX` MUST remain `NO` on the `SwitchMTP` target so the app can seize the USB MTP interface from macOS's background `ptpcamerad` daemon (`IOUSBHostObjectInitOptions.deviceSeize`) and export files to user-selected directories.
- Do not add restricted DriverKit or USB entitlements to `CODE_SIGN_ENTITLEMENTS` when signing with a Personal Team, as macOS `amfid` will terminate the binary on launch.

---

## Nintendo Switch MTP Protocol Reference & Quirks

Agents modifying `MTPUSBClient.swift` or `MTPModels.swift` must preserve these hardware-verified behaviors of the Nintendo Switch (`usb:ds` service):

1. **USB Enumeration**:
   - Vendor ID: `0x057E` (Nintendo), Product ID: `0x201D`.
   - Interface #0: `bInterfaceClass = 0x06` (Still Imaging), `bInterfaceSubClass = 0x01`, `bInterfaceProtocol = 0x01`, `"kUSBString" = "MTP"`.
   - Endpoints: Bulk IN `0x81` (`maxPacketSize = 512`), Bulk OUT `0x01` (`maxPacketSize = 512`), Interrupt IN `0x82` (`maxPacketSize = 24`).

2. **Split 12-Byte Data Container Header**:
   - Standard MTP containers begin with a 12-byte header: `length: UInt32`, `type: UInt16` (`1` = Command, `2` = Data, `3` = Response), `code: UInt16`, `transactionID: UInt32`.
   - **Quirk**: During a Data phase (`type == 2`), the Nintendo Switch sends the 12-byte MTP Data header in its own separate 12-byte USB Bulk IN packet first, followed by the payload bytes in subsequent Bulk IN transfers, followed by a 12-byte Response container (`type == 3`).
   - Always compute `expectedPayload = Int(containerLen) - 12` from the first packet and continue reading from `pipeIn` until `payload.count == expectedPayload`, then read one more packet for the Response container.

3. **512-Byte Bulk IN Buffer Alignment**:
   - Always round the `NSMutableData` receive buffer length up to a multiple of `maxPacketSizeIn` (`512` bytes) when calling `pipeIn.__sendIORequest(with:bytesTransferred:completionTimeout:)` to prevent USB host controller babble/overflow errors.

4. **Strict Transaction IDs & Stale Session Recovery (`0x201E`)**:
   - `OpenSession` (`0x1002`) MUST be sent with `TransactionID = 0`. The first command after `OpenSession` uses `TransactionID = 1` and increments by `1` on every command.
   - If the app was previously force-quit or restarted while the Switch remained plugged in, the Switch keeps its MTP session open and returns `0x201E` (`SessionAlreadyOpen`) to `OpenSession(tx=0)`, while rejecting `CloseSession` unless the exact expected `TransactionID` is supplied.
   - `MTPUSBClient.openSessionSync()` persists `SwitchMTP.lastTransactionID` in `UserDefaults` and probes `CloseSession` (`0x1003`) across candidate transaction IDs until the Switch returns `0x2001` (`OK`), then reopens a clean session at `tx = 0`.

5. **Supported Switch MTP Operations**:
   - The Switch supports opcodes `0x1001` (`GetDeviceInfo`), `0x1002` (`OpenSession`), `0x1003` (`CloseSession`), `0x1004` (`GetStorageIDs`), `0x1005` (`GetStorageInfo`), `0x1006` (`GetNumObjects`), `0x1007` (`GetObjectHandles`), `0x1008` (`GetObjectInfo`), `0x1009` (`GetObject`), and `0x100A` (`GetThumb`).
   - Root object handles on storage `0x00170001` (`Album`) must be queried with `parentHandle = 0xFFFFFFFF` (using `0x00000000` returns `0x2009` `InvalidObjectHandle` on the Switch).

---

## Code Style, UI & Concurrency Guidelines

- **Apple Human Interface Guidelines (HIG)**:
  - When designing or modifying any UI, always follow the [Apple Human Interface Guidelines for macOS](https://developer.apple.com/design/human-interface-guidelines). Use native macOS patterns, standard SwiftUI/AppKit controls, semantic colors and materials, standard SF Symbols, keyboard shortcuts, and expected window/split-view behaviors.
- **Default Actor Isolation**: This target uses Swift 6 approachable concurrency where types are `@MainActor`-isolated by default unless annotated.
  - Mark pure data models and parsers in `MTPModels.swift` and `MTPUSBClient.swift` as `nonisolated` so they can be used on the background USB queue without actor-hopping warnings.
- **USB Thread Safety**:
  - Never call `IOUSBHostPipe.__sendIORequest` on `@MainActor` or directly on Swift's cooperative thread pool. Always dispatch synchronous USB calls onto `MTPUSBClient.usbQueue`.
  - Do not perform speculative `pipeIn` reads with short timeouts before sending a command; timing out a bulk read logs IOKit errors and can stall the pipe.
- **Video Player**:
  - Use `MacVideoPlayerView` (`NSViewRepresentable` wrapping AppKit's `AVPlayerView`) rather than SwiftUI's `VideoPlayer`, which can fail at runtime with `failed to demangle superclass of VideoPlayerView from mangled name 'So12AVPlayerViewC'`.

---

## Hardware Testing & Debugging

- **Live Hardware Testing with User**:
  - It is completely okay (and encouraged) to ask the user to connect their physical Nintendo Switch via USB and enable **System Settings → Data Management → Manage Screenshots and Videos → Copy to a Computer via USB Connection** whenever you need to verify device connection, test MTP operations, or confirm end-to-end functionality.
- **"Nintendo Switch disconnected" / Device Not Found**:
  - Verify the Switch is awake and on the **System Settings → Data Management → Manage Screenshots and Videos → Copy to a Computer via USB Connection** screen.
  - Check `MTPUSBClient.isSwitchPresentInRegistry()` to confirm macOS enumerates `idVendor == 0x057E` and `idProduct == 0x201D`.
- **"`Could not claim USB MTP interface: Failed to create IOUSBHostInterface.`" / "`USB transfer error: Unable to send IO.`"**:
  - macOS automatically spawns `ptpcamerad` / `PTPCamera` (or a background Xcode Preview instance) to claim `IOUSBHostInterface` exclusively when a Still Image (`bInterfaceClass = 0x06`) USB device is plugged in. Because Personal Team code signing cannot include the restricted `com.apple.vm.device-access` entitlement required for kernel-level `.deviceSeize`, `MTPUSBClient.releaseCompetingUSBHoldersIfNeeded()` inspects `kIOServicePlane` child user clients (`IOUserClientCreator`), terminates competing user-space holders, waits for the kernel `IOUSBHostDevice` / `IOUSBHostInterface` re-enumeration to settle before acquiring a fresh `io_service_t`, and calls `drainPendingBulkInSync()` to drain any unread Bulk IN packets left in the Switch's USB FIFO by `ptpcamerad`.
- **`MTP device returned Invalid Transaction ID (0x2004)`**:
  - Ensure `transactionID` increments by 1 per command and that no two commands execute concurrently outside `usbQueue`.
- **SF Symbols**:
  - Note that `"usb"` is not a valid SF Symbol name on macOS; use `"cable.connector"` or `"cable.connector.horizontal"` instead.
