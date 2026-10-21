"""独立进程检查分块复制不积累 Foundation 自动释放对象；仅使用临时文件。"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CopyMemoryTests(unittest.TestCase):
    def test_large_copy_has_bounded_memory_and_identical_content(self):
        with tempfile.TemporaryDirectory(prefix='fastbudo-copy-memory-') as temp:
            root = Path(temp)
            source = root / 'source.bin'
            with source.open('wb') as stream:
                for _ in range(256):
                    stream.write(b'x' * (1024 * 1024))
            main = root / 'main.swift'
            main.write_text('''import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try ArchiveFiles.stage([root.appendingPathComponent("source.bin")],
    into: root.appendingPathComponent("output"), excludeDSStore: false, preserveAttributes: false)
''')
            executable = root / 'copy-probe'
            subprocess.run(['swiftc', '-O', str(ROOT / 'App/ArchiveFiles.swift'),
                            str(main), '-o', str(executable)], check=True, capture_output=True)
            result = subprocess.run(['/usr/bin/time', '-l', str(executable), str(root)],
                                    check=True, capture_output=True, text=True)
            peak = int(re.search(r'(\d+)\s+maximum resident set size', result.stderr)[1])
            # 256 MiB 输入不应全部驻留；独立进程避免测试宿主和其他测试影响峰值。
            self.assertLess(peak, 128 * 1024 * 1024, result.stderr)
            with source.open('rb') as expected, (root / 'output/source.bin').open('rb') as actual:
                while chunk := expected.read(1024 * 1024):
                    self.assertEqual(actual.read(len(chunk)), chunk)
                self.assertEqual(actual.read(1), b'')
            print(f'COPY_256_MIB_PEAK_BYTES={peak}')


if __name__ == '__main__':
    unittest.main()
