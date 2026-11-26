-- Updater: pulls the latest task hub files from a git repository over HTTP.
-- Returns the number of files changed, so hub/display/tasks can load it and restart on updates.
-- Usage: update                   update the task files already on this computer
--        update check             only report what would change
--        update <hub|display|client>  install that role's files
--        update url <url> [branch]    set the repository to pull from
--        update ref               print (and return) the latest commit hash on GitHub
-- Any form takes --ref <commit|branch|tag> to pull that exact version instead of the branch tip.

local URL_SETTING = "tasks.update_url"
local BRANCH_SETTING = "tasks.update_branch"
local STARTUP_SETTING = "tasks.startup_file"
local DEFAULT_URL = "https://github.com/wolfcomp/CCTaskList"
local DEFAULT_BRANCH = "master"

local ROLES = {
  hub = { "hub.lua" },
  display = { "display.lua" },
  client = { "tasks.lua" },
}
local KNOWN = { "hub.lua", "display.lua", "taskview.lua", "tasks.lua", "update.lua" }
local DEPENDS = {
  ["hub.lua"] = { "taskview.lua" },
  ["display.lua"] = { "taskview.lua" },
}
-- A program copied to startup.lua is recognised by its first line, so these headers must
-- stay unchanged in the repository files.
local HEADERS = {
  ["hub.lua"] = "-- Task hub:",
  ["display.lua"] = "-- Display node:",
  ["tasks.lua"] = "-- Task client:",
  ["update.lua"] = "-- Updater:",
}

settings.define(URL_SETTING, { description = "Git repository the task updater pulls from", type = "string" })
settings.define(BRANCH_SETTING, { description = "Branch the task updater pulls from", type = "string" })
settings.define(STARTUP_SETTING, {
  description = "Task file startup.lua is a copy of (e.g. hub.lua), 'none' to never touch it; unset to auto-detect",
  type = "string",
})

-- Files live next to this program because hub.lua and display.lua require taskview from their own folder.
local dir = fs.getDir(shell.getRunningProgram())

local function setColor(c)
  if term.isColour() then term.setTextColor(c) end
end

local function normalise(url)
  return (url:gsub("/+$", ""):gsub("%.git$", ""))
end

-- Split GitHub page or raw URLs so the branch can be swapped for a commit hash.
local function parseGithub(url, branch)
  local user, repo, rest = url:match("^https?://github%.com/([^/]+)/([^/]+)(.*)$")
  if user then
    local treeBranch, path = rest:match("^/tree/([^/]+)(.*)$")
    return { user = user, repo = repo, branch = treeBranch or branch, path = path or "" }
  end
  local u, r, b, path = url:match("^https?://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)(.*)$")
  if u then return { user = u, repo = r, branch = b, path = path } end
end

local function githubRaw(gh, ref)
  return ("https://raw.githubusercontent.com/%s/%s/%s%s"):format(gh.user, gh.repo, ref, gh.path)
end

-- Repository page URLs don't serve file contents, so map GitLab and Gitea/Forgejo (Codeberg)
-- page URLs to their raw-file form. Anything else is assumed to be a raw base URL.
local function rawBase(url, branch)
  if url:find("/%-/raw/") or url:find("/raw/") then return url end
  if url:find("/%-/tree/") then return (url:gsub("/%-/tree/", "/-/raw/")) end
  if url:find("/src/branch/") then return (url:gsub("/src/branch/", "/raw/branch/")) end
  if url:find("^https?://gitlab%.com/") then return url .. "/-/raw/" .. branch end
  if url:find("^https?://codeberg%.org/") then return url .. "/raw/branch/" .. branch end
  return url
end

local function isCommit(ref)
  return ref ~= nil and #ref == 40 and ref:match("^%x+$") ~= nil
end

