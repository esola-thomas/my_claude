"""Unit tests for libexec/sync_models.py using a fixture catalog."""
import importlib.util
import json
import pathlib
import unittest

root = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("sync_models", root / "libexec" / "sync_models.py")
sm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sm)
catalog = json.loads((root / "tests" / "fixtures" / "catalog.json").read_text())["data"]


class SyncTests(unittest.TestCase):
    def test_picks_newest_enabled(self):
        sel = sm.select_models(catalog)
        self.assertEqual(sel["opus_latest"]["id"], "claude-opus-5.5")
        self.assertEqual(sel["sonnet_latest"]["id"], "claude-sonnet-5.5")

    def test_disabled_model_is_ignored(self):
        sel = sm.select_models(catalog)
        self.assertNotEqual(sel["opus_latest"]["id"], "claude-opus-9")

    def test_fast_variants_excluded(self):
        sel = sm.select_models(catalog)
        self.assertNotIn("gpt_sol_latest", sel)

    def test_gpt_families_are_optional(self):
        sel = sm.select_models(catalog)
        self.assertIn("gpt_luna_latest", sel)
        self.assertNotIn("gpt_astra_latest", sel)

    def test_missing_required_family_raises(self):
        only_opus = [m for m in catalog if m["id"].startswith("claude-opus")]
        with self.assertRaises(RuntimeError):
            sm.select_models(only_opus)

    def test_one_million_context_gets_profile_suffix(self):
        sel = sm.select_models(catalog)
        self.assertEqual(sm.claude_context_profile(sel["opus_latest"]), "claude-opus-5.5[1m]")
        self.assertEqual(sm.claude_context_profile(sel["haiku_latest"]), "claude-haiku-5.5")

    def test_config_has_no_secret_and_skips_missing_fallbacks(self):
        cfg = sm.render_managed_config(sm.select_models(catalog))
        self.assertIn("os.environ/MY_CLAUDE_KEY", cfg)
        self.assertNotIn("gpt-astra-latest", cfg)
        self.assertIn("claude-opus-primary:", cfg)

    def test_generated_text_is_ascii(self):
        sel = sm.select_models(catalog)
        text = sm.render_managed_config(sel) + json.dumps(sm.build_settings(sel))
        text.encode("ascii")

    def test_primary_override(self):
        sm.PREFERRED_PRIMARY = "claude-opus-5.0"
        try:
            sel = sm.select_models(catalog)
            self.assertEqual(sel["opus_primary"]["id"], "claude-opus-5.0")
            self.assertEqual(sel["opus_latest"]["id"], "claude-opus-5.5")
        finally:
            sm.PREFERRED_PRIMARY = ""


if __name__ == "__main__":
    unittest.main()
