#!/usr/bin/env bash
# Antigravity Linux Installer
# Installs/updates Google Antigravity 2.0 and, optionally, Antigravity IDE on Debian/Ubuntu.
# It resolves the latest official Google tarballs from https://antigravity.google/download.
set -Eeuo pipefail

ORIGINAL_ARGS=("$@")
PROJECT_NAME="antigravity-linux"
DOWNLOAD_PAGE="https://antigravity.google/download"
CLI_INSTALLER="https://antigravity.google/cli/install.sh"
INSTALL_DESKTOP=1
INSTALL_IDE=0
INSTALL_CLI=0
INSTALL_NAUTILUS=1
INSTALL_DEPS=1
DO_UNINSTALL=0
DO_STATUS=0
DO_PRINT_DOWNLOADS=0
FORCE=0
YES=0
ACTION=install
PRODUCTS_EXPLICIT=0
AUTO_REQUEST=""
NAUTILUS_EXPLICIT=0
SCHEDULED=0
ALLOW_DOWNGRADE=0
DESKTOP_SHA256=""
IDE_SHA256=""
STATE_DIR=/var/lib/antigravity-linux
LOCK_FILE=/run/antigravity-linux-update.lock
SAVED_DESKTOP=0
SAVED_IDE=0
AUTO_UPDATE=1
SAVED_NAUTILUS=1
WORK_DIR=""
OPERATION=""
FAILURE_MESSAGE=""
TRACK_RESULT=0


log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
err() { FAILURE_MESSAGE="$*"; printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "Required command not found: $1"; }

usage() {
  cat <<'USAGE'
Antigravity Linux Installer

Usage:
  install.sh [install|update|check|rollback] [options]
  install.sh --status | --print-downloads | --uninstall
  install.sh --enable-auto-update | --disable-auto-update

Install defaults to the desktop app. Update, check and rollback default to
previously installed products. All commands use this reviewed local helper.

Options:
  --desktop              Select desktop app
  --ide                  Select standalone IDE
  --all                  Select both apps
  --check-updates         Check versions without installing (same as check)
  --no-auto-update       Disable automatic installation; save this preference
  --auto-update          Enable daily automatic installation
  --enable-auto-update   Enable automatic installation without updating now
  --disable-auto-update  Disable automatic installation without updating now
  --no-nautilus          Skip Nautilus integration; save this preference
  --no-apt               Skip dependency installation (still check prerequisites)
  --force                Reinstall the same release; does not allow downgrades
  --allow-downgrade      Explicitly permit an older release
  --desktop-sha256 HASH  Verify desktop archive against a trusted SHA-256
  --ide-sha256 HASH      Verify IDE archive against a trusted SHA-256
  --cli                  Run Google's CLI installer as the invoking non-root user
  --status               Show products, verification, timer and update history
  --print-downloads      Print approved download URLs
  --uninstall            Remove helper-managed files; keep user settings
  -y, --yes              Non-interactive operation
  -h, --help             Show this help

Examples:
  sudo bash install.sh --ide --no-auto-update
  antigravity-linux check
  sudo antigravity-linux update
  sudo antigravity-linux rollback --desktop
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    install|update|check|rollback) ACTION="$1" ;;
    --desktop) INSTALL_DESKTOP=1; INSTALL_IDE=0; PRODUCTS_EXPLICIT=1 ;;
    --ide) INSTALL_DESKTOP=0; INSTALL_IDE=1; PRODUCTS_EXPLICIT=1 ;;
    --all) INSTALL_DESKTOP=1; INSTALL_IDE=1; PRODUCTS_EXPLICIT=1 ;;
    --check-updates) ACTION=check ;;
    --auto-update) AUTO_REQUEST=1 ;;
    --no-auto-update) AUTO_REQUEST=0 ;;
    --enable-auto-update) ACTION=configure; AUTO_REQUEST=1 ;;
    --disable-auto-update) ACTION=configure; AUTO_REQUEST=0 ;;
    --scheduled) ACTION=update; SCHEDULED=1 ;;
    --cli) INSTALL_CLI=1 ;;
    --no-nautilus) INSTALL_NAUTILUS=0; NAUTILUS_EXPLICIT=1 ;;
    --no-apt) INSTALL_DEPS=0 ;;
    --force) FORCE=1 ;;
    --allow-downgrade) ALLOW_DOWNGRADE=1 ;;
    --desktop-sha256|--ide-sha256)
      option="$1"; shift
      [ $# -gt 0 ] && [[ "$1" =~ ^[0-9a-fA-F]{64}$ ]] || err "$option requires a SHA-256 hash"
      if [ "$option" = --desktop-sha256 ]; then DESKTOP_SHA256="${1,,}"; else IDE_SHA256="${1,,}"; fi
      ;;
    --install-url) err "--install-url was removed. Updates use the reviewed local helper." ;;
    --status) DO_STATUS=1 ;;
    --print-downloads) DO_PRINT_DOWNLOADS=1 ;;
    --uninstall) DO_UNINSTALL=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1" ;;
  esac
  shift
done

if [ "$(uname -s)" != "Linux" ]; then
  err "This installer is for Linux only."
fi

case "$(uname -m)" in
  x86_64|amd64) AG_PLATFORM="linux-x64"; DESKTOP_TOP="Antigravity-x64" ;;
  aarch64|arm64) AG_PLATFORM="linux-arm"; DESKTOP_TOP="Antigravity-arm64" ;;
  *) err "Unsupported CPU architecture: $(uname -m). Google currently provides x64 and ARM64 Linux builds." ;;
esac

require_root_or_reexec() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" != "bash" ] && [ "${BASH_SOURCE[0]}" != "sh" ]; then
    exec sudo bash "${BASH_SOURCE[0]}" "${ORIGINAL_ARGS[@]}"
  fi
  err "System-wide install needs root. Download or clone the repository, review it, then run: sudo bash install.sh"
}

