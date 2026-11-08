# Build and locally sign Orion Diagnostics

This guide is for someone who has not built a Mac app before. Commands go in **Terminal**, which is in **Applications → Utilities**. Paste one command at a time and press Return. Do not include the surrounding Markdown backticks.

You build for your **Mac**, not for an individual BMS. The app identifies the connected BMS at runtime. Building the source does not add support for an otherwise unsupported BMS or firmware.

## 1. Prepare your Mac

You need:

- **macOS 14 or later** to run the app.
- **Xcode with Swift 6 or later**, including the macOS development tools. Install a compatible Xcode from the Mac App Store or [Apple Developer downloads](https://developer.apple.com/download/all/). Open Xcode once and finish its first-launch setup. Choose the macOS components if prompted; iPhone simulators are not needed for this app. See [Apple's component instructions](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components).
- **Python 3** for the packaging script's icon step. It uses only Python's standard library. Check with `python3 --version`. If Python is missing, install a supported Python 3 release from [python.org](https://www.python.org/downloads/macos/), then reopen Terminal.

An Apple Developer account or signing certificate is **not required for the default local build**. The packaging script applies an ad-hoc signature automatically. Apple calls this kind of signing [Sign to Run Locally](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## 2. Download the source

On this repository's main GitHub page, select **Code → Download ZIP**, then unzip it in Finder. This is the source archive, separate from the ready-made app ZIP in `downloads/`.

In Terminal, type `cd `, including the trailing space. Drag the unzipped **source folder** from Finder into Terminal, then press Return. Terminal inserts that folder's path for you.

Check you are in the right folder:

```sh
ls
```

You should see `Package.swift`, `Sources`, `Tests` and `scripts`. All following build commands run from this folder. Keep the quotation marks shown around names containing spaces.

## 3. Build for your Mac

First run the tests:

```sh
./scripts/swiftw test
```

Wait for the test summary. If tests fail, resolve the reported failure before continuing.

For an app built for the architecture running your Terminal session:

```sh
./scripts/package-app.sh
```

Normally this produces an Apple Silicon build on an M-series Mac or an Intel build on an Intel Mac. A Terminal session running under Rosetta can select Intel instead. To avoid that distinction, or to share with both kinds of Mac, use the universal build:

```sh
./scripts/package-app.sh --universal
```

**Choose one packaging command.** Both produce the same output names and replace any earlier build in `dist/`. The universal option includes `arm64` and `x86_64` in one application; it does not add support for macOS versions below 14.

When successful, the script prints `Built .../dist/Orion Diagnostics.app`. It creates:

- `dist/Orion Diagnostics.app` — the runnable application, already locally signed.
- `dist/Orion-Diagnostics-macOS.zip` — a ZIP containing that app.

Open the app:

```sh
open "dist/Orion Diagnostics.app"
```

Choose **Explore Offline Demo** to try it without a BMS. You can also drag the app from `dist/` into Applications in Finder. Quit a previous copy before replacing it.

To check the architectures in your build:

```sh
lipo -archs "dist/Orion Diagnostics.app/Contents/MacOS/OrionDiagnostics"
```

A universal build lists both `arm64` and `x86_64`. A native build lists one. Only this macOS app is built; Windows, Linux, iPhone and iPad builds are not supported.

## 4. Check the automatic local signature

The packaging script already signs and verifies the app. You can repeat the verification:

```sh
codesign --verify --deep --strict --verbose=2 "dist/Orion Diagnostics.app"
```

A successful command exits without an error; verbose output may report that the app is valid on disk and satisfies its designated requirement.

Display the signature details:

```sh
codesign --display --verbose=2 "dist/Orion Diagnostics.app"
```

For the default build, look for `Signature=adhoc`. No named Apple signing identity is attached. This checks the signature, not the accuracy of BMS measurements, and does not mean Apple has notarized the app.

## 5. Apply your own local signature manually

This is optional. It is useful after changing an app bundle, or when you want to re-sign your own copy. Quit the app first.

For a build in this source folder, set:

```sh
ORION_SIGN_APP="dist/Orion Diagnostics.app"
```

Alternatively, for a downloaded copy placed in your personal Applications folder, use this **instead**:

```sh
ORION_SIGN_APP="$HOME/Applications/Orion Diagnostics.app"
```

Check that the selected path exists:

```sh
ls -ld "$ORION_SIGN_APP"
```

Then apply an ad-hoc signature and verify it:

```sh
codesign --force --sign - --timestamp=none "$ORION_SIGN_APP"
codesign --verify --deep --strict --verbose=2 "$ORION_SIGN_APP"
```

The single `-` after `--sign` means ad-hoc signing. `--force` replaces the app's existing signature. This requires no signing certificate and does not require administrator access when the app is in a folder you own. It does not notarize the app or guarantee Gatekeeper acceptance on other Macs.

### Optional: use a certificate already in your keychain

If you have your own valid code-signing certificate and its private key, list the available identities locally:

```sh
security find-identity -v -p codesigning
```

Copy the quoted name of the identity you intend to use and replace the placeholder in this command. Do not use the placeholder literally:

```sh
codesign --force --sign "YOUR CODE-SIGNING IDENTITY" --timestamp=none "$ORION_SIGN_APP"
codesign --verify --deep --strict --verbose=2 "$ORION_SIGN_APP"
```

If the list reports zero valid identities, use the ad-hoc method above or follow [Apple's signing-identity instructions](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates) to set up a certificate. Certificates used for local development and **Developer ID Application** certificates used for independent distribution have different purposes. [Apple explains those signing options here](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac).

Rebuilding with `package-app.sh` replaces the app and reapplies the default ad-hoc signature. Apply your certificate signature **after** your final build. Changing files inside a signed app afterward can invalidate its signature.

If you re-sign the app in `dist/` and need an updated ZIP, recreate it after signing:

```sh
ditto -c -k --sequesterRsrc --keepParent "dist/Orion Diagnostics.app" "dist/Orion-Diagnostics-macOS.zip"
```

## If something does not work

| What you see | What to do |
| --- | --- |
| `No such file or directory` for a script | Repeat the `cd` step and check that `ls` shows `Package.swift` and `scripts`. |
| `Permission denied` running a script | Run `chmod +x scripts/swiftw scripts/package-app.sh`, then retry. |
| Xcode setup, SDK or toolchain error | Open Xcode and finish setup. The wrapper uses `/Applications/Xcode.app` if present. For a differently named installation, set `DEVELOPER_DIR` to that Xcode app's `Contents/Developer` folder in this Terminal session. |
| Swift tools version is too old | Install a compatible Xcode that includes Swift 6 or later. An older standalone Command Line Tools installation may not be enough. |
| `python3: command not found` | Install Python 3 using the link in step 1 and reopen Terminal. |
| SwiftPM says the native build system is deprecated | This is a warning. Check the final build result; it does not by itself mean the build failed. |
| `no identity found` when signing | Use the exact identity shown by `security find-identity`, or use `--sign -` for local ad-hoc signing. |
| Signature verification fails | Rebuild an unmodified copy and verify again. Re-sign only the copy you intend to use. |

For a downloaded app blocked because its developer cannot be verified, review [Apple's instructions for opening apps](https://support.apple.com/en-us/102445). For an app you have reviewed and choose to trust, macOS provides an app-specific **Open Anyway** option in **System Settings → Privacy & Security** after an attempted launch. Local signing is not notarization; this guide does not require disabling Gatekeeper or other system-wide security settings.

For distribution to other people with normal Developer ID verification, signing alone is not the whole process: use your own Developer ID Application certificate and Apple's notarization workflow. See [Apple's Developer ID guidance](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).
