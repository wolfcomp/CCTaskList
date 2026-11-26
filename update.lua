-- Updater: pulls the latest task hub files from a git repository over HTTP.
-- Usage: update                   update the task files already on this computer
--        update check             only report what would change
--        update <hub|display|client>  install that role's files
--        update url <url> [branch]    set the repository to pull from

local URL_SETTING = "tasks.update_url"
local BRANCH_SETTING = "tasks.update_branch"
local DEFAULT_URL = nil -- e.g. "https://github.com/you/CCTaskList"
local DEFAULT_BRANCH = "main"

local ROLES = {
  hub = { "hub.lua", "taskview.lua" },
  display = { "display.lua", "taskview.lua" },
  client = { "tasks.lua" },
}
local KNOWN = { "hub.lua", "display.lua", "taskview.lua", "tasks.lua", "update.lua" }

settings.define(URL_SETTING, { description = "Git repository the task updater pulls from", type = "string" })
settings.define(BRANCH_SETTING, { description = "Branch the task updater pulls from", type = "string" })

-- Files live next to this program because hub.lua and display.lua require taskview from their own folder.
local dir = fs.getDir(shell.getRunningProgram())

local function setColor(c)
  if term.isColour() then term.setTextColor(c) end
end

-- Repository page URLs don't serve file contents, so map GitHub, GitLab and Gitea/Forgejo
-- (Codeberg) page URLs to their raw-file form. Anything else is assumed to be a raw base URL.
local function rawBase(url, branch)
  url = url:gsub("/+$", ""):gsub("%.git$", "")
  if url:find("raw%.githubusercontent%.com") or url:find("/%-/raw/") or url:find("/raw/") then
    return url
  end

  local user, repo, rest = url:match("^https?://github%.com/([^/]+)/([^/]+)(.*)$")
  if user then
    local treeBranch, path = rest:match("^/tree/([^/]+)(.*)$")
    return ("https://raw.githubusercontent.com/%s/%s/%s%s"):format(user, repo, treeBranch or branch, path or "")
  end
  if url:find("/%-/tree/") then return (url:gsub("/%-/tree/", "/-/raw/")) end
  if url:find("/src/branch/") then return (url:gsub("/src/branch/", "/raw/branch/")) end
  if url:find("^https?://gitlab%.com/") then return url .. "/-/raw/" .. branch end
  if url:find("^https?://codeberg%.org/") then return url .. "/raw/branch/" .. branch end
  return url
end

local function fetch(url)
  local res, err, failed = http.get(url)
  if not res then
    if failed then failed.close() end
    return nil, err
  end
  local body = res.readAll()
  res.close()
  return body
end

local function readLocal(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local body = f.readAll()
  f.close()
  return body
end

local function writeLocal(path, body)
  local f = fs.open(path, "w")
  f.write(body)
  f.close()
end

local args = { ... }
local cmd = args[1] and args[1]:lower()

if cmd == "url" then
  if not args[2] then
    print("Repository: " .. tostring(settings.get(URL_SETTING) or DEFAULT_URL or "not set"))
    print("Branch: " .. (settings.get(BRANCH_SETTING) or DEFAULT_BRANCH))
    return
  end
  settings.set(URL_SETTING, args[2])
  if args[3] then settings.set(BRANCH_SETTING, args[3]) end
  settings.save()
  print("Updates will come from " .. rawBase(args[2], args[3] or settings.get(BRANCH_SETTING) or DEFAULT_BRANCH))
  return
end

if not http then
  printError("The HTTP API is disabled. Enable it in the CC:Tweaked server config.")
  return
end

local repo = settings.get(URL_SETTING) or DEFAULT_URL
if not repo then
  printError("No repository set. Run: update url <git url> [branch]")
  return
end
local base = rawBase(repo, settings.get(BRANCH_SETTING) or DEFAULT_BRANCH)

local files
if cmd == nil or cmd == "check" then
  files = {}
  for _, name in ipairs(KNOWN) do
    if fs.exists(fs.combine(dir, name)) then files[#files + 1] = name end
  end
  if #files == 0 then
    printError("No task files here yet. Run: update <hub|display|client>")
    return
  end
elseif ROLES[cmd] then
  files = { "update.lua" }
  for _, name in ipairs(ROLES[cmd]) do files[#files + 1] = name end
else
  printError("Unknown option: " .. args[1])
  print("Usage: update [check | hub | display | client | url <url> [branch]]")
  return
end

print("Checking " .. base)

-- Download everything before writing anything, so a failed fetch never leaves a mix of
-- old and new files (e.g. a new hub.lua next to an old taskview.lua).
local changed, failures = {}, 0
for _, name in ipairs(files) do
  local body, err = fetch(base .. "/" .. name)
  if not body then
    failures = failures + 1
    setColor(colors.red)
    print("  " .. name .. ": " .. tostring(err))
  else
    local path = fs.combine(dir, name)
    local current = readLocal(path)
    if current ~= body then
      changed[#changed + 1] = { name = name, path = path, body = body, new = current == nil }
    end
  end
end
setColor(colors.white)

if failures > 0 then
  printError("Update aborted: " .. failures .. " file(s) could not be fetched. Nothing was changed.")
  return
end

if #changed == 0 then
  print("Already up to date.")
  return
end

for _, file in ipairs(changed) do
  setColor(file.new and colors.lime or colors.yellow)
  print(("  %s %s"):format(file.new and "new" or "changed", file.name))
end
setColor(colors.white)

if cmd == "check" then
  print(#changed .. " file(s) can be updated. Run 'update' to apply.")
  return
end

for _, file in ipairs(changed) do writeLocal(file.path, file.body) end
print("Updated " .. #changed .. " file(s). Restart running programs (or reboot) to use them.")
