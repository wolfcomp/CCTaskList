-- Display node: mirrors the hub's task board on a local monitor. Needs taskview.lua alongside it.

local taskview = require("taskview")

local PROTOCOL = "tasklist"
local STATE_PROTOCOL = "tasklist_state"
local HOSTNAME = "hub"
local MONITOR_NAME = nil -- e.g. "top" or "monitor_0"; nil uses the first monitor found
local TEXT_SCALE = 0.5
local PAGE_SECONDS = 8
-- The hub pushes every change instantly; polling only covers missed pushes and hub restarts.
local POLL_SECONDS = 15

local view = taskview.new({ monitorName = MONITOR_NAME, textScale = TEXT_SCALE, pageSeconds = PAGE_SECONDS })
local people = {}
local hub, online, everSeen = nil, false, false

local function openModems()
  peripheral.find("modem", rednet.open)
end

local function getState()
  if online then return people end
  return people, everSeen and "Hub offline" or "Looking for hub"
end

local function request()
  if not rednet.isOpen() then return end
  hub = hub or rednet.lookup(PROTOCOL, HOSTNAME)
  if hub then rednet.send(hub, { get = true }, PROTOCOL) end
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
      online, everSeen, awaiting = true, true, false
      os.queueEvent("tasks_changed")
    end
  end
end

openModems()
term.clear()
term.setCursorPos(1, 1)
print("Task display node. Hold Ctrl+T to stop.")
if not rednet.isOpen() then printError("No modem attached: attach one to reach the hub.") end
if not view.findMonitor() then printError("No monitor attached.") end

parallel.waitForAny(netLoop, function() view.run(getState, openModems) end)
