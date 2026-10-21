#!/usr/bin/env python3
"""阻止源码、暂存区及解包后的发布产物携带本机用户目录。"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

PATTERN = re.compile(rb'/(?:Users|home)/[^/\s\x00]+|/(?:private/)?var/folders/|[A-Za-z]:[\\/]Users[\\/]', re.I)


def git(*args):
    return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL)


def read_file(path):
    # 不跟随符号链接，以免读取仓库或产物之外的用户数据。
    return os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--staged', action='store_true', help='检查完整 Git 索引')
    mode.add_argument('--artifact', type=Path, help='检查解包后的发布目录或单个文件')
    args = parser.parse_args()
    failed = False
    if args.artifact:
        root = args.artifact
        if not root.exists():
            raise OSError('missing artifact')
        paths = [root] if root.is_file() or root.is_symlink() else root.rglob('*')
        entries = ((str(p.relative_to(root)) if p != root else p.name, read_file(p))
                   for p in paths if p.is_symlink() or p.is_file())
    else:
        os.chdir(os.fsdecode(git('rev-parse', '--show-toplevel').strip()))
        options = [] if args.staged else ['--others', '--exclude-standard']
        names = sorted(set(git('ls-files', '-z', '--cached', *options).split(b'\0')) - {b''})
        entries = ((os.fsdecode(n), git('show', ':' + os.fsdecode(n)) if args.staged else read_file(Path(os.fsdecode(n)))) for n in names)
    for name, data in entries:
        if PATTERN.search(data) or PATTERN.search(os.fsencode(name)):
            print('发现用户目录信息：' + name)
            failed = True
    if not failed:
        print('用户目录检查通过')
    return int(failed)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError):
        print('检查失败：无法读取全部输入，请检查路径、权限或 Git 索引。', file=sys.stderr)
        sys.exit(2)