require_local_script() {
  local source="${BASH_SOURCE[0]:-}"
  [ -n "$source" ] && [ -f "$source" ] || err "Piped execution is intentionally unsupported. Download or clone the repository, review it, then run: sudo bash install.sh"
}

install_deps_debian() {
  if [ "$INSTALL_DEPS" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    local packages=(ca-certificates curl tar python3 util-linux desktop-file-utils xdg-utils)
    if [ "$INSTALL_NAUTILUS" -eq 1 ] && [ "$INSTALL_IDE" -eq 1 ]; then
      packages+=(python3-nautilus)
    fi
    apt-get install -y "${packages[@]}"
  fi
  for c in tar python3 flock sha256sum; do need "$c"; done
}

# Validate every hop BEFORE connecting. Shared cloud hosts are restricted to
# the publisher's bucket/path, rather than trusting all tenants on that host.
network_policy() {
  cat <<'PY'
import gzip, shutil, sys, time
from urllib.parse import urlsplit, urljoin, unquote
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.error import HTTPError, URLError

def approved(url):
    p = urlsplit(url)
    path = unquote(p.path)
    if (p.scheme != 'https' or p.username or p.password or p.port not in (None, 443)
            or p.fragment or any(c.isspace() or ord(c) < 32 for c in url)
            or '\\' in path or '..' in path.split('/')):
        raise ValueError('Unsafe download URL: ' + url)
    host = p.hostname
    allowed = (
        (host in ('antigravity.google', 'www.antigravity.google') and
         (path == '/download' or path.startswith('/_astro/') or path == '/cli/install.sh')) or
        (host == 'storage.googleapis.com' and path.startswith('/antigravity-public/')) or
        (host == 'edgedl.me.gvt1.com' and path.startswith('/edgedl/release2/') and '/antigravity/' in path) or
        (host == 'dl.google.com' and path.startswith('/release2/') and '/antigravity/' in path)
    )
    if not allowed:
        raise ValueError('Unapproved download location: ' + url)
    return url

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def fetch(url, destination):
    opener = build_opener(NoRedirect())
    for attempt in range(3):
        current = url
        try:
            for hop in range(9):
                approved(current)
                request = Request(current, headers={'User-Agent': 'Mozilla/5.0', 'Accept-Encoding': 'identity'})
                try:
                    response = opener.open(request, timeout=60)
                except HTTPError as e:
                    if e.code in (301, 302, 303, 307, 308) and e.headers.get('Location'):
                        current = urljoin(current, e.headers['Location'])
                        e.close()
                        continue
                    raise
                with response, open(destination, 'wb') as out:
                    if response.status != 200:
                        raise ValueError('Unexpected HTTP response: ' + str(response.status))
                    stream = gzip.GzipFile(fileobj=response) if response.headers.get('Content-Encoding') == 'gzip' else response
                    shutil.copyfileobj(stream, out)
                return
            raise ValueError('Too many redirects')
        except (URLError, TimeoutError, OSError):
            if attempt == 2:
                raise
            time.sleep(attempt + 1)
PY
}

validate_url() {
  { network_policy; printf '%s\n' 'approved(sys.argv[1])'; } | python3 - "$1"
}

fetch_official() {
  { network_policy; printf '%s\n' 'fetch(sys.argv[1], sys.argv[2])'; } | python3 - "$1" "$2"
}

resolve_main_bundle() {
  local tmpdir="$1"
  local html="$tmpdir/download.html"
  local js="$tmpdir/download.js"

  # Google serves an incomplete document to curl's default user agent. A normal
  # desktop-browser user agent yields the official links directly, which is
  # simpler and less brittle than depending on Astro bundle names.
  fetch_official "$DOWNLOAD_PAGE" "$html" || return 1
  if python3 - "$html" "$AG_PLATFORM" <<'PY' >/dev/null
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors='replace').replace("\\/", "/")
platform = re.escape(sys.argv[2])
raise SystemExit(0 if re.search(r'https?://[^"\s<>)]*/' + platform + r'/Antigravity(?:\.tar\.gz|%20IDE\.tar\.gz)', text) else 1)
PY
  then
    printf '%s\n' "$html"
    return
  fi

  # Compatibility fallback for an older page layout that exposes links only in
  # an Astro bundle.
  local main_js_url
  main_js_url=$(python3 - "$html" "$DOWNLOAD_PAGE" <<'PY'
import re, sys
from pathlib import Path
from urllib.parse import urljoin
html = Path(sys.argv[1]).read_text(errors='replace')
page = sys.argv[2]
matches = re.findall(r'(?:src|href)=["\']([^"\']*main-[^"\']+\.js)["\']', html)
if not matches:
    matches = re.findall(r'(?:src|href)=["\']([^"\']+\.js)["\']', html)
if not matches:
    raise SystemExit('Could not find JavaScript bundle on the official Antigravity download page')
print(urljoin(page, matches[-1]))
PY
) || return 1
  fetch_official "$main_js_url" "$js" || return 1
  printf '%s\n' "$js"
}

