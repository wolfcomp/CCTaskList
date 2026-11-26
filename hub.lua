-- Task hub: stores everyone's tasks, serves them over rednet and shows them on a monitor.

local taskview = require("taskview")
local pager = require("pager")

local PROTOCOL = "tasklist"
-- Kept separate from PROTOCOL so state pushes never get mistaken for a command reply.
local STATE_PROTOCOL = "tasklist_state"
local UPDATE_PROTOCOL = "tasklist_update"
local HOSTNAME = "hub"
local DATA_FILE = "tasks.dat"
local MONITOR_NAME = nil -- e.g. "top" or "monitor_0"; nil uses the first monitor found
local TEXT_SCALE = 0.5
local PAGE_SECONDS = 8

-- people[i] = { name = "Alex", tasks = { "current task", "next task", ... } }
local people = {}

local function loadData()
  if not fs.exists(DATA_FILE) then return end
  local f = fs.open(DATA_FILE, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  if type(data) == "table" then people = data end
end

local function saveData()
  local f = fs.open(DATA_FILE, "w")
  f.write(textutils.serialize(people))
  f.close()
  os.queueEvent("tasks_changed")
  if rednet.isOpen() then rednet.broadcast({ people = people }, STATE_PROTOCOL) end
end

local function findPerson(name)
  if not name then return nil end
  local lower = name:lower()
  for i, p in ipairs(people) do
    if p.name:lower() == lower then return p, i end
  end
end

local function needPerson(name)
  local p, i = findPerson(name)
  if not p then error("No such person: " .. tostring(name), 0) end
  return p, i
end

local function needTask(p, n)
  local i = tonumber(n)
  if not i or not p.tasks[i] then error("No task #" .. tostring(n) .. " for " .. p.name, 0) end
  return i
end

local function needTasks(p)
  if #p.tasks == 0 then error(p.name .. " has no tasks", 0) end
end

-- Commands ------------------------------------------------------------------

local commands, helpLines = {}, {}

local function command(name, usage, desc, fn)
  commands[name] = fn
  helpLines[#helpLines + 1] = name .. " " .. usage .. "- " .. desc
end

command("help", "", "show this list", function()
  return helpLines
end)

command("list", "[person] ", "show everyone, or one person's tasks", function(a)
  if a[2] then
    local p = needPerson(a[2])
    if #p.tasks == 0 then return p.name .. ": idle" end
    local out = { p.name .. ":" }
    for i, t in ipairs(p.tasks) do
      out[#out + 1] = (i == 1 and " *" or "  ") .. i .. " " .. t
    end
    return out
  end
  if #people == 0 then return "Nobody here yet" end
  local out = {}
  for _, p in ipairs(people) do
    if #p.tasks == 0 then
      out[#out + 1] = p.name .. ": idle"
    else
      out[#out + 1] = ("%s (%d): %s"):format(p.name, #p.tasks, p.tasks[1])
    end
  end
  return out
end)

command("add", "<person> <task> ", "queue a task (adds the person if new)", function(a)
  if not a[2] or not a[3] then error("Usage: add <person> <task>", 0) end
  local p = findPerson(a[2])
  if not p then
    p = { name = a[2], tasks = {} }
    people[#people + 1] = p
  end
  p.tasks[#p.tasks + 1] = table.concat(a, " ", 3)
  saveData()
  if #p.tasks == 1 then return "Now current for " .. p.name end
  return ("Queued as #%d for %s"):format(#p.tasks, p.name)
end)

command("done", "<person> [n] ", "finish the current task, or task n", function(a)
  local p = needPerson(a[2])
  needTasks(p)
  local i = a[3] and needTask(p, a[3]) or 1
  local finished = table.remove(p.tasks, i)
  saveData()
  local out = { "Done: " .. finished }
  if i == 1 then out[2] = p.tasks[1] and ("Now: " .. p.tasks[1]) or (p.name .. " is idle") end
  return out
end)

command("top", "<person> <n> ", "make task n the current task", function(a)
  local p = needPerson(a[2])
  local i = needTask(p, a[3])
  table.insert(p.tasks, 1, table.remove(p.tasks, i))
  saveData()
  return "Now: " .. p.tasks[1]
end)

command("skip", "<person> ", "move the current task to the back", function(a)
  local p = needPerson(a[2])
  if #p.tasks < 2 then error(p.name .. " has nothing to skip to", 0) end
  table.insert(p.tasks, table.remove(p.tasks, 1))
  saveData()
  return "Now: " .. p.tasks[1]
end)

command("clear", "<person> ", "remove all of a person's tasks", function(a)
  local p = needPerson(a[2])
  p.tasks = {}
  saveData()
  return "Cleared " .. p.name
end)

command("addperson", "<name> ", "add a person with no tasks", function(a)
  if not a[2] then error("Usage: addperson <name>", 0) end
  if findPerson(a[2]) then error(a[2] .. " already exists", 0) end
  people[#people + 1] = { name = a[2], tasks = {} }
  saveData()
  return "Added " .. a[2]
end)

command("delperson", "<name> ", "remove a person and their tasks", function(a)
  local p, i = needPerson(a[2])
  table.remove(people, i)
  saveData()
  return "Removed " .. p.name
end)

local function run(line)
  local args = {}
  for word in line:gmatch("%S+") do args[#args + 1] = word end
  if #args == 0 then return true, {} end
  local fn = commands[args[1]:lower()]
  if not fn then return false, { "Unknown command: " .. args[1], "Type 'help' for commands" } end
  local ok, res = pcall(fn, args)
  if not ok then return false, { tostring(res) } end
  if type(res) == "string" then res = { res } end
  return true, res or {}
end

-- Loops ---------------------------------------------------------------------

local view = taskview.new({ monitorName = MONITOR_NAME, textScale = TEXT_SCALE, pageSeconds = PAGE_SECONDS })

local function openModems()
  peripheral.find("modem", rednet.open)
  if rednet.isOpen() then rednet.host(PROTOCOL, HOSTNAME) end
end

local function displayLoop()
  view.run(function() return people end, openModems)
end

local function netLoop()
  while true do
    local id, msg = rednet.receive(PROTOCOL)
    if type(msg) == "table" and msg.get then
      rednet.send(id, { people = people }, STATE_PROTOCOL)
    else
      local line = type(msg) == "table" and msg.line or msg
      if type(line) == "string" then
        local ok, out = run(line)
        rednet.send(id, { ok = ok, out = out }, PROTOCOL)
      end
    end
  end
end

local function setColor(c)
  if term.isColour() then term.setTextColor(c) end
end

-- Returns whatever update.lua returns (nil if it is missing or fails).
local function runUpdater(...)
  local path = fs.combine(fs.getDir(shell.getRunningProgram()), "update.lua")
  if not fs.exists(path) then
    printError("update.lua is not installed here.")
    return nil
  end
  local fn, err = loadfile(path, nil, _ENV)
  if not fn then
    printError(err)
    return nil
  end
  local ok, res = pcall(fn, ...)
  if not ok then
    printError(res)
    return nil
  end
  return res
end

local function pushUpdate()
  -- Resolving the commit once here means every remote installs the same version, and only
  -- the hub spends a call against GitHub's per-IP API rate limit.
  local ref = runUpdater("ref")
  if type(ref) ~= "string" then ref = nil end
  if rednet.isOpen() then
    rednet.broadcast({ update = true, ref = ref }, UPDATE_PROTOCOL)
    print("Told display nodes and clients to update" .. (ref and (" to " .. ref:sub(1, 7)) or "") .. ".")
  else
    printError("No modem: remotes can't be told to update.")
  end
  local changed
  if ref then changed = runUpdater("--ref", ref) else changed = runUpdater() end
  return (tonumber(changed) or 0) > 0
end

local restart = false

local function cliLoop()
  local history = {}
  while true do
    setColor(colors.yellow)
    write("hub> ")
    setColor(colors.white)
    local line = read(nil, history)
    if line:match("%S") then history[#history + 1] = line end
    if line == "exit" then return end
    -- Kept off the rednet command set so a remote client can't trigger a network-wide update.
    if line == "pushupdate" then
      if pushUpdate() then
        restart = true
        return
      end
    else
      local ok, out = run(line)
      if line == "help" then
        -- Copied so the shared help list sent to remote clients doesn't gain the console-only entry.
        local lines = { table.unpack(out) }
        lines[#lines + 1] = "pushupdate - update remotes, then this hub (console only)"
        pager.help(lines)
      else
        pager.lines(out, ok and colors.white or colors.red)
      end
    end
  end
end

loadData()
openModems()
term.clear()
term.setCursorPos(1, 1)
print("Task hub running. Type 'help' for commands, 'exit' to stop.")
if rednet.isOpen() then
  print(("Hosting '%s' as '%s' (id %d)"):format(PROTOCOL, HOSTNAME, os.getComputerID()))
else
  printError("No modem attached: clients and display nodes can't connect.")
end
if not view.findMonitor() then
  printError("No monitor attached: nothing will be displayed here.")
end

parallel.waitForAny(cliLoop, netLoop, displayLoop)

if rednet.isOpen() then rednet.unhost(PROTOCOL) end
view.clear()

if restart then
  print("Hub updated, restarting...")
  shell.run(shell.getRunningProgram())
end
