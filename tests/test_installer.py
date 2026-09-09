"""Offline behavioral tests. All installation paths are redirected into temp dirs."""
import fcntl
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SOURCE = (REPO / 'install.sh').read_text()
DESKTOP_URL = 'https://storage.googleapis.com/antigravity-public/antigravity-hub/{version}/linux-x64/Antigravity.tar.gz'
IDE_URL = 'https://edgedl.me.gvt1.com/edgedl/release2/test/antigravity/stable/{version}/linux-x64/Antigravity%20IDE.tar.gz'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = SOURCE
        for prefix in ['/usr/local', '/usr/share', '/opt', '/etc/systemd', '/var/lib', '/var/tmp', '/run']:
            (self.root / prefix.lstrip('/')).mkdir(parents=True)
            source = source.replace(prefix, str(self.root / prefix.lstrip('/')))
        self.helper = self.root / 'install.sh'
        self.helper.write_text(source)
        self.state = self.root / 'var/lib/antigravity-linux'
        self.desktop = self.root / 'opt/antigravity'
        self.ide = self.root / 'opt/antigravity-ide'
        self.log = self.root / 'calls'
        self.page = self.root / 'page.html'
        self.set_release('1.2.3-100')
        self.mocks = r'''
require_root_or_reexec() { :; }
systemd_available() { return 0; }
systemctl() { printf 'systemctl %s\n' "$*" >> "$TEST_LOG"; }
install_deps_debian() { :; }
fix_chrome_sandbox() { :; }
refresh_desktop_caches() { :; }
install_nautilus_extension() { :; }
fetch_official() {
  validate_url "$1" || return 1
  case "$1" in
    */download) cp "$TEST_PAGE" "$2" ;;
    */Antigravity.tar.gz) cp "$TEST_DESKTOP_ARCHIVE" "$2" ;;
    */Antigravity%20IDE.tar.gz) cp "$TEST_IDE_ARCHIVE" "$2" ;;
    *) return 1 ;;
  esac
}
'''

    def run_shell(self, body, args=(), mocks=False, ok=True):
        env = dict(os.environ, TEST_HELPER=str(self.helper), TEST_LOG=str(self.log),
                   TEST_PAGE=str(self.page), TEST_DESKTOP_ARCHIVE=str(self.root/'desktop.tar.gz'),
                   TEST_IDE_ARCHIVE=str(self.root/'ide.tar.gz'))
        code = 'source "$TEST_HELPER" "$@"\n' + (self.mocks if mocks else '') + '\n' + body
        result = subprocess.run(['bash', '-c', code, 'test', *args], env=env,
                                capture_output=True, text=True, timeout=15)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def set_release(self, version):
        self.page.write_text(DESKTOP_URL.format(version=version) + '\n' + IDE_URL.format(version=version))
        for product, top, launcher in [('desktop', 'Antigravity-x64', 'antigravity'), ('ide', 'Antigravity IDE', 'antigravity-ide')]:
            with tarfile.open(self.root / (product + '.tar.gz'), 'w:gz') as tf:
                content = ('#!/bin/sh\necho ' + version + '\n').encode()
                m = tarfile.TarInfo(top + '/' + launcher); m.mode = 0o755; m.size = len(content)
                tf.addfile(m, io.BytesIO(content))

    def managed(self, path, version, launcher='Antigravity-x64/antigravity'):
        (path / launcher).parent.mkdir(parents=True, exist_ok=True)
        (path / launcher).write_text('#!/bin/sh\nexit 0\n'); (path / launcher).chmod(0o755)
        (path / '.antigravity-linux-version').write_text(version + '\n')

    def test_ide_only_and_scheduled_update_preserve_products(self):
        self.run_shell('main', ['--ide'], mocks=True)
        self.assertFalse(self.desktop.exists())
        self.assertIn('desktop=0\nide=1', (self.state/'preferences').read_text())
        self.set_release('1.2.3-101')
        self.run_shell('main', ['update', '--scheduled', '--no-apt'], mocks=True)
        self.assertFalse(self.desktop.exists())
        self.assertEqual((self.ide/'.antigravity-linux-version').read_text().strip(), '1.2.3-101')
        self.assertEqual(self.log.read_text().count('enable --now'), 1)

    def test_manual_update_does_not_reenable_timer(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.log.write_text('')
        self.run_shell('systemctl() { printf "%s\\n" "$*" >> "$TEST_LOG"; }; main', ['update'], mocks=True)
        self.assertNotIn('enable --now', self.log.read_text())

    def test_saved_disable_prevents_scheduled_downloads(self):
        self.run_shell('main', ['--ide', '--no-auto-update', '--no-nautilus'], mocks=True)
        self.run_shell('fetch_official() { return 99; }; main', ['update', '--scheduled'], mocks=True)
        result = self.run_shell('load_state; echo "$AUTO_UPDATE $INSTALL_NAUTILUS"', ['update'])
        self.assertEqual(result.stdout.strip(), '0 0')
        self.run_shell('main', ['--enable-auto-update'], mocks=True)
        self.assertIn('auto_update=1', (self.state/'preferences').read_text())
        self.run_shell('main', ['--disable-auto-update'], mocks=True)
        self.assertIn('auto_update=0', (self.state/'preferences').read_text())

    def test_manual_product_selection_keeps_other_product_saved(self):
        self.run_shell('main', ['--all'], mocks=True)
        self.run_shell('main', ['update', '--ide'], mocks=True)
        self.assertIn('desktop=1\nide=1', (self.state/'preferences').read_text())

    def test_check_only_does_not_change_installation_or_state(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.set_release('1.2.4-200')
        result = self.run_shell('main', ['check'], mocks=True)
        self.assertIn('upgrade', result.stdout)
        for name, content in before.items():
            if name not in ['page.html', 'desktop.tar.gz', 'ide.tar.gz']:
                self.assertEqual((self.root/name).read_bytes(), content, name)

    def test_new_build_installs_and_downgrade_requires_explicit_flag(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.set_release('1.2.3-101')
        self.run_shell('main', ['update'], mocks=True)
        self.assertEqual((self.desktop/'.antigravity-linux-version').read_text().strip(), '1.2.3-101')
        self.set_release('1.2.3-100')
        self.run_shell('main', ['update', '--force'], mocks=True, ok=False)
        self.assertEqual((self.desktop/'.antigravity-linux-version').read_text().strip(), '1.2.3-101')
        self.run_shell('main', ['update', '--allow-downgrade'], mocks=True)
        self.assertEqual((self.desktop/'.antigravity-linux-version').read_text().strip(), '1.2.3-100')

    def test_malformed_and_unapproved_urls_fail_closed(self):
        for url in ['http://evil.test/stable/1.2.3/linux-x64/Antigravity.tar.gz',
                    'https://storage.googleapis.com/other-bucket/stable/1.2.3/linux-x64/Antigravity.tar.gz',
                    DESKTOP_URL.format(version='unknown'), 'no download links']:
            with self.subTest(url=url):
                self.page.write_text(url)
                self.run_shell('resolve_desktop_download "$TEST_PAGE"', ok=False)
        for url in ['https://antigravity.google@evil.test/download', 'https://antigravity.google:444/download',
                    'https://storage.googleapis.com/antigravity-public/../other/file',
                    'https://storage.googleapis.com/antigravity-public/%2e%2e/other/file']:
            with self.subTest(url=url):
                self.run_shell('validate_url ' + repr(url), ok=False)

    def test_release_suffixes_preserved_and_unknown_order_blocked(self):
        self.page.write_text(DESKTOP_URL.format(version='1.2.3-build2'))
        self.assertIn('1.2.3-build2 ', self.run_shell('resolve_desktop_download "$TEST_PAGE"').stdout)
        self.assertEqual(self.run_shell('version_relation 1.2.3-build1 1.2.3-build2').stdout.strip(), 'ambiguous')
        self.assertEqual(self.run_shell('version_relation 1.2.3 1.2.3-123').stdout.strip(), 'upgrade')

    def test_checksum_mismatch_keeps_existing_release(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.set_release('1.2.4-200')
        self.run_shell('main', ['update', '--desktop-sha256', '0'*64], mocks=True, ok=False)
        self.assertEqual((self.desktop/'.antigravity-linux-version').read_text().strip(), '1.2.3-100')
        digest = hashlib.sha256((self.root/'desktop.tar.gz').read_bytes()).hexdigest()
        self.run_shell('main', ['update', '--desktop-sha256', digest], mocks=True)
        self.assertIn('Matched supplied', (self.desktop/'.antigravity-linux-verification').read_text())

    def test_failed_activation_restores_previous_release(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.set_release('1.2.4-200')
        body = r'''
mv() {
  if [[ "$1" == */antigravity.new ]]; then return 1; fi
  command mv "$@"
}
main
'''
        self.run_shell(body, ['update'], mocks=True, ok=False)
        self.assertEqual((self.desktop/'.antigravity-linux-version').read_text().strip(), '1.2.3-100')

    def test_post_activation_validation_failure_restores_previous(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.set_release('1.2.4-200')
        body = r'''
mv() {
  command mv "$@" || return
  if [[ "$1" == */antigravity.new ]]; then rm "$2/Antigravity-x64/antigravity"; fi
}
main
'''
        self.run_shell(body, ['update'], mocks=True, ok=False)
        self.assertEqual((self.desktop/'.antigravity-linux-version').read_text().strip(), '1.2.3-100')
        self.assertTrue((self.desktop/'Antigravity-x64/antigravity').exists())

    def test_interrupted_replacement_recovered_before_update(self):
        self.managed(Path(str(self.desktop)+'.previous'), '1.2.3-100')
        self.run_shell('main', ['update', '--desktop'], mocks=True)
        self.assertTrue((self.desktop/'Antigravity-x64/antigravity').exists())

    def test_rollback_restores_release_and_disables_automatic_installation(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.set_release('1.2.4-200')
        self.run_shell('main', ['update'], mocks=True)
        self.run_shell('main', ['rollback'], mocks=True)
        self.assertEqual((self.desktop/'.antigravity-linux-version').read_text().strip(), '1.2.3-100')
        self.assertEqual((Path(str(self.desktop)+'.previous')/'.antigravity-linux-version').read_text().strip(), '1.2.4-200')
        self.assertIn('auto_update=0', (self.state/'preferences').read_text())

    def test_all_mutations_share_lock(self):
        lock = self.root/'run/antigravity-linux-update.lock'
        with lock.open('w') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for args in [[], ['update'], ['rollback'], ['--uninstall'], ['--disable-auto-update']]:
                with self.subTest(args=args):
                    r = self.run_shell('main', args, mocks=True, ok=False)
                    self.assertIn('Another install', r.stderr)
        self.assertFalse(self.state.exists())

    def test_status_contains_revision_history_and_verification(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.page.write_text('broken')
        self.run_shell('main', ['update'], mocks=True, ok=False)
        r = self.run_shell('main', ['--status'], mocks=True)
        for text in ['Helper revision (SHA-256)', 'last-success:', 'last-failure:', 'Archive SHA-256:', 'no publisher checksum supplied']:
            self.assertIn(text, r.stdout)

    def test_uninstall_removes_only_sandbox_managed_files(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.run_shell('main', ['--uninstall'], mocks=True)
        self.assertFalse(self.desktop.exists()); self.assertFalse(self.state.exists())
        self.assertTrue(self.helper.exists())

    def test_archive_rejects_traversal_links_special_files_and_duplicates(self):
        cases = [('Antigravity-x64/../../outside', tarfile.REGTYPE, ''),
                 ('Antigravity-x64/escape', tarfile.SYMTYPE, '/etc'),
                 ('Antigravity-x64/fifo', tarfile.FIFOTYPE, ''),
                 ('Other/launcher', tarfile.REGTYPE, '')]
        for name, typ, link in cases:
            with self.subTest(name=name):
                archive = self.root/'bad.tar.gz'
                with tarfile.open(archive, 'w:gz') as tf:
                    m = tarfile.TarInfo(name); m.type=typ; m.linkname=link; tf.addfile(m)
                self.run_shell(f'extract_archive "{archive}" "{self.root}" Antigravity-x64', ok=False)

    def test_redirect_rejected_before_second_request(self):
        # Exercise the actual network policy with an in-memory HTTP opener.
        policy = self.run_shell('network_policy').stdout
        namespace = {}; exec(policy, namespace)
        HTTPError = namespace['HTTPError']
        calls = []
        class Opener:
            def open(self, request, timeout):
                calls.append(request.full_url)
                raise HTTPError(request.full_url, 302, 'redirect', {'Location': 'http://evil.test/payload'}, None)
        namespace['build_opener'] = lambda *_: Opener()
        with self.assertRaises(ValueError):
            namespace['fetch']('https://antigravity.google/download', str(self.root/'out'))
        self.assertEqual(calls, ['https://antigravity.google/download'])

    def test_migrate_old_helper_products_and_disabled_timer(self):
        self.managed(self.ide, '1.2.3', 'Antigravity-IDE/antigravity-ide')
        timer = self.root/'etc/systemd/system/antigravity-linux-update.timer'
        timer.parent.mkdir(parents=True, exist_ok=True); timer.write_text('old timer')
        body = 'systemctl() { if [ "$1" = is-enabled ]; then return 1; fi; printf "%s\\n" "$*" >> "$TEST_LOG"; }; main'
        self.run_shell(body, ['update'], mocks=True)
        self.assertFalse(self.desktop.exists())
        preferences = (self.state/'preferences').read_text()
        self.assertIn('desktop=0\nide=1', preferences)
        self.assertIn('auto_update=0', preferences)
        self.assertNotIn('enable --now', self.log.read_text())

    def test_installed_helper_updates_without_copying_over_itself(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.helper = self.root/'usr/local/lib/antigravity-linux/install.sh'
        self.run_shell('main', ['update'], mocks=True)
        self.assertTrue(self.helper.exists())

    def test_network_failure_keeps_installed_release(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.run_shell('fetch_official() { return 1; }; main', ['update'], mocks=True, ok=False)
        self.assertEqual((self.desktop/'.antigravity-linux-version').read_text().strip(), '1.2.3-100')
        self.assertIn('update', (self.state/'update-last-failure').read_text())

    def test_configuration_does_not_overwrite_last_update_result(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        self.run_shell('main', ['update'], mocks=True)
        before = (self.state/'update-last-success').read_bytes()
        self.run_shell('main', ['--disable-auto-update'], mocks=True)
        self.assertEqual((self.state/'update-last-success').read_bytes(), before)

    def test_invalid_preferences_are_never_executed(self):
        self.state.mkdir(parents=True)
        (self.state/'preferences').write_text('desktop=$(touch '+str(self.root/'executed')+')\n')
        self.run_shell('main', ['update'], mocks=True, ok=False)
        self.assertFalse((self.root/'executed').exists())

    def test_missing_rollback_target_changes_nothing(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        before = (self.state/'preferences').read_bytes()
        self.run_shell('main', ['rollback'], mocks=True, ok=False)
        self.assertEqual((self.state/'preferences').read_bytes(), before)
        self.assertEqual((self.desktop/'.antigravity-linux-version').read_text().strip(), '1.2.3-100')

    def test_masked_timer_is_not_overwritten(self):
        self.run_shell('main', ['--desktop'], mocks=True)
        timer = self.root/'etc/systemd/system/antigravity-linux-update.timer'
        timer.unlink(); timer.symlink_to('/dev/null')
        self.run_shell('main', ['update'], mocks=True)
        self.assertTrue(timer.is_symlink())
        self.assertEqual(os.readlink(timer), '/dev/null')
        self.run_shell('main', ['--enable-auto-update'], mocks=True, ok=False)
        self.assertEqual(os.readlink(timer), '/dev/null')

    def test_archive_rejects_symlink_chain_escape(self):
        archive = self.root/'chain.tar.gz'
        with tarfile.open(archive, 'w:gz') as tf:
            for name, target in [('Antigravity-x64/a', '.'), ('Antigravity-x64/b', 'a/../outside')]:
                member = tarfile.TarInfo(name); member.type = tarfile.SYMTYPE; member.linkname = target
                tf.addfile(member)
        self.run_shell(f'extract_archive "{archive}" "{self.root}" Antigravity-x64', ok=False)
        self.assertFalse((self.root/'Antigravity-x64').exists())

    def test_archive_accepts_safe_relative_links(self):
        archive = self.root/'links.tar.gz'
        with tarfile.open(archive, 'w:gz') as tf:
            member = tarfile.TarInfo('Antigravity-x64/file'); member.size = 2
            tf.addfile(member, io.BytesIO(b'ok'))
            member = tarfile.TarInfo('Antigravity-x64/lib/link'); member.type = tarfile.SYMTYPE; member.linkname = '../file'
            tf.addfile(member)
        self.run_shell(f'extract_archive "{archive}" "{self.root}" Antigravity-x64')
        self.assertEqual((self.root/'Antigravity-x64/lib/link').read_bytes(), b'ok')

    def test_embedded_units_match_repository(self):
        destination = self.root/'units'
        self.run_shell(f'install_update_units "{self.root}/empty" "{destination}"')
        for path in (REPO/'systemd').glob('*'):
            self.assertEqual((destination/path.name).read_text().replace(str(self.root), ''), path.read_text())


if __name__ == '__main__':
    unittest.main()