resolve_download_from_bundle() {
  local js="$1"
  local product="$2"
  local resolved version url
  resolved=$(python3 - "$js" "$AG_PLATFORM" "$product" <<'PY'
import html, re, sys
from pathlib import Path
from urllib.parse import unquote
bundle = html.unescape(Path(sys.argv[1]).read_text(errors='replace'))
platform = sys.argv[2]
product = sys.argv[3]

# Normalize escaped slashes sometimes found in JS string literals.
text = bundle.replace("\\/", "/")

def fail(msg):
    raise SystemExit(msg)

def version_from_url(url):
    decoded = unquote(url)
    # Known current layouts include antigravity-hub/<version>/ and stable/<version>/.
    for pattern in (r'/antigravity-hub/([^/]+)/', r'/stable/([^/]+)/', r'/(\d+\.\d+\.\d+(?:-[^/]+)?)/'):
        m = re.search(pattern, decoded)
        if m:
            version = m.group(1)
            if re.fullmatch(r'\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?', version):
                return version
    fail('Unrecognized release version in URL: ' + url)

if product == 'desktop':
    marker = 'id:"antigravity-2"'
    next_marker = 'id:"antigravity-cli"'
    filename_patterns = [r'Antigravity\.tar\.gz']
    label = 'Antigravity 2.0'
elif product == 'ide':
    marker = 'id:"antigravity-ide"'
    next_marker = 'id:"antigravity-sdk"'
    filename_patterns = [r'Antigravity%20IDE\.tar\.gz', r'Antigravity\+IDE\.tar\.gz', r'Antigravity IDE\.tar\.gz']
    label = 'Antigravity IDE'
else:
    fail(f'Unknown product: {product}')

sections = []
start = text.find(marker)
if start != -1:
    end = text.find(next_marker, start)
    sections.append(text[start:end if end != -1 else None])
sections.append(text)

for section in sections:
    for filename_re in filename_patterns:
        pattern = r'https?://[^"\'\s<>)]*/' + re.escape(platform) + r'/' + filename_re
        matches = re.findall(pattern, section)
        if matches:
            url = matches[-1]
            print(version_from_url(url), url)
            sys.exit(0)

fail(f'Could not find official {label} tarball for {platform} in Google download bundle')
PY
) || return 1
  read -r version url <<< "$resolved"
  validate_url "$url" || return 1
  printf '%s %s\n' "$version" "$url"
}

resolve_desktop_download() { resolve_download_from_bundle "$1" desktop; }
resolve_ide_download() { resolve_download_from_bundle "$1" ide; }

asar_extract_icon_png() {
  local asar="$1"
  local out="$2"
  python3 - "$asar" "$out" <<'PY'
import json, struct, sys
from pathlib import Path
asar = Path(sys.argv[1])
out = Path(sys.argv[2])
with asar.open('rb') as f:
    f.read(4)
    header_size = struct.unpack('<I', f.read(4))[0]
    f.read(4)
    json_size = struct.unpack('<I', f.read(4))[0]
    header = json.loads(f.read(json_size).decode())
icon = header.get('files', {}).get('icon.png')
if not icon:
    raise SystemExit('icon.png not found in app.asar')
with asar.open('rb') as f:
    f.seek(8 + header_size + int(icon['offset']))
    out.write_bytes(f.read(int(icon['size'])))
PY
}

validate_installation() {
  local root="$1" launcher="$2"
  [ -d "$root" ] && [ ! -L "$root" ] && [ -f "$root/$launcher" ] &&
    [ ! -L "$root/$launcher" ] && [ -x "$root/$launcher" ] &&
    [ -s "$root/.antigravity-linux-version" ]
}

recover_installation() {
  local root="$1" launcher="$2"
  if [ ! -e "$root" ] && validate_installation "${root}.previous" "$launcher"; then
    mv "${root}.previous" "$root" || return 1
    warn "Recovered interrupted replacement at $root"
  fi
}

safe_replace_dir() {
  local newdir="$1" target="$2" launcher="$3"
  validate_installation "$newdir" "$launcher" || { warn "Invalid staged installation"; return 1; }
  if [ -e "$target" ]; then
    validate_installation "$target" "$launcher" || { warn "Existing installation is invalid; refusing to discard recovery files"; return 1; }
    rm -rf "${target}.previous" || return 1
    mv "$target" "${target}.previous" || return 1
  fi
  if mv "$newdir" "$target" && validate_installation "$target" "$launcher"; then
    return 0
  fi
  if [ -e "$target" ]; then mv "$target" "$newdir" || return 1; fi
  recover_installation "$target" "$launcher" || return 1
  warn "Replacement failed; the previous installation was restored when available"
  return 1
}

verify_archive() {
  local archive="$1" expected="$2"
  ARCHIVE_HASH=$(sha256sum "$archive")
  ARCHIVE_HASH="${ARCHIVE_HASH%% *}"
  ARCHIVE_VERIFICATION="HTTPS and approved location; no publisher checksum supplied"
  if [ -n "$expected" ]; then
    [ "$ARCHIVE_HASH" = "$expected" ] || err "Archive SHA-256 mismatch"
    ARCHIVE_VERIFICATION="Matched supplied trusted SHA-256"
  fi
}

