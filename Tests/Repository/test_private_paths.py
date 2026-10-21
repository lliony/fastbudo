import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/check-private-paths.py'


class PrivatePathTests(unittest.TestCase):
    def test_staged_scan_uses_index_not_working_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', directory], check=True)
            file = root / 'notes.md'
            file.write_text('/' + 'Users' + '/example/project')
            subprocess.run(['git', '-C', directory, 'add', 'notes.md'], check=True)
            file.write_text('$HOME/project')
            result = subprocess.run(['python3', str(SCRIPT), '--staged'], cwd=root, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn(b'notes.md', result.stdout)
            self.assertNotIn(b'example', result.stdout)
            subprocess.run(['git', '-C', directory, 'add', 'notes.md'], check=True)
            self.assertEqual(subprocess.run(['python3', str(SCRIPT), '--staged'], cwd=root, capture_output=True).returncode, 0)

    def test_artifact_scan_includes_binary_paths(self):
        paths = ['/' + 'Users' + '/example/source', '/' + 'home' + '/example/source',
                 '/' + 'private/var/folders' + '/ab/token/file', 'C:' + '\\Users' + '\\example\\source']
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'app-binary'
            for path in paths:
                with self.subTest(path=path):
                    file.write_bytes(b'\x00\x01' + path.encode() + b'\x00')
                    result = subprocess.run(['python3', str(SCRIPT), '--artifact', directory], capture_output=True)
                    self.assertEqual(result.returncode, 1)
            file.write_bytes(b'\x00$HOME/project\x00App/main.swift\x00')
            self.assertEqual(subprocess.run(['python3', str(SCRIPT), '--artifact', directory], capture_output=True).returncode, 0)

    def test_missing_artifact_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(['python3', str(SCRIPT), '--artifact', str(Path(directory) / 'missing')], capture_output=True)
            self.assertEqual(result.returncode, 2)

    def test_symlink_target_is_checked_without_following(self):
        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory) / 'shortcut'
            link.symlink_to('/' + 'Users' + '/example/missing')
            result = subprocess.run(['python3', str(SCRIPT), '--artifact', directory], capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(b'example', result.stdout)
