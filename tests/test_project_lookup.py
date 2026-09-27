import json
import sqlite3
import tempfile
import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "colorq"))
from project_lookup import lookup


class ProjectLookupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.catalog = self.root / "catalog.sqlite"
        self.state = self.root / "state.json"
        with sqlite3.connect(self.catalog) as db:
            db.execute(
                "CREATE TABLE local_thread_catalog "
                "(thread_id TEXT, project_id TEXT, display_title TEXT, missing_candidate INTEGER)"
            )
            db.executemany(
                "INSERT INTO local_thread_catalog VALUES (?, ?, ?, ?)",
                [
                    ("thread-a", None, "Example chat", 0),
                    ("thread-b", None, "Duplicate", 0),
                    ("thread-c", None, "Duplicate", 0),
                    ("thread-d", None, "Shared project", 0),
                    ("thread-e", None, "Shared project", 0),
                    ("thread-f", None, "No project", 0),
                    ("thread-z", None, "Hidden", 1),
                ],
            )
        self.state.write_text(
            json.dumps(
                {
                    "thread-project-assignments": {
                        "thread-a": {"projectKind": "local", "projectId": "project-a"},
                        "thread-b": {"projectId": "project-a"},
                        "thread-c": {"projectId": "project-b"},
                        "thread-d": {"projectId": "project-a"},
                        "thread-e": {"projectId": "project-a"},
                    },
                    "local-projects": {
                        "project-a": {"id": "project-a", "name": "Demo project"},
                        "project-b": {"id": "project-b", "name": "another-project"},
                    },
                }
            ),
            encoding="utf-8",
        )

    def test_unique_title_resolves_actual_assignment(self):
        result = lookup("Example chat", self.catalog, self.state)
        self.assertEqual(result["project"], "Demo project")
        self.assertEqual(result["thread_id"], "thread-a")

    def test_title_collision_does_not_guess(self):
        self.assertEqual(lookup("Duplicate", self.catalog, self.state)["status"], "ambiguous")

    def test_same_title_same_project_is_safe_for_color_rule(self):
        result = lookup("Shared project", self.catalog, self.state)
        self.assertEqual(result["project"], "Demo project")
        self.assertNotIn("thread_id", result)

    def test_projectless_and_missing(self):
        self.assertEqual(lookup("No project", self.catalog, self.state)["status"], "projectless")
        self.assertEqual(lookup("Hidden", self.catalog, self.state)["status"], "missing")


if __name__ == "__main__":
    unittest.main()
