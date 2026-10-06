local core = require("colorq.core")
local M = {}

local BUNDLE_ID = "com.openai.codex"
local BASE = os.getenv("COLORQ_DIR") or
  (os.getenv("HOME") .. "/.hammerspoon/colorq")
local CONFIG_PATH = BASE .. "/config.json"
local RUNTIME_PATH = BASE .. "/runtime.json"
local PROJECT_LOOKUP_PATH = BASE .. "/project_lookup.py"
local function firstInstalled(paths)
  for _, path in ipairs(paths) do
    if hs.fs.attributes(path) then return path end
  end
  return nil
end
local runtime = hs.json.read(RUNTIME_PATH)
local configuredPython = type(runtime) == "table" and runtime.pythonPath
local PYTHON_BIN = configuredPython and hs.fs.attributes(configuredPython) and
  configuredPython or firstInstalled({
  "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"
})
local overlays = {}
local innerEdges = {}
local innerStates = {}
local hoverTabs = {}
local windowFrames = {}
local windowColors = {}
local projectLookups = {}
local projectLookupTasks = {}
local hoverCandidates = {}
local config
local timer
local hoverTimer
local geometryTimer
local fastGeometryTimer
local dragTap
local draggingColorWindow = false
local fastUntil = 0
local geometryRefresh
local spaceWatcher
local spaceRefreshTimer
local orderedWindows
local orderedAt = -10
local orderedFocusId
local orderedFrontPid
local spaceTransitionUntil = 0
local spaceRevision = 0
local menu
local hotkeys = {}
local lastContexts = {}
local panel
local panelFrame
local panelWindowId
local panelScope = "chat"
local panelDismissTap
local closePanel, renderPanel, togglePanel
local borderTask
local borderConfigTask
local borderApplied = {}
local borderCleared = {}
local borderDaemonPresent = false
local lastBorderProbe = -10
local borderReadyAt = 0
local lastFocusedWindowId
local BORDER_BIN = firstInstalled({
  "/opt/homebrew/bin/borders", "/usr/local/bin/borders"
})
local function borderAvailable()
  return BORDER_BIN and hs.fs.attributes(BORDER_BIN)
end
local refresh

local function loadConfig()
  local loaded = hs.json.read(CONFIG_PATH)
  if type(loaded) ~= "table" then loaded = {} end
  loaded.palette = type(loaded.palette) == "table" and loaded.palette or core.defaultPalette
  loaded.chatRules = type(loaded.chatRules) == "table" and loaded.chatRules or {}
  loaded.projectRules = type(loaded.projectRules) == "table" and loaded.projectRules or {}
  loaded.chatProjects = type(loaded.chatProjects) == "table" and loaded.chatProjects or {}
  loaded.windowChats = type(loaded.windowChats) == "table" and loaded.windowChats or {}
  loaded.thickness = math.max(1, math.min(12,
    tonumber(loaded.thickness) or tonumber(loaded.stripHeight) or 4))
  loaded.fadeWidth = math.max(0, math.min(32,
    math.floor(tonumber(loaded.fadeWidth) or 12)))
  loaded.lineOpacity = math.max(0, math.min(100,
    math.floor(tonumber(loaded.lineOpacity) or 100)))
  loaded.stripHeight = nil
  if loaded.renderer ~= "canvas" and loaded.renderer ~= "inside" and
      loaded.renderer ~= "borders" then
    loaded.renderer = "inside"
  end
  if loaded.renderer == "borders" and not borderAvailable() then
    loaded.renderer = "inside"
  end
  return loaded
end

local function saveConfig()
  local encoded = hs.json.encode(config, true)
  if not encoded then return false end
  local path = CONFIG_PATH .. ".tmp"
  local file = io.open(path, "w")
  if not file then return false end
  file:write(encoded, "\n")
  file:close()
  return os.rename(path, CONFIG_PATH) ~= nil
end

local function axValue(element, name)
  if not element then return nil end
  local ok, value = pcall(function() return element:attributeValue(name) end)
  return ok and value or nil
end

