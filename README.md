# ColorQ

### Find the right Codex window at a glance.

ColorQ gives each **Codex Desktop window** a color cue that follows its active chat or project. When several tasks are open, the colors make switching between them a little easier on your eyes and your attention.

![Four Codex windows, each with a different colored top and left edge](docs/images/four-windows-demo.png)

<sub>Illustrative screenshot. Conversation content has been replaced with placeholders.</sub>

**Made for macOS.** ColorQ runs alongside Codex through [Hammerspoon](https://www.hammerspoon.org/). It does not change or inject code into the Codex app. The default color sits **inside the top and left edges** of each window, with rounded corners and an optional soft fade.

## What you can do

| | |
| --- | --- |
| **Color a chat** | Give one chat title a persistent color. |
| **Color a project** | Give chats in the same Codex project a shared color. |
| **Let ColorQ choose** | Unassigned chats get a stable automatic color. Your chat rule takes priority over a project rule. |
| **Tune the look** | Adjust line thickness, inward fade, and opacity from a small palette. |

The cue updates when the window changes chats. It follows window movement and resizing, and respects other windows covering it.

## Install

You'll need **Hammerspoon**, **Python 3 with `sqlite3`**, and macOS Accessibility permission for Hammerspoon. If you use Homebrew:

```sh
brew install --cask hammerspoon
brew install python
```

Then install ColorQ:

```sh
git clone https://github.com/HarveyLijh/ColorQ.git
cd ColorQ
./install.sh
```

Open Hammerspoon, grant its **Accessibility** permission in macOS Settings, then choose **Reload Config** from the Hammerspoon menu. You do not need to change any Codex setting. The installer copies ColorQ to `~/.hammerspoon/colorq/`, adds its startup line to `~/.hammerspoon/init.lua`, and backs up an existing `init.lua` before editing it. Existing ColorQ settings are preserved. [Hammerspoon setup guide](https://www.hammerspoon.org/go/)

## Pick a color

1. Move your pointer to the **middle of a Codex window's title bar** and click the small palette icon.
2. Choose **This chat** or **Project**, then click a color.
3. Adjust **Thickness**, **Inner fade**, and **Line opacity** in the same panel. Changes preview and save immediately.

Press **Esc** to close the panel without choosing anything. You can also click **×**, click outside, or click the icon again.

![ColorQ palette with example chat and project names, color swatches, and appearance controls](docs/images/color-panel-demo.png)

<sub>Illustrative palette screenshot with example names.</sub>

| Shortcut | Action |
| --- | --- |
| `⌥⌘C` | Open the palette for this chat |
| `⌥⌘P` | Open the palette for this project |
| `⌥⌘0` | Clear this chat's color rule |

The Hammerspoon menu-bar **🎨** menu also offers these actions, project assignment, and a link to the config file.

## Make it yours

Open `~/.hammerspoon/colorq/config.json`, edit it, then choose **Reload config.json** from the **🎨** menu. Start with the included [`config.example.json`](config.example.json).

| Setting | What it changes |
| --- | --- |
| `thickness`, `fadeWidth`, `lineOpacity` | Width and softness of the inside edge |
| `palette` | Automatic colors and the visible swatches |
| `chatRules` | Exact chat title → color |
| `projectRules` | Exact Codex project name → color |
| `chatProjects` | Manual project fallback if Codex's assignment cannot be found |
| `renderer` | `inside` (default), `canvas` (top strip), or `borders` (outside border) |

Colors use `#RRGGBB` or `#RGB`. The palette shows the first eight valid colors in `palette`. If you prefer an outside border, install [JankyBorders](https://github.com/FelixKratz/JankyBorders) and choose **Outside** in the ColorQ palette. The default inside mode needs only Hammerspoon.

For example, these two entries would make one chat blue and one project purple:

```json
{
  "chatRules": { "Example chat": "#61AFEF" },
  "projectRules": { "Demo project": "#BE8CFF" }
}
```

Keep the rest of the JSON file in place when editing. `thickness` accepts 1–12 pt, `fadeWidth` accepts 0–32 pt, and `lineOpacity` accepts 0–100%.

## How project colors work

ColorQ reads the active chat title through macOS Accessibility and checks **local Codex metadata** for its project. This lookup is read-only. Color rules are stored locally in `config.json`; ColorQ does not send chat data to a service or read message bodies for coloring.

Rules are keyed by **title**, so chats with the same title share a chat color. If two projects contain chats with the same title, ColorQ leaves the project unresolved rather than guessing. When project lookup is unavailable, you can set a manual project fallback. A new chat with no readable title can be given a temporary window label from the menu. Codex's Accessibility tree and local metadata may change in future releases; chat-title coloring remains available if project lookup stops working.

To turn ColorQ off, remove or comment out `require("colorq").start()` in `~/.hammerspoon/init.lua` and reload Hammerspoon. Your settings remain in `~/.hammerspoon/colorq/config.json`.
