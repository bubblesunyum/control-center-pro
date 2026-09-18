#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise Codex generation and hook commands in disposable repositories."""

import contextlib
import importlib.util
import io
import json
import re
import shutil
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("codex_support", Path(__file__).with_name("codex-support.py"))
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


class CodexSupportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="codex harness ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / ".claude/agents/reviewer.md"
        self.source.parent.mkdir(parents=True)
        self.source.write_text('---\nname: reviewer\ndescription: Reviews "quoted" paths\n'
                               'model: sonnet\ntools: Read, Bash\n---\n\n'
                               'Read `CLAUDE.md`. Keep \\paths and "quotes" intact.\n')
        self.skill = self.root / ".claude/skills/workflow"
        self.skill.mkdir(parents=True)
        (self.skill / "SKILL.md").write_text("---\nname: workflow\ndescription: Shared procedure\n---\nRead me.\n")
        with contextlib.redirect_stdout(io.StringIO()):
            support.write(self.root)

    def verdict(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return support.check(self.root)

    def test_prompt_round_trips_without_claude_configuration(self):
        agent = tomllib.loads((self.root / ".codex/agents/reviewer.toml").read_text())
        self.assertEqual(set(agent), {"name", "description", "developer_instructions"})
        self.assertEqual(agent["description"], 'Reviews "quoted" paths')
        self.assertEqual(agent["developer_instructions"], self.source.read_text().split("---\n", 2)[2].lstrip("\n"))
        self.assertEqual(self.verdict(), 0)

    def test_regeneration_leaves_claude_sources_unchanged(self):
        before = {p: p.read_bytes() for p in (self.root / ".claude").rglob("*") if p.is_file()}
        with contextlib.redirect_stdout(io.StringIO()):
            support.write(self.root)
        after = {p: p.read_bytes() for p in (self.root / ".claude").rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_source_edits_fail_check_without_rewriting_generated_agent(self):
        target = self.root / ".codex/agents/reviewer.toml"
        before = target.read_bytes()
        self.source.write_text(self.source.read_text() + "New rule.\n")
        self.assertEqual(self.verdict(), 1)
        self.assertEqual(target.read_bytes(), before)

    def test_skill_edit_is_shared_and_broken_link_fails(self):
        link = self.root / ".agents/skills/workflow"
        self.assertFalse(Path(link.readlink()).is_absolute())
        (self.skill / "SKILL.md").write_text("Updated shared procedure")
        self.assertEqual((link / "SKILL.md").read_text(), "Updated shared procedure")
        link.unlink()
        link.symlink_to("missing")
        self.assertEqual(self.verdict(), 1)

    def test_writer_preserves_copied_skills(self):
        link = self.root / ".agents/skills/workflow"
        link.unlink()
        link.mkdir()
        (link / "SKILL.md").write_text("Local work")
        with self.assertRaisesRegex(ValueError, "reconcile"):
            support.write(self.root)
        self.assertEqual((link / "SKILL.md").read_text(), "Local work")

    def test_renamed_skill_does_not_leave_a_broken_discovery_link(self):
        self.skill.rename(self.skill.with_name("renamed"))
        self.assertEqual(self.verdict(), 1)
        with contextlib.redirect_stdout(io.StringIO()):
            support.write(self.root)
        self.assertFalse((self.root / ".agents/skills/workflow").is_symlink())
        self.assertTrue((self.root / ".agents/skills/renamed/SKILL.md").is_file())

    def test_renamed_agent_is_removed_but_personal_agent_is_preserved(self):
        self.source.rename(self.source.with_name("renamed.md"))
        personal = self.root / ".codex/agents/personal.toml"
        personal.write_text('name = "personal"\n')
        self.assertEqual(self.verdict(), 1)
        with contextlib.redirect_stdout(io.StringIO()):
            support.write(self.root)
        self.assertFalse((self.root / ".codex/agents/reviewer.toml").exists())
        self.assertTrue(personal.exists())

    def test_stock_beads_hook_reintroduction_fails(self):
        path = self.root / ".codex/hooks.json"
        path.write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [
            {"type": "command", "command": "bd codex-hook SessionStart"}
        ]}]}}))
        self.assertEqual(self.verdict(), 1)

    def test_hooks_run_from_nested_directory_with_spaces(self):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / "brief.sh").write_text('test "$1" = --hook || exit 2\n'
            "echo '{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"fixture brief\"}}'\n")
        (scripts / "dashboard.py").write_text("import sys\nprint('dashboard ' + sys.argv[1])\n")
        nested = self.root / "nested folder"
        nested.mkdir()
        config = json.loads((self.root / ".codex/hooks.json").read_text())["hooks"]
        for source in ("startup", "resume", "clear", "compact"):
            outputs = []
            for group in config["SessionStart"]:
                if re.search(group["matcher"], source):
                    for hook in group["hooks"]:
                        outputs.append(subprocess.check_output(hook["command"], shell=True, cwd=nested, text=True).strip())
            self.assertEqual(json.loads(outputs[0])["hookSpecificOutput"]["additionalContext"], "fixture brief")
            self.assertEqual(outputs[1:], [] if source == "compact" else ["dashboard up"])
        end = config["SessionEnd"][0]["hooks"][0]
        self.assertEqual(subprocess.check_output(end["command"], shell=True, cwd=nested, text=True).strip(), "dashboard down")

    def test_staged_review_includes_codex_files_and_excludes_other_work(self):
        def git(*args):
            subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

        git("init", "-q")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "--allow-empty", "-qm", "fixture")
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy(Path(__file__).with_name("review.sh"), scripts / "review.sh")
        metadata = self.skill / "agents/openai.yaml"
        metadata.parent.mkdir()
        metadata.write_text("interface:\n  display_name: Workflow\n")
        git("add", ".codex", ".agents", ".claude")
        (self.root / "unrelated.swift").write_text("UNRELATED_WORK")
        output = subprocess.check_output(["bash", str(scripts / "review.sh"), "--staged"], cwd=self.root, text=True)
        packet = Path(output.split(" (", 1)[0])
        self.addCleanup(packet.unlink, missing_ok=True)
        second = subprocess.check_output(["bash", str(scripts / "review.sh"), "--staged"], cwd=self.root, text=True)
        second_packet = Path(second.split(" (", 1)[0])
        self.addCleanup(second_packet.unlink, missing_ok=True)
        self.assertNotEqual(packet, second_packet)
        content = packet.read_text()
        self.assertIn(".codex/agents/reviewer.toml", content)
        self.assertIn(".claude/skills/workflow/agents/openai.yaml", content)
        self.assertIn(".agents/skills/workflow", content)
        self.assertNotIn("UNRELATED_WORK", content)


if __name__ == "__main__":
    unittest.main()
