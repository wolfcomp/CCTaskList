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

-- opts: monitorName (nil = first found), textScale, pageSeconds
function M.new(opts)
  opts = opts or {}
  local textScale = opts.textScale or 0.5
  local pageSeconds = opts.pageSeconds or 8
  local monitor, win
  local page = 1
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

  local function drawColumn(x, width, bottom, p, idx)
    local head = color(HEADER_COLORS[(idx - 1) % #HEADER_COLORS + 1], colors.white)
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

    if #people == 0 then
      centered(math.ceil(h / 2), status or "No tasks", colors.gray)
    else
      local cols = math.min(blockColumns(w), #people)
      local pages = math.ceil(#people / cols)
      if page > pages then page = 1 end
      local footer = (pages > 1 or status) and 1 or 0

      for c = 1, cols do
        local idx = (page - 1) * cols + c
        if people[idx] then
          local x0 = math.floor((c - 1) * w / cols) + 1
          local x1 = math.floor(c * w / cols)
          drawColumn(x0, x1 - x0 + 1, h - footer, people[idx], idx)
        end
      end

      if footer == 1 then
        local parts = {}
        if status then parts[#parts + 1] = status end
        if pages > 1 then parts[#parts + 1] = ("Page %d/%d"):format(page, pages) end
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

  -- Redraws on "tasks_changed" events; getState() returns people, status.
  function self.run(getState, onPeripheral)
    self.attach()
    self.render(getState())
    local timer = os.startTimer(pageSeconds)
    while true do
      local ev, a = os.pullEvent()
      if (ev == "timer" and a == timer) or ev == "monitor_touch" then
        page = page + 1
        self.render(getState())
        timer = os.startTimer(pageSeconds)
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
