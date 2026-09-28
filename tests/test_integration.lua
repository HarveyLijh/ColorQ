package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local state = {title = "Chat A", frame = {x = 10, y = 20, w = 600, h = 300},
  windows = {}, front = true, space = 1, mouse = {x = 0, y = 0},
  created = {}, deleted = 0, timers = {}, timerObjects = {}, timerIntervals = {}, taps = {}, tasks = {}, now = 0,
  lookupEnabled = false, config = {renderer = "canvas",
  palette = {"#112233", "#445566"}, chatRules = {['Chat B'] = "#abcdef"},
  projectRules = {}, chatProjects = {}}, promptAnswer = "Manual Chat"}
local app = {bundleID = function() return "com.openai.codex" end,
             pid = function() return 17 end,
             allWindows = function() return state.windows end}
local window = {
  id = function() return 99 end,
  title = function() return "ChatGPT" end,
  role = function() return "AXWindow" end,
  isStandard = function() return true end,
  application = function() return app end,
  isVisible = function() return true end,
  isMinimized = function() return false end,
  frame = function() return state.frame end,
  screen = function() return {} end,
}
local windowB = {
  id = function() return 100 end,
  title = function() return "ChatGPT" end,
  role = function() return "AXWindow" end,
  isStandard = function() return true end,
  application = function() return app end,
  isVisible = function() return true end,
  isMinimized = function() return false end,
  frame = function() return state.frameB end,
  screen = function() return {} end,
}
local otherWindow = {
  id = function() return 101 end,
  application = function() return {bundleID = function() return "other" end} end,
  isStandard = function() return true end,
  frame = function() return {x = 0, y = 0, w = 200, h = 200} end,
}
local transparentPopover = {
  id = function() return 102 end,
  application = function() return app end,
  isStandard = function() return false end,
  frame = function() return {x = 400, y = 125, w = 200, h = 80} end,
}
local otherDialog = {
  id = function() return 103 end,
  application = function() return {bundleID = function() return "other" end} end,
  isStandard = function() return false end,
  frame = function() return {x = 400, y = 125, w = 200, h = 80} end,
}
state.windows = {window}

