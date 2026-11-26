-- Task client: sends commands to the hub from any computer or pocket computer with a modem.
-- Usage: tasks <command> [args]   (one-shot)
--        tasks                    (interactive prompt)

local PROTOCOL = "tasklist"
local HOSTNAME = "hub"
local TIMEOUT = 3
local UPDATE_PROTOCOL = "tasklist_update"
local PERSON_SETTING = "tasks.person"

-- Commands whose first argument is a person, so a remembered name can stand in for it.
local PERSON_COMMANDS = { add = true, done = true, top = true, skip = true, clear = true }

settings.define(PERSON_SETTING, {
  description = "Person the tasks client acts as when no name is given",
  type = "string",
})

local function setColor(c)
  if term.isColour() then term.setTextColor(c) end
end

local function currentPerson()
  local name = settings.get(PERSON_SETTING)
  if name and name ~= "" then return name end
end

local hub
local function findHub()
  if hub then return hub end
  peripheral.find("modem", rednet.open)
  if not rednet.isOpen() then
    printError("No modem attached.")
    return
  end
  hub = rednet.lookup(PROTOCOL, HOSTNAME)
  if not hub then printError("Task hub not found. Is it running and in range?") end
  return hub
end

-- "@Name" always targets that person; otherwise a missing name (or a bare task number)
-- falls back to the remembered person. "add" never treats its first word as a name,
-- since a task can start with any word.
local function resolve(line)
  local args = {}
  for word in line:gmatch("%S+") do args[#args + 1] = word end
  local cmd = args[1] and args[1]:lower()
  if not PERSON_COMMANDS[cmd] then return line end

  local target = args[2] and args[2]:match("^@(.+)")
  if target then
    args[2] = target
  else
    local person = currentPerson()
    local named = args[2] and cmd ~= "add" and not tonumber(args[2])
    if person and not named then table.insert(args, 2, person) end
  end
  return table.concat(args, " ")
end

local function send(line)
  if not findHub() then return end
  rednet.send(hub, { line = resolve(line) }, PROTOCOL)
  local deadline = os.clock() + TIMEOUT
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then
      printError("No reply from hub.")
      hub = nil
      return
    end
    local id, reply = rednet.receive(PROTOCOL, remaining)
    if id == hub and type(reply) == "table" then
      setColor(reply.ok and colors.white or colors.red)
      for _, l in ipairs(reply.out or {}) do print(l) end
      setColor(colors.white)
      return
    end
  end
end

local function setPerson(name)
  if not name then
    local person = currentPerson()
    print(person and ("Adding tasks as " .. person) or "No person set. Use 'as <name>'.")
    return
  end
  if name == "-" or name:lower() == "none" then
    settings.unset(PERSON_SETTING)
    print("Forgot person. Commands need a name again.")
  else
    name = name:match("^@?(.+)")
    settings.set(PERSON_SETTING, name)
    print("Adding tasks as " .. name)
  end
  settings.save()
end

local function handle(line)
  local cmd, rest = line:match("^%s*(%S+)%s*(.-)%s*$")
  if not cmd then return end
  cmd = cmd:lower()
  if cmd == "as" then
    setPerson(rest ~= "" and rest:match("%S+") or nil)
    return
  end
  send(line)
  if cmd == "help" then
    print("as [name|none] - remember who you are")
    print("With a name remembered, <person> can be left out; use @name for someone else.")
  end
end

local args = { ... }
if #args > 0 then
  handle(table.concat(args, " "))
  return
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

if not findHub() then return end
local hubId = hub
print("Connected to task hub #" .. hub .. ". Type 'help', or 'exit' to quit.")
setPerson()

local function promptLoop()
  local history = {}
  while true do
    local person = currentPerson()
    setColor(colors.yellow)
    write(person and ("tasks (" .. person .. ")> ") or "tasks> ")
    setColor(colors.white)
    local line = read(nil, history)
    if line == "exit" then return end
    if line:match("%S") then
      history[#history + 1] = line
      handle(line)
    end
  end
end

local restart = false
local function updateListener()
  while true do
    -- hub can be cleared by a timed-out command, so match against the id we connected to.
    local id, msg = rednet.receive(UPDATE_PROTOCOL)
    if id == hubId and type(msg) == "table" and msg.update then
      print()
      print("Hub announced an update.")
      if runUpdater() > 0 then
        restart = true
        return
      end
    end
  end
end

parallel.waitForAny(promptLoop, updateListener)

if restart then
  print("tasks updated, restarting...")
  shell.run(shell.getRunningProgram())
end
