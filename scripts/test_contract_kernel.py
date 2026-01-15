#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR))

from contract_kernel_lib import parse_contract_version, parse_validation_rules  # noqa: E402


class TestContractKernelParser(unittest.TestCase):
    def test_parse_contract_version(self) -> None:
        text = "# **Version: 4.9**\nOther\n"
        self.assertEqual(parse_contract_version(text), "4.9")

    def test_gate_id_block_parsing(self) -> None:
        rules_text = "\n".join(
            [
                "## VR-123: Example Rule",
                "**Contract ref:** CONTRACT.md §1.0",
                "**Rule:** Example rule text.",
                "**Gate ID:**",
                "- VR-123a",
                "- VR-123b",
            ]
        )
        rules = parse_validation_rules(rules_text, "<memory>")
        self.assertEqual(len(rules), 1)
        self.assertEqual(rules[0]["gate_ids"], ["VR-123a", "VR-123b"])
        self.assertEqual(rules[0]["fields"], {})

    def test_inline_gate_ids_and_fields(self) -> None:
        rules_text = "\n".join(
            [
                "## VR-124: Rich Rule",
                "**Contract ref:** CONTRACT.md §1.1",
                "**Rule:** Another rule text.",
                "**Gate ID:** VR-124a, VR-124b",
                "**Owner:** Risk",
                "**Evidence:** log:example",
            ]
        )
        rules = parse_validation_rules(rules_text, "<memory>")
        self.assertEqual(rules[0]["gate_ids"], ["VR-124a", "VR-124b"])
        self.assertEqual(
            rules[0]["fields"],
            {"owner": ["Risk"], "evidence": ["log:example"]},
        )

    def test_invalid_gate_id_fails(self) -> None:
        rules_text = "\n".join(
            [
                "## VR-125: Bad Gate",
                "**Contract ref:** CONTRACT.md §1.2",
                "**Rule:** Example rule text.",
                "**Gate ID:** NOT_A_GATE",
            ]
        )
        stderr = sys.stderr
        try:
            sys.stderr = open("/dev/null", "w", encoding="utf-8")
            with self.assertRaises(SystemExit):
                parse_validation_rules(rules_text, "<memory>")
        finally:
            sys.stderr.close()
            sys.stderr = stderr


if __name__ == "__main__":
    unittest.main()