local function canvas(frame)
  local result = {currentFrame = frame, visible = false}
  function result:level() return self end
  function result:behaviorAsLabels() return self end
  function result:frame(nextFrame) self.currentFrame = nextFrame; return self end
  function result:show() self.visible = true; return self end
  function result:hide() self.visible = false; return self end
  function result:delete() state.deleted = state.deleted + 1 end
  function result:clickActivating() return self end
  function result:mouseCallback(callback) self.mouseHandler = callback; return self end
  function result:replaceElements(...)
    for index = 1, #self do self[index] = nil end
    self.elements = {...}
    for index, item in ipairs(self.elements) do self[index] = item end
    return self
  end
  function result:imageFromCanvas() return {color = self[1].fillColor.hex} end
  state.created[#state.created + 1] = result
  return result
end

_G.hs = {
  json = {read = function() return state.config end, encode = function() return "{}" end,
    decode = function() return state.lookupResult end},
  fs = {attributes = function(path)
    if path and path:match("project_lookup%.py$") then return state.lookupEnabled end
    return true
  end},
  application = {get = function() return app end,
    frontmostApplication = function() return state.front and app or
      {pid = function() return 18 end,
       bundleID = function() return state.frontBundle or "other" end} end},
  window = {focusedWindow = function()
    if state.useNoFocus then return nil end
    return state.focused or window
  end, get = function(id) return id == 100 and windowB or window end,
    orderedWindows = function() return state.orderedWindows or {window} end},
  axuielement = {windowElement = function()
    state.axReads = (state.axReads or 0) + 1
    if state.axRoot then return state.axRoot end
    local title = state.title
    local header = {attributeValue = function(_, name)
      if name == "AXRole" then return "AXButton" end
      if name == "AXTitle" then return title end
      if name == "AXPosition" then return {x = state.frame.x + 280, y = state.frame.y + 12} end
      if name == "AXSize" then return {w = 230, h = 27} end
      return nil
    end}
    return {attributeValue = function(_, name)
      if name == "AXChildren" and title ~= "ChatGPT" then return {header} end
      return nil
    end}
  end},
  spaces = {focusedSpace = function() return state.space end,
    activeSpaceOnScreen = function() return state.space end,
    windowSpaces = function() return {1} end,
    watcher = {new = function(callback)
      state.spaceCallback = callback
      return {start = function(self) return self end, stop = function() end}
    end}},
  canvas = {new = canvas},
  timer = {secondsSinceEpoch = function() return state.now end,
    doAfter = function(_, callback)
      state.delayed = state.delayed or {}
      state.delayed[#state.delayed + 1] = callback
      return {stop = function() end}
    end,
    doEvery = function(interval, callback)
    state.timers[#state.timers + 1] = callback
    state.timerIntervals[#state.timerIntervals + 1] = interval
    local result = {stop = function(self) self.active = false end,
      callback = callback, active = true}
    state.timerObjects[#state.timerObjects + 1] = result
    return result
  end},
  execute = function() return "", state.bordersRunning or false end,
  task = {new = function(_, callback, arguments)
    local result = {callback = callback, arguments = arguments, terminated = false}
    function result:start()
      state.tasks[#state.tasks + 1] = self
      if arguments[1] == "whitelist=ChatGPT" then state.bordersRunning = true end
      return true
    end
    function result:terminate() self.terminated = true end
    return result
  end},
  menubar = {new = function()
    local result = {}
    function result:setTitle() end
    function result:setMenu(value) self.items = type(value) == "function" and value() or value; state.menu = self end
    function result:delete() end
    return result
  end},
  hotkey = {bind = function(modifiers, key, callback)
    state.hotkeys = state.hotkeys or {}; state.hotkeys[key] = callback
    return {delete = function() end}
  end},
  dialog = {textPrompt = function(title, message, default, accept)
    state.lastPrompt = {title = title, message = message, default = default, accept = accept}
    local answer = state.promptAnswer
    if type(answer) == "table" then answer = table.remove(state.promptAnswer, 1) end
    return accept, answer
  end},
  alert = {show = function() end},
  mouse = {absolutePosition = function() return state.mouse end},
  keycodes = {map = {escape = 53}},
  eventtap = {event = {types = {keyDown = "keyDown", leftMouseDown = "leftMouseDown",
    leftMouseDragged = "leftMouseDragged", leftMouseUp = "leftMouseUp"}},
    new = function(events, callback)
      local result = {events = events, callback = callback, active = false}
      function result:start() self.active = true; return self end
      function result:stop() self.active = false; return self end
      state.taps[#state.taps + 1] = result
      return result
    end},
  chooser = {new = function(callback)
    local result = {callback = callback}
    function result:choices(values) self.items = values; return self end
    function result:placeholderText() return self end
    function result:show() state.chooser = self; return self end
    return result
  end},
}

local module = require("colorq")
local function element(canvasObject, id)
  for _, item in ipairs(canvasObject.elements or {}) do
    if item.id == id then return item end
  end
end
module.start()
assert(module.contextFor(window).chat == "Chat A")
assert(#state.created == 2)
local helperWindow = {
  id = function() return 100 end, title = function() return "Computer Use" end,
  role = function() return "AXWindow" end, application = function() return app end,
}
state.windows = {window, helperWindow}
module.refresh()
assert(#state.created == 2)
state.windows = {window}
local tab, strip = state.created[1], state.created[2]
assert(not tab.visible)
assert(strip.visible)
assert(strip.currentFrame.x == 16)
state.mouse = {x = 40, y = 30}
state.timers[2]()
assert(tab.visible)
assert(tab.currentFrame.x == 286)
assert(tab.currentFrame.y == 28)
assert(tab.elements[2].fillColor.hex == strip[1].fillColor.hex)
state.mouse = {x = 210, y = 130}
state.timers[2]()
assert(not tab.visible)
state.mouse = {x = 210, y = 30}
state.timers[2]()
assert(tab.visible)
tab.mouseHandler(tab, "mouseUp")
assert(#state.created == 3)
local panel = state.created[3]
assert(panel.visible)
assert(state.config.fadeWidth == 12 and state.config.lineOpacity == 100)
assert(element(panel, "close") and element(panel, "scope:chat"))
assert(element(panel, "color:1") and element(panel, "thickness:plus"))
assert(element(panel, "fade:plus") and element(panel, "opacity:minus"))
panel.mouseHandler(panel, "mouseUp", "close")
assert(not panel.visible)
assert(next(state.config.chatRules) ~= nil) -- Closing makes no changes.
tab.mouseHandler(tab, "mouseUp")
assert(panel.visible)
assert(state.taps[#state.taps].active)
state.taps[#state.taps].callback({getType = function() return "keyDown" end,
  getKeyCode = function() return 53 end})
assert(not panel.visible)
assert(not state.taps[#state.taps].active)
tab.mouseHandler(tab, "mouseUp")
assert(panel.visible)
state.taps[#state.taps].callback({getType = function() return "leftMouseDown" end,
  location = function() return {x = 800, y = 700} end})
assert(not panel.visible)
tab.mouseHandler(tab, "mouseUp")
assert(panel.visible)
tab.mouseHandler(tab, "mouseUp")
assert(not panel.visible)
state.mouse = {x = 800, y = 700}
state.timers[2]()
assert(not tab.visible)
local firstColor = strip[1].fillColor.hex
state.title = "Chat B"
module.refresh()
assert(strip[1].fillColor.hex == "#abcdef")
assert(tab.elements[2].fillColor.hex == "#abcdef")
assert(firstColor ~= "#abcdef")
state.frame = {x = 50, y = 40, w = 600, h = 500}
module.refresh()
assert(strip.currentFrame.x == 56)
assert(strip.currentFrame.w == 588)
assert(tab.currentFrame.x == 326)
state.promptAnswer = "7"
tab.mouseHandler(tab, "mouseUp")
panel.mouseHandler(panel, "mouseUp", "thickness:plus")
panel.mouseHandler(panel, "mouseUp", "thickness:plus")
panel.mouseHandler(panel, "mouseUp", "thickness:plus")
assert(state.config.thickness == 7)
assert(strip.currentFrame.h == 7)
state.front = false
state.frontBundle = "org.hammerspoon.Hammerspoon"
panel.mouseHandler(panel, "mouseUp", "fade:plus")
assert(panel.visible)
state.front = true
panel.mouseHandler(panel, "mouseUp", "opacity:minus")
panel.mouseHandler(panel, "mouseUp", "opacity:minus")
assert(state.config.fadeWidth == 14 and state.config.lineOpacity == 80)
state.promptAnswer = "Lab UI"
panel.mouseHandler(panel, "mouseUp", "scope:project")
assert(element(panel, "scope:project"))
panel.mouseHandler(panel, "mouseUp", "color:2")
assert(state.config.projectRules["Lab UI"] == "#445566")
assert(state.config.chatProjects["Chat B"] == "Lab UI")
tab.mouseHandler(tab, "mouseUp")
panel.mouseHandler(panel, "mouseUp", "scope:project")
panel.mouseHandler(panel, "mouseUp", "clear")
assert(state.config.projectRules["Lab UI"] == nil)
panel.mouseHandler(panel, "mouseUp", "close")
state.config.chatProjects["Chat B"] = nil -- The later AX project test starts without a manual assignment.
state.promptAnswer = "Manual Chat"
state.space = 2
module.refresh()
assert(not strip.visible)
state.space = 1
state.timers[2]()
state.windows = {}
module.refresh()
assert(state.deleted == 2)

-- A color click can prompt for a missing chat title without losing the
-- window identity captured when the panel opened.
state.title = "ChatGPT"
state.focused = window
state.hotkeys.C()
assert(panel.visible)
state.useNoFocus = true
panel.mouseHandler(panel, "mouseUp", "color:1")
assert(state.lastPrompt.title == "Chat title")
assert(state.config.chatRules["Manual Chat"] == "#112233")
assert(state.config.windowChats["99"] == "Manual Chat")
assert(module.contextFor(window).chat == "Manual Chat")
assert(state.lastPrompt.message == "Enter the chat title exactly as shown in ChatGPT")

-- Project color for an unnamed chat asks for both names so the rule applies now.
state.config.windowChats["99"] = nil
state.useNoFocus = false
state.windows = {window}
state.promptAnswer = {"Fresh Chat", "Fresh Project"}
state.hotkeys.P()
panel.mouseHandler(panel, "mouseUp", "color:2")
assert(state.config.windowChats["99"] == "Fresh Chat")
assert(state.config.chatProjects["Fresh Chat"] == "Fresh Project")
assert(state.config.projectRules["Fresh Project"] == "#445566")
state.config.windowChats["99"] = "Manual Chat"

-- The live app exposes the active chat as a small AXButton in the top bar.
-- Its sidebar entry also has a title, so only the header may drive the color.
local function axNode(attributes, children)
  attributes.AXChildren = children or {}
  return {attributeValue = function(_, name) return attributes[name] end}
end
local sidebar = axNode({AXRole = "AXButton", AXTitle = "Demo chat",
  AXPosition = {x = 58, y = 200}, AXSize = {w = 237, h = 61}})
local function header(title)
  return axNode({AXRole = "AXButton", AXTitle = title,
    AXPosition = {x = state.frame.x + 280, y = state.frame.y + 12},
    AXSize = {w = 230, h = 27}})
end
state.windows = {window}
state.config.chatRules["Demo chat"] = "#445566"
state.axRoot = axNode({AXRole = "AXWindow"}, {sidebar, header("Demo chat")})
assert(module.contextFor(window).chat == "Demo chat")
module.refresh()
local liveStrip = state.created[#state.created]
assert(liveStrip[1].fillColor.hex == "#445566")
state.axRoot = axNode({AXRole = "AXWindow"}, {sidebar, header("Chat B")})
assert(module.contextFor(window).chat == "Chat B")
module.refresh()
assert(liveStrip[1].fillColor.hex == "#abcdef")
local webArea = axNode({AXRole = "AXWebArea", AXTitle = "Demo chat"})
state.axRoot = axNode({AXRole = "AXWindow"}, {sidebar, webArea})
assert(module.contextFor(window).chat == "Demo chat")
assert(module.contextFor(window).source == "web area title")
module.refresh()
assert(liveStrip[1].fillColor.hex == "#445566")
webArea = axNode({AXRole = "AXWebArea", AXTitle = "Chat B"})
state.axRoot = axNode({AXRole = "AXWindow"}, {sidebar, webArea})
module.refresh()
assert(liveStrip[1].fillColor.hex == "#abcdef")
local projectButton = axNode({AXRole = "AXPopUpButton", AXTitle = "Project: Lab",
  AXPosition = {x = 300, y = 49}, AXSize = {w = 32, h = 32}})
state.config.chatRules["Chat B"] = nil
state.config.projectRules.Lab = "#123456"
state.config.chatProjects["Chat B"] = "#abcdef" -- Malformed legacy project value.
state.axRoot = axNode({AXRole = "AXWindow"}, {sidebar, projectButton, header("Chat B")})
assert(module.contextFor(window).project == "Lab")
module.refresh()
assert(liveStrip[1].fillColor.hex == "#123456")
state.config.chatProjects["Chat B"] = nil
state.config.windowChats["99"] = nil
state.axRoot = axNode({AXRole = "AXWindow"}, {
  axNode({AXRole = "AXStaticText", AXSelected = true,
    AXValue = "Selected content"})})
assert(module.contextFor(window).chat == nil)
state.config.windowChats["99"] = "Manual Chat"
state.axRoot = axNode({AXRole = "AXWindow"}, {sidebar})
assert(module.contextFor(window).chat == "Manual Chat")
module.stop()

-- Starting JankyBorders and applying a color must never block Hammerspoon.
state.config.renderer = "borders"
state.windows = {window}
state.axRoot = axNode({AXRole = "AXWindow"}, {header("Chat B")})
local canvasCount = #state.created
module.start()
assert(#state.tasks == 1)
assert(state.tasks[1].arguments[1] == "whitelist=ChatGPT")
assert(#state.created == canvasCount + 1) -- Hover control only; no fallback strip.
state.now = 2.1
module.refresh()
assert(#state.tasks == 2)
assert(state.tasks[2].arguments[1] == "apply-to=99")
assert(#state.created == canvasCount + 1)
state.tasks[2].callback(0)
module.refresh()
state.now = 11
module.refresh()
assert(#state.tasks == 2) -- No needless reapply after eight seconds.
state.frame = {x = 80, y = 90, w = 540, h = 420}
module.refresh()
assert(#state.tasks == 2) -- Resizing does not add a line or reapply color.
assert(#state.created == canvasCount + 1)
state.axRoot = axNode({AXRole = "AXWindow"}, {header("Chat C")})
module.refresh()
assert(#state.tasks == 3) -- A real chat/color change still updates JankyBorders.
assert(#state.created == canvasCount + 1)
local beforeInside = #state.created
module.setPlacement("inside")
assert(state.config.renderer == "inside")
assert(#state.created == beforeInside + 5)
local topLeft, topEdge, topRight, leftEdge, bottomLeft =
  state.created[beforeInside + 1], state.created[beforeInside + 2],
  state.created[beforeInside + 3], state.created[beforeInside + 4],
  state.created[beforeInside + 5]
for _, edge in ipairs({topLeft, topEdge, topRight, leftEdge, bottomLeft}) do
  assert(edge.visible and edge[1].type == "segments")
  assert(edge.elements[#edge.elements].strokeWidth == state.config.thickness)
  assert(edge.elements[#edge.elements].strokeColor.alpha == 0.8)
end
local radius = topEdge.currentFrame.x - state.frame.x
assert(topLeft.currentFrame.x == state.frame.x and topLeft.currentFrame.y == state.frame.y)
assert(topEdge.currentFrame.y == state.frame.y and
  topEdge.currentFrame.h == state.config.thickness + state.config.fadeWidth)
assert(topEdge.currentFrame.w == state.frame.w - 2 * radius)
assert(topRight.currentFrame.x + topRight.currentFrame.w == state.frame.x + state.frame.w)
assert(leftEdge.currentFrame.x == state.frame.x and leftEdge.currentFrame.y == state.frame.y + radius)
assert(leftEdge.currentFrame.w == state.config.thickness + state.config.fadeWidth)
assert(leftEdge.currentFrame.y + leftEdge.currentFrame.h == state.frame.y + state.frame.h - radius)
assert(bottomLeft.currentFrame.x == state.frame.x)
assert(bottomLeft.currentFrame.y + bottomLeft.currentFrame.h == state.frame.y + state.frame.h)
assert(topLeft.elements[#topLeft.elements].coordinates[2].c1x)
assert(topRight.elements[#topRight.elements].coordinates[2].c1x)
assert(bottomLeft.elements[#bottomLeft.elements].coordinates[2].c1x)
assert(#topEdge.elements == state.config.fadeWidth + 1)
assert(#leftEdge.elements == state.config.fadeWidth + 1)
assert(topEdge.elements[1].strokeColor.alpha <
  topEdge.elements[state.config.fadeWidth].strokeColor.alpha)
assert(topEdge.elements[state.config.fadeWidth].strokeColor.alpha <
  topEdge.elements[#topEdge.elements].strokeColor.alpha)
state.config.fadeWidth = 0
module.refresh()
assert(#topEdge.elements == 1 and #leftEdge.elements == 1)
assert(topEdge.currentFrame.h == state.config.thickness)
assert(leftEdge.currentFrame.w == state.config.thickness)
state.config.fadeWidth = 14
module.refresh()
assert(#topEdge.elements == 15 and #leftEdge.elements == 15)
assert(state.tasks[#state.tasks].arguments[2] == "active_color=0x00000000")
local taskCount = #state.tasks
state.frame = {x = 95, y = 105, w = 580, h = 460}
module.refresh()
assert(topEdge.currentFrame.x == 95 + radius and topEdge.currentFrame.w == 580 - 2 * radius)
assert(leftEdge.currentFrame.x == 95 and leftEdge.currentFrame.y + leftEdge.currentFrame.h == 565 - radius)
assert(#state.tasks == taskCount)
module.openPanel(window, "chat")
local placementPanel = state.created[#state.created]
assert(element(placementPanel, "placement:inside"))
assert(element(placementPanel, "placement:outside"))
placementPanel.mouseHandler(placementPanel, "mouseUp", "placement:outside")
assert(state.config.renderer == "borders")
assert(not topEdge.visible)
placementPanel.mouseHandler(placementPanel, "mouseUp", "placement:inside")
assert(state.config.renderer == "inside")
assert(topEdge.visible)
state.space = 2
state.spaceCallback(2)
assert(not topEdge.visible)
state.delayed[#state.delayed]()
assert(not topEdge.visible)
state.space = 1
state.spaceCallback(1)
state.delayed[#state.delayed]()
assert(topEdge.visible)
state.frameB = {x = 130, y = 125, w = 580, h = 460}
state.windows = {window, windowB}
state.orderedWindows = {window, windowB}
state.now = 12
local beforeOverlap = #state.created
module.refresh()
assert(state.timerIntervals[3] <= 0.16) -- Idle checks stay separate from AX polling.
local backTop = state.created[beforeOverlap + 3]
assert(backTop.visible and backTop.elements[1].action == "clip")
assert(backTop.elements[1].frame.x > 0) -- The front window masks the covered portion.
assert(backTop.elements[1].frame.w < backTop.currentFrame.w)
local backElements = backTop.elements
local frontElements = topEdge.elements
local axReads = state.axReads
local function tickGeometry()
  for index = #state.timers, 1, -1 do
    if state.timerIntervals[index] <= 1 / 60 + 0.001 and
        state.timerObjects[index].active then
      state.timers[index]()
      break
    end
  end
  state.timers[6]() -- The normal timer skips while fast tracking is active.
end
state.frame = {x = 800, y = 10, w = 580, h = 460}
tickGeometry() -- Geometry updates without a full Accessibility refresh.
assert(state.axReads == axReads)
assert(topEdge.currentFrame.x == 800 + radius and topEdge.elements == frontElements)
assert(state.created[canvasCount + 1].currentFrame.x == 800 + (580 - 48) / 2)
assert(backTop.elements[1].type == "segments")
assert(backTop.elements ~= backElements)
state.frame = {x = 95, y = 105, w = 580, h = 460}
state.focused = windowB
state.orderedWindows = {windowB, window}
state.now = 13
tickGeometry()
assert(backTop.elements[1].type == "segments") -- The new front window is not clipped.
local hasClip = false
for _, item in ipairs(topEdge.elements) do
  if item.action == "clip" then hasClip = true end
end
assert(hasClip) -- The previous front window is clipped.
state.front = false
state.frontBundle = "other"
state.orderedWindows = {otherWindow, windowB, window}
state.now = 14
tickGeometry()
assert(backTop.visible) -- Exposed rear-window color remains visible behind another app.
module.refresh()
assert(backTop.visible)
local otherClip = false
for _, item in ipairs(backTop.elements) do
  if item.action == "clip" then otherClip = true end
end
assert(otherClip) -- The other app covers only the overlapping part.
state.front = true
state.orderedWindows = {windowB, window}
state.now = 15
module.refresh()
assert(backTop.elements[1].type == "segments")
state.orderedWindows = {transparentPopover, windowB, window}
state.now = 16
module.refresh()
assert(backTop.elements[1].type == "segments") -- A transparent popover cannot cut the top line.
state.orderedWindows = {otherDialog, windowB, window}
state.now = 17.1
module.refresh()
local dialogClip = false
for _, item in ipairs(backTop.elements) do
  if item.action == "clip" then dialogClip = true end
end
assert(dialogClip) -- An opaque dialog from another app still covers it.
state.orderedWindows = {windowB, window}
state.now = 18
local dragTap
for _, tap in ipairs(state.taps) do
  if #tap.events == 3 and tap.active then dragTap = tap end
end
assert(dragTap and dragTap.active)
dragTap.callback({getType = function() return "leftMouseDown" end,
  location = function() return {x = 200, y = 130} end})
local fastTimerIndex = #state.timers
assert(state.timerIntervals[fastTimerIndex] <= 1 / 60 + 0.001)
local dragAxReads = state.axReads
state.frameB = {x = 170, y = 125, w = 580, h = 460}
state.now = 18.03
dragTap.callback({getType = function() return "leftMouseDragged" end})
assert(backTop.currentFrame.x ~= 170 + radius) -- Do not block native drag event processing.
state.timers[6]()
assert(backTop.currentFrame.x ~= 170 + radius) -- No duplicate slow-timer work during dragging.
state.timers[fastTimerIndex]()
assert(backTop.currentFrame.x == 170 + radius)
assert(state.axReads == dragAxReads)
state.timers[4]() -- A scheduled AX scan must not stall an active drag.
assert(state.axReads == dragAxReads)
state.now = 18.5
state.timers[fastTimerIndex]()
state.timers[4]()
assert(state.axReads > dragAxReads) -- Discovery resumes after motion settles.
state.frameB = {x = 190, y = 125, w = 580, h = 460}
state.now = 18.6
state.timers[6]() -- Resizing or scripted moves also enable fast tracking.
assert(backTop.currentFrame.x == 190 + radius)
assert(state.timerIntervals[#state.timers] <= 1 / 60 + 0.001)
state.lookupEnabled = true
state.axRoot = axNode({AXRole = "AXWindow"}, {header("Example chat")})
state.config.chatProjects["Example chat"] = "Wrong project"
state.config.projectRules["Wrong project"] = "#ff0000"
local pending = module.contextFor(window)
assert(pending.project == nil and pending.projectLookupStatus == "pending")
local lookupTask = state.tasks[#state.tasks]
assert(lookupTask.arguments[1]:match("project_lookup%.py$"))
assert(lookupTask.arguments[2] == "Example chat")
state.lookupResult = {status = "ok", project = "Demo project"}
lookupTask.callback(0, "{}", "")
local actual = module.contextFor(window)
assert(actual.project == "Demo project")
assert(actual.projectSource == "Codex project assignment")
module.openPanel(window, "project")
local actualPanel
local projectShown = false
for _, candidate in ipairs(state.created) do
  for _, item in ipairs(candidate.elements or {}) do
    if item.type == "text" and item.text == "Demo project" then
      actualPanel, projectShown = candidate, true
    end
  end
end
assert(projectShown)
actualPanel.mouseHandler(actualPanel, "mouseUp", "color:1")
assert(state.config.projectRules["Demo project"] == "#112233")
state.now = 100
module.contextFor(window)
lookupTask = state.tasks[#state.tasks]
state.lookupResult = {status = "ambiguous", matches = 2}
lookupTask.callback(0, "{}", "")
local ambiguous = module.contextFor(window)
assert(ambiguous.project == nil and ambiguous.projectLookupStatus == "ambiguous")
module.stop()
assert(not dragTap.active)
print("integration tests passed")
