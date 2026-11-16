# Windows installer changelog

## 1.0.0 - 2026-11-15

- Add PowerShell install/restore scripts and double-click CMD launchers alongside the existing Linux scripts.
- Reuse the eight existing ICO themes; identify PNG-only themes as requiring conversion.
- Support separate current-user and all-users scopes, explicit folder selection, preview, and confirmation.
- Preserve shortcut launch settings, MSI advertisement, and application property data while applying icons.
- Keep original shortcut backups, stable icon copies, integrity checks, operation locking, and recovery journaling.
- Preserve later user edits and report conflicts or partial failures.
- Add local integration tests, Windows documentation, and a local ZIP packaging script.
