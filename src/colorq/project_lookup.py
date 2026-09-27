"""Read a Codex chat's assigned local project without using the app UI."""

import json
import sqlite3
import sys
from pathlib import Path


def lookup(title, catalog_path, state_path):
    with sqlite3.connect(Path(catalog_path).resolve().as_uri() + "?mode=ro", uri=True) as db:
        rows = db.execute(
            "SELECT thread_id, project_id FROM local_thread_catalog "
            "WHERE display_title = ? AND missing_candidate = 0",
            (title,),
        ).fetchall()
    if not rows:
        return {"status": "missing"}

    with open(state_path, encoding="utf-8") as source:
        state = json.load(source)
    assignments = state.get("thread-project-assignments") or {}
    project_records = state.get("local-projects") or {}
    if isinstance(project_records, dict):
        project_records = project_records.values()
    projects = {
        project["id"]: project["name"]
        for project in project_records
        if isinstance(project, dict) and project.get("id") and project.get("name")
    }
    candidates = []
    for thread_id, catalog_project_id in rows:
        assignment = assignments.get(thread_id) or {}
        project_id = assignment.get("projectId") or catalog_project_id
        candidates.append((thread_id, project_id, projects.get(project_id)))

    names = {name for _, _, name in candidates}
    if len(names) != 1:
        return {"status": "ambiguous", "matches": len(candidates)}
    project = next(iter(names))
    if project is None:
        return {"status": "projectless", "matches": len(candidates)}
    result = {"status": "ok", "project": project, "matches": len(candidates)}
    if len(candidates) == 1:
        result["thread_id"] = candidates[0][0]
        result["project_id"] = candidates[0][1]
    return result


if __name__ == "__main__":
    home = Path.home()
    try:
        result = lookup(
            sys.argv[1],
            home / ".codex/sqlite/codex-dev.db",
            home / ".codex/.codex-global-state.json",
        )
    except (IndexError, OSError, ValueError, sqlite3.Error):
        result = {"status": "unavailable"}
    print(json.dumps(result, ensure_ascii=False))
