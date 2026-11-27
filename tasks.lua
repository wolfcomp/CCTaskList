-- Task client: sends commands to the hub from any computer or pocket computer with a modem.
-- Usage: tasks <command> [args]   (one-shot)
--        tasks                    (clickable UI on advanced/pocket computers, text prompt otherwise)
--        tasks gui | tasks cli    (force the clickable UI or the text prompt)

local pager = require("pager")

local PROTOCOL = "tasklist"
local STATE_PROTOCOL = "tasklist_state"
local UPDATE_PROTOCOL = "tasklist_update"
local HOSTNAME = "hub"
local TIMEOUT = 3
local PERSON_SETTING = "tasks.person"

-- Commands whose first argument is a person, so a remembered name can stand in for it.
local PERSON_COMMANDS = { add = true, done = true, edit = true, top = true, skip = true, clear = true }

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

local function rememberPerson(name)
  if name then
    settings.set(PERSON_SETTING, name)
  else
    settings.unset(PERSON_SETTING)
  end
  settings.save()
end

local hub
-- Returns the hub's id, or nil and why it can't be reached. Errors are returned rather than
-- printed so the clickable UI can show them in its status line instead of over the screen.
local function findHub()
  if hub then return hub end
  peripheral.find("modem", rednet.open)
  if not rednet.isOpen() then return nil, "No modem attached." end
  hub = rednet.lookup(PROTOCOL, HOSTNAME)
  if not hub then return nil, "Task hub not found. Is it running and in range?" end
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

-- Sends a command exactly as given. Returns ok, output lines; or nil, error message.
local function sendRaw(line)
  local id, err = findHub()
  if not id then return nil, err end
  rednet.send(id, { line = line }, PROTOCOL)
  local deadline = os.clock() + TIMEOUT
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then
      hub = nil
      return nil, "No reply from hub."
    end
    local from, reply = rednet.receive(PROTOCOL, remaining)
    if from == id and type(reply) == "table" then
      return reply.ok, reply.out or {}
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
    rememberPerson(nil)
    print("Forgot person. Commands need a name again.")
  else
    name = name:match("^@?(.+)")
    rememberPerson(name)
    print("Adding tasks as " .. name)
  end
end

local function handle(line)
  local cmd, rest = line:match("^%s*(%S+)%s*(.-)%s*$")
  if not cmd then return end
  cmd = cmd:lower()
  if cmd == "as" then
    setPerson(rest ~= "" and rest:match("%S+") or nil)
    return
  end
  local ok, out = sendRaw(resolve(line))
  if ok == nil then
    printError(out)
    return
  end
  if cmd == "help" then
    out[#out + 1] = "as [name|none] - remember who you are"
    out[#out + 1] = "With a name remembered, <person> can be left out; use @name for someone else."
    pager.help(out)
  else
    pager.lines(out, ok and colors.white or colors.red)
  end
end

local args = { ... }
local mode = args[1] and args[1]:lower()
if #args > 0 and mode ~= "gui" and mode ~= "cli" then
  handle(table.concat(args, " "))
  return
end
-- Basic computers get no mouse events, so they stay on the text prompt.
local useGui = mode == "gui" or (mode == nil and term.isColour())

-- Returns the number of files update.lua changed (0 if it is missing or fails).
local function runUpdater(...)
  local path = fs.combine(fs.getDir(shell.getRunningProgram()), "update.lua")
  if not fs.exists(path) then
    printError("The hub wants this computer updated, but update.lua is not installed here.")
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

local hubId, hubErr = findHub()
if not hubId then
  printError(hubErr)
  return
end

-- Remembers the last hub version tried, so a catch-up that fails (or that the repository
-- can't satisfy) is attempted once rather than on every board the hub sends.
local triedVersion

local function needsCatchUp(version)
  return type(version) == "string" and #version == 40 and version:match("^%x+$") ~= nil
    and version ~= settings.get("tasks.version") and version ~= triedVersion
end

local restart = false
-- Update notices and version catch-ups are both handled here, in one coroutine, so two
-- updater runs can never overlap.
local function updateListener()
  while true do
    local _, id, msg, protocol = os.pullEvent("rednet_message")
    -- hub can be cleared by a timed-out command, so match against the id we connected to.
    local message, ref
    if id == hubId and type(msg) == "table" then
      if protocol == UPDATE_PROTOCOL and msg.update then
        message, ref = "Hub announced an update.", msg.ref
      elseif protocol == STATE_PROTOCOL and needsCatchUp(msg.version) then
        triedVersion = msg.version
        message, ref = "Hub is on " .. msg.version:sub(1, 7) .. ", catching up.", msg.version
      end
    end
    if message then
      if useGui then
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
      else
        print()
      end
      print(message)
      local changed = type(ref) == "string" and runUpdater("--ref", ref) or runUpdater()
      if changed > 0 then
        restart = true
        return
      end
      -- Nothing changed: have the UI repaint over the updater's output.
      os.queueEvent("task_state")
    end
  end
end

if useGui then
  local taskgui = require("taskgui")
  local state = {}

  local function stateListener()
    while true do
      local id, msg = rednet.receive(STATE_PROTOCOL)
      if id == hubId and type(msg) == "table" and type(msg.people) == "table" then
        state.people = msg.people
        os.queueEvent("task_state")
      end
    end
  end

  local function gui()
    taskgui.run({
      state = state,
      send = sendRaw,
      requestState = function() rednet.send(hubId, { get = true }, PROTOCOL) end,
      me = currentPerson,
      remember = rememberPerson,
    })
  end

  -- The listener runs in its own coroutine so state pushes aren't lost while the UI is
  -- blocked waiting for a command reply.
  parallel.waitForAny(gui, stateListener, updateListener)
else
  print("Connected to task hub #" .. hubId .. ". Type 'help', or 'exit' to quit.")
  setPerson()
  -- The prompt never shows the board, but the reply carries the hub's version to catch up to.
  rednet.send(hubId, { get = true }, PROTOCOL)

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

  parallel.waitForAny(promptLoop, updateListener)
end

if restart then
  print("tasks updated, restarting...")
  shell.run(shell.getRunningProgram(), table.unpack(args))
end
