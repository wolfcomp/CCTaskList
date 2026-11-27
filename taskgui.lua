-- Task GUI: clickable front end for the hub, display nodes and the tasks client on advanced
-- computers and pocket computers, and on touch monitors.
--
-- Layout (26x20 pocket shown, scales to any size):
--   row 1        header: < person > + x    (tap the name to manage people, + adds one)
--   rows 2..h-3  task list                 (tap a task to select it, scroll if long)
--   rows h-2,h-1 action buttons             (row h-3 too when the caller adds extras)
--   row h        status line, also the typing line for text input

local pager = require("pager")

local M = {}

local POLL_SECONDS = 30
-- CC's font has CP437 glyphs at these codes.
local ARROW_LEFT, ARROW_RIGHT, ARROW_UP, ARROW_DOWN, SHIFT = "\17", "\16", "\30", "\31", "\24"
-- Monitors have no keyboard, so text is typed on these keys instead.
local KEY_ROWS = { "1234567890", "qwertyuiop", "asdfghjkl-", "zxcvbnm,.'" }

-- Shared with tasks.lua, so the hub, display nodes and clients all remember "me" the same way.
local PERSON_SETTING = "tasks.person"

settings.define(PERSON_SETTING, {
  description = "Person the tasks client acts as when no name is given",
  type = "string",
})

local function defaultMe()
  local name = settings.get(PERSON_SETTING)
  if name and name ~= "" then return name end
end

local function defaultRemember(name)
  if name then
    settings.set(PERSON_SETTING, name)
  else
    settings.unset(PERSON_SETTING)
  end
  settings.save()
end