# Reject escaping links, special files, duplicate paths and privilege bits before
# root extraction. Do not depend on tar's partial path traversal protections.
extract_archive() {
  python3 - "$1" "$2" "$3" <<'PY'
import os, posixpath, sys, tarfile
from pathlib import PurePosixPath
archive, destination, top = sys.argv[1:]
with tarfile.open(archive, 'r:gz') as tf:
    members = tf.getmembers()
    seen = set()
    symlinks = {}
    for m in members:
        path = PurePosixPath(m.name)
        if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != top:
            raise SystemExit('Unsafe archive path: ' + m.name)
        normalized = str(path)
        if normalized in seen:
            raise SystemExit('Duplicate archive path: ' + m.name)
        seen.add(normalized)
        if not (m.isfile() or m.isdir() or m.issym() or m.islnk()):
            raise SystemExit('Unsupported archive member: ' + m.name)
        if m.issym() or m.islnk():
            link = m.linkname
            resolved = posixpath.normpath(posixpath.join(str(path.parent), link) if m.issym() else link)
            if link.startswith('/') or not (resolved == top or resolved.startswith(top + '/')):
                raise SystemExit('Escaping archive link: ' + m.name)
            if m.issym():
                symlinks[normalized] = m.linkname
        m.uid = m.gid = 0
        m.uname = m.gname = ''
        m.mode &= 0o755
    # Resolve link chains in archive space before extraction, including on
    # Python versions without tarfile's data filter.
    def resolve_link(path):
        pending = path.split('/')
        resolved = []
        hops = 0
        while pending:
            part = pending.pop(0)
            if part in ('', '.'):
                continue
            if part == '..':
                if len(resolved) <= 1:
                    raise SystemExit('Escaping archive link chain: ' + path)
                resolved.pop()
                continue
            candidate = '/'.join(resolved + [part])
            if candidate in symlinks:
                hops += 1
                if hops > 40:
                    raise SystemExit('Cyclic archive link: ' + path)
                pending = symlinks[candidate].split('/') + pending
            else:
                resolved.append(part)
        if not resolved or resolved[0] != top:
            raise SystemExit('Escaping archive link chain: ' + path)

    regular_files = {str(PurePosixPath(m.name)) for m in members if m.isfile()}
    for name in symlinks:
        resolve_link(name)
    for m in members:
        path = PurePosixPath(m.name)
        if any(str(parent) in symlinks for parent in path.parents):
            raise SystemExit('Archive member nested below symlink: ' + m.name)
        if m.islnk() and str(PurePosixPath(m.linkname)) not in regular_files:
            raise SystemExit('Hard link must target a regular archive member: ' + m.name)
    # Explicit validation above supports Python versions predating tar filters.
    kwargs = {'filter': 'data'} if hasattr(tarfile, 'data_filter') else {}
    tf.extractall(destination, members=members, **kwargs)
PY
}

version_relation() {
  python3 - "$1" "$2" <<'PY'
import re, sys

def parse(v):
    m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?', v)
    if not m:
        raise SystemExit('Unrecognized recorded version: ' + v)
    return tuple(map(int, m.group(1, 2, 3))), m.group(4)
old, new = sys.argv[1:]
a, x = parse(old); b, y = parse(new)
if old == new:
    print('same')
elif a != b:
    print('upgrade' if b > a else 'downgrade')
elif x is None:
    # Migration from the old helper, which discarded build identifiers.
    print('upgrade')
elif x.isdigit() and y is not None and y.isdigit():
    print('upgrade' if int(y) > int(x) else 'downgrade')
else:
    # Unknown suffix ordering must not silently replace a newer release.
    print('ambiguous')
PY
}

should_install() {
  local root="$1" launcher="$2" version="$3" current relation
  current=$(installed_version "$root/.antigravity-linux-version")
  if [ -n "$current" ]; then
    relation=$(version_relation "$current" "$version") || err "Cannot compare installed release"
    if [ "$relation" = downgrade ] || [ "$relation" = ambiguous ]; then
      [ "$ALLOW_DOWNGRADE" -eq 1 ] || err "Refusing $relation release change $current -> $version; use --allow-downgrade explicitly"
    fi
    if [ "$relation" = same ] && [ "$FORCE" -eq 0 ] && validate_installation "$root" "$launcher"; then
      log "$root $version is already installed."
      return 1
    fi
  fi
  return 0
}

fix_chrome_sandbox() {
  local sandbox="$1"
  if [ -f "$sandbox" ] && [ ! -L "$sandbox" ]; then
    chown root:root "$sandbox"
    chmod 4755 "$sandbox"
  fi
}

refresh_desktop_caches() {
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q /usr/share/icons/hicolor >/dev/null 2>&1 || true
  fi
}

installed_version() {
  local file="$1"
  cat "$file" 2>/dev/null || true
}

install_desktop_app() {
  local tmpdir="$1"
  local js="$2"
  local version url
  local resolved
  resolved=$(resolve_desktop_download "$js") || err "Could not resolve desktop download"
  read -r version url <<< "$resolved"
  local root="/opt/antigravity"
  if ! should_install "$root" "$DESKTOP_TOP/antigravity" "$version"; then return; fi

  log "Downloading Antigravity 2.0 $version for $AG_PLATFORM from Google..."
  local archive="$tmpdir/Antigravity.tar.gz"
  fetch_official "$url" "$archive"
  verify_archive "$archive" "$DESKTOP_SHA256"
  local top_dir="$DESKTOP_TOP"
  extract_archive "$archive" "$tmpdir" "$top_dir"
  [ -x "$tmpdir/$top_dir/antigravity" ] || err "Antigravity launcher not found inside tarball."

  local icon_staged="$tmpdir/antigravity.png"
  if [ -f "$tmpdir/$top_dir/resources/app.asar" ]; then
    asar_extract_icon_png "$tmpdir/$top_dir/resources/app.asar" "$icon_staged" || warn "Could not extract desktop icon; continuing."
  fi

  rm -rf "${root}.new"
  mkdir -p "${root}.new"
  cp -a "$tmpdir/$top_dir" "${root}.new/"
  printf '%s\n' "$version" > "${root}.new/.antigravity-linux-version"
  printf '%s\n' "$url" > "${root}.new/.antigravity-linux-source-url"
  fix_chrome_sandbox "${root}.new/$top_dir/chrome-sandbox"
  printf '%s\n' "$ARCHIVE_HASH" > "${root}.new/.antigravity-linux-sha256"
  printf '%s\n' "$ARCHIVE_VERIFICATION" > "${root}.new/.antigravity-linux-verification"
  safe_replace_dir "${root}.new" "$root" "$DESKTOP_TOP/antigravity" || err "Could not activate desktop release"

  install -d -m0755 /usr/local/bin
  ln -sfn "$root/$top_dir/antigravity" /usr/local/bin/antigravity
  mkdir -p /usr/share/icons/hicolor/512x512/apps /usr/share/applications
  if [ -f "$icon_staged" ]; then
    install -m 0644 "$icon_staged" /usr/share/icons/hicolor/512x512/apps/antigravity.png
  fi
  cat > /usr/share/applications/antigravity.desktop <<DESKTOP
[Desktop Entry]
Name=Antigravity
Comment=Google Antigravity 2.0 agent platform
Exec=/usr/local/bin/antigravity %U
Icon=antigravity
Terminal=false
Type=Application
Categories=Development;IDE;
StartupNotify=true
StartupWMClass=Antigravity
DESKTOP
  refresh_desktop_caches
  log "Installed Antigravity 2.0 $version at $root/$top_dir"
}

