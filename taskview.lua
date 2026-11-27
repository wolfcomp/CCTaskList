-- Monitor renderer shared by the hub and display nodes.

local M = {}

local HEADER_COLORS = {
  colors.cyan, colors.orange, colors.lime, colors.magenta,
  colors.yellow, colors.lightBlue, colors.pink, colors.red,
}

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
  if #line > 0 then lines[#lines + 1] = line end
  return lines
end

-- opts: monitorName (nil = first found), textScale, pageSeconds, holdSeconds (how long a
-- page picked with a person button stays up before rotation resumes)
function M.new(opts)
  opts = opts or {}
  local textScale = opts.textScale or 0.5
  local pageSeconds = opts.pageSeconds or 8
  local holdSeconds = opts.holdSeconds or 30
  local monitor, win
  local page = 1
  local hits = {}
  local self = {}

  function self.attach()
    monitor = opts.monitorName and peripheral.wrap(opts.monitorName) or peripheral.find("monitor")
    win = nil
    if not monitor then return end
    monitor.setTextScale(textScale)
    local w, h = monitor.getSize()
    -- Drawing into a hidden window and revealing it at once avoids visible flicker on redraw.
    win = window.create(monitor, 1, 1, w, h, false)
  end

  function self.findMonitor()
    return opts.monitorName and peripheral.wrap(opts.monitorName) or peripheral.find("monitor")
  end

  local function color(c, mono)
    return win.isColour() and c or mono
  end

  local function put(x, y, text, fg, bg)
    win.setCursorPos(x, y)
    win.setTextColor(fg)
    win.setBackgroundColor(bg)
    win.write(text)
  end

  local function centered(y, text, fg)
    local w = win.getSize()
    put(math.max(1, math.floor((w - #text) / 2) + 1), y, text, fg, colors.black)
  end

  -- Inverse of CC's monitor sizing (chars = (64 * blocks - 20) / (6 * scale)), so each
  -- physical block column of the monitor gets one person.
  local function blockColumns(w)
    return math.max(1, math.floor((w * 6 * textScale + 20) / 64 + 0.5))
  end

  local function headColor(idx)
    return color(HEADER_COLORS[(idx - 1) % #HEADER_COLORS + 1], colors.white)
  end

  -- Packs one button per person into rows; nil if they need more than maxRows, in which
  -- case the plain page counter is used instead.
  local function layoutBar(people, w, maxRows)
    local buttons, x, row = {}, 1, 1
    for idx, p in ipairs(people) do
      local label = (" " .. p.name .. " "):sub(1, w)
      if x > 1 and x + #label - 1 > w then row, x = row + 1, 1 end
      buttons[#buttons + 1] = { x = x, row = row, label = label, idx = idx }
      x = x + #label + 1
    end
    if row > maxRows then return nil end
    return buttons, row
  end

  local function drawColumn(x, width, bottom, p, idx)
    local head = headColor(idx)
    put(x, 1, (" "):rep(width), colors.black, head)
    local name = p.name:sub(1, width)
    put(x + math.floor((width - #name) / 2), 1, name, colors.black, head)

    -- One blank char either side keeps neighbouring columns' text from running together.
    local inner = math.max(1, width - 2)
    local y = 2
    local function emit(text, fg)
      if y <= bottom then put(x + 1, y, text:sub(1, inner), fg, colors.black) end
      y = y + 1
    end

    if #p.tasks == 0 then
      emit("Idle", colors.gray)
      return
    end

    emit("Now:", color(colors.yellow, colors.white))
    for _, l in ipairs(wrap(p.tasks[1], inner)) do emit(l, colors.white) end
    if #p.tasks == 1 then return end

    y = y + 1
    emit("Next:", color(colors.lightBlue, colors.lightGray))
    for i = 2, #p.tasks do
      local prefix = i .. " "
      local body = wrap(p.tasks[i], math.max(1, inner - #prefix))
      local remainingAfter = #p.tasks - i
      local room = bottom - y + 1 - (remainingAfter > 0 and 1 or 0)
      if #body > room then
        emit("+" .. (remainingAfter + 1) .. " more", colors.gray)
        return
      end
      for j, l in ipairs(body) do
        emit((j == 1 and prefix or (" "):rep(#prefix)) .. l, colors.lightGray)
      end
    end
  end

  -- status: optional short message (e.g. "Hub offline") shown on the bottom row.
  function self.render(people, status)
    if not win then return end
    local w, h = win.getSize()
    win.setVisible(false)
    win.setBackgroundColor(colors.black)
    win.clear()
    hits = {}

    if #people == 0 then
      centered(math.ceil(h / 2), status or "No tasks", colors.gray)
      for y = 1, h do hits[#hits + 1] = { x0 = 1, x1 = w, y = y, manage = true } end
    else
      local cols = math.min(blockColumns(w), #people)
      local pages = math.ceil(#people / cols)
      if page > pages then page = 1 end
      -- Basic monitors can't be touched, so buttons would only cost them rows.
      local bar, barRows
      if pages > 1 and win.isColour() then
        bar, barRows = layoutBar(people, w, math.max(1, math.floor(h / 4)))
      end
      local footer = (status or (pages > 1 and not bar)) and 1 or 0
      local bottom = h - footer - (bar and barRows or 0)

      for c = 1, cols do
        local idx = (page - 1) * cols + c
        if people[idx] then
          local x0 = math.floor((c - 1) * w / cols) + 1
          local x1 = math.floor(c * w / cols)
          drawColumn(x0, x1 - x0 + 1, bottom, people[idx], idx)
          for y = 1, bottom do
            hits[#hits + 1] = { x0 = x0, x1 = x1, y = y, manage = true, person = people[idx].name }
          end
        end
      end

      if bar then
        for _, b in ipairs(bar) do
          local y = bottom + b.row
          local target = math.ceil(b.idx / cols)
          local head = headColor(b.idx)
          if target == page then
            put(b.x, y, b.label, colors.black, head)
          else
            put(b.x, y, b.label, head, colors.gray)
          end
          hits[#hits + 1] = { x0 = b.x, x1 = b.x + #b.label - 1, y = y, page = target }
        end
      end

      if footer == 1 then
        local parts = {}
        if status then parts[#parts + 1] = status end
        if pages > 1 and not bar then parts[#parts + 1] = ("Page %d/%d"):format(page, pages) end
        centered(h, table.concat(parts, "  "), status and color(colors.red, colors.white) or colors.gray)
      end
    end

    win.setVisible(true)
  end

  function self.clear()
    if not monitor then return end
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
  end

  local function ours(side)
    return monitor ~= nil and peripheral.getName(monitor) == side
  end

  local function touched(x, y)
    for _, t in ipairs(hits) do
      if y == t.y and x >= t.x0 and x <= t.x1 then return t end
    end
  end

  -- Redraws on "tasks_changed" events; getState() returns people, status.
  -- manage(target, side, person), if given, runs the clickable UI on the monitor until it
  -- closes; tapping a person's column opens it.
  function self.run(getState, onPeripheral, manage)
    self.attach()
    self.render(getState())
    local timer = os.startTimer(pageSeconds)
    while true do
      local ev, a, b, c = os.pullEvent()
      if ev == "timer" and a == timer then
        page = page + 1
        self.render(getState())
        timer = os.startTimer(pageSeconds)
      elseif ev == "monitor_touch" and ours(a) then
        local t = touched(b, c)
        if t and t.page then
          -- Hold the picked person on screen so rotation doesn't flip away straight after.
          page = t.page
          timer = os.startTimer(holdSeconds)
        elseif t and t.manage and manage then
          win.setVisible(true)
          -- A peripheral detaching mid-edit throws; the board just redraws after it.
          local ok, err = pcall(manage, win, a, t.person)
          if not ok and err == "Terminated" then error(err, 0) end
          if not ok then
            -- Shown rather than swallowed, so a broken UI isn't mistaken for a missing feature.
            -- Guarded too, because the monitor may be the thing that went away.
            pcall(function()
              local w = win.getSize()
              win.setBackgroundColor(colors.black)
              win.clear()
              put(1, 1, "Monitor UI error:", colors.red, colors.black)
              for i, l in ipairs(wrap(tostring(err), w)) do put(1, i + 1, l, colors.white, colors.black) end
              win.setVisible(true)
            end)
            sleep(8)
          end
          self.attach()
          timer = os.startTimer(pageSeconds)
        else
          page = page + 1
          timer = os.startTimer(pageSeconds)
        end
        self.render(getState())
      elseif ev == "tasks_changed" then
        self.render(getState())
      elseif ev == "monitor_resize" or ev == "peripheral" or ev == "peripheral_detach" then
        if onPeripheral then onPeripheral() end
        self.attach()
        self.render(getState())
      end
    end
  end

  return self
end

return M
