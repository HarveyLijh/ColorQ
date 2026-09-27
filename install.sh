#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install_home=${COLORQ_INSTALL_HOME:-$HOME}
destination="$install_home/.hammerspoon/colorq"
init_file="$install_home/.hammerspoon/init.lua"

if [ ! -d /Applications/Hammerspoon.app ] &&
   [ ! -d "$install_home/Applications/Hammerspoon.app" ]; then
  echo "Install Hammerspoon in Applications first, then rerun this script." >&2
  exit 1
fi

python_bin=""
for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 "$(command -v python3 || true)"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ] &&
     "$candidate" -c 'import json, sqlite3' >/dev/null 2>&1; then
    python_bin=$candidate
    break
  fi
done
if [ -z "$python_bin" ]; then
  echo "Python 3 with sqlite3 is required for Codex project detection." >&2
  echo "Install Python 3, then rerun this script." >&2
  exit 1
fi

if [ -f "$init_file" ] && grep -Fq 'require("chatgpt-window-colors")' "$init_file"; then
  echo "An older ChatGPT window color module is active in $init_file." >&2
  echo "Disable that require line before installing ColorQ to avoid duplicate overlays." >&2
  exit 1
fi

mkdir -p "$destination"
install -m 644 "$project_dir/src/colorq/init.lua" "$destination/init.lua"
install -m 644 "$project_dir/src/colorq/core.lua" "$destination/core.lua"
install -m 644 "$project_dir/src/colorq/project_lookup.py" "$destination/project_lookup.py"
if [ ! -f "$destination/config.json" ]; then
  install -m 644 "$project_dir/config.example.json" "$destination/config.json"
fi
"$python_bin" - "$python_bin" "$destination/runtime.json" <<'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[2]).write_text(json.dumps({"pythonPath": sys.argv[1]}) + "\n")
PY

if [ ! -f "$init_file" ]; then
  printf 'require("colorq").start()\n' > "$init_file"
elif ! grep -Fq 'require("colorq")' "$init_file"; then
  cp -p "$init_file" "$init_file.colorq-backup-$(date +%Y%m%d%H%M%S)"
  printf '\n-- ColorQ\nrequire("colorq").start()\n' >> "$init_file"
fi

echo "ColorQ installed to $destination"
echo "Existing config.json was preserved if present."
echo "Open Hammerspoon and choose Reload Config. Grant Accessibility permission when macOS asks."
