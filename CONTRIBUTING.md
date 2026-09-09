# Contributing

Thanks for helping improve Antigravity Linux Installer.

## Easy way

The easiest way to contribute is to test the installer on your OS and, if issues arise, [open an issue](https://github.com/ricanwarfare/antigravity-linux/issues/new), describe the problem, your system details, and screenshots (if possible).

## Development workflow

1. Fork the repository.
2. Create a feature branch.
3. Edit `install.sh`.
4. Run:

```bash
bash scripts/sync-site.sh
bash scripts/check.sh
```

5. Open a pull request.

## Rules of thumb

- Do not mirror or redistribute Google Antigravity binaries.
- Do not hard-code a third-party tarball URL.
- Keep installs reversible through `--uninstall`.
- Prefer standard Linux integration points: `.desktop` files, MIME entries, icon themes, and file-manager extensions.
- Avoid `--no-sandbox` launchers unless there is a documented, user-selected troubleshooting flag.

## Testing checklist

Please test on at least one fresh VM before opening a release PR:

- Ubuntu LTS x86_64
- Debian stable x86_64
- ARM64 if you touched architecture logic

Recommended commands:

```bash
sudo bash install.sh --all --force
antigravity-linux --status
sudo antigravity-linux update --all
sudo bash install.sh --uninstall
```

## Automated behavior coverage

`bash scripts/check.sh` runs offline Python unittest scenarios against temporary
installation paths, including update selection, timer preferences, concurrency,
rollback, interrupted activation, unsafe archives and URLs, checksum mismatch,
version ordering, and status history. No host applications are installed.

Keep fixtures small and network-independent. Verify both embedded and checked-in
systemd units; standalone `install.sh` must remain fully usable. The check script
also checks generated documentation and website copy-button commands. Regenerate
`docs/install.sh` and `docs/llms.txt` with `bash scripts/sync-site.sh` after changes.

Before release, test the real tarballs and desktop integration in a fresh VM.
Archive validation does not replace an application startup test.
