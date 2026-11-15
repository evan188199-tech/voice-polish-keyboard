"""Source-level regression: held results need a visible voice-page action.

This does not replace SwiftUI, accessibility, ordering, or device tests.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class VoiceRecoveryContract(unittest.TestCase):
    def test_held_result_has_direct_voice_page_action(self):
        source = (ROOT / "Keyboard/KeyboardView.swift").read_text()
        voice = source.split("private var voiceContent:", 1)[1].split(
            "private var privateReferenceContent", 1
        )[0]
        self.assertIn("model.heldResult", voice, "The voice page must expose held-result state")
        self.assertIn("model.insertHeldResult(recoveryID:", voice, "The voice page must offer a direct recovery action")
        self.assertIn("插入当前输入框", voice, "The action must identify the current input field")


if __name__ == "__main__":
    unittest.main()
