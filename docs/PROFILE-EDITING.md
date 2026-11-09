# Profile editing and uploads

Available in local **v0.4.0**, for the verified **3.x firmware / 3.0 profile layout**. This is a configuration-writing feature. It has been checked against the original utility offline and exercised in the protected simulator; physical upload acceptance has not been performed.

## Edit the connected BMS profile

1. Open **Profile** and **Read Current Profile**. Authenticate with the existing profile password if requested.
2. Choose **Edit Current Profile**. Each named setting now has an **Edit** button.
3. Enter the new value and choose **Apply to Draft**. Verified voltage settings use volts and enforce their storage precision. Fields labelled **raw** use whole-number configured values; their presentation units have not been verified.
4. Repeat as needed. **Save Draft** saves a local JSON file. No BMS writes occur while editing or saving a draft.
5. Choose **Review Upload**. Compare the before/after settings, or select **Compare all changed bytes** to see every changed configuration byte. Check the target serial number and firmware.
6. Enter the existing profile password if required, acknowledge that you have reviewed the complete profile, and choose **Upload & Verify**.
7. Success requires a complete read-back match. **Show Original Profile Backup** reveals the original profile saved before the write.

The editor currently exposes **66 named core fields**. It preserves all other settings, tables and reserved bytes. File integrity, integer range, exact voltage precision, compatible unit type and basic limit relationships are checked. These checks do not certify every vendor setting or the suitability of a profile for a battery and its equipment. Zero current limits are highlighted because they can prevent charging or discharging.

## Import a complete profile

Read the target BMS profile first, then choose **Import Profile**. Importing stages the complete file against this target baseline; it does not upload automatically.

Supported inputs:

- Orion Diagnostics profile JSON backups and saved drafts with schema 1 / layout 3.0. Demo/hardware mixing and a mismatched firmware value are rejected.
- Original utility XML `.j2bms` files containing one complete, checksummed `profileStr` in the supported layout. The importer extracts that data string without running Java, instantiating objects or evaluating XML instructions. Other serialized Java properties are not interpreted independently of `profileStr`.
- A 3.0 raw hexadecimal profile, including a two-line `.j2ps` file with the complete profile on the second line.

Every accepted file must contain exactly 3,474 profile bytes with a valid full checksum. The imported unit-type byte and reserved layout byte must match the target baseline. A matching layout does not establish that an imported profile's features are compatible with the connected firmware. Prepare vendor profiles for that firmware before importing.

Encrypted vendor files and older layouts/conversions are not supported. XML entities, document type declarations, duplicate or nested profile strings, and files over 2 MB are rejected. A vendor XML file with an absent or stale `profileStr` must be re-saved by the original utility; changing separate XML properties does not change the imported bytes.

Imported changes outside the named core settings are highlighted by their changed-byte count. The byte comparison shows those changes too. Tables can be replaced through a compatible complete imported profile; there are no individual table editors yet.

## Transfer, backup and recovery

Before the first configuration write, the app identifies the BMS again, reads its full active profile, and requires an exact match with the draft's original baseline. A stale baseline or changed device/firmware stops the upload. An active recording is ended before upload, and live polling pauses for the operation.

The complete original JSON backup is saved and checked before enabling writes. Hardware backups are stored in `~/Library/Application Support/OrionDiagnostics/ProfileBackups/`; simulated backups use the separate `DemoProfileBackups/` folder. Backups are private local files with generated filenames and include the device identity, acquisition time and original profile bytes.

The upload uses the reference utility's profile password session and separate write-unlock step. Blocks and their checksums match the original serializer. The vendor's `0x7F/0x3B/0x72` acknowledgement is treated as success. Leading authentication status bytes are checked while allowing additional acknowledgement bytes, including the eight-byte reply observed during hardware testing of profile reading.

Only explicit BMS block retransmission requests are retried, at most twice. A timed-out block or commit is not automatically repeated. After commit, the session is re-locked and the full profile is read back; the app reports success only if every byte matches the reviewed upload.

Cancellation stops before any further block or commit is sent and still attempts session cleanup. An interrupted commit or failed verification can leave the active result uncertain. The app preserves the backup, closes an uncertain connection, and asks you to reconnect and read the active profile before deciding whether to retry or restore. It does not automatically roll back or re-commit a profile. To restore, import the original backup against a newly read baseline and review that upload.

Passwords and challenge/response values are not retained in diagnostic traces. Profile upload payloads are also redacted. No password-change, firmware-update, fault-clear, reset or calibration commands were added.

## Validation performed

- Independent offline Java utility oracle: all 63 profile block frames plus the commit frame, both authentication levels, full original/edited profile bytes, checksum and vendor XML import.
- Native serial pseudo-terminal tests: the unusual vendor acknowledgement, upload trace redaction, invalid block prevention and no automatic timeout retry.
- Simulator tests: authentication and extended acknowledgements, draft validation, backup, re-locking and complete read-back comparison; stale baselines, denied write access, cancellation, lost commit replies and mismatched verification.
- Native Mac UI: protected-demo read, edit, before/after review, authenticated upload, original backup and verified changed setting. No physical BMS configuration was written during these checks.
