#!/usr/bin/env python3
"""在独立 64 MiB 测试磁盘内验证空间不足；不填满用户磁盘。"""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='fastbudo-space-') as directory:
    root = Path(directory)
    image = root / 'space.sparseimage'
    mount = root / 'mount'
    mount.mkdir()
    subprocess.run(['hdiutil', 'create', '-size', '64m', '-fs', 'HFS+', '-volname',
                    'FastBudoSpaceTest', '-type', 'SPARSE', str(image)], check=True, capture_output=True)
    subprocess.run(['hdiutil', 'attach', '-nobrowse', '-mountpoint', str(mount), str(image)],
                   check=True, capture_output=True)
    try:
        archive = root / 'input.zip'
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_STORED) as stream:
            with stream.open('payload', 'w') as output:
                for _ in range(64):
                    output.write(b'x' * (1024 * 1024))
        before = hashlib.sha256(archive.read_bytes()).digest()
        result = subprocess.run([str(ROOT / '.build/engine/ArchiveBridge'),
                                 str(ROOT / '.build/engine/7z.so'), str(archive), str(mount)],
                                input=b'', capture_output=True, timeout=30)
        assert result.returncode != 0, result.stdout
        assert hashlib.sha256(archive.read_bytes()).digest() == before
        print('空间不足时任务失败，原归档保持不变。')
    finally:
        subprocess.run(['hdiutil', 'detach', str(mount)], check=True, capture_output=True)