install_ide_app() {
  local tmpdir="$1"
  local js="$2"
  local version url
  local resolved
  resolved=$(resolve_ide_download "$js") || err "Could not resolve ide download"
  read -r version url <<< "$resolved"
  local root="/opt/antigravity-ide"
  local install_dir="Antigravity-IDE"
  if ! should_install "$root" "$install_dir/antigravity-ide" "$version"; then return; fi

  log "Downloading Antigravity IDE $version for $AG_PLATFORM from Google..."
  local archive="$tmpdir/Antigravity-IDE.tar.gz"
  fetch_official "$url" "$archive"
  verify_archive "$archive" "$IDE_SHA256"
  local top_dir="Antigravity IDE"
  extract_archive "$archive" "$tmpdir" "$top_dir"
  [ -x "$tmpdir/$top_dir/antigravity-ide" ] || err "Antigravity IDE launcher not found inside tarball."

  rm -rf "${root}.new"
  mkdir -p "${root}.new/$install_dir"
  cp -a "$tmpdir/$top_dir/." "${root}.new/$install_dir/"
  printf '%s\n' "$version" > "${root}.new/.antigravity-linux-version"
  printf '%s\n' "$url" > "${root}.new/.antigravity-linux-source-url"
  fix_chrome_sandbox "${root}.new/$install_dir/chrome-sandbox"
  printf '%s\n' "$ARCHIVE_HASH" > "${root}.new/.antigravity-linux-sha256"
  printf '%s\n' "$ARCHIVE_VERIFICATION" > "${root}.new/.antigravity-linux-verification"
  safe_replace_dir "${root}.new" "$root" "$install_dir/antigravity-ide" || err "Could not activate ide release"

  install -d -m0755 /usr/local/bin
  ln -sfn "$root/$install_dir/antigravity-ide" /usr/local/bin/antigravity-ide
  mkdir -p /usr/share/icons/hicolor/512x512/apps /usr/share/applications
  local icon_source="$root/$install_dir/resources/app/resources/linux/code.png"
  if [ -f "$icon_source" ]; then
    install -m 0644 "$icon_source" /usr/share/icons/hicolor/512x512/apps/antigravity-ide.png
  fi
  cat > /usr/share/applications/antigravity-ide.desktop <<DESKTOP
[Desktop Entry]
Name=Antigravity IDE
Comment=Google Antigravity IDE
Exec=/usr/local/bin/antigravity-ide %F
Icon=antigravity-ide
Terminal=false
Type=Application
Categories=Development;IDE;
MimeType=inode/directory;text/plain;application/x-code-workspace;application/x-antigravity-workspace;x-scheme-handler/antigravity-ide;
StartupNotify=true
StartupWMClass=antigravity-ide
DESKTOP
  refresh_desktop_caches
  log "Installed Antigravity IDE $version at $root/$install_dir"
}

install_nautilus_extension() {
  [ "$INSTALL_NAUTILUS" -eq 1 ] || return 0
  [ "$INSTALL_IDE" -eq 1 ] || return 0
  if ! command -v nautilus >/dev/null 2>&1; then
    return 0
  fi
  if ! python3 - <<'PY' >/dev/null 2>&1
try:
    import gi
    gi.require_version('Nautilus', '4.0')
except Exception:
    raise SystemExit(1)
PY
  then
    warn "Skipping Nautilus extension because Python Nautilus bindings are unavailable."
    return 0
  fi
  mkdir -p /usr/share/nautilus-python/extensions
  cat > /usr/share/nautilus-python/extensions/open-in-antigravity-ide.py <<'PY'
import subprocess
from urllib.parse import unquote, urlparse
from gi.repository import Nautilus, GObject

class OpenInAntigravityIDE(GObject.GObject, Nautilus.MenuProvider):
    def _path(self, file_info):
        uri = file_info.get_uri()
        parsed = urlparse(uri)
        if parsed.scheme != 'file':
            return None
        return unquote(parsed.path)

    def get_file_items(self, files):
        if not files or len(files) != 1:
            return []
        path = self._path(files[0])
        if not path:
            return []
        item = Nautilus.MenuItem(
            name='OpenInAntigravityIDE::open',
            label='Open in Antigravity IDE',
            tip='Open this folder or file in Antigravity IDE'
        )
        item.connect('activate', lambda _item: subprocess.Popen(['antigravity-ide', path]))
        return [item]

    def get_background_items(self, folder):
        path = self._path(folder)
        if not path:
            return []
        item = Nautilus.MenuItem(
            name='OpenInAntigravityIDE::open_background',
            label='Open Folder in Antigravity IDE',
            tip='Open the current folder in Antigravity IDE'
        )
        item.connect('activate', lambda _item: subprocess.Popen(['antigravity-ide', path]))
        return [item]
PY
  log "Installed Nautilus context-menu helper. Restart Files/Nautilus to see it."
}

