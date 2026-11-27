-- Display node: mirrors the hub's task board on a local monitor. Needs taskview.lua alongside it.
-- Usage: display       (clickable UI on the terminal of an advanced computer)
--        display cli   (terminal shows status text only)

local taskview = require("taskview")
local taskgui = require("taskgui")

local args = { ... }

local PROTOCOL = "tasklist"
local STATE_PROTOCOL = "tasklist_state"
local UPDATE_PROTOCOL = "tasklist_update"
local HOSTNAME = "hub"
local MONITOR_NAME = nil -- e.g. "top" or "monitor_0"; nil uses the first monitor found
local TEXT_SCALE = 0.5
local PAGE_SECONDS = 8
-- The hub pushes every change instantly; polling only covers missed pushes and hub restarts.
local POLL_SECONDS = 15
local TIMEOUT = 3
-- The monitor goes back to the board after this long without a tap, so a walk-away
-- doesn't leave it stuck on one person.
local MONITOR_IDLE_SECONDS = 60

local view = taskview.new({ monitorName = MONITOR_NAME, textScale = TEXT_SCALE, pageSeconds = PAGE_SECONDS })
local people = {}
local hub, online, everSeen = nil, false, false
-- Separate from people so the UI shows "Waiting for the hub" until the first real board arrives.
local guiState = {}
local guiOpen = false

local function openModems()
  peripheral.find("modem", rednet.open)
end

local function getState()
  if online then return people end
  return people, everSeen and "Hub offline" or "Looking for hub"
end

-- Returns the number of files update.lua changed (0 if it is missing or fails).
local function runUpdater(...)
  local path = fs.combine(fs.getDir(shell.getRunningProgram()), "update.lua")
  if not fs.exists(path) then
    printError("Hub announced an update, but update.lua is not installed here.")
    return 0
  end
  local fn, err = loadfile(path, nil, _ENV)
  if not fn then
    printError(err)
    return 0
  end
  local ok, res = pcall(fn, ...)
  if not ok then
    printError(res)
    return 0
  end
  return tonumber(res) or 0
end

local function request()
  if not rednet.isOpen() then return end
  hub = hub or rednet.lookup(PROTOCOL, HOSTNAME)
  if hub then rednet.send(hub, { get = true }, PROTOCOL) end
end

-- Sends a command for the UI. Returns ok, output lines; or nil, error message.
local function send(line)
  if not rednet.isOpen() then return nil, "No modem attached." end
  local id = hub or rednet.lookup(PROTOCOL, HOSTNAME)
  if not id then return nil, "Task hub not found. Is it running and in range?" end
  rednet.send(id, { line = line }, PROTOCOL)
  local deadline = os.clock() + TIMEOUT
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then return nil, "No reply from hub." end
    local from, reply = rednet.receive(PROTOCOL, remaining)
    if from == id and type(reply) == "table" then return reply.ok, reply.out or {} end
  end
end

local function netLoop()
  local awaiting = false
  local timer = os.startTimer(0)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      if awaiting then
        -- Forget the id so the next poll re-looks it up, in case the hub moved to another computer.
        hub = nil
        if online then
          online = false
          os.queueEvent("tasks_changed")
        end
      end
      request()
      awaiting = true
      timer = os.startTimer(POLL_SECONDS)
    elseif ev == "rednet_message" and c == STATE_PROTOCOL and (hub == nil or a == hub)
        and type(b) == "table" and type(b.people) == "table" then
      hub = a
      people = b.people
      guiState.people = b.people
      online, everSeen, awaiting = true, true, false
      os.queueEvent("tasks_changed")
    elseif ev == "rednet_message" and c == UPDATE_PROTOCOL and hub and a == hub
        and type(b) == "table" and b.update then
      if guiOpen then
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
      end
      print("Hub announced an update.")
      local changed = type(b.ref) == "string" and runUpdater("--ref", b.ref) or runUpdater()
      if changed > 0 then return true end
      -- Nothing changed: have the UI repaint over the updater's output.
      os.queueEvent("task_state")
    end
  end
end

local function banner()
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  print("Task display node. Hold Ctrl+T to stop.")
  if not rednet.isOpen() then printError("No modem attached: attach one to reach the hub.") end
  if not view.findMonitor() then printError("No monitor attached.") end
end

local function terminalLoop()
  while true do
    guiOpen = true
    taskgui.run({ state = guiState, send = send, requestState = request })
    guiOpen = false
    banner()
    print("Press G for the task UI.")
    repeat local _, key = os.pullEvent("key") until key == keys.g
  end
end

openModems()
banner()

local restart = false
local loops = {
  function() restart = netLoop() end,
  function()
    view.run(getState, openModems, function(target, side, person)
      taskgui.run({
        state = guiState,
        send = send,
        requestState = request,
        term = target,
        touch = side,
        person = person,
        idleSeconds = MONITOR_IDLE_SECONDS,
      })
    end)
  end,
}
-- Basic computers get no mouse events, so their terminal keeps the status text.
if term.isColour() and (args[1] or ""):lower() ~= "cli" then loops[#loops + 1] = terminalLoop end
parallel.waitForAny(table.unpack(loops))

if restart then
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Display updated, restarting...")
  shell.run(shell.getRunningProgram(), table.unpack(args))
end
