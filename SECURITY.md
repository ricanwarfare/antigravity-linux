# Security Policy

## Reporting a vulnerability

Please open a private security advisory on GitHub if available, or contact the maintainer directly.

Do not publicly disclose a vulnerability until a fix or mitigation is available.

## Scope

Security issues in this project include:

- unsafe shell behavior
- privilege escalation bugs caused by the helper
- incorrect file permissions
- downloading from non-official sources
- desktop integration that runs unexpected commands

Security issues in Google Antigravity itself should be reported to Google through their official channels.

## Design choices

- The installer downloads official Google tarballs at install/update time.
- The project does not host Google binaries.
- The installer writes only helper-managed system files and leaves user home settings untouched during uninstall.
- The Electron/Chromium sandbox is preserved by setting `chrome-sandbox` to `root:root` with mode `4755` when present.

## Download trust and update controls

- All helper downloads require HTTPS and an approved host/path on each redirect.
  Google Cloud Storage is restricted to the Antigravity publisher bucket.
- The inspected Google download page does not expose independent signatures or
  a trusted SHA-256 manifest for these tarballs. Automated updates therefore trust
  HTTPS and the approved publisher locations, not a verified publisher signature.
- A supplied trusted `--desktop-sha256` or `--ide-sha256` is checked before
  extraction. The recorded local archive hash alone is an audit value, not proof
  of authenticity. Status reports the verification actually performed.
- Archives reject escaping links/paths, duplicate members, special files, and
  entries below symlinks. Extraction strips privilege and group/other-write bits.
- Install, update, preference changes, rollback and uninstall share one lock.
  Activation retains a previous release and restores it on failure when possible.
- Full release/build identifiers are compared. Downgrades or ambiguous suffix
  changes require explicit `--allow-downgrade`; `--force` does not bypass this.
- The updater itself remains a reviewed local file. Its own changes require a new
  explicit installation. The optional `--cli` path executes Google's current CLI
  installer as the invoking non-root user and is outside desktop/IDE rollback.

Report vulnerabilities privately through this fork's GitHub security advisory
page: https://github.com/ricanwarfare/antigravity-linux/security/advisories/new
