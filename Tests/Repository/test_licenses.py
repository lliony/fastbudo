import tarfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class LicenseTests(unittest.TestCase):
    def test_lgpl_text_matches_pinned_upstream(self):
        with tarfile.open(ROOT / 'Vendor/7zip/7z2604-src.tar.xz') as archive:
            self.assertEqual((ROOT / 'Vendor/7zip/COPYING.txt').read_bytes(),
                             archive.extractfile('DOC/copying.txt').read())

    def test_application_embeds_distribution_notices(self):
        config = (ROOT / 'project.yml').read_text()
        project = (ROOT / 'FastBudo.xcodeproj/project.pbxproj').read_text()
        for path in ['LICENSE', 'THIRD-PARTY-NOTICES.md',
                     'Vendor/7zip/LICENSE.txt', 'Vendor/7zip/COPYING.txt']:
            with self.subTest(path=path):
                self.assertIn('- path: ' + path + '\n        buildPhase: resources', config)
                self.assertIn(Path(path).name + ' in Resources', project)
