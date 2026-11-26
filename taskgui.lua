-- Task GUI: clickable front end for the tasks client on advanced computers and pocket computers.
--
-- Layout (26x20 pocket shown, scales to any size):
--   row 1        header: < person > x      (tap the name to manage people)
--   rows 2..h-3  task list                 (tap a task to select it, scroll if long)
--   rows h-2,h-1 action buttons
--   row h        status line, also the typing line for text input

local pager = require("pager")

local M = {}

local POLL_SECONDS = 30
-- CC's font has CP437 glyphs at these codes.
local ARROW_LEFT, ARROW_RIGHT, ARROW_UP, ARROW_DOWN = "\17", "\16", "\30", "\31"

-- ctx: state = { people = ... } (kept current by the caller), send(line) -> ok, out | nil, err,
--      requestState(), me() -> name|nil, remember(name|nil)
function M.run(ctx)
  local w, h = term.getSize()
  local mode = "main" -- or "people"
  local selPerson, selTask
  local scroll = { main = 0, people = 0 }
  local status, statusColor = "Tap a task to select it", colors.lightGray
  local confirm -- { question = "...", action = function }
  local hits = {}
  local quit = false

  local function people() return ctx.state.people or {} end

  local function same(a, b) return a ~= nil and b ~= nil and a:lower() == b:lower() end

  local function findPerson(name)
    for i, p in ipairs(people()) do
      if same(p.name, name) then return p, i end
    end
  end

  -- Falls back to "me" or the first person when the selected one was removed elsewhere.
  local function selected()
    local p = findPerson(selPerson)
    if not p then
      p = findPerson(ctx.me()) or people()[1]
      selPerson, selTask = p and p.name, nil
    end
    if p and selTask and not p.tasks[selTask] then selTask = nil end
    return p
  end

  local function setStatus(s, color)
    status, statusColor = s or "", color or colors.lightGray
  end

  -- Drawing -----------------------------------------------------------------

  local function fill(x, y, width, bg)
    if width < 1 then return end
    term.setCursorPos(x, y)
    term.setBackgroundColor(bg)
    term.write((" "):rep(width))
  end

  local function text(x, y, s, fg, bg)
    term.setCursorPos(x, y)
    term.setTextColor(fg)
    term.setBackgroundColor(bg)
    term.write(s)
  end

  local function hit(x0, x1, y, action)
    hits[#hits + 1] = { x0 = x0, x1 = x1, y = y, action = action }
  end

  -- A nil action draws the button greyed out and unclickable.
  local function button(x0, x1, y, label, action, bg, fg)
    if not action then bg, fg = colors.gray, colors.lightGray end
    local width = x1 - x0 + 1
    fill(x0, y, width, bg)
    label = label:sub(1, width)
    text(x0 + math.floor((width - #label) / 2), y, label, fg, bg)
    if action then hit(x0, x1, y, action) end
  end

  -- defs: { { label, action, bg, fg }, ... }
  local function buttonRow(y, defs)
    local n = #defs
    for i, d in ipairs(defs) do
      local x0 = math.floor((i - 1) * w / n) + 1
      local x1 = math.floor(i * w / n)
      -- A one-column gap keeps neighbouring buttons readable as separate targets.
      if i < n then x1 = x1 - 1 end
      button(x0, x1, y, d[1], d[2], d[3] or colors.lightGray, d[4] or colors.black)
    end
  end

  local function messageRows(s)
    local rows = {}
    for _, l in ipairs(pager.wrap(s, w - 1)) do rows[#rows + 1] = { text = l, fg = colors.lightGray } end
    return rows
  end

  -- rows: { { text, fg, bg, prefix, prefixFg, action }, ... }; the last column is kept for
  -- the scroll bar so wrapping doesn't depend on whether the list overflows.
  local function drawList(rows, top, bottom, key)
    local height = bottom - top + 1
    if height < 1 then return end
    local width = w - 1
    local maxScroll = math.max(0, #rows - height)
    scroll[key] = math.max(0, math.min(scroll[key], maxScroll))

    for r = 0, height - 1 do
      local row, y = rows[scroll[key] + r + 1], top + r
      if row then
        local bg = row.bg or colors.black
        fill(1, y, width, bg)
        term.setCursorPos(1, y)
        term.setBackgroundColor(bg)
        local used = 0
        if row.prefix then
          term.setTextColor(row.prefixFg or row.fg or colors.white)
          term.write(row.prefix)
          used = #row.prefix
        end
        term.setTextColor(row.fg or colors.white)
        term.write(row.text:sub(1, width - used))
        if row.action then hit(1, width, y, row.action) end
      end
    end

    if maxScroll > 0 then
      local step = math.max(1, height - 1)
      for y = top, bottom do fill(w, y, 1, colors.gray) end
      local canUp, canDown = scroll[key] > 0, scroll[key] < maxScroll
      text(w, top, ARROW_UP, canUp and colors.white or colors.lightGray, colors.gray)
      text(w, bottom, ARROW_DOWN, canDown and colors.white or colors.lightGray, colors.gray)
      if canUp then hit(w, w, top, function() scroll[key] = scroll[key] - step end) end
      if canDown then hit(w, w, bottom, function() scroll[key] = scroll[key] + step end) end
    end
  end

  local function drawStatus()
    fill(1, h, w, colors.black)
    text(1, h, status:sub(1, w), statusColor, colors.black)
  end

  -- Actions -----------------------------------------------------------------

  local function run(line)
    setStatus("Sending...")
    drawStatus()
    local ok, out = ctx.send(line)
    if ok == nil then
      setStatus(out, colors.red)
    else
      setStatus(out[1] or (ok and "OK" or "Failed"), ok and colors.lime or colors.red)
    end
  end

  -- Reads a line on the bottom row; blank input cancels.
  local function input(label)
    fill(1, h - 1, w, colors.black)
    text(1, h - 1, ("Type, Enter. Blank cancels"):sub(1, w), colors.lightGray, colors.black)
    fill(1, h, w, colors.black)
    text(1, h, label, colors.yellow, colors.black)
    term.setTextColor(colors.white)
    local s = read()
    s = s and s:match("^%s*(.-)%s*$") or ""
    if s == "" then
      setStatus("Cancelled")
      return nil
    end
    return s
  end

  local function askConfirm(question, action)
    confirm = { question = question, action = action }
  end

  local function cycle(d)
    local list = people()
    local _, i = findPerson(selPerson)
    if not i then return end
    selPerson = list[(i - 1 + d) % #list + 1].name
    selTask, scroll.main = nil, 0
  end

  -- Screens -----------------------------------------------------------------

  local function drawMain()
    local p = selected()
    local me = ctx.me()
    local isMe = p and same(p.name, me)

    fill(1, 1, w, colors.blue)
    if #people() > 1 then
      button(1, 3, 1, ARROW_LEFT, function() cycle(-1) end, colors.blue, colors.white)
      button(w - 5, w - 3, 1, ARROW_RIGHT, function() cycle(1) end, colors.blue, colors.white)
    end
    button(w - 2, w, 1, "x", function() quit = true end, colors.red, colors.white)
    local name = p and (p.name .. (isMe and " (me)" or "")) or "People"
    button(4, w - 6, 1, name, function()
      mode = "people"
      setStatus("Tap to pick, again to open")
    end, colors.blue, colors.white)

    local rows
    if ctx.state.people == nil then
      rows = messageRows("Waiting for the hub...")
    elseif not p then
      rows = messageRows("Nobody here yet. Tap People to add someone.")
    elseif #p.tasks == 0 then
      rows = messageRows(p.name .. " is idle. Tap Add for a new task.")
    else
      rows = {}
      for i, t in ipairs(p.tasks) do
        local sel = selTask == i
        local prefix = i .. " "
        local function pick() selTask = (selTask == i) and nil or i end
        for j, l in ipairs(pager.wrap(t, math.max(1, w - 1 - #prefix))) do
          rows[#rows + 1] = {
            prefix = j == 1 and prefix or (" "):rep(#prefix),
            prefixFg = sel and colors.black or (i == 1 and colors.yellow or colors.gray),
            text = l,
            fg = sel and colors.black or (i == 1 and colors.white or colors.lightGray),
            bg = sel and colors.lightGray or colors.black,
            action = pick,
          }
        end
      end
    end
    drawList(rows, 2, h - 3, "main")

    local hasTasks = p and #p.tasks > 0
    local target = selTask or 1
    buttonRow(h - 2, {
      { "Add", p and function()
        local s = input("Task: ")
        if s then run("add " .. p.name .. " " .. s) end
      end, colors.green, colors.white },
      { selTask and ("Done #" .. target) or "Done", hasTasks and function()
        run("done " .. p.name .. " " .. target)
        selTask = nil
      end, colors.lime, colors.black },
      { selTask and ("Top #" .. target) or "Top", (selTask and selTask > 1) and function()
        run("top " .. p.name .. " " .. target)
        selTask = 1
      end },
    })
    buttonRow(h - 1, {
      { "Skip", (p and #p.tasks > 1) and function()
        run("skip " .. p.name)
        selTask = nil
      end },
      { "Clear", hasTasks and function()
        askConfirm("Clear all of " .. p.name .. "'s tasks?", function() run("clear " .. p.name) end)
      end, colors.red, colors.white },
      { isMe and "Not me" or "Me", p and function()
        if isMe then
          ctx.remember(nil)
          setStatus("Forgot who you are")
        else
          ctx.remember(p.name)
          setStatus("You are " .. p.name .. " now", colors.lime)
        end
      end, colors.purple, colors.white },
    })
  end

  local function drawPeople()
    fill(1, 1, w, colors.blue)
    local title = "People"
    text(math.floor((w - #title) / 2) + 1, 1, title, colors.white, colors.blue)

    local me = ctx.me()
    local current = selected()
    local rows = {}
    for _, p in ipairs(people()) do
      local sel = current and same(p.name, current.name)
      local label = p.name .. (same(p.name, me) and " (me)" or "")
      local count = #p.tasks == 0 and "idle" or tostring(#p.tasks)
      local pad = math.max(1, (w - 1) - #label - #count)
      rows[#rows + 1] = {
        text = label .. (" "):rep(pad) .. count,
        fg = sel and colors.black or colors.white,
        bg = sel and colors.lightGray or colors.black,
        action = function()
          if sel then
            mode, scroll.main = "main", 0
          else
            selPerson, selTask = p.name, nil
          end
        end,
      }
    end
    if #rows == 0 then rows = messageRows("Nobody here yet. Tap New.") end
    drawList(rows, 2, h - 2, "people")

    buttonRow(h - 1, {
      { "New", function()
        local s = input("Name: ")
        if not s then return end
        if not s:match("^%S+$") then
          setStatus("Names must be one word", colors.red)
          return
        end
        run("addperson " .. s)
        selPerson, selTask = s, nil
      end, colors.green, colors.white },
      { "Remove", current and function()
        local name = current.name
        askConfirm("Remove " .. name .. " and all their tasks?", function() run("delperson " .. name) end)
      end, colors.red, colors.white },
      { "Open", current and function() mode, scroll.main = "main", 0 end },
    })
  end

  local function drawConfirm()
    -- Only Yes/No are live while asking; a tap anywhere else cancels.
    hits = {}
    local lines = pager.wrap(confirm.question, w)
    if #lines > 2 then lines = { lines[1], lines[2] } end
    for i = #lines, 1, -1 do
      local y = h - 2 - (#lines - i)
      fill(1, y, w, colors.orange)
      text(1, y, lines[i], colors.black, colors.orange)
    end
    buttonRow(h - 1, {
      { "Yes", function()
        local action = confirm.action
        confirm = nil
        action()
      end, colors.red, colors.white },
      { "No", function()
        confirm = nil
        setStatus("Cancelled")
      end },
    })
  end

  local function redraw()
    w, h = term.getSize()
    hits = {}
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.clear()
    if mode == "people" then drawPeople() else drawMain() end
    if confirm then drawConfirm() end
    drawStatus()
  end

  local function click(x, y)
    for i = #hits, 1, -1 do
      local t = hits[i]
      if y == t.y and x >= t.x0 and x <= t.x1 then
        t.action()
        return
      end
    end
    if confirm then
      confirm = nil
      setStatus("Cancelled")
    end
  end

  -- Event loop ----------------------------------------------------------------

  ctx.requestState()
  local poll = os.startTimer(POLL_SECONDS)
  redraw()
  while not quit do
    local ev, a, b, c = os.pullEvent()
    local dirty = true
    if ev == "mouse_click" then
      click(b, c)
    elseif ev == "mouse_scroll" then
      scroll[mode] = scroll[mode] + a
    elseif ev == "key" and (a == keys.up or a == keys.down) then
      scroll[mode] = scroll[mode] + (a == keys.up and -1 or 1)
    elseif ev == "timer" and a == poll then
      ctx.requestState()
      poll = os.startTimer(POLL_SECONDS)
      dirty = false
    elseif ev ~= "task_state" and ev ~= "term_resize" then
      dirty = false
    end
    if dirty and not quit then redraw() end
  end

  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

return M