install_update_units() {
  local source_dir="$1"
  local destination_dir="$2"
  if [ -f "$source_dir/systemd/antigravity-linux-update.service" ] && [ -f "$source_dir/systemd/antigravity-linux-update.timer" ]; then
    install -Dm0644 "$source_dir/systemd/antigravity-linux-update.service" "$destination_dir/antigravity-linux-update.service"
    install -Dm0644 "$source_dir/systemd/antigravity-linux-update.timer" "$destination_dir/antigravity-linux-update.timer"
    return
  fi

  # A reviewed standalone install.sh has no sibling systemd/ directory. Keep
  # that supported by materializing the same units embedded below.
  install -d -m0755 "$destination_dir"
  cat > "$destination_dir/antigravity-linux-update.service" <<'UNIT'
[Unit]
Description=Update Google Antigravity from its official Linux tarball
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/antigravity-linux/install.sh update --scheduled --no-apt --yes
UNIT
  cat > "$destination_dir/antigravity-linux-update.timer" <<'UNIT'
[Unit]
Description=Daily Antigravity update check

[Timer]
OnCalendar=*-*-* 04:17:00
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
UNIT
}

install_manager_command() {
  local source="${BASH_SOURCE[0]:-}"
  [ -n "$source" ] && [ -f "$source" ] || err "Run a downloaded or checked-out install.sh; piped execution is intentionally unsupported."
  local source_dir
  source_dir=$(cd "$(dirname "$source")" && pwd)
  # An update runs this already-installed copy. Reinstalling a file over itself
  # makes GNU install fail, which previously caused no-op scheduled updates to
  # exit unsuccessfully.
  if [ "$(readlink -f "$source")" != "/usr/local/lib/antigravity-linux/install.sh" ]; then
    install -Dm0755 "$source" /usr/local/lib/antigravity-linux/install.sh
    install_update_units "$source_dir" /usr/local/lib/antigravity-linux/systemd
  fi

  install -d -m0755 /usr/local/bin
  cat > /usr/local/bin/antigravity-linux <<'SH'
#!/usr/bin/env bash
set -euo pipefail
helper=/usr/local/lib/antigravity-linux/install.sh
exec "$helper" "$@"
SH
  chmod 0755 /usr/local/bin/antigravity-linux
  cat > /usr/local/bin/update-antigravity <<'SH'
#!/usr/bin/env bash
exec antigravity-linux update --desktop "$@"
SH
  chmod 0755 /usr/local/bin/update-antigravity
  cat > /usr/local/bin/update-antigravity-ide <<'SH'
#!/usr/bin/env bash
exec antigravity-linux update --ide "$@"
SH
  chmod 0755 /usr/local/bin/update-antigravity-ide
}

systemd_available() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

install_update_timer() {
  local unit
  for unit in antigravity-linux-update.service antigravity-linux-update.timer; do
    if [ "$(readlink "/etc/systemd/system/$unit" 2>/dev/null || true)" = /dev/null ]; then
      [ "$AUTO_REQUEST" != 1 ] || err "$unit is masked. Unmask it before explicitly enabling automatic updates."
      warn "Preserving masked unit $unit"
      return
    fi
  done
  local source_dir
  source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  install_update_units "$source_dir" /etc/systemd/system
  if ! systemd_available; then
    warn "systemd is unavailable; use manual updates on this system"
    return
  fi
  systemctl daemon-reload
  # Never re-enable a timer simply because an ordinary update ran.
  if [ "$AUTO_REQUEST" = 1 ] || { [ "$ACTION" = install ] && [ "$HAD_STATE" -eq 0 ] && [ "$AUTO_UPDATE" -eq 1 ]; }; then
    systemctl enable --now antigravity-linux-update.timer
  elif [ "$AUTO_UPDATE" -eq 0 ]; then
    systemctl disable --now antigravity-linux-update.timer
  fi
}

load_state() {
  HAD_STATE=0
  if [ -f "$STATE_DIR/preferences" ]; then
    HAD_STATE=1
    local key value
    while IFS='=' read -r key value; do
      [[ "$value" =~ ^[01]$ ]] || err "Invalid saved preference: $key"
      case "$key" in
        desktop) SAVED_DESKTOP="$value" ;;
        ide) SAVED_IDE="$value" ;;
        auto_update) AUTO_UPDATE="$value" ;;
        nautilus) SAVED_NAUTILUS="$value" ;;
        *) err "Unknown saved preference: $key" ;;
      esac
    done < "$STATE_DIR/preferences"
  else
    # Migrate existing helper installations without selecting uninstalled apps.
    [ ! -f /opt/antigravity/.antigravity-linux-version ] || SAVED_DESKTOP=1
    [ ! -f /opt/antigravity-ide/.antigravity-linux-version ] || SAVED_IDE=1
    if [ -f /etc/systemd/system/antigravity-linux-update.timer ]; then
      HAD_STATE=1
      if systemd_available && ! systemctl is-enabled --quiet antigravity-linux-update.timer; then AUTO_UPDATE=0; fi
    fi
  fi
  if [ "$NAUTILUS_EXPLICIT" -eq 0 ]; then INSTALL_NAUTILUS="$SAVED_NAUTILUS"; fi
  if [ "$PRODUCTS_EXPLICIT" -eq 0 ] && { [ "$ACTION" != install ] || [ "$DO_PRINT_DOWNLOADS" -eq 1 ]; }; then
    INSTALL_DESKTOP="$SAVED_DESKTOP"; INSTALL_IDE="$SAVED_IDE"
  fi
  if [ -n "$AUTO_REQUEST" ]; then AUTO_UPDATE="$AUTO_REQUEST"; fi
}