-- raw.githubusercontent.com keeps serving a branch's old files for minutes after a push, but a
-- commit URL can only ever serve that commit, so resolving the branch tip sidesteps the cache.
local function latestCommit(gh)
  local res, _, failed = http.get(
    ("https://api.github.com/repos/%s/%s/commits/%s"):format(gh.user, gh.repo, gh.branch),
    { Accept = "application/vnd.github.sha", ["User-Agent"] = "CCTaskList-updater" }
  )
  if not res then
    if failed then failed.close() end
    return nil
  end
  local sha = res.readAll():match("^%s*(%x+)%s*$")
  res.close()
  if isCommit(sha) then return sha:lower() end
end

local function fetch(url, bust)
  local headers
  if bust then
    -- Not every cache honours no-cache, but a never-seen query string forces a miss on most.
    url = url .. "?nocache=" .. os.epoch("utc")
    headers = { ["Cache-Control"] = "no-cache", Pragma = "no-cache" }
  end
  local res, err, failed = http.get(url, headers)
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

-- Returns the startup file's path and which task file it is a copy of, if any.
-- A wrapper such as shell.run("hub") matches nothing and is left alone.
local function detectStartup()
  local forced = settings.get(STARTUP_SETTING)
  if forced == "none" then return nil end
  for _, path in ipairs({ "startup.lua", "startup" }) do
    if fs.exists(path) and not fs.isDir(path) then
      if forced then
        if HEADERS[forced] or forced == "taskview.lua" then return path, forced end
        printError("Ignoring " .. STARTUP_SETTING .. " = " .. forced .. ": not a task file")
        return nil
      end
      local f = fs.open(path, "r")
      local first = f.readLine() or ""
      f.close()
      for name, header in pairs(HEADERS) do
        if first:sub(1, #header) == header then return path, name end
      end
      return nil
    end
  end
end

local args, ref, selfUpdated = {}, nil, false
do
  local raw = { ... }
  local i = 1
  while i <= #raw do
    if raw[i] == "--ref" then
      ref = raw[i + 1]
      i = i + 2
    elseif raw[i] == "--self-updated" then
      selfUpdated = true
      i = i + 1
    else
      args[#args + 1] = raw[i]
      i = i + 1
    end
  end
end
local cmd = args[1] and args[1]:lower()

-- The hub sends refs over rednet, so anything that could reshape the URL is rejected.
if ref and (not ref:match("^[%w%._%-/]+$") or ref:find("%.%.")) then
  printError("Invalid --ref: " .. ref)
  return
end

local function describe(url, branch)
  local gh = parseGithub(url, branch)
  if gh then return githubRaw(gh, gh.branch) .. " (pinned to its latest commit)" end
  return rawBase(url, branch)
end

if cmd == "url" then
  if not args[2] then
    print("Repository: " .. tostring(settings.get(URL_SETTING) or DEFAULT_URL or "not set"))
    print("Branch: " .. (settings.get(BRANCH_SETTING) or DEFAULT_BRANCH))
    return
  end
  settings.set(URL_SETTING, args[2])
  if args[3] then settings.set(BRANCH_SETTING, args[3]) end
  settings.save()
  print("Updates will come from " .. describe(normalise(args[2]), args[3] or settings.get(BRANCH_SETTING) or DEFAULT_BRANCH))
  return
end

if cmd ~= nil and cmd ~= "check" and cmd ~= "ref" and not ROLES[cmd] then
  printError("Unknown option: " .. args[1])
  print("Usage: update [check | ref | hub | display | client | url <url> [branch]] [--ref <ref>]")
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
repo = normalise(repo)
local branch = settings.get(BRANCH_SETTING) or DEFAULT_BRANCH

local gh = parseGithub(repo, branch)
local base, useRef
if gh then
  useRef = ref or latestCommit(gh)
  if not useRef then
    printError("GitHub API unreachable or rate limited: using the branch URL with cache bypass.")
  end
  base = githubRaw(gh, useRef or gh.branch)
else
  base = rawBase(repo, branch)
end
-- A commit URL is immutable, so only branch/tag URLs need the cache bypass.
local bust = not isCommit(useRef)

if cmd == "ref" then
  if useRef then print(useRef) end
  return useRef
end

-- The updater replaces itself first and hands over to the new copy, so file lists, dependencies
-- and URL handling always come from the same version as the files being installed.
if cmd ~= "check" and not selfUpdated then
  local selfPath = fs.combine(dir, "update.lua")
  local body, err = fetch(base .. "/update.lua", bust)
  if not body then
    printError("Update aborted: could not fetch update.lua: " .. tostring(err))
    return
  end
  if readLocal(selfPath) ~= body then
    -- Compile before writing, so a broken download can't replace a working updater.
    local fn, loadErr = load(body, "=update.lua", "t", _ENV)
    if not fn then
      printError("Update aborted: downloaded update.lua does not load: " .. tostring(loadErr))
      return
    end
    writeLocal(selfPath, body)
    setColor(colors.yellow)
    print("  changed update.lua, continuing with the new version")
    setColor(colors.white)

    -- --self-updated stops the new copy from replacing itself again, and passing the ref keeps
    -- both halves of the run on the same commit without another API call.
    local rerun = { "--self-updated" }
    if useRef then
      rerun[#rerun + 1] = "--ref"
      rerun[#rerun + 1] = useRef
    end
    for _, a in ipairs(args) do rerun[#rerun + 1] = a end
    local ok, res = pcall(fn, table.unpack(rerun))
    if not ok then
      printError(res)
      return 1
    end
    return (tonumber(res) or 0) + 1
  end
end

-- targets: { name = file in the repository, path = where it lives on this computer }
local targets, seen = {}, {}
local function want(name, path)
  if seen[path] then return end
  seen[path] = true
  targets[#targets + 1] = { name = name, path = path }
  for _, dep in ipairs(DEPENDS[name] or {}) do want(dep, fs.combine(fs.getDir(path), dep)) end
end

local startupPath, startupName = detectStartup()
if startupName then
  print(("%s is a copy of %s"):format(startupPath, startupName))
  want(startupName, startupPath)
end

if ROLES[cmd] then
  want("update.lua", fs.combine(dir, "update.lua"))
  for _, name in ipairs(ROLES[cmd]) do want(name, fs.combine(dir, name)) end
else
  for _, name in ipairs(KNOWN) do
    local path = fs.combine(dir, name)
    if fs.exists(path) then want(name, path) end
  end
end

if #targets == 0 then
  printError("No task files here yet. Run: update <hub|display|client>")
  return
end

if isCommit(useRef) then
  print(("Checking %s/%s at commit %s"):format(gh.user, gh.repo, useRef:sub(1, 7)))
else
  print("Checking " .. base .. " (cache bypass)")
end

-- Download everything before writing anything, so a failed fetch never leaves a mix of
-- old and new files (e.g. a new hub.lua next to an old taskview.lua).
local downloaded, changed, failures = {}, {}, 0
for _, target in ipairs(targets) do
  local body, err = downloaded[target.name]
  if not body then
    body, err = fetch(base .. "/" .. target.name, bust)
    downloaded[target.name] = body
  end
  local label = target.path == target.name and target.name or (target.path .. " (" .. target.name .. ")")
  if not body then
    failures = failures + 1
    setColor(colors.red)
    print("  " .. label .. ": " .. tostring(err))
  else
    local current = readLocal(target.path)
    if current ~= body then
      changed[#changed + 1] = { label = label, path = target.path, body = body, new = current == nil }
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
  return 0
end

for _, file in ipairs(changed) do
  setColor(file.new and colors.lime or colors.yellow)
  print(("  %s %s"):format(file.new and "new" or "changed", file.label))
end
setColor(colors.white)

if cmd == "check" then
  print(#changed .. " file(s) can be updated. Run 'update' to apply.")
  return #changed
end

for _, file in ipairs(changed) do writeLocal(file.path, file.body) end
print("Updated " .. #changed .. " file(s). Restart running programs (or reboot) to use them.")
return #changed
