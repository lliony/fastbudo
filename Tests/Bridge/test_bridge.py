"""通过真实引擎验证结构化条目与文件写入边界。"""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / '.build/engine/ArchiveBridge'
LIBRARY = ROOT / '.build/engine/7z.so'


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fastbudo-bridge-')
        self.root = Path(self.temp.name)
        self.archive = self.root / 'input.zip'
        self.output = self.root / 'out'
        self.output.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def zip(self, entries):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for name, data in entries:
                archive.writestr(name, data)

    def run_bridge(self, extract=False, password=b''):
        args = [str(ENGINE), str(LIBRARY), str(self.archive)]
        if extract:
            args.append(str(self.output))
        result = subprocess.run(args, input=password, capture_output=True, timeout=20)
        return result.returncode, json.loads(result.stdout)

    def test_extract_success_does_not_repeat_listing(self):
        self.zip([('a.txt', b'a')])
        code, result = self.run_bridge(True)
        self.assertEqual(code, 0)
        self.assertEqual(result, {'ok': True})
        self.assertEqual((self.output / 'a.txt').read_bytes(), b'a')

    def test_preserves_original_names_and_sizes(self):
        self.zip([('a\nb', b'newline'), ('a_b', b'underscore'), ('中文.txt', b'utf8')])
        code, result = self.run_bridge()
        self.assertEqual(code, 0)
        self.assertEqual({e['path']: e['size'] for e in result['entries']},
                         {'a\nb': 7, 'a_b': 10, '中文.txt': 4})

    def test_extracts_regular_files_and_empty_directories(self):
        self.zip([('dir/', b''), ('a\nb', b'exact bytes')])
        code, _ = self.run_bridge(True)
        self.assertEqual(code, 0)
        self.assertEqual((self.output / 'a\nb').read_bytes(), b'exact bytes')
        self.assertTrue((self.output / 'dir').is_dir())

    def test_rejects_traversal_before_any_output(self):
        for name in ('../outside', '/absolute', 'dir/../../outside'):
            with self.subTest(name=name):
                self.zip([('valid', b'data'), (name, b'bad')])
                code, result = self.run_bridge(True)
                self.assertNotEqual(code, 0)
                self.assertEqual(result['error'], 'unsafe_path')
                self.assertEqual(list(self.output.iterdir()), [])

    def test_rejects_symlink(self):
        link = zipfile.ZipInfo('link')
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.zip([(link, b'../outside')])
        code, result = self.run_bridge(True)
        self.assertNotEqual(code, 0)
        self.assertEqual(result['error'], 'unsupported_entry')
        self.assertEqual(list(self.output.iterdir()), [])

    def test_does_not_follow_existing_symlink(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.output / 'dir').symlink_to(outside, target_is_directory=True)
        self.zip([('dir/file', b'bad')])
        code, _ = self.run_bridge(True)
        self.assertNotEqual(code, 0)
        self.assertEqual(list(outside.iterdir()), [])

    def test_does_not_overwrite_existing_file(self):
        (self.output / 'existing').write_bytes(b'original')
        self.zip([('existing', b'changed')])
        code, _ = self.run_bridge(True)
        self.assertNotEqual(code, 0)
        self.assertEqual((self.output / 'existing').read_bytes(), b'original')

    def test_rejects_name_collisions(self):
        for names in [('a', 'A'), ('é', 'e\u0301'), ('a', 'a/child'), ('Dir/a', 'dir/b')]:
            with self.subTest(names=names):
                self.zip([(name, b'data') for name in names])
                code, result = self.run_bridge(True)
                self.assertNotEqual(code, 0)
                self.assertEqual(result['error'], 'path_collision')
                self.assertEqual(list(self.output.iterdir()), [])

    def test_password_and_split_7z(self):
        cli = ROOT / '.build/engine/7zz'
        payload = os.urandom(4096)
        (self.root / 'payload').write_bytes(payload)
        for split in (False, True):
            with self.subTest(split=split):
                archive = self.root / ('split.7z' if split else 'encrypted.7z')
                args = [str(cli), 'a', '-t7z', '-p', '-mhe=on', str(archive), 'payload']
                if split:
                    args.append('-v1k')
                subprocess.run(args, cwd=self.root, input=b'test-password\ntest-password\n',
                               capture_output=True, check=True, timeout=30)
                self.archive = Path(str(archive) + '.001') if split else archive
                code, _ = self.run_bridge(password=b'wrong')
                self.assertNotEqual(code, 0)
                code, result = self.run_bridge(password=b'test-password')
                self.assertEqual(code, 0, result)
                self.assertEqual(result['entries'][0]['path'], 'payload')
                code, result = self.run_bridge(True, b'test-password')
                self.assertEqual(code, 0, result)
                self.assertEqual((self.output / 'payload').read_bytes(), payload)
                (self.output / 'payload').unlink()

    def test_rejects_tar_hardlinks_and_devices(self):
        import tarfile
        for kind in (tarfile.LNKTYPE, tarfile.CHRTYPE, tarfile.FIFOTYPE):
            with self.subTest(kind=kind):
                self.archive = self.root / 'input.tar'
                with tarfile.open(self.archive, 'w') as archive:
                    entry = tarfile.TarInfo('special')
                    entry.type = kind
                    if kind == tarfile.LNKTYPE:
                        entry.linkname = '../outside'
                    archive.addfile(entry)
                code, result = self.run_bridge(True)
                self.assertNotEqual(code, 0)
                self.assertEqual(result['error'], 'unsupported_entry')

    def test_preserves_modification_time(self):
        import datetime
        info = zipfile.ZipInfo('dated.txt', (2020, 1, 2, 3, 4, 6))
        self.zip([(info, b'content')])
        code, result = self.run_bridge(True)
        self.assertEqual(code, 0, result)
        expected = datetime.datetime(2020, 1, 2, 3, 4, 6).timestamp()
        self.assertAlmostEqual((self.output / 'dated.txt').stat().st_mtime, expected, delta=2)

    def test_expansion_requires_confirmation_before_writing(self):
        with zipfile.ZipFile(self.archive, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('large', b'0' * (4 * 1024 * 1024))
        code, result = self.run_bridge(True)
        self.assertNotEqual(code, 0)
        self.assertEqual(result['error'], 'expansion_confirmation')
        self.assertEqual(list(self.output.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