save_state() {
  install -d -m0755 "$STATE_DIR"
  # Record every managed installed product; selecting one for a manual update
  # does not silently remove the other from scheduled updates.
  SAVED_DESKTOP=0; SAVED_IDE=0
  [ ! -f /opt/antigravity/.antigravity-linux-version ] || SAVED_DESKTOP=1
  [ ! -f /opt/antigravity-ide/.antigravity-linux-version ] || SAVED_IDE=1
  printf 'desktop=%s\nide=%s\nauto_update=%s\nnautilus=%s\n' \
    "$SAVED_DESKTOP" "$SAVED_IDE" "$AUTO_UPDATE" "$INSTALL_NAUTILUS" > "$STATE_DIR/preferences.new"
  chmod 0644 "$STATE_DIR/preferences.new"
  mv "$STATE_DIR/preferences.new" "$STATE_DIR/preferences"
}

acquire_lock() {
  need flock
  exec 9>"$LOCK_FILE"
  flock -n 9 || err "Another install, update, rollback or uninstall is running. Try again after it finishes."
}

finish_operation() {
  local code="$?"
  trap - EXIT
  if [ "$code" -ne 0 ] && [ "$TRACK_RESULT" -eq 1 ]; then
    recover_installation /opt/antigravity "$DESKTOP_TOP/antigravity" || true
    recover_installation /opt/antigravity-ide Antigravity-IDE/antigravity-ide || true
  fi
  if [ -n "$WORK_DIR" ]; then rm -rf -- "$WORK_DIR"; fi
  if [ "$TRACK_RESULT" -eq 1 ]; then
    local result=last-success
    [ "$code" -eq 0 ] || result=last-failure
    printf '%s | %s | exit=%s | %s\n' "$(date -u +%FT%TZ)" "$OPERATION" "$code" "$FAILURE_MESSAGE" > "$STATE_DIR/$result.new"
    mv "$STATE_DIR/$result.new" "$STATE_DIR/$result"
    if [ "$OPERATION" = update ]; then
      cp "$STATE_DIR/$result" "$STATE_DIR/update-$result.new"
      mv "$STATE_DIR/update-$result.new" "$STATE_DIR/update-$result"
    fi
  fi
  exit "$code"
}

rollback_product() {
  local root="$1" launcher="$2"
  validate_installation "${root}.previous" "$launcher" || err "No valid previous release for $root"
  # This temporary rename leaves the current installation usable on interruption.
  rm -rf "${root}.new"
  mv "${root}.previous" "${root}.new"
  safe_replace_dir "${root}.new" "$root" "$launcher" || err "Rollback failed for $root"
  log "Restored $root $(installed_version "$root/.antigravity-linux-version")"
}

check_updates() {
  local js="$1" product root resolved version url current relation
  for product in desktop ide; do
    [ "$product" != desktop ] || [ "$INSTALL_DESKTOP" -eq 1 ] || continue
    [ "$product" != ide ] || [ "$INSTALL_IDE" -eq 1 ] || continue
    root=/opt/antigravity
    [ "$product" != ide ] || root=/opt/antigravity-ide
    resolved=$(resolve_download_from_bundle "$js" "$product") || err "Could not resolve $product download"
    read -r version url <<< "$resolved"
    if [ "$DO_PRINT_DOWNLOADS" -eq 1 ]; then
      log "$product $version: $url"
      continue
    fi
    current=$(installed_version "$root/.antigravity-linux-version")
    relation='not installed'
    if [ -n "$current" ]; then relation=$(version_relation "$current" "$version") || err "Cannot compare $product releases"; fi
    log "$product: installed=${current:-none}; available=$version; $relation"
  done
}

print_status() {
  log "Antigravity Linux status"
  if [ -x /usr/local/bin/antigravity ]; then
    log "- Antigravity 2.0: installed ($(installed_version /opt/antigravity/.antigravity-linux-version))"
    log "  Command: /usr/local/bin/antigravity"
  else
    log "- Antigravity 2.0: not installed by this helper"
  fi
  if [ -x /usr/local/bin/antigravity-ide ]; then
    log "- Antigravity IDE: installed ($(installed_version /opt/antigravity-ide/.antigravity-linux-version))"
    log "  Command: /usr/local/bin/antigravity-ide"
  else
    log "- Antigravity IDE: not installed by this helper"
  fi
  if [ -x /usr/local/bin/antigravity-linux ]; then
    log "- Update helper: installed"
  else
    log "- Update helper: not installed"
  fi
  log "- Managed products: desktop=$SAVED_DESKTOP ide=$SAVED_IDE"
  log "- Automatic installation preference: $AUTO_UPDATE (1=enabled, 0=disabled)"
  local timer_state=unavailable
  if systemd_available; then timer_state=$(systemctl is-enabled antigravity-linux-update.timer 2>/dev/null || true); fi
  log "- Timer: $timer_state"
  local helper=/usr/local/lib/antigravity-linux/install.sh digest
  if [ -f "$helper" ]; then
    digest=$(sha256sum "$helper"); log "- Helper revision (SHA-256): ${digest%% *}"
  fi
  local item root
  for item in last-success last-failure update-last-success update-last-failure; do
    log "- $item: $(installed_version "$STATE_DIR/$item")"
  done
  for root in /opt/antigravity /opt/antigravity-ide; do
    if [ -f "$root/.antigravity-linux-version" ]; then
      log "- $root verification: $(installed_version "$root/.antigravity-linux-verification")"
      log "  Archive SHA-256: $(installed_version "$root/.antigravity-linux-sha256")"
      log "  Previous release: $(installed_version "${root}.previous/.antigravity-linux-version")"
    fi
  done
}


print_success_summary() {
  log ""
  log "Antigravity Linux install complete."
  log ""
  log "Installed:"
  if [ "$INSTALL_DESKTOP" -eq 1 ]; then
    log "- Antigravity 2.0: /usr/local/bin/antigravity"
  fi
  if [ "$INSTALL_IDE" -eq 1 ]; then
    log "- Antigravity IDE: /usr/local/bin/antigravity-ide"
  fi
  log ""
  log "Manage:"
  log "- Status:    antigravity-linux --status"
  log "- Update:    sudo antigravity-linux update"
  log "- Update log: journalctl -u antigravity-linux-update.service"
  log "- Timer:     systemctl status antigravity-linux-update.timer"
  log "- Uninstall: sudo antigravity-linux --uninstall"

  if [ "$INSTALL_IDE" -eq 1 ]; then
    log ""
    log "Folder open integration: use your file manager's Open With menu, or Nautilus context menu after restarting Files."
  fi
}

