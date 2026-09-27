local M = {}

M.defaultPalette = {
  "#E06C75", "#D19A66", "#E5C07B", "#98C379",
  "#56B6C2", "#61AFEF", "#C678DD", "#BE8CFF",
}

function M.clean(value)
  if type(value) ~= "string" then return nil end
  local result = value:match("^%s*(.-)%s*$")
  if result == "" then return nil end
  return result
end

function M.validColor(value)
  return type(value) == "string" and
    (value:match("^#%x%x%x%x%x%x$") ~= nil or value:match("^#%x%x%x$") ~= nil)
end

local function hash(text)
  local result = 0
  for index = 1, #text do
    result = (result * 31 + text:byte(index)) % 2147483647
  end
  return result
end

function M.resolve(config, context)
  local chat = M.clean(context.chat)
  local project = M.clean(context.project)
  if not project and chat and context.projectLookupStatus ~= "pending" and
      context.projectLookupStatus ~= "ambiguous" then
    local savedProject = M.clean((config.chatProjects or {})[chat])
    if not M.validColor(savedProject) then project = savedProject end
  end
  local chatRule = chat and (config.chatRules or {})[chat]
  if M.validColor(chatRule) then return chatRule, "chat", project end
  local projectRule = project and (config.projectRules or {})[project]
  if M.validColor(projectRule) then return projectRule, "project", project end
  local palette = config.palette or M.defaultPalette
  if type(palette) ~= "table" or #palette == 0 then palette = M.defaultPalette end
  local key = project or chat or tostring(context.windowId or "window")
  local color = palette[(hash(key) % #palette) + 1]
  if not M.validColor(color) then color = M.defaultPalette[(hash(key) % #M.defaultPalette) + 1] end
  return color, "auto", project
end

function M.setRule(config, scope, name, color)
  name = M.clean(name)
  if not name or not M.validColor(color) then return false end
  if scope == "chat" then
    config.chatRules = config.chatRules or {}
    config.chatRules[name] = color
  elseif scope == "project" then
    config.projectRules = config.projectRules or {}
    config.projectRules[name] = color
  else
    return false
  end
  return true
end

function M.clearRule(config, scope, name)
  name = M.clean(name)
  if not name then return false end
  local rules = scope == "chat" and config.chatRules or scope == "project" and config.projectRules
  if not rules or rules[name] == nil then return false end
  rules[name] = nil
  return true
end

-- Return the portions of a canvas band that are not covered by windows above it.
function M.visibleRects(rect, occluders)
  local pieces = {{x = rect.x, y = rect.y, w = rect.w, h = rect.h}}
  for _, cover in ipairs(occluders or {}) do
    local nextPieces = {}
    for _, piece in ipairs(pieces) do
      local left = math.max(piece.x, cover.x)
      local top = math.max(piece.y, cover.y)
      local right = math.min(piece.x + piece.w, cover.x + cover.w)
      local bottom = math.min(piece.y + piece.h, cover.y + cover.h)
      if right <= left or bottom <= top then
        nextPieces[#nextPieces + 1] = piece
      else
        if top > piece.y then
          nextPieces[#nextPieces + 1] = {x = piece.x, y = piece.y,
            w = piece.w, h = top - piece.y}
        end
        if bottom < piece.y + piece.h then
          nextPieces[#nextPieces + 1] = {x = piece.x, y = bottom,
            w = piece.w, h = piece.y + piece.h - bottom}
        end
        if left > piece.x then
          nextPieces[#nextPieces + 1] = {x = piece.x, y = top,
            w = left - piece.x, h = bottom - top}
        end
        if right < piece.x + piece.w then
          nextPieces[#nextPieces + 1] = {x = right, y = top,
            w = piece.x + piece.w - right, h = bottom - top}
        end
      end
    end
    pieces = nextPieces
    if #pieces == 0 then break end
  end
  return pieces
end

return M
