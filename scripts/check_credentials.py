#!/usr/bin/env python3
"""Fail if app Swift sources contain a key shape or a hard-coded bearer header."""

from pathlib import Path
import re
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
KEY_SHAPE = "nv" + "api-"
BEARER_HEADER = re.compile(r"Bearer[ \t]+[A-Za-z0-9][A-Za-z0-9._-]{8,}")


def find_issues(root: Path) -> list[str]:
    issues: list[str] = []
    for source in root.rglob("*.swift"):
        text = source.read_text(encoding="utf-8")
        if KEY_SHAPE in text:
            issues.append(f"Key shape in {source}")
        for line in text.splitlines():
            if "Authorization" in line and BEARER_HEADER.search(line):
                issues.append(f"Hard-coded bearer header in {source}")
    return sorted(issues)


class CredentialHygieneTests(unittest.TestCase):
    def test_scanner_catches_key_shape_and_literal_header(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            fixture = Path(folder) / "Bad.swift"
            fixture.write_text(
                f'let sample = "{KEY_SHAPE}example-only"\n'
                'let Authorization = "Bearer hardcoded-example-token"',
                encoding="utf-8",
            )
            self.assertEqual(len(find_issues(Path(folder))), 2)

    def test_app_sources_have_no_embedded_credentials(self) -> None:
        self.assertEqual(find_issues(ROOT / "FoldForm"), [])


if __name__ == "__main__":
    unittest.main()