uninstall_all() {
  require_root_or_reexec
  systemctl disable --now antigravity-linux-update.timer 2>/dev/null || true
  rm -f /etc/systemd/system/antigravity-linux-update.service /etc/systemd/system/antigravity-linux-update.timer
  if systemd_available; then systemctl daemon-reload; fi
  rm -rf /opt/antigravity /opt/antigravity.new /opt/antigravity.previous /opt/antigravity-ide /opt/antigravity-ide.new /opt/antigravity-ide.previous /usr/local/lib/antigravity-linux
  rm -f /usr/local/bin/antigravity /usr/local/bin/antigravity-ide /usr/local/bin/update-antigravity /usr/local/bin/update-antigravity-ide /usr/local/bin/antigravity-linux
  rm -f /usr/share/applications/antigravity.desktop /usr/share/applications/antigravity-ide.desktop
  rm -f /usr/share/icons/hicolor/512x512/apps/antigravity.png /usr/share/icons/hicolor/512x512/apps/antigravity-ide.png
  rm -f /usr/share/nautilus-python/extensions/open-in-antigravity-ide.py
  rm -rf "$STATE_DIR"
  refresh_desktop_caches
  log "Removed helper-managed Antigravity files. User settings under home directories were left untouched."
}

main() {
  load_state
  if [ "$DO_STATUS" -eq 1 ]; then print_status; return; fi
  if [ "$ACTION" = check ] || [ "$DO_PRINT_DOWNLOADS" -eq 1 ]; then
    [ "$INSTALL_DESKTOP$INSTALL_IDE" != 00 ] || err "No managed products. Select --desktop, --ide or --all to check."
    need python3
    WORK_DIR=$(mktemp -d)
    trap finish_operation EXIT
    local js
    js=$(resolve_main_bundle "$WORK_DIR") || err "Could not read official downloads"
    check_updates "$js"
    return
  fi

  require_local_script
  require_root_or_reexec
  umask 022
  acquire_lock
  # Re-read state under the lock before any changes.
  load_state
  if [ "$DO_UNINSTALL" -eq 1 ]; then uninstall_all; return; fi
  if [ "$SCHEDULED" -eq 1 ] && [ "$AUTO_UPDATE" -eq 0 ]; then
    log "Automatic installation is disabled."
    return
  fi
  OPERATION="$ACTION"
  install -d -m0755 "$STATE_DIR"
  TRACK_RESULT=1
  trap finish_operation EXIT
  trap 'FAILURE_MESSAGE="Interrupted"; exit 130' INT
  trap 'FAILURE_MESSAGE="Terminated"; exit 143' TERM
  trap 'FAILURE_MESSAGE="Failed at line $LINENO"' ERR
  recover_installation /opt/antigravity "$DESKTOP_TOP/antigravity"
  recover_installation /opt/antigravity-ide Antigravity-IDE/antigravity-ide

  if [ "$ACTION" = configure ]; then
    [ -f /usr/local/lib/antigravity-linux/install.sh ] || err "Install the helper before configuring automatic updates"
    save_state
    install_update_timer
    log "Automatic installation preference saved: $AUTO_UPDATE"
    return
  fi
  [ "$INSTALL_DESKTOP$INSTALL_IDE" != 00 ] || err "No managed products. Run install with --desktop or --ide first."
  if [ "$ACTION" = rollback ]; then
    # Validate all requested rollback targets before changing either product.
    if [ "$INSTALL_DESKTOP" -eq 1 ]; then validate_installation /opt/antigravity.previous "$DESKTOP_TOP/antigravity" || err "No previous desktop release"; fi
    if [ "$INSTALL_IDE" -eq 1 ]; then validate_installation /opt/antigravity-ide.previous Antigravity-IDE/antigravity-ide || err "No previous IDE release"; fi
    # Disable updates first so a later failure cannot immediately undo rollback.
    AUTO_UPDATE=0; AUTO_REQUEST=0
    save_state
    install_update_timer
    if [ "$INSTALL_DESKTOP" -eq 1 ]; then rollback_product /opt/antigravity "$DESKTOP_TOP/antigravity"; fi
    if [ "$INSTALL_IDE" -eq 1 ]; then rollback_product /opt/antigravity-ide Antigravity-IDE/antigravity-ide; fi
    log "Automatic installation is disabled to preserve the restored release."
    return
  fi

  install_deps_debian
  WORK_DIR=$(mktemp -d /var/tmp/antigravity-linux.XXXXXX)
  local js
  js=$(resolve_main_bundle "$WORK_DIR") || err "Could not read official downloads"
  if [ "$INSTALL_DESKTOP" -eq 1 ]; then install_desktop_app "$WORK_DIR" "$js"; fi
  if [ "$INSTALL_IDE" -eq 1 ]; then install_ide_app "$WORK_DIR" "$js"; fi
  install_nautilus_extension
  if [ "$INSTALL_CLI" -eq 1 ]; then
    [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || err "--cli requires a non-root invoking user via sudo"
    log "Running Google's official CLI installer as $SUDO_USER..."
    fetch_official "$CLI_INSTALLER" "$WORK_DIR/cli-install.sh"
    sudo -u "$SUDO_USER" -H bash < "$WORK_DIR/cli-install.sh"
  fi
  install_manager_command
  save_state
  install_update_timer
  print_success_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
