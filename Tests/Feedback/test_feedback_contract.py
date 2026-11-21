"""Static checks for GitHub feedback links and issue forms (requires PyYAML)."""
import re
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import yaml

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = ROOT / "VoicePolishApp/Views/SettingsView.swift"
TEMPLATES = ROOT / ".github/ISSUE_TEMPLATE"


class FeedbackContractTests(unittest.TestCase):
    def test_links_match_forms_and_never_prefill_content(self):
        view = SETTINGS.read_text().split("private struct FeedbackView:", 1)[1]
        links = {
            name: urlparse(url) for name, url in re.findall(
                r'let (\w+URL) = URL\(string: "([^"]+)"\)', view
            )
        }
        self.assertEqual(set(links), {"issuesURL", "bugURL", "suggestionURL"})
        for url in links.values():
            self.assertEqual((url.scheme, url.netloc), ("https", "github.com"))
            self.assertTrue(url.path.startswith("/evan188199-tech/voice-polish-keyboard/issues"))
            self.assertFalse(url.fragment)
        self.assertEqual(links["issuesURL"].path, "/evan188199-tech/voice-polish-keyboard/issues")
        self.assertFalse(links["issuesURL"].query)
        expected = {"bugURL": "bug-report.yml", "suggestionURL": "feature-request.yml"}
        for name, filename in expected.items():
            self.assertTrue(links[name].path.endswith("/issues/new"))
            self.assertEqual(parse_qs(links[name].query), {"template": [filename]})
            self.assertTrue((TEMPLATES / filename).is_file())

    def test_form_fields_and_public_notice(self):
        for path in sorted(TEMPLATES.glob("*.yml")):
            with self.subTest(path=path.name):
                data = yaml.safe_load(path.read_text())
                self.assertTrue(data["name"] and data["description"] and data["title"])
                self.assertIsInstance(data["body"], list)
                self.assertEqual(data["body"][0]["type"], "markdown")
                self.assertIn("公开", data["body"][0]["attributes"]["value"])
                ids = [item["id"] for item in data["body"] if "id" in item]
                self.assertEqual(len(ids), len(set(ids)))
                for item in data["body"]:
                    if item["type"] != "markdown":
                        self.assertTrue(item["attributes"]["label"])
                    if item["type"] == "dropdown":
                        options = item["attributes"]["options"]
                        self.assertEqual(len(options), len(set(options)))
                self.assertGreaterEqual(sum(
                    item.get("validations", {}).get("required", False) for item in data["body"]
                ), 2)
