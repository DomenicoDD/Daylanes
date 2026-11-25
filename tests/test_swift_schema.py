"""The Swift engine (core/Schema.swift) must create exactly the schema the Python engine does."""
import re
import unittest
from pathlib import Path

from tracker import store

SWIFT = (Path(__file__).resolve().parent.parent / "core" / "Schema.swift").read_text(encoding="utf-8")


def swift_string(name):
    match = re.search(rf'static let {name} = """\n(.*?)\n"""', SWIFT, re.S)
    assert match, name
    return match.group(1)


class SwiftSchemaTest(unittest.TestCase):
    def test_schema_text_matches(self):
        self.assertEqual(swift_string("tables"), store.SCHEMA.strip("\n"))
        self.assertEqual(swift_string("focusRules"), store.FOCUS_RULES_SCHEMA.strip("\n"))

    def test_entry_columns_match(self):
        fields = re.search(r"static let entryFields = \[(.*?)\]", SWIFT).group(1)
        self.assertEqual(tuple(re.findall(r'"(\w+)"', fields)), store.ENTRY_FIELDS)
        columns = dict(re.findall(r'\("(\w+)", "([^"]+)"\)', SWIFT))
        self.assertEqual(columns, store.ENTRY_COLUMNS)
        self.assertIn(f'selfClientDefault = "{store.SELF_CLIENT_DEFAULT}"', SWIFT)


if __name__ == "__main__":
    unittest.main()
