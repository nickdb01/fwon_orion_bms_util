# Orion Diagnostics for macOS

Native macOS monitoring and diagnostics for Orion Junior BMS devices. Current version: **0.2.5**. Supports macOS 14 or later on Apple Silicon and Intel.

## Download and run

[Download Orion Diagnostics v0.2.5 for macOS](downloads/Orion-Diagnostics-v0.2.5-macOS.zip)

Unzip the archive and open **Orion Diagnostics.app**. The application is ad-hoc signed; Developer ID signing and notarization have not been performed.

1. Connect a USB-to-RS-232 adapter to the powered BMS diagnostic port. The adapter must provide RTS; use straight-through wiring if extending the serial cable.
2. Close other software using the serial port. USB adapters are detected automatically; **Refresh Connections** rescans immediately.
3. Select the adapter and choose **Connect to BMS**. Use **Reconnect** if the BMS was powered or attached after the adapter.
4. Open **Diagnostics** and click **Download Faults & Events**. Review **Faults**, **Recent Events** and **Download Details**.
5. Use **Export** to save JSON and CSV reports. Disconnect before opening a saved diagnostic report.

The application only issues diagnostic reads. It has no fault-clear, reset, calibration, firmware-update or configuration-write commands.

## Features

- **Overview:** live pack measurements, state of charge, temperatures, output flags and current limits.
- **Cells:** voltage, resistance and open-cell voltage for up to 16 channels, with configured and balancing flags, acquisition times and summary statistics.
- **Live Charts:** selectable signals, Pack Health / Charging / SOC Investigation presets, time windows, inspection and panning. The dropdown shows the matching preset or **Custom**.
- **Recordings:** incremental `.orionlog` recording, replay and CSV export. Acquisition continues when charts are paused.
- **History:** lifetime runtime, power-ups, cycles and available accumulated counters.
- **Diagnostics:** retained faults/events, selected fault subcodes and available core freeze-frame readings, with partial-result and cancellation handling.
- Automatic serial discovery, manual refresh/reconnect and disconnect detection.
- An offline demo with clearly marked synthetic data; it opens no serial port.
- Workspace keyboard shortcuts **Command-1** through **Command-6**.

## Data and compatibility

Event timestamps are cumulative BMS operating seconds, not historical calendar dates. Mac acquisition/download times are recorded separately. Overwritten BMS events cannot be recovered.

Missing or unsupported measurements remain unavailable. Read requests use bounded retries and cancellation checks. Recent raw replies and section statuses are retained in diagnostic exports. Empty fault lists must be interpreted alongside download status.

The reader recognizes signatures `ORIONBMS03` through `ORIONBMS08`, including `ORIONBMS04`. Device signature and firmware are displayed without inferring the exact product generation. Compatibility varies by device and firmware; broader hardware acceptance remains incomplete.

Recordings preserve per-signal timestamps, raw replies and device identity. The live/replay buffer retains up to 2,000 polling cycles. Recording files stop at 100 MB; file rotation and full-file indexing are not implemented. Incomplete final recording lines can be recovered.

Profile editing, service writes, histogram distributions, legacy vendor-log import and CAN/accessory integrations are not implemented.

## Build and test

Requires Xcode with Swift 6 or later. The application has no third-party package dependencies and does not require Java.

```sh
./scripts/swiftw test
./scripts/package-app.sh --universal
```

The packaged app and ZIP are generated in `dist/`. Omit `--universal` for a build targeting the current Mac. Build caches remain inside `.build/`; the wrapper does not change the system developer-directory selection. Release builds omit debug symbols.

The test suite contains **48 tests**, covering framing, serial pseudo-terminal exchanges, decoding, discovery, cancellation, missing data, recording recovery, export and application layout sizing. Physical acceptance should also compare values and diagnostic records with the manufacturer utility on each target firmware.

Run a synthetic export without opening a window:

```sh
"./dist/Orion Diagnostics.app/Contents/MacOS/OrionDiagnostics" --export-demo /tmp
```

Launch that executable with `--demo` to connect to the simulator and download synthetic records automatically. Normal launches do not connect automatically.

## Source layout

- `Sources/CSerial`: POSIX serial configuration and I/O, 9600 baud, 8E1 and RTS.
- `Sources/BMSCore`: request framing, discovery, decoding, acquisition, recordings and report import/export.
- `Sources/OrionDiagnostics`: SwiftUI interface and application state.
- `Tests/BMSCoreTests`: protocol, transport and application tests.
- `scripts`: build, packaging and icon generation.
- `downloads`: packaged macOS application and checksum.

## References

- [Orion Jr. 2 wiring manual](https://www.orionbms.com/manuals/pdf/jr2_wiring_manual.pdf)
- [Orion Jr. 2 operation manual](https://www.orionbms.com/manuals/pdf/jr2_operational_manual.pdf)

This is an independently implemented utility, not an official Ewert Energy Systems or Orion application. No vendor JAR, native libraries, UI assets, extracted Java source or vendor fault documents are included.