-- The app exposes its current chat as a button in the top bar. Sidebar chat
-- buttons have similar titles, so require the observed header frame and role.
local function chatFromAX(window)
  local ok, root = pcall(hs.axuielement.windowElement, window)
  if not ok or not root then return nil, nil end
  local frame = window:frame()
  local queue = {root}
  local head = 1
  local headerChat, webAreaChat, project
  while head <= #queue and head <= 350 do
    local element = queue[head]
    head = head + 1
    local role = axValue(element, "AXRole")
    local position = axValue(element, "AXPosition")
    local size = axValue(element, "AXSize")
    if role == "AXWebArea" and not webAreaChat then
      local webTitle = core.clean(axValue(element, "AXTitle"))
      if webTitle and webTitle ~= "ChatGPT" and webTitle ~= "Codex" then
        webAreaChat = webTitle
      end
    end
    if frame and role == "AXPopUpButton" and position and size and
        position.x >= frame.x + 200 and position.x < frame.x + math.min(frame.w - 130, 900) and
        position.y >= frame.y + 5 and position.y <= frame.y + 20 then
      local title = core.clean(axValue(element, "AXTitle"))
      if title then project = core.clean(title:match("^Project:%s*(.+)$")) or project end
    end
    if frame and role == "AXButton" and position and size and
        position.x >= frame.x + 270 and position.x < frame.x + math.min(frame.w - 130, 900) and
        position.y >= frame.y + 10 and position.y <= frame.y + 16 and
        size.w >= 60 and size.h >= 22 and size.h <= 30 then
      local title = core.clean(axValue(element, "AXTitle"))
      if title then headerChat = title end
    end
    local children = axValue(element, "AXChildren")
    if type(children) == "table" then
      for _, child in ipairs(children) do queue[#queue + 1] = child end
    end
  end
  if headerChat then return headerChat, "header AX button", project end
  if webAreaChat then return webAreaChat, "web area title", project end
  return nil, nil, project
end

local function projectInfoForChat(chat)
  if not chat or not PYTHON_BIN or not hs.fs.attributes(PROJECT_LOOKUP_PATH) or
      not hs.fs.attributes(PYTHON_BIN) then return nil end
  local now = hs.timer.secondsSinceEpoch()
  local cached = projectLookups[chat]
  if cached and cached.expiresAt > now then return cached end
  if projectLookupTasks[chat] then return cached end
  if not cached then
    cached = {status = "pending", expiresAt = now + 10}
    projectLookups[chat] = cached
  else
    cached.expiresAt = now + 30
  end
  local task
  task = hs.task.new(PYTHON_BIN, function(exitCode, output)
    if projectLookupTasks[chat] ~= task then return end
    projectLookupTasks[chat] = nil
    local ok, result = pcall(hs.json.decode, output or "")
    if exitCode ~= 0 or not ok or type(result) ~= "table" then
      result = {status = "unavailable"}
    end
    result.expiresAt = hs.timer.secondsSinceEpoch() +
      (result.status == "ok" and 30 or 10)
    projectLookups[chat] = result
    if timer and refresh then refresh() end
  end, {PROJECT_LOOKUP_PATH, chat})
  if not task or not task:start() then
    cached.status = "unavailable"
    cached.expiresAt = now + 10
    return cached
  end
  projectLookupTasks[chat] = task
  return cached
end

local function contextFor(window)
  local title = core.clean(window:title())
  -- Read the target window itself. Color pickers and dialogs can take focus
  -- after the user invokes them, but the target window's AX tree is still valid.
  local detected, detectedSource, detectedProject = chatFromAX(window)
  local generic = title == "ChatGPT" or title == "Codex" or title == "OpenAI"
  local remembered = core.clean(config.windowChats[tostring(window:id())])
  local chat = detected or (not generic and title) or remembered
  local projectInfo = projectInfoForChat(chat)
  local actualProject = projectInfo and projectInfo.status == "ok" and
    core.clean(projectInfo.project) or nil
  local manualProject = chat and core.clean(config.chatProjects[chat]) or nil
  -- Older versions could accidentally save a hex color as a project name.
  if core.validColor(manualProject) then manualProject = nil end
  local lookupStatus = projectInfo and projectInfo.status or nil
  local project, projectSource
  if actualProject then
    project, projectSource = actualProject, "Codex project assignment"
  elseif lookupStatus == "ambiguous" then
    projectSource = "Ambiguous chat title"
  elseif detectedProject then
    project, projectSource = detectedProject, "Accessibility project label"
  elseif lookupStatus ~= "pending" and manualProject then
    project, projectSource = manualProject, "Manual fallback"
  elseif lookupStatus == "pending" then
    projectSource = "Looking up Codex project"
  else
    projectSource = "No Codex project found"
  end
  return {chat = chat, project = project, windowId = window:id(), title = title,
          projectSource = projectSource, projectLookupStatus = lookupStatus,
          source = detectedSource or (not generic and title) and "window title" or
            remembered and "manual window label" or "window ID"}
end

local function isTarget(window)
  if not window or not window:id() then return false end
  local app = window:application()
  return app and app:bundleID() == BUNDLE_ID and window:role() == "AXWindow" and
    window:title() == "ChatGPT" and window:isStandard()
end

local function focusedTarget()
  local window = hs.window.focusedWindow()
  if isTarget(window) then return window end
  if lastFocusedWindowId then
    window = hs.window.get(lastFocusedWindowId)
    if isTarget(window) then return window end
  end
  return nil
end

local function currentSpaceContains(window)
  local ok, current = pcall(hs.spaces.activeSpaceOnScreen, window:screen())
  if not ok or not current then ok, current = pcall(hs.spaces.focusedSpace) end
  if not ok or not current then return true end
  local valid, spaces = pcall(hs.spaces.windowSpaces, window)
  if not valid or not spaces or #spaces == 0 then return true end
  for _, space in ipairs(spaces) do if space == current then return true end end
  return false
end

local function discard(id)
  if panelWindowId == id and closePanel then closePanel() end
  if overlays[id] then
    overlays[id]:delete()
    overlays[id] = nil
  end
  if innerEdges[id] then
    for _, edge in ipairs(innerEdges[id]) do edge:delete() end
    innerEdges[id] = nil
  end
  innerStates[id] = nil
  windowColors[id] = nil
  if hoverTabs[id] then
    hoverTabs[id]:delete()
    hoverTabs[id] = nil
  end
  windowFrames[id] = nil
  lastContexts[id] = nil
  if borderApplied[id] and borderApplied[id].task then borderApplied[id].task:terminate() end
  borderApplied[id] = nil
  if borderCleared[id] and borderCleared[id].task then borderCleared[id].task:terminate() end
  borderCleared[id] = nil
  if lastFocusedWindowId == id then lastFocusedWindowId = nil end
end

local function borderHex(color)
  local rgb = color:sub(2)
  if #rgb == 3 then rgb = rgb:sub(1, 1):rep(2) .. rgb:sub(2, 2):rep(2) .. rgb:sub(3, 3):rep(2) end
  return "0xff" .. rgb
end

local function startBorders()
  if config.renderer ~= "borders" or not borderAvailable() then return end
  local _, running = hs.execute("/usr/bin/pgrep -x borders >/dev/null")
  local arguments = {"whitelist=ChatGPT", "active_color=0x00000000",
    "inactive_color=0x00000000", string.format("width=%.1f", config.thickness), "style=round"}
  if not running then
    borderReadyAt = hs.timer.secondsSinceEpoch() + 2
    borderTask = hs.task.new(BORDER_BIN, function() borderTask = nil end,
      arguments)
    if borderTask then borderDaemonPresent = not not borderTask:start() end
  else
    borderDaemonPresent = true
    borderReadyAt = hs.timer.secondsSinceEpoch() + 0.5
    borderConfigTask = hs.task.new(BORDER_BIN, function() borderConfigTask = nil end, arguments)
    if borderConfigTask then borderConfigTask:start() end
  end
end

local function applyBorder(id, color)
  if config.renderer ~= "borders" or not borderAvailable() then return false end
  local now = hs.timer.secondsSinceEpoch()
  borderCleared[id] = nil
  if now < borderReadyAt then return false end
  local last = borderApplied[id]
  if last and last.pending then
    if last.color == color and now - last.time < 3 then return true end
    if last.task then last.task:terminate() end
    borderApplied[id] = nil
    last = nil
  end
  if last and last.color == color and last.success then return true end
  if last and last.failedAt and now - last.failedAt < 5 then return false end
  local opaque = borderHex(color)
  local command = {string.format("apply-to=%d", id), "active_color=" .. opaque,
    "inactive_color=" .. opaque}
  local current = {color = color, time = now, pending = true}
  local task = hs.task.new(BORDER_BIN, function(exitCode)
    if borderApplied[id] ~= current then return end
    current.pending = false
    current.task = nil
    current.success = exitCode == 0
    if not current.success then current.failedAt = hs.timer.secondsSinceEpoch() end
  end, command)
  if not task then return false end
  current.task = task
  borderApplied[id] = current
  if not task:start() then
    borderApplied[id] = nil
  end
  return false
end

local function clearBorder(id)
  if not borderAvailable() then return end
  local now = hs.timer.secondsSinceEpoch()
  if not borderDaemonPresent then
    if now - lastBorderProbe < 10 then return end
    lastBorderProbe = now
    local _, running = hs.execute("/usr/bin/pgrep -x borders >/dev/null")
    if not running then return end
    borderDaemonPresent = true
  end
  local last = borderCleared[id]
  if last and last.pending and now - last.time < 3 then return end
  if last and last.success then return end
  if last and last.failedAt and now - last.failedAt < 5 then return end
  if last and last.task then last.task:terminate() end
  local applied = borderApplied[id]
  if applied and applied.task then applied.task:terminate() end
  borderApplied[id] = nil
  local current = {time = now, pending = true}
  local command = {string.format("apply-to=%d", id),
    "active_color=0x00000000", "inactive_color=0x00000000"}
  local task = hs.task.new(BORDER_BIN, function(exitCode)
    if borderCleared[id] ~= current then return end
    current.pending = false
    current.task = nil
    current.success = exitCode == 0
    if not current.success then current.failedAt = hs.timer.secondsSinceEpoch() end
  end, command)
  if not task then return end
  current.task = task
  borderCleared[id] = current
  if not task:start() then borderCleared[id] = nil end
end

local function showCanvas(id, frame, color)
  local height = config.thickness
  local strip = {x = frame.x + 6, y = frame.y + 2, w = frame.w - 12, h = height}
  local canvas = overlays[id]
  if not canvas then
    canvas = hs.canvas.new(strip)
    canvas:level("floating")
    canvas:behaviorAsLabels({"canJoinAllSpaces", "ignoresCycle"})
    overlays[id] = canvas
  else
    canvas:frame(strip)
  end
  canvas[1] = {type = "rectangle", action = "fill", fillColor = {hex = color},
               roundedRectRadii = {xRadius = 2, yRadius = 2}}
  canvas:show()
end

local function hideInner(id)
  if innerEdges[id] then
    for index, edge in ipairs(innerEdges[id]) do
      local state = innerStates[id] and innerStates[id][index]
      if not state or state.visible then edge:hide() end
      if state then state.visible = false end
    end
  end
end

local function showInner(id, frame, color, occluders)
  local thickness = config.thickness
  local half = thickness / 2
  local radius = math.min(14, frame.w / 2, frame.h / 2)
  local fadeWidth = config.fadeWidth
  local opacity = config.lineOpacity / 100
  local cornerSize = math.max(radius + half, thickness + fadeWidth)
  local function curveFor(offset) return 0.55228475 * (radius - offset) end
  local function topLeft(offset)
    if offset > radius then return nil end
    local curve = curveFor(offset)
    return {{x = offset, y = radius},
      {x = radius, y = offset, c1x = offset, c1y = radius - curve,
        c2x = radius - curve, c2y = offset}}
  end
  local function top(offset)
    local start = math.max(radius, offset) - radius
    return {{x = start, y = offset},
      {x = frame.w - 2 * radius - start, y = offset}}
  end
  local function topRight(offset)
    if offset > radius then return nil end
    local curve = curveFor(offset)
    return {{x = cornerSize - radius, y = offset},
      {x = cornerSize - offset, y = radius,
        c1x = cornerSize - radius + curve, c1y = offset,
        c2x = cornerSize - offset, c2y = radius - curve}}
  end
  local function left(offset)
    local start = math.max(radius, offset) - radius
    return {{x = offset, y = start},
      {x = offset, y = frame.h - 2 * radius - start}}
  end
  local function bottomLeft(offset)
    if offset > radius then return nil end
    local curve = curveFor(offset)
    return {{x = offset, y = cornerSize - radius},
      {x = radius, y = cornerSize - offset,
        c1x = offset, c1y = cornerSize - radius + curve,
        c2x = radius - curve, c2y = cornerSize - offset}}
  end
  local specs = {
    {frame = {x = frame.x, y = frame.y, w = cornerSize, h = cornerSize},
      coordinates = topLeft},
    {frame = {x = frame.x + radius, y = frame.y,
      w = frame.w - 2 * radius, h = thickness + fadeWidth},
      coordinates = top},
    {frame = {x = frame.x + frame.w - cornerSize, y = frame.y,
      w = cornerSize, h = cornerSize},
      coordinates = topRight},
    {frame = {x = frame.x, y = frame.y + radius,
      w = thickness + fadeWidth, h = frame.h - 2 * radius},
      coordinates = left},
    {frame = {x = frame.x, y = frame.y + frame.h - cornerSize,
      w = cornerSize, h = cornerSize},
      coordinates = bottomLeft},
  }
  local edges = innerEdges[id] or {}
  local states = innerStates[id] or {}
  for index, spec in ipairs(specs) do
    local visible = core.visibleRects(spec.frame, occluders)
    local edge = edges[index]
    local state = states[index]
    if not edge then
      edge = hs.canvas.new(spec.frame)
      edge:level("floating")
      edge:behaviorAsLabels({"canJoinAllSpaces", "ignoresCycle"})
      edge:clickActivating(false)
      edges[index] = edge
      state = {frame = spec.frame, visible = false}
      states[index] = state
    elseif not state or state.frame.x ~= spec.frame.x or state.frame.y ~= spec.frame.y or
        state.frame.w ~= spec.frame.w or state.frame.h ~= spec.frame.h then
      edge:frame(spec.frame)
      state = state or {}
      state.frame = spec.frame
      states[index] = state
    end
    if #visible == 0 then
      if state.visible then edge:hide(); state.visible = false end
    else
      local keyParts = {color, thickness, fadeWidth, config.lineOpacity,
        spec.frame.w, spec.frame.h}
      for _, rect in ipairs(visible) do
        keyParts[#keyParts + 1] = string.format("%.2f,%.2f,%.2f,%.2f",
          rect.x - spec.frame.x, rect.y - spec.frame.y, rect.w, rect.h)
      end
      local key = table.concat(keyParts, "|")
      if state.key ~= key then
        local elements = {}
        if #visible ~= 1 or visible[1].x ~= spec.frame.x or
            visible[1].y ~= spec.frame.y or visible[1].w ~= spec.frame.w or
            visible[1].h ~= spec.frame.h then
          for part, rect in ipairs(visible) do
            elements[#elements + 1] = {type = "rectangle",
              action = part == #visible and "clip" or "build",
              frame = {x = rect.x - spec.frame.x, y = rect.y - spec.frame.y,
                w = rect.w, h = rect.h}}
          end
        end
        for step = fadeWidth, 1, -1 do
          local coordinates = spec.coordinates(thickness + step - 0.5)
          if coordinates then
            elements[#elements + 1] = {type = "segments", action = "stroke",
              coordinates = coordinates, strokeWidth = 1,
              strokeColor = {hex = color, alpha = opacity * (1 - (step - 0.5) / fadeWidth)},
              strokeCapStyle = "butt", strokeJoinStyle = "round"}
          end
        end
        elements[#elements + 1] = {type = "segments", action = "stroke",
          coordinates = spec.coordinates(half), strokeColor = {hex = color, alpha = opacity},
          strokeWidth = thickness, strokeCapStyle = "butt", strokeJoinStyle = "round"}
        edge:replaceElements((table.unpack or unpack)(elements))
        state.key = key
      end
      if not state.visible then edge:show(); state.visible = true end
    end
  end
  for index = #edges, #specs + 1, -1 do
    edges[index]:delete()
    edges[index] = nil
    states[index] = nil
  end
  innerEdges[id] = edges
  innerStates[id] = states
end

local assignProject, clearRule, status, relabelChat, setThickness

local function updateHoverTab(id, frame, color)
  local width, height = 48, 28
  local tabFrame = {x = frame.x + (frame.w - width) / 2, y = frame.y + 8, w = width, h = height}
  local tab = hoverTabs[id]
  if not tab then
    tab = hs.canvas.new(tabFrame)
    tab:level("floating")
    tab:behaviorAsLabels({"canJoinAllSpaces", "ignoresCycle"})
    tab:clickActivating(false)
    tab:mouseCallback(function(_, message)
      if message == "mouseUp" then
        local window = hs.window.get(id)
        if isTarget(window) then togglePanel(window) end
      end
    end)
    hoverTabs[id] = tab
  else
    tab:frame(tabFrame)
  end
  tab:replaceElements(
    {type = "rectangle", action = "fill", fillColor = {hex = "#20242C"},
      strokeColor = {hex = "#FFFFFF", alpha = 0.24}, strokeWidth = 1,
      roundedRectRadii = {xRadius = 7, yRadius = 7}, trackMouseUp = true},
    {type = "rectangle", action = "fill", fillColor = {hex = color},
      strokeColor = {hex = "#FFFFFF", alpha = 0.7}, strokeWidth = 1,
      roundedRectRadii = {xRadius = 4, yRadius = 4},
      frame = {x = 5, y = 5, w = 18, h = 18}, trackMouseUp = true},
    {type = "text", text = "🎨", textSize = 16,
      textAlignment = "center", frame = {x = 24, y = 1, w = 22, h = 25},
      trackMouseUp = true}
  )
end

local function targetIsActive(app)
  local front = hs.application.frontmostApplication()
  if not app or not front then return false end
  if app:pid() == front:pid() then return true end
  return panelWindowId ~= nil and front:bundleID() == "org.hammerspoon.Hammerspoon"
end

local function hoverRefresh()
  local app = hs.application.get(BUNDLE_ID)
  local active = targetIsActive(app)
  local point = active and hs.mouse.absolutePosition() or nil
  local chosen
  if point then
    for _, window in ipairs(hoverCandidates) do
      local id = window:id()
      local frame = windowFrames[id]
      if frame and point.x >= frame.x and point.x <= frame.x + frame.w and
          point.y >= frame.y and point.y <= frame.y + 80 then
        chosen = id
        break
      end
    end
  end
  if active and panelWindowId and windowFrames[panelWindowId] then chosen = panelWindowId end
  for id, tab in pairs(hoverTabs) do
    if id == chosen then tab:show() else tab:hide() end
  end
end

local function activateFastGeometry(now)
  fastUntil = now + 0.25
  if fastGeometryTimer then return end
  fastGeometryTimer = hs.timer.doEvery(1 / 60, function()
    if hs.timer.secondsSinceEpoch() >= fastUntil then
      fastGeometryTimer:stop()
      fastGeometryTimer = nil
    else
      geometryRefresh()
    end
  end, true)
end

geometryRefresh = function()
  if config.renderer ~= "inside" or hs.timer.secondsSinceEpoch() < spaceTransitionUntil then
    for id in pairs(innerEdges) do hideInner(id) end
    return
  end
  local focused = hs.window.focusedWindow()
  local focusId = isTarget(focused) and focused:id() or lastFocusedWindowId
  local front = hs.application.frontmostApplication()
  local frontPid = front and front:pid()
  local now = hs.timer.secondsSinceEpoch()
  if not orderedWindows or focusId ~= orderedFocusId or frontPid ~= orderedFrontPid or
      (not draggingColorWindow and now - orderedAt >= 1.0) then
    orderedWindows = hs.window.orderedWindows()
    orderedAt = now
    orderedFocusId = focusId
    orderedFrontPid = frontPid
  end
  local moved = false
  for _, window in ipairs(hoverCandidates) do
    local id = window:id()
    local frame = window:frame()
    if frame and window:isVisible() and not window:isMinimized() and
        currentSpaceContains(window) and windowColors[id] then
      local occluders = {}
      local found = false
      for _, above in ipairs(orderedWindows) do
        if above:id() == id then found = true; break end
        local application = above:application()
        if application and application:bundleID() ~= "org.hammerspoon.Hammerspoon" and
            (application:bundleID() ~= BUNDLE_ID or above:isStandard()) then
          local cover = above:frame()
          if cover and cover.w > 0 and cover.h > 0 then
            occluders[#occluders + 1] = cover
          end
        end
      end
      if found then
        local previous = windowFrames[id]
        if previous and (previous.x ~= frame.x or previous.y ~= frame.y or
            previous.w ~= frame.w or previous.h ~= frame.h) then
          moved = true
          local tab = hoverTabs[id]
          if tab then
            tab:frame({x = frame.x + (frame.w - 48) / 2,
              y = frame.y + 8, w = 48, h = 28})
          end
        end
        windowFrames[id] = frame
        showInner(id, frame, windowColors[id], occluders)
        if panelWindowId == id and renderPanel and previous and
            (previous.x ~= frame.x or previous.y ~= frame.y or
              previous.w ~= frame.w or previous.h ~= frame.h) then renderPanel() end
      else
        windowFrames[id] = nil
        hideInner(id)
      end
    else
      windowFrames[id] = nil
      hideInner(id)
    end
  end
  if moved then activateFastGeometry(now) end
end

refresh = function()
  local app = hs.application.get(BUNDLE_ID)
  local active = targetIsActive(app)
  if active then
  local focused = hs.window.focusedWindow()
    if isTarget(focused) then lastFocusedWindowId = focused:id() end
  end
  local seen = {}
  hoverCandidates = {}
  windowFrames = {}
  if app then
    for _, window in ipairs(app:allWindows() or {}) do
      if isTarget(window) then
        local id = window:id()
        seen[id] = true
        local visible = (active or config.renderer == "inside") and
          window:isVisible() and not window:isMinimized() and currentSpaceContains(window)
        local frame = window:frame()
        visible = visible and frame and frame.w > 20 and frame.h > 20
        if visible then
          windowFrames[id] = frame
          hoverCandidates[#hoverCandidates + 1] = window
          local context = contextFor(window)
          lastContexts[id] = context
          local color = core.resolve(config, context)
          windowColors[id] = color
          updateHoverTab(id, frame, color)
          if config.renderer == "inside" then
            clearBorder(id)
            if overlays[id] then overlays[id]:hide() end
          elseif config.renderer == "borders" and borderAvailable() then
            applyBorder(id, color)
            if overlays[id] then overlays[id]:hide() end
            hideInner(id)
          else
            clearBorder(id)
            hideInner(id)
            showCanvas(id, frame, color)
          end
        else
          if overlays[id] then overlays[id]:hide() end
          hideInner(id)
        end
      end
    end
  end
  local stale = {}
  for id in pairs(overlays) do if not seen[id] then stale[#stale + 1] = id end end
  for id in pairs(innerEdges) do if not seen[id] then stale[#stale + 1] = id end end
  for id in pairs(hoverTabs) do if not seen[id] then stale[#stale + 1] = id end end
  local removed = {}
  for _, id in ipairs(stale) do
    if not removed[id] then discard(id); removed[id] = true end
  end
  if config.renderer == "inside" then geometryRefresh() end
  if panelWindowId then
    if not windowFrames[panelWindowId] then closePanel()
    elseif renderPanel then renderPanel() end
  end
end

local function scheduledRefresh()
  if hs.timer.secondsSinceEpoch() >= fastUntil then refresh() end
end

local function notify(message)
  hs.alert.show(message, 1.5)
end

local function promptName(scope, current)
  local label = scope == "project" and "Project name" or "Chat title"
  local prompt = scope == "project" and "Name this chat's project" or
    "Enter the chat title exactly as shown in ChatGPT"
  local button, answer = hs.dialog.textPrompt(label, prompt, current or "", "Save", "Cancel")
  if button ~= "Save" then return nil end
  return core.clean(answer)
end

local function editRule(scope, color, selectedWindow, context)
  local window = selectedWindow or focusedTarget()
  if not window then return notify("Focus a ChatGPT window first") end
  context = context or contextFor(window)
  if scope == "project" and not context.project and
      (context.projectLookupStatus == "pending" or
       context.projectLookupStatus == "ambiguous") then
    return notify(context.projectLookupStatus == "pending" and
      "Codex project is still loading" or
      "Chat title belongs to multiple projects")
  end
  local newChat
  if scope == "project" and not context.chat then
    newChat = promptName("chat", context.title)
    if not newChat then return notify("Chat title is empty") end
  end
  local name
  if scope == "project" then name = context.project else name = context.chat end
  if not name then
    name = promptName(scope, scope == "chat" and context.title or nil)
    if scope == "chat" then context.source = "manual input" end
  end
  if not name then return notify(scope == "project" and "Project name is empty" or "Chat title is empty") end
  if scope == "chat" and context.source == "manual input" then
    config.windowChats[tostring(window:id())] = name
  end
  if newChat then
    config.windowChats[tostring(window:id())] = newChat
    context.chat = newChat
  end
  if scope == "project" and context.chat then config.chatProjects[context.chat] = name end
  if not core.setRule(config, scope, name, color) then return notify("Invalid color") end
  if not saveConfig() then return notify("Could not save config.json") end
  refresh()
  notify(scope .. ": " .. name .. " → " .. color)
end

clearRule = function(scope, selectedWindow)
  local window = selectedWindow or focusedTarget()
  if not window then return notify("Focus a ChatGPT window first") end
  local context = contextFor(window)
  local name
  if scope == "project" then name = context.project else name = context.chat end
  if not name then name = promptName(scope) end
  if not core.clearRule(config, scope, name) then return notify("No " .. scope .. " override") end
  if not saveConfig() then return notify("Could not save config.json") end
  refresh()
  notify("Cleared " .. scope .. " override")
end

assignProject = function(selectedWindow)
  local window = selectedWindow or focusedTarget()
  if not window then return notify("Focus a ChatGPT window first") end
  local context = contextFor(window)
  if context.projectSource == "Codex project assignment" then
    return notify("Use Project color for " .. context.project)
  end
  local chat = context.chat or promptName("chat", context.title)
  if not chat then return notify("Chat title is empty") end
  local button, answer = hs.dialog.textPrompt("Assign chat to project", chat,
    config.chatProjects[chat] or "", "Save", "Cancel")
  if button ~= "Save" then return end
  if not context.chat then config.windowChats[tostring(window:id())] = chat end
  config.chatProjects[chat] = core.clean(answer)
  if not saveConfig() then return notify("Could not save config.json") end
  refresh()
end

relabelChat = function(selectedWindow)
  local window = selectedWindow or focusedTarget()
  if not window then return notify("Focus a ChatGPT window first") end
  local context = contextFor(window)
  local name = promptName("chat", context.chat)
  if not name then return notify("Chat title is empty") end
  config.windowChats[tostring(window:id())] = name
  if not saveConfig() then return notify("Could not save config.json") end
  refresh()
  notify("Window label: " .. name)
end

local function applyThickness(value, quiet)
  value = tonumber(value)
  if not value or value % 1 ~= 0 or value < 1 or value > 12 then
    if not quiet then notify("Enter a whole number from 1 to 12") end
    return false
  end
  if value == config.thickness then return true end
  local previous = config.thickness
  config.thickness = value
  if not saveConfig() then
    config.thickness = previous
    notify("Could not save config.json")
    return false
  end
  if config.renderer == "borders" and borderAvailable() then startBorders() end
  refresh()
  if not quiet then notify("Indicator thickness: " .. value .. " pt") end
  return true
end

local function applyInsideSetting(key, value, maximum)
  value = tonumber(value)
  if not value or value % 1 ~= 0 or value < 0 or value > maximum then return false end
  if value == config[key] then return true end
  local previous = config[key]
  config[key] = value
  if not saveConfig() then
    config[key] = previous
    notify("Could not save config.json")
    return false
  end
  refresh()
  return true
end

local function resetBorderState()
  for _, applied in pairs(borderApplied) do
    if applied.task then applied.task:terminate() end
  end
  for _, cleared in pairs(borderCleared) do
    if cleared.task then cleared.task:terminate() end
  end
  borderApplied = {}
  borderCleared = {}
end

local function setPlacement(mode, quiet)
  if mode ~= "inside" and mode ~= "borders" and mode ~= "canvas" then return false end
  if mode == "borders" and not borderAvailable() then
    notify("Install JankyBorders to use Outside")
    return false
  end
  if config.renderer == mode then return true end
  local previous = config.renderer
  config.renderer = mode
  if not saveConfig() then
    config.renderer = previous
    notify("Could not save config.json")
    return false
  end
  resetBorderState()
  if mode == "borders" then startBorders() end
  refresh()
  if not quiet then
    notify(mode == "inside" and "Color moved inside the window" or
      mode == "borders" and "Outside border enabled" or "Top strip enabled")
  end
  return true
end

setThickness = function()
  local button, answer = hs.dialog.textPrompt("Indicator thickness",
    "Indicator thickness in points (1–12)", tostring(config.thickness), "Save", "Cancel")
  if button ~= "Save" then return end
  applyThickness(answer, false)
end

status = function(selectedWindow)
  local window = selectedWindow or focusedTarget()
  if not window then return notify("Focus a ChatGPT window first") end
  local context = contextFor(window)
  local color, source, project = core.resolve(config, context)
  local message = string.format("Chat: %s\nProject: %s\nProject source: %s\nColor: %s (%s)\nPlacement: %s\nInner fade: %d pt\nLine opacity: %d%%\nRead from: %s\nWindow ID: %s",
    context.chat or "unavailable", project or "unavailable",
    context.projectSource or "unavailable", color, source,
    config.renderer, config.fadeWidth, config.lineOpacity,
    context.source, tostring(context.windowId))
  hs.dialog.blockAlert("ChatGPT window color", message, "OK")
end

local PANEL_W, PANEL_H = 336, 478
local PANEL_BG, SURFACE, TEXT, MUTED = "#1F252D", "#2C3540", "#F4F7FA", "#AEB9C5"

local function addBox(items, id, x, y, w, h, fill, radius, stroke)
  items[#items + 1] = {type = "rectangle", id = id, action = "fill",
    frame = {x = x, y = y, w = w, h = h}, fillColor = {hex = fill},
    roundedRectRadii = {xRadius = radius or 8, yRadius = radius or 8},
    strokeColor = stroke and {hex = stroke} or nil, strokeWidth = stroke and 1 or nil,
    trackMouseUp = id ~= nil}
end

local function addText(items, label, x, y, w, h, size, color, alignment, id)
  items[#items + 1] = {type = "text", id = id, text = label,
    frame = {x = x, y = y, w = w, h = h}, textSize = size,
    textColor = {hex = color or TEXT}, textAlignment = alignment or "left",
    textLineBreak = "truncateTail", trackMouseUp = id ~= nil}
end

closePanel = function()
  panelWindowId = nil
  panelFrame = nil
  if panel then panel:hide() end
  if panelDismissTap then panelDismissTap:stop(); panelDismissTap = nil end
  hoverRefresh()
end

renderPanel = function()
  if not panelWindowId then return end
  local window = hs.window.get(panelWindowId)
  if not isTarget(window) then return closePanel() end
  local frame = window:frame()
  if not frame then return closePanel() end
  panelFrame = {x = frame.x + (frame.w - PANEL_W) / 2,
    y = frame.y + 44, w = PANEL_W, h = PANEL_H}
  local context = contextFor(window)
  local color, source, project = core.resolve(config, context)
  local scopeName
  if panelScope == "chat" then scopeName = context.chat else scopeName = project end
  local rule = scopeName and config[panelScope == "chat" and "chatRules" or "projectRules"][scopeName]
  local items = {}
  addBox(items, nil, 0, 0, PANEL_W, PANEL_H, PANEL_BG, 14, "#5B6875")
  addBox(items, nil, 14, 14, 7, 42, color, 3)
  addText(items, "Window color", 32, 13, 236, 27, 19, TEXT)
  addText(items, context.chat or "Unnamed chat", 32, 40, 257, 19, 11, MUTED)
  addText(items, "Project: " .. (project or "unavailable") .. " · " ..
    (context.projectSource or "unknown"), 32, 58, 280, 15, 10, MUTED)
  addBox(items, "close", 292, 17, 30, 30, SURFACE, 8)
  addText(items, "×", 292, 17, 30, 27, 23, MUTED, "center", "close")

  addText(items, "APPLY COLOR TO", 17, 75, 180, 17, 10, MUTED)
  addBox(items, "scope:chat", 16, 96, 149, 34,
    panelScope == "chat" and "#435262" or SURFACE, 8)
  addBox(items, "scope:project", 171, 96, 149, 34,
    panelScope == "project" and "#435262" or SURFACE, 8)
  addText(items, "This chat", 16, 102, 149, 23, 13, TEXT, "center", "scope:chat")
  addText(items, "Project", 171, 102, 149, 23, 13, TEXT, "center", "scope:project")
  local scopeDescription = context.chat or "Name chat when choosing color"
  if panelScope == "project" then
    scopeDescription = project or
      (context.projectLookupStatus == "pending" and "Finding Codex project…" or
       context.projectLookupStatus == "ambiguous" and "Same title in multiple projects" or
       "Name manual project fallback when choosing color")
  end
  addText(items, scopeDescription, 18, 140, 300, 20, 11, MUTED)

  addText(items, "CHOOSE A COLOR", 17, 168, 180, 17, 10, MUTED)
  local valid = {}
  for _, hex in ipairs(config.palette) do if core.validColor(hex) then valid[#valid + 1] = hex end end
  local count = math.min(#valid, 8)
  for index = 1, count do
    local x = 17 + (index - 1) * 38
    local selected = rule and rule:lower() == valid[index]:lower()
    addBox(items, "color:" .. index, x, 190, 32, 32, valid[index], 9,
      selected and TEXT or "#52606C")
  end

  addBox(items, "clear", 16, 235, 304, 32, SURFACE, 8)
  addText(items, rule and "↺  Use automatic color" or "Automatic color active",
    27, 241, 274, 21, 12, rule and TEXT or MUTED, nil, "clear")
  addText(items, "Placement", 17, 283, 88, 20, 12, TEXT)
  addBox(items, "placement:inside", 107, 277, 101, 32,
    config.renderer == "inside" and "#435262" or SURFACE, 8)
  addBox(items, "placement:outside", 214, 277, 106, 32,
    config.renderer == "borders" and "#435262" or SURFACE, 8)
  addText(items, "Inside", 107, 283, 101, 21, 12, TEXT, "center", "placement:inside")
  addText(items, "Outside", 214, 283, 106, 21, 12, TEXT, "center", "placement:outside")
  addText(items, "Thickness", 17, 332, 116, 20, 12, TEXT)
  addBox(items, "thickness:minus", 190, 326, 30, 29, SURFACE, 8)
  addText(items, "−", 190, 328, 30, 20, 16, TEXT, "center", "thickness:minus")
  addText(items, tostring(config.thickness) .. " pt", 222, 330, 58, 20, 12, TEXT, "center")
  addBox(items, "thickness:plus", 287, 326, 30, 29, SURFACE, 8)
  addText(items, "+", 287, 328, 30, 20, 16, TEXT, "center", "thickness:plus")
  addText(items, "Inner fade", 17, 372, 116, 20, 12, TEXT)
  addBox(items, "fade:minus", 190, 366, 30, 29, SURFACE, 8)
  addText(items, "−", 190, 368, 30, 20, 16, TEXT, "center", "fade:minus")
  addText(items, tostring(config.fadeWidth) .. " pt", 222, 370, 58, 20, 12, TEXT, "center")
  addBox(items, "fade:plus", 287, 366, 30, 29, SURFACE, 8)
  addText(items, "+", 287, 368, 30, 20, 16, TEXT, "center", "fade:plus")
  addText(items, "Line opacity", 17, 412, 116, 20, 12, TEXT)
  addBox(items, "opacity:minus", 190, 406, 30, 29, SURFACE, 8)
  addText(items, "−", 190, 408, 30, 20, 16, TEXT, "center", "opacity:minus")
  addText(items, tostring(config.lineOpacity) .. "%", 222, 410, 58, 20, 12, TEXT, "center")
  addBox(items, "opacity:plus", 287, 406, 30, 29, SURFACE, 8)
  addText(items, "+", 287, 408, 30, 20, 16, TEXT, "center", "opacity:plus")
  addText(items, "Esc or click outside to close", 17, 450, 302, 18, 10, MUTED, "center")
  if not panel then
    panel = hs.canvas.new(panelFrame)
    panel:level("floating")
    panel:behaviorAsLabels({"canJoinAllSpaces", "ignoresCycle"})
    panel:clickActivating(false)
  else
    panel:frame(panelFrame)
  end
  panel:mouseCallback(function(_, message, id)
      if message ~= "mouseUp" or not id then return end
      if id == "close" then return closePanel() end
      if id == "scope:chat" or id == "scope:project" then
        panelScope = id:sub(7); return renderPanel()
      end
      if id == "placement:inside" or id == "placement:outside" then
        setPlacement(id == "placement:inside" and "inside" or "borders", true)
        return renderPanel()
      end
      if id == "thickness:minus" or id == "thickness:plus" then
        applyThickness(config.thickness + (id == "thickness:plus" and 1 or -1), true)
        return renderPanel()
      end
      if id == "fade:minus" or id == "fade:plus" then
        applyInsideSetting("fadeWidth", config.fadeWidth + (id == "fade:plus" and 2 or -2), 32)
        return renderPanel()
      end
      if id == "opacity:minus" or id == "opacity:plus" then
        applyInsideSetting("lineOpacity", config.lineOpacity + (id == "opacity:plus" and 10 or -10), 100)
        return renderPanel()
      end
      local target = hs.window.get(panelWindowId)
      if not isTarget(target) then return closePanel() end
      if id == "clear" then
        if rule then clearRule(panelScope, target); renderPanel() end
        return
      end
      local index = tonumber(id:match("^color:(%d+)$"))
      if index and valid[index] then
        local selectedScope = panelScope
        local selectedContext = contextFor(target)
        closePanel()
        editRule(selectedScope, valid[index], target, selectedContext)
      end
  end)
  panel:replaceElements((table.unpack or unpack)(items))
  panel:show()
end

local function pointInside(point, frame)
  return frame and point and point.x >= frame.x and point.x <= frame.x + frame.w and
    point.y >= frame.y and point.y <= frame.y + frame.h
end

local function openPanel(window, scope)
  window = window or focusedTarget()
  if not isTarget(window) then return notify("Focus a ChatGPT window first") end
  if panelWindowId then closePanel() end
  panelWindowId = window:id()
  panelScope = scope or "chat"
  renderPanel()
  if not panelDismissTap then
    panelDismissTap = hs.eventtap.new({hs.eventtap.event.types.keyDown,
      hs.eventtap.event.types.leftMouseDown}, function(event)
      if not panelWindowId then return false end
      if event:getType() == hs.eventtap.event.types.keyDown and
          event:getKeyCode() == hs.keycodes.map.escape then
        closePanel()
        return true
      end
      if event:getType() == hs.eventtap.event.types.leftMouseDown then
        local point = event:location()
        local frame = windowFrames[panelWindowId] or window:frame()
        local iconFrame = frame and {x = frame.x + (frame.w - 48) / 2,
          y = frame.y + 8, w = 48, h = 28}
        if not pointInside(point, panelFrame) and not pointInside(point, iconFrame) then
          closePanel()
        end
      end
      return false
    end)
    if panelDismissTap then panelDismissTap:start() end
  end
  hoverRefresh()
end

togglePanel = function(window)
  if panelWindowId == window:id() then closePanel()
  else openPanel(window, "chat") end
end

local function openConfig()
  hs.open(CONFIG_PATH)
end

local function reloadConfig()
  local previousRenderer = config.renderer
  config = loadConfig()
  if config.renderer ~= previousRenderer then resetBorderState() end
  if config.renderer == "borders" then startBorders() end
  refresh()
end

local function buildMenu()
  return {
    {title = "Current ChatGPT Window…", fn = status},
    {title = "Set chat color…", fn = function() openPanel(nil, "chat") end},
    {title = "Change current window's chat label…", fn = function() relabelChat() end},
    {title = "Set project color…", fn = function() openPanel(nil, "project") end},
    {title = "Assign manual project fallback…", fn = assignProject},
    {title = "Clear chat override", fn = function() clearRule("chat") end},
    {title = "Clear project override", fn = function() clearRule("project") end},
    {title = "Place color inside window", fn = function() setPlacement("inside") end},
    {title = "Place color outside window", fn = function() setPlacement("borders") end},
    {title = "Adjust border/strip thickness…", fn = setThickness},
    {title = "Open config.json", fn = openConfig},
    {title = "Reload config.json", fn = reloadConfig},
  }
end

function M.start()
  if timer then return M end
  config = loadConfig()
  if not hs.fs.attributes(CONFIG_PATH) then saveConfig() end
  startBorders()
  menu = hs.menubar.new()
  menu:setTitle("🎨")
  menu:setMenu(buildMenu)
  hotkeys[#hotkeys + 1] = hs.hotkey.bind({"alt", "cmd"}, "C", function() openPanel(nil, "chat") end)
  hotkeys[#hotkeys + 1] = hs.hotkey.bind({"alt", "cmd"}, "P", function() openPanel(nil, "project") end)
  hotkeys[#hotkeys + 1] = hs.hotkey.bind({"alt", "cmd"}, "0", function() clearRule("chat") end)
  -- Native AX/window-order queries can throw while windows disappear. Keep
  -- polling so one transient error cannot freeze floating overlays indefinitely.
  timer = hs.timer.doEvery(1.2, scheduledRefresh, true)
  hoverTimer = hs.timer.doEvery(0.12, hoverRefresh, true)
  geometryTimer = hs.timer.doEvery(0.15, function()
    if fastGeometryTimer and not fastGeometryTimer:running() then
      fastGeometryTimer = nil
    end
    if not fastGeometryTimer then geometryRefresh() end
  end, true)
  dragTap = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown,
    hs.eventtap.event.types.leftMouseDragged, hs.eventtap.event.types.leftMouseUp},
    function(event)
      if config.renderer ~= "inside" then return false end
      local eventType = event:getType()
      if eventType == hs.eventtap.event.types.leftMouseDown then
        draggingColorWindow = false
        local point = event:location()
        for _, window in ipairs(hoverCandidates) do
          if pointInside(point, windowFrames[window:id()]) then
            draggingColorWindow = true
            break
          end
        end
        if draggingColorWindow then activateFastGeometry(hs.timer.secondsSinceEpoch()) end
      elseif eventType == hs.eventtap.event.types.leftMouseDragged and
          not draggingColorWindow then
        local point = event:location()
        for _, window in ipairs(hoverCandidates) do
          if pointInside(point, windowFrames[window:id()]) then
            draggingColorWindow = true
            activateFastGeometry(hs.timer.secondsSinceEpoch())
            break
          end
        end
      elseif draggingColorWindow then
        -- Let the app process this mouse event before reading its new frame.
        activateFastGeometry(hs.timer.secondsSinceEpoch())
        if eventType == hs.eventtap.event.types.leftMouseUp then
          draggingColorWindow = false
        end
      end
      return false
    end)
  if dragTap then dragTap:start() end
  if hs.spaces.watcher then
    spaceWatcher = hs.spaces.watcher.new(function()
      spaceRevision = spaceRevision + 1
      local revision = spaceRevision
      orderedWindows = nil
      spaceTransitionUntil = hs.timer.secondsSinceEpoch() + 0.15
      for id in pairs(innerEdges) do hideInner(id) end
      for _, tab in pairs(hoverTabs) do tab:hide() end
      if spaceRefreshTimer then spaceRefreshTimer:stop() end
      spaceRefreshTimer = hs.timer.doAfter(0.15, function()
        spaceRefreshTimer = nil
        if revision ~= spaceRevision then return end
        spaceTransitionUntil = 0
        refresh()
      end)
    end):start()
  end
  refresh()
  return M
end

function M.stop()
  closePanel()
  if panel then panel:delete(); panel = nil end
  if timer then timer:stop(); timer = nil end
  if hoverTimer then hoverTimer:stop(); hoverTimer = nil end
  if geometryTimer then geometryTimer:stop(); geometryTimer = nil end
  if fastGeometryTimer then fastGeometryTimer:stop(); fastGeometryTimer = nil end
  if dragTap then dragTap:stop(); dragTap = nil end
  draggingColorWindow = false
  fastUntil = 0
  if spaceWatcher then spaceWatcher:stop(); spaceWatcher = nil end
  if spaceRefreshTimer then spaceRefreshTimer:stop(); spaceRefreshTimer = nil end
  for _, task in pairs(projectLookupTasks) do task:terminate() end
  projectLookupTasks = {}
  projectLookups = {}
  orderedWindows = nil
  orderedAt = -10
  orderedFocusId = nil
  orderedFrontPid = nil
  spaceTransitionUntil = 0
  for _, key in ipairs(hotkeys) do key:delete() end
  hotkeys = {}
  if menu then menu:delete(); menu = nil end
  local allIds = {}
  for id in pairs(overlays) do allIds[#allIds + 1] = id end
  for id in pairs(innerEdges) do allIds[#allIds + 1] = id end
  for id in pairs(hoverTabs) do allIds[#allIds + 1] = id end
  local removed = {}
  for _, id in ipairs(allIds) do if not removed[id] then discard(id); removed[id] = true end end
  if borderTask then borderTask:terminate(); borderTask = nil end
  if borderConfigTask then borderConfigTask:terminate(); borderConfigTask = nil end
  resetBorderState()
end

M.refresh = refresh
M.status = status
M.contextFor = contextFor
M.openPanel = openPanel
M.closePanel = closePanel
M.setPlacement = setPlacement
M.panelState = function() return panelWindowId, panelFrame end
M.panelImage = function() return panel and panel:imageFromCanvas() end
return M
