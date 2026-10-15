#!/usr/bin/env python3
"""复现 7zz 文本列表丢失文件名信息；仅使用临时合成归档。"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import zipfile


def probe(engine: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="fastbudo-listing-") as directory:
        root = Path(directory)
        listings = []
        actual_names = []
        for index, name in enumerate(("a\nb", "a_b")):
            archive = root / f"{index}.zip"
            with zipfile.ZipFile(archive, "w") as stream:
                stream.writestr(zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0)), b"same")
            result = subprocess.run(
                [str(engine), "l", "-slt", "-ba", str(archive)],
                capture_output=True, check=True, timeout=30,
            )
            listings.append(result.stdout)
            output = root / str(index)
            subprocess.run(
                [str(engine), "x", str(archive), "-o" + str(output)],
                capture_output=True, check=True, timeout=30,
            )
            actual_names.append([item.name for item in output.iterdir()])
        assert actual_names == [["a\nb"], ["a_b"]], actual_names
        assert listings[0] == listings[1], "引擎行为已改变，请重新评估结构化枚举需求"
        print("已复现：两个不同的实际文件名具有完全相同的文本列表。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", type=Path)
    probe(parser.parse_args().engine.resolve(strict=True))
