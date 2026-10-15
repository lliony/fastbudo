"""用上游固定样本的内容/CRC 断言验证兼容性，不执行归档中的程序。"""
import binascii
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[2]


class FormatTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fastbudo-format-')
        self.root = Path(self.temp.name)
        self.output = self.root / 'output'
        self.output.mkdir()
        for source in (ROOT / 'Tests/Fixtures/libarchive').glob('*.uu'):
            lines = source.read_bytes().splitlines()
            content = b''.join(binascii.a2b_uu(line) for line in lines[1:] if line not in (b'end', b''))
            (self.root / source.name[:-3]).write_bytes(content)

    def tearDown(self):
        self.temp.cleanup()

    def extract(self, name, password=b''):
        result = subprocess.run([str(ROOT / '.build/engine/ArchiveBridge'),
                                 str(ROOT / '.build/engine/7z.so'),
                                 str(self.root / name), str(self.output)],
                                input=password, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout)
        return json.loads(result.stdout)

    def test_rar5_stored(self):
        self.extract('test_read_format_rar5_stored.rar')
        self.assertEqual((self.output / 'helloworld.txt').read_bytes(), b'hello libarchive test suite!\n')

    def test_rar4_and_rar5_encrypted_headers(self):
        for version in (4, 5):
            with self.subTest(version=version):
                self.extract(f'test_read_format_rar{version}_encrypted_filenames.rar', b'password')
                for letter in 'abcd':
                    file = self.output / f'{letter}.txt'
                    self.assertEqual(file.read_bytes(), f'This is from {letter}.txt'.encode())
                    file.unlink()

    def test_rar4_volumes(self):
        self.extract('test_rar_multivolume_single_file.part1.rar')
        content = (self.output / 'LibarchiveAddingTest.html').read_bytes()
        self.assertEqual(len(content), 20111)
        self.assertTrue(content.endswith(b'<P STYLE="margin-bottom: 0in"><BR>\n</P>\n</BODY>\n</HTML>'))

    def test_rar5_volumes(self):
        self.extract('test_read_format_rar5_multiarchive.part01.rar')
        parent = self.output / 'home/antek/temp/build/unrar5/libarchive/bin'
        self.assertEqual(zlib.crc32((parent / 'bsdcat_test').read_bytes()), 0x35277473)
        self.assertEqual(zlib.crc32((parent / 'bsdtar_test').read_bytes()), 0xE59665F8)

    def test_zip_aes_zipcrypto_and_split(self):
        payload = bytes(range(256)) * 1024
        (self.root / 'data').write_bytes(payload)
        cli = ROOT / '.build/engine/7zz'
        for method in ('AES256', 'ZipCrypto'):
            name = method + '.zip'
            subprocess.run([str(cli), 'a', '-tzip', '-p', '-mem='+method, str(self.root/name), 'data'],
                           cwd=self.root, input=b'password\npassword\n', capture_output=True, check=True)
            self.extract(name, b'password')
            self.assertEqual((self.output/'data').read_bytes(), payload)
            (self.output/'data').unlink()
        subprocess.run(['/usr/bin/zip', '-0', '-s', '64k', 'split.zip', 'data'], cwd=self.root,
                       capture_output=True, check=True)
        self.extract('split.zip')
        self.assertEqual((self.output/'data').read_bytes(), payload)

    def test_legacy_rar_volume_names(self):
        # RAR4 主头仅改变编号标志和头 CRC，数据与上游样本保持一致。
        import struct
        for i, suffix in enumerate(('.rar', '.r00', '.r01'), 1):
            data = bytearray((self.root / f'test_rar_multivolume_single_file.part{i}.rar').read_bytes())
            flags = struct.unpack_from('<H', data, 10)[0]
            struct.pack_into('<H', data, 10, flags & ~0x10)
            header_size = struct.unpack_from('<H', data, 12)[0]
            struct.pack_into('<H', data, 7, zlib.crc32(data[9:7 + header_size]) & 0xFFFF)
            (self.root / ('legacy' + suffix)).write_bytes(data)
        self.extract('legacy.rar')
        content = (self.output / 'LibarchiveAddingTest.html').read_bytes()
        self.assertEqual(len(content), 20111)
        self.assertTrue(content.endswith(b'</HTML>'))

    def test_missing_rar_volume_fails(self):
        (self.root / 'test_rar_multivolume_single_file.part2.rar').unlink()
        result = subprocess.run([str(ROOT / '.build/engine/ArchiveBridge'),
                                 str(ROOT / '.build/engine/7z.so'),
                                 str(self.root / 'test_rar_multivolume_single_file.part1.rar'),
                                 str(self.output)], input=b'', capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