-- ctx: state = { people = ... } (kept current by the caller), send(line) -> ok, out | nil, err,
--      requestState(), me() -> name|nil, remember(name|nil) (both default to the
--      tasks.person setting), status, statusColor (optional first status line),
--      extras = { { label, action, confirm }, ... } (optional extra button row on the main
--      screen; action() runs on a cleared screen and returns quit, status, statusColor),
--      term + touch (draw on that redirect target and take monitor_touch events from the
--      monitor named touch instead of the mouse and keyboard), person (start on them),
--      idleSeconds (close after this long without a tap)
function M.run(ctx)
  local scr = ctx.term or term
  -- A shared monitor has no single owner, so it has no "me".
  ctx.me = ctx.me or (ctx.touch and function() end) or defaultMe
  ctx.remember = ctx.remember or defaultRemember
  local w, h = scr.getSize()
  local mode = "main" -- or "people"
  local selPerson, selTask = ctx.person, nil
  local scroll = { main = 0, people = 0 }
  local status, statusColor = ctx.status or "Tap a task to select it", ctx.statusColor or colors.lightGray
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

  -- Events ------------------------------------------------------------------

  local idleTimer = ctx.idleSeconds and os.startTimer(ctx.idleSeconds)

  -- In touch mode the computer's own mouse and keyboard belong to whatever runs on its
  -- terminal, so only taps on our monitor count, and they are handed on as clicks.
  local function pull()
    while true do
      local ev, a, b, c = os.pullEvent()
      if not ctx.touch then return ev, a, b, c end
      if ev == "monitor_touch" then
        if a == ctx.touch then
          if idleTimer then idleTimer = os.startTimer(ctx.idleSeconds) end
          return "mouse_click", 1, b, c
        end
      elseif ev == "monitor_resize" then
        if a == ctx.touch then return "term_resize" end
      elseif ev == "timer" and a == idleTimer then
        return "idle"
      elseif ev ~= "mouse_click" and ev ~= "mouse_scroll" and ev ~= "key" and ev ~= "term_resize" then
        return ev, a, b, c
      end
    end
  end

  -- Drawing -----------------------------------------------------------------

  local function fill(x, y, width, bg)
    if width < 1 then return end
    scr.setCursorPos(x, y)
    scr.setBackgroundColor(bg)
    scr.write((" "):rep(width))
  end

  local function text(x, y, s, fg, bg)
    scr.setCursorPos(x, y)
    scr.setTextColor(fg)
    scr.setBackgroundColor(bg)
    scr.write(s)
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
        scr.setCursorPos(1, y)
        scr.setBackgroundColor(bg)
        local used = 0
        if row.prefix then
          scr.setTextColor(row.prefixFg or row.fg or colors.white)
          scr.write(row.prefix)
          used = #row.prefix
        end
        scr.setTextColor(row.fg or colors.white)
        scr.write(row.text:sub(1, width - used))
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

  -- Monitors are drawn off screen and shown at once, since a visible clear flickers there.
  local function hide() if scr.setVisible then scr.setVisible(false) end end
  local function show() if scr.setVisible then scr.setVisible(true) end end

  local function click(x, y)
    for i = #hits, 1, -1 do
      local hb = hits[i]
      if y == hb.y and x >= hb.x0 and x <= hb.x1 then
        hb.action()
        return
      end
    end
    if confirm then
      confirm = nil
      setStatus("Cancelled")
    end
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

  -- Full-screen on-screen keyboard. Returns the typed text, or nil when cancelled.
  -- Layout: row 1 prompt, row 2 the text so far, then the keys, then Shift/Space/Del/Cancel/OK.
  local function touchInput(label)
    local s, shift, result = "", false, nil
    local function add(ch) s = s .. ch end

    while result == nil do
      w, h = scr.getSize()
      local wide = w >= 30
      hide()
      hits = {}
      scr.setBackgroundColor(colors.black)
      scr.clear()

      fill(1, 1, w, colors.blue)
      text(1, 1, (label:gsub(":%s*$", "") .. " (tap the keys)"):sub(1, w), colors.white, colors.blue)

      local room = w - 1
      local shown = #s >= room and (ARROW_LEFT .. s:sub(-(room - 2))) or s
      fill(1, 2, w, colors.white)
      text(1, 2, shown .. "_", colors.black, colors.white)

      -- Keys grow to fill the screen so they stay easy to hit on large monitors.
      local kw = math.max(1, math.floor(w / 10))
      local kh = math.max(1, math.min(3, math.floor((h - 4) / #KEY_ROWS)))
      local gap = kw >= 3 and 1 or 0
      local x = math.floor((w - kw * 10) / 2) + 1
      for r, row in ipairs(KEY_ROWS) do
        local y0 = 3 + (r - 1) * kh
        if y0 + kh - 1 >= h then break end
        for i = 1, #row do
          local ch = row:sub(i, i)
          if shift then ch = ch:upper() end
          local x0 = x + (i - 1) * kw
          local x1 = x0 + kw - 1 - gap
          -- Alternating shades keep gapless single-column keys distinguishable.
          local light = gap == 1 or (i + r) % 2 == 0
          local bg, fg = light and colors.lightGray or colors.gray, light and colors.black or colors.white
          local function press()
            add(ch)
            shift = false
          end
          for y = y0, y0 + kh - 1 do
            button(x0, x1, y, y == y0 + math.floor((kh - 1) / 2) and ch or "", press, bg, fg)
          end
        end
      end

      buttonRow(h, {
        { wide and "Shift" or SHIFT, function() shift = not shift end, shift and colors.yellow or colors.lightGray },
        { wide and "Space" or "_", function() add(" ") end },
        { wide and "Del" or ARROW_LEFT, function() s = s:sub(1, -2) end },
        { wide and "Cancel" or "x", function() result = false end, colors.red, colors.white },
        { "OK", function() result = s end, colors.green, colors.white },
      })
      show()

      local ev, _, b, c = pull()
      if ev == "idle" then
        quit, result = true, false
      elseif ev == "mouse_click" then
        click(b, c)
      end
    end
    return result or nil
  end

  -- Reads a line on the bottom row; blank input cancels.
  local function input(label)
    local s
    if ctx.touch then
      s = touchInput(label)
    else
      fill(1, h - 1, w, colors.black)
      text(1, h - 1, ("Type, Enter. Blank cancels"):sub(1, w), colors.lightGray, colors.black)
      fill(1, h, w, colors.black)
      text(1, h, label, colors.yellow, colors.black)
      scr.setTextColor(colors.white)
      s = read()
    end
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

  local function newPerson()
    local s = input("Name: ")
    if not s then return end
    if not s:match("^%S+$") then
      setStatus("Names must be one word", colors.red)
      return
    end
    run("addperson " .. s)
    selPerson, selTask, mode, scroll.main = s, nil, "main", 0
  end

  local function cycle(d)
    local list = people()
    local _, i = findPerson(selPerson)
    if not i then return end
    selPerson = list[(i - 1 + d) % #list + 1].name
    selTask, scroll.main = nil, 0
  end

  local function extraDefs()
    local defs = {}
    for _, extra in ipairs(ctx.extras or {}) do
      local function go()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)
        local done, msg, color = extra.action()
        if done then quit = true end
        if msg then setStatus(msg, color) end
      end
      defs[#defs + 1] = { extra.label, function()
        if extra.confirm then askConfirm(extra.confirm, go) else go() end
      end, colors.cyan, colors.black }
    end
    return defs
  end

  -- Screens -----------------------------------------------------------------

  local function drawMain()
    local p = selected()
    local me = ctx.me()
    local isMe = p and same(p.name, me)

    fill(1, 1, w, colors.blue)
    -- Narrow monitors (15 columns) need one-column arrows to leave room for the name.
    local aw = w >= 20 and 3 or 1
    button(w - 2, w, 1, "x", function() quit = true end, colors.red, colors.white)
    button(w - 5, w - 3, 1, "+", newPerson, colors.green, colors.white)
    local nameL, nameR = 1, w - 6
    if #people() > 1 then
      button(1, aw, 1, ARROW_LEFT, function() cycle(-1) end, colors.blue, colors.white)
      button(w - 5 - aw, w - 6, 1, ARROW_RIGHT, function() cycle(1) end, colors.blue, colors.white)
      nameL, nameR = aw + 1, w - 6 - aw
    end
    local name = p and (p.name .. (isMe and " (me)" or "")) or "People"
    button(nameL, nameR, 1, name, function()
      mode = "people"
      setStatus("Tap to pick, again to open")
    end, colors.blue, colors.white)

    local rows
    if ctx.state.people == nil then
      rows = messageRows("Waiting for the hub...")
    elseif not p then
      rows = messageRows("Nobody here yet. Tap + or here to add someone.")
      for _, r in ipairs(rows) do r.action = newPerson end
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
    local extras = extraDefs()
    local listBottom = h - 3
    if #extras > 0 then
      listBottom = h - 4
      buttonRow(h - 3, extras)
    end
    drawList(rows, 2, listBottom, "main")

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
    local second = {
      { "Skip", (p and #p.tasks > 1) and function()
        run("skip " .. p.name)
        selTask = nil
      end },
      { "Clear", hasTasks and function()
        askConfirm("Clear all of " .. p.name .. "'s tasks?", function() run("clear " .. p.name) end)
      end, colors.red, colors.white },
    }
    if not ctx.touch then
      second[#second + 1] = { isMe and "Not me" or "Me", p and function()
        if isMe then
          ctx.remember(nil)
          setStatus("Forgot who you are")
        else
          ctx.remember(p.name)
          setStatus("You are " .. p.name .. " now", colors.lime)
        end
      end, colors.purple, colors.white }
    end
    buttonRow(h - 1, second)
  end

  local function drawPeople()
    fill(1, 1, w, colors.blue)
    local title = "People"
    text(math.max(1, math.floor((w - 6 - #title) / 2) + 1), 1, title, colors.white, colors.blue)
    button(w - 2, w, 1, "x", function() quit = true end, colors.red, colors.white)
    button(w - 5, w - 3, 1, "+", newPerson, colors.green, colors.white)

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
    if #rows == 0 then
      rows = messageRows("Nobody here yet. Tap New or here to add someone.")
      for _, r in ipairs(rows) do r.action = newPerson end
    end
    drawList(rows, 2, h - 2, "people")

    buttonRow(h - 1, {
      { "New", newPerson, colors.green, colors.white },
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
    w, h = scr.getSize()
    hits = {}
    hide()
    scr.setCursorBlink(false)
    scr.setBackgroundColor(colors.black)
    scr.clear()
    if mode == "people" then drawPeople() else drawMain() end
    if confirm then drawConfirm() end
    drawStatus()
    show()
  end

  -- Event loop ----------------------------------------------------------------

  -- Drawn first because a display node's request may block on a hub lookup.
  redraw()
  ctx.requestState()
  local poll = os.startTimer(POLL_SECONDS)
  while not quit do
    local ev, a, b, c = pull()
    local dirty = true
    if ev == "mouse_click" then
      click(b, c)
    elseif ev == "mouse_scroll" then
      scroll[mode] = scroll[mode] + a
    elseif ev == "key" and (a == keys.up or a == keys.down) then
      scroll[mode] = scroll[mode] + (a == keys.up and -1 or 1)
    elseif ev == "idle" then
      quit = true
    elseif ev == "timer" and a == poll then
      ctx.requestState()
      poll = os.startTimer(POLL_SECONDS)
      dirty = false
    -- tasks_changed comes from the hub's own saves and from display nodes receiving a push.
    elseif ev ~= "task_state" and ev ~= "tasks_changed" and ev ~= "term_resize" then
      dirty = false
    end
    if dirty and not quit then redraw() end
  end

  scr.setBackgroundColor(colors.black)
  scr.setTextColor(colors.white)
  scr.clear()
  scr.setCursorPos(1, 1)
  show()
end

return M
