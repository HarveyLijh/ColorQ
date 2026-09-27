package.path = "./src/?.lua;./src/?/init.lua;" .. package.path
local core = require("colorq.core")
local config = {palette = {"#123456", "#abcdef"}, chatRules = {}, projectRules = {}, chatProjects = {}}
local color = core.resolve(config, {chat = " A ", windowId = 1})
assert(color == core.resolve(config, {chat = "A", windowId = 2}))
assert(core.setRule(config, "project", "P", "#ff8800"))
assert(core.resolve(config, {chat = "A", project = "P"}) == "#ff8800")
assert(core.setRule(config, "chat", "A", "#00ff00"))
assert(core.resolve(config, {chat = "A", project = "P"}) == "#00ff00")
assert(core.clearRule(config, "chat", "A"))
assert(core.resolve(config, {chat = "A", project = "P"}) == "#ff8800")
config.chatProjects.A = "P"
assert(core.resolve(config, {chat = "A"}) == "#ff8800")
assert(core.setRule(config, "project", "Actual", "#334455"))
assert(core.resolve(config, {chat = "A", project = "Actual"}) == "#334455")
local _, pendingSource, pendingProject = core.resolve(config,
  {chat = "A", projectLookupStatus = "pending"})
assert(pendingSource == "auto" and pendingProject == nil)
local _, ambiguousSource, ambiguousProject = core.resolve(config,
  {chat = "A", projectLookupStatus = "ambiguous"})
assert(ambiguousSource == "auto" and ambiguousProject == nil)
config.chatProjects.A = "#ff8800"
local _, source, project = core.resolve(config, {chat = "A"})
assert(source == "auto" and project == nil)
assert(not core.setRule(config, "chat", "A", "green"))
assert(not core.clearRule(config, "chat", "missing"))
local band = {x = 0, y = 0, w = 100, h = 20}
local pieces = core.visibleRects(band, {{x = 30, y = -10, w = 40, h = 40}})
assert(#pieces == 2)
assert(pieces[1].x == 0 and pieces[1].w == 30)
assert(pieces[2].x == 70 and pieces[2].w == 30)
pieces = core.visibleRects(band, {
  {x = 30, y = -10, w = 40, h = 40}, {x = 0, y = 0, w = 20, h = 20}})
assert(#pieces == 2 and pieces[1].x == 20 and pieces[1].w == 10)
assert(pieces[2].x == 70 and pieces[2].w == 30)
assert(#core.visibleRects(band, {{x = 0, y = 0, w = 100, h = 20}}) == 0)
assert(#core.visibleRects(band, {{x = 100, y = 0, w = 40, h = 20}}) == 1)
print("core tests passed")
