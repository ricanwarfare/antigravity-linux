"""Catch stale install instructions and broken generated documentation offline."""
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Buttons(HTMLParser):
    def __init__(self):
        super().__init__()
        self.commands = []
        self.ids = []
        self.duplicate_attrs = []

    def handle_starttag(self, tag, attrs):
        names = [k for k, _ in attrs]
        if len(set(names)) != len(names):
            self.duplicate_attrs.append(tag)
        for key, value in attrs:
            if key == 'data-copy': self.commands.append(value)
            if key == 'id': self.ids.append(value)


class DocsTests(unittest.TestCase):
    def test_generated_files_match(self):
        self.assertEqual((ROOT/'install.sh').read_bytes(), (ROOT/'docs/install.sh').read_bytes())
        body = (ROOT/'README.md').read_text().split('A community installer and updater', 1)[1]
        self.assertEqual((ROOT/'docs/llms.txt').read_text(), '# Antigravity Linux Installer\n\nA community installer and updater' + body)

    def test_website_commands_are_reviewed_and_parse(self):
        page = (ROOT/'docs/index.html').read_text()
        parser = Buttons(); parser.feed(page)
        self.assertGreater(len(parser.commands), 10)
        self.assertFalse(parser.duplicate_attrs)
        self.assertEqual(len(parser.ids), len(set(parser.ids)))
        for command in parser.commands:
            with self.subTest(command=command):
                self.assertNotIn('INSTALLER_URL', command)
                self.assertNotIn('--install-url', command)
                self.assertNotRegex(command, r'curl[^\n]*\|')
                result = subprocess.run(['bash','-n'], input=command, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                if 'git clone' in command:
                    self.assertIn('git rev-parse HEAD', command)
                    self.assertIn('less install.sh', command)
                    self.assertIn('bash scripts/check.sh', command)
        self.assertNotIn('store a specific update URL', page)

    def test_public_options_documented(self):
        help_text = subprocess.run(['bash', str(ROOT/'install.sh'), '--help'], check=True, capture_output=True, text=True).stdout
        readme = (ROOT/'README.md').read_text()
        for option in ['--check-updates', '--allow-downgrade', '--desktop-sha256', '--ide-sha256',
                       '--disable-auto-update', '--enable-auto-update']:
            self.assertIn(option, help_text)
            self.assertIn(option, readme)
