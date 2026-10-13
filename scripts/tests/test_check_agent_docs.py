"""Exercise the documentation gate against complete and broken mini repositories."""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CHECKER = Path(__file__).resolve().parents[1] / "check-agent-docs.py"


class AgentDocsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for relative in (
            "AGENTS.md", "README.md", ".agents/README.md", ".agents/notes/README.md",
            "docs/development.md", "docs/testing.md",
        ):
            self.write(relative, "# Guide\n\n[Development](" + (
                "development.md" if relative.startswith("docs/") else
                "../../docs/development.md" if relative.startswith(".agents/notes/") else
                "../docs/development.md" if relative.startswith(".agents/") else
                "docs/development.md"
            ) + ")\n")
        for name in ("piclight-development", "piclight-verification", "piclight-review"):
            self.write(f".agents/skills/{name}/SKILL.md",
                       f"---\nname: {name}\ndescription: Use when working on PicLight.\n---\n\n# Skill\n")

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_gate(self):
        return subprocess.run([sys.executable, str(CHECKER), "--root", str(self.root)],
                              capture_output=True, text=True, timeout=10)

    def test_complete_navigation_and_skills_pass(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_local_link_blocks_the_gate(self):
        self.write("docs/testing.md", "# Tests\n\n[Missing](missing.md)\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("missing.md", result.stdout)

    def test_empty_skill_description_blocks_discovery(self):
        self.write(".agents/skills/piclight-review/SKILL.md",
                   "---\nname: piclight-review\ndescription:\n---\n\n# Review\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("description", result.stdout)

    def test_skill_name_must_match_its_directory(self):
        self.write(".agents/skills/piclight-review/SKILL.md",
                   "---\nname: another-skill\ndescription: Use when reviewing.\n---\n\n# Review\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("another-skill", result.stdout)

    def test_proposal_cannot_be_marked_implemented_by_its_path(self):
        self.write(".agents/notes/implemented/2026-10-12-example.md",
                   "# Decision\n\nStatus: proposed\n\n## Problem\n\nAn unresolved choice.\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Status", result.stdout)

    def test_examples_and_remote_links_are_not_local_navigation(self):
        self.write("docs/testing.md", "# Tests\n\n```markdown\n[Example](missing.md)\n```\n\n"
                   "`[Inline example](missing.md)`\n\n[External](https://example.com/missing.md)\n")
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
