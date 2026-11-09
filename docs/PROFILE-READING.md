# Read the current BMS profile

Available in **macOS build 0.3.1**. This feature reads configuration; it does not transmit changed settings.

1. Quit an older copy of Orion Diagnostics and open the downloaded app (or your local build in `dist/`).
2. Connect to the BMS with the usual USB-to-RS-232 adapter.
3. Choose **Profile** in the sidebar, then **Read Current Profile**.
4. If the BMS requires authentication, enter its existing profile password and choose **Authenticate & Read**. Cancel leaves the previous profile snapshot available.
5. Review the named settings, filter the table, or select **Show complete raw profile**.
6. **Save Profile Backup** saves a JSON file locally with the full downloaded bytes, decoded core settings, device identity and acquisition time.

## Authentication

The app checks profile-lock status and prompts when the BMS requires a password. It does not guess passwords or make automatic password retries. This implementation accepts 1–8 printable ASCII characters, matching the supported profile authentication representation; it rejects longer/non-ASCII input rather than truncating it.

Passwords are used for the requested operation only. They are not saved to preferences, keychain, diagnostic traces or profile JSON. Both directions of authentication exchanges are redacted from transport logs. The profile itself is an explicit local backup of settings; keep exported files wherever you normally keep configuration backups.

If the app authenticates a session, it sends the reference utility's re-lock command after success, a transfer error, or cancellation. Cancellation does not skip cleanup. If re-locking cannot be confirmed, the connection is closed and a specific error is shown. No profile-write, password-change, reset or calibration commands were added.

## Format and limits

- Supported physical profile layout: the **3.x firmware / 3.0 profile format**, 3,474 bytes, derived from the original utility. Other/unknown firmware layouts produce an unsupported-layout message instead of guessed settings.
- Every transfer block is checked for its address, length and checksum. The complete profile checksum must also pass before replacing the displayed snapshot.
- The viewer names **66 core settings**. Verified voltage scalings are displayed in volts; other fields remain clearly labelled raw configured values until their presentation units are verified.
- All remaining profile settings and tables are retained in the complete raw view and JSON backup. They are not yet fully interpreted in the settings table.
- The JSON backup is not a vendor `.j2bms` file and cannot be uploaded by this app.
- Live polling pauses during a profile transfer and resumes afterward when it was previously running.

## Offline testing

With no device connected in the app, choose **Diagnostics → Explore Password-Protected Demo** from the menu bar. Open Profile and choose Read Current Profile. The demo password is `demo`. A wrong password is rejected; the correct password downloads clearly labelled synthetic settings. The ordinary offline demo provides an unlocked profile.

The profile reader has automated tests, native pseudo-terminal tests for redaction/cancellation cleanup, and offline request/layout checks against the original Java utility. The Mac password prompt and settings display have been exercised with the protected demo. Physical profile transfer/authentication still needs acceptance testing on the target BMS.
