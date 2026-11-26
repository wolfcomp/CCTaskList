-- Pager: prints replies wrapped to the terminal and paused a screenful at a time, so long
-- output (help especially) never scrolls out of view on a 26x20 pocket computer.

local M = {}

local function setColor(c)
  if term.isColour() then term.setTextColor(c) end
end

local function wrap(text, width)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    while #word > width do
      if #line > 0 then lines[#lines + 1] = line; line = "" end
      lines[#lines + 1] = word:sub(1, width)
      word = word:sub(width + 1)
    end
    if #line == 0 then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = word
    end
  end
  if #line > 0 or #lines == 0 then lines[#lines + 1] = line end
  return lines
end

local function setBackground(c)
  if term.isColour() then term.setBackgroundColor(c) end
end

local function navText(page, pages, w)
  local long = ("Page %d/%d  Space: next  B: back  Q: done"):format(page, pages)
  if #long <= w then return long end
  return (("%d/%d Space B:back Q:done"):format(page, pages)):sub(1, w)
end

-- The bottom row belongs to navigation while paging and to the prompt afterwards, so a page
-- is always exactly h - 1 rows and never scrolls under either of them.
local function drawPage(rows, page, pageRows, w, h, pages)
  setBackground(colors.black)
  term.clear()
  local first = (page - 1) * pageRows
  for r = 1, pageRows do
    local row = rows[first + r]
    if not row then break end
    term.setCursorPos(1, r)
    setColor(row.color)
    term.write(row.text)
  end
  term.setCursorPos(1, h)
  setBackground(colors.gray)
  setColor(colors.white)
  term.clearLine()
  term.write(navText(page, pages, w))
  setBackground(colors.black)
end

local NEXT_KEYS = { [keys.space] = true, [keys.enter] = true, [keys.down] = true, [keys.pageDown] = true, [keys.n] = true }
local BACK_KEYS = { [keys.b] = true, [keys.up] = true, [keys.pageUp] = true, [keys.p] = true }

local function page(rows, w, h)
  local pageRows = h - 1
  local pages = math.ceil(#rows / pageRows)
  local current = 1
  drawPage(rows, current, pageRows, w, h, pages)
  while true do
    local _, key = os.pullEvent("key")
    local target = current
    if NEXT_KEYS[key] then
      target = current + 1
    elseif BACK_KEYS[key] then
      target = math.max(1, current - 1)
    elseif key == keys.q then
      target = pages + 1
    end
    if target > pages then
      -- Swallow the char event the key press also produced, or it would be typed into the prompt.
      repeat local ev = os.pullEvent() until ev == "key_up"
      break
    end
    if target ~= current then
      current = target
      drawPage(rows, current, pageRows, w, h, pages)
    end
  end
  -- Leave the last page on rows 1..h-1 and hand the bottom row back for typing.
  term.setCursorPos(1, h)
  setBackground(colors.black)
  term.clearLine()
  setColor(colors.white)
end

-- items: { { text = "...", color = colors.white, indent = 0 }, ... }
function M.print(items)
  local w, h = term.getSize()
  local rows = {}
  for _, item in ipairs(items) do
    local indent = item.indent or 0
    for _, l in ipairs(wrap(item.text, math.max(1, w - indent))) do
      rows[#rows + 1] = { text = (" "):rep(indent) .. l, color = item.color or colors.white }
    end
  end

  if #rows > h - 1 and h > 1 then
    page(rows, w, h)
    return
  end
  for _, row in ipairs(rows) do
    setColor(row.color)
    print(row.text)
  end
  setColor(colors.white)
end

function M.lines(lines, color)
  local items = {}
  for i, l in ipairs(lines) do items[i] = { text = l, color = color } end
  M.print(items)
end

-- Help lines look like "usage - description". On screens too narrow for that on one line,
-- the description goes underneath, indented, so commands stay easy to scan.
function M.help(lines)
  local w = term.getSize()
  local items = {}
  for _, l in ipairs(lines) do
    local usage, desc = l:match("^(.-) %- (.*)$")
    if usage and #l > w then
      items[#items + 1] = { text = usage, color = colors.yellow }
      items[#items + 1] = { text = desc, color = colors.white, indent = 2 }
    elseif usage then
      items[#items + 1] = { text = l, color = colors.white }
    else
      items[#items + 1] = { text = l, color = colors.lightGray }
    end
  end
  M.print(items)
end

return M
