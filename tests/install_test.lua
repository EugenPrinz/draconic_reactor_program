-- Тест установщика (Lua 5.3, вне Minecraft): lua5.3 tests/install_test.lua
local DIR = (arg[0]:match("^(.*)/tests/") or ".")
local FAILS = 0
local function check(c, m) print((c and "  ✔ " or "  ✘ ") .. m); if not c then FAILS = FAILS + 1 end end

local function readLocal(p) local f = io.open(DIR .. "/" .. p); local d = f:read("a"); f:close(); return d end

local function run(mode, opts)
  local ROOT = os.tmpname(); os.remove(ROOT); os.execute("mkdir -p " .. ROOT .. "/home")
  if opts.hw then local f = io.open(ROOT .. "/home/drc-hw.cfg", "w"); f:write(opts.hw); f:close() end
  local gates = {}
  for i = 1, opts.gates or 2 do gates[i] = { address = ("g%d-aaaa-bbbb"):format(i), low = 0, ov = false } end
  local comps = {
    ["r1-reactor"] = { type = "draconic_reactor", getReactorInfo = function() return { status = "offline", maxFuelConversion = 524880 } end },
    ["gpu1"] = { type = "gpu", maxResolution = function() return 160, 50 end },
  }
  if opts.internet ~= false then
    comps["inet1"] = { type = "internet" }
  end
  for _, g in ipairs(gates) do
    comps[g.address] = { type = "flux_gate", getSignalLowFlow = function() return g.low end,
      getOverrideEnabled = function() return g.ov end }
  end
  local component = {
    isAvailable = function(t) for _, c in pairs(comps) do if c.type == t then return true end end return false end,
    list = function(t)
      local keys = {}
      for a, c in pairs(comps) do if c.type == t then keys[#keys + 1] = a end end
      local i = 0
      return function() i = i + 1; return keys[i], keys[i] and t end
    end,
    proxy = function(a) return comps[a] end,
  }
  setmetatable(component, { __index = function(_, k) for _, c in pairs(comps) do if c.type == k then return c end end end })
  local t, pulls = 0, 0
  package.loaded.component = component
  package.loaded.computer = { uptime = function() return t end }
  package.loaded.event = { pull = function(dt)
    t = t + (dt or 0); pulls = pulls + 1
    if opts.changeAt and pulls == opts.changeAt then gates[opts.changeGate].low = gates[opts.changeGate].low + 1000 end
    return nil
  end }
  package.loaded.serialization = {
    serialize = function(v)
      local p = {}
      for k, x in pairs(v) do p[#p + 1] = ("[%q]=%s"):format(k, type(x) == "string" and ("%q"):format(x) or tostring(x)) end
      return "{" .. table.concat(p, ",") .. "}"
    end,
    unserialize = function(s) return load("return " .. s)() end,
  }
  package.loaded.filesystem = {
    path = function(p) return p:match("^(.*)/[^/]*$") end,
    exists = function(p) local f = io.open(p); if f then f:close(); return true end return false end,
    makeDirectory = function(p) os.execute("mkdir -p " .. p) end,
    copy = function(a, b) os.execute(("cp %q %q"):format(a, b)) end,
  }
  package.loaded.internet = { request = function(url)
    local name = url:match("/main/(.+)$")
    local data = readLocal(name)
    local done = false
    return function() if done then return nil end done = true; return data end
  end }
  local answers, ai = opts.answers or {}, 0
  local out = {}
  local oldRead, oldWrite = io.read, io.write
  io.read = function() ai = ai + 1; return answers[ai] end
  io.write = function(...) for _, s in ipairs({ ... }) do out[#out + 1] = tostring(s) end end
  DRC_ROOT, DRC_WAIT = ROOT, 10   -- luacheck: ignore
  local fn = assert(loadfile(DIR .. "/install.lua"))
  local ok, err = pcall(fn, mode)
  io.read, io.write = oldRead, oldWrite
  local text = table.concat(out)
  if os.getenv("SHOW") then print(text) end
  local hwf = io.open(ROOT .. "/home/drc-hw.cfg")
  local hw = hwf and load("return " .. hwf:read("a"))() or nil
  if hwf then hwf:close() end
  local prog = io.open(ROOT .. "/home/drc.lua"); if prog then prog:close() end
  local shrc = io.open(ROOT .. "/home/.shrc"); local sh = shrc and shrc:read("a"); if shrc then shrc:close() end
  os.execute("rm -rf " .. ROOT)
  return { ok = ok, err = err, text = text, hw = hw, prog = prog ~= nil, shrc = sh, gates = gates }
end

print("== full: вход найден по изменению уставки (гейт 2)")
local r = run("full", { changeAt = 3, changeGate = 2, answers = { "", "" } })
check(r.ok, "без ошибок " .. tostring(r.err))
check(r.prog, "drc.lua скачан")
check(r.hw and r.hw.inGate == r.gates[2].address and r.hw.outGate == r.gates[1].address, "вход = гейт 2, выход = гейт 1")
check(r.shrc == "drc\n", "автозапуск добавлен")
check(r.text:find("Экран 160x50") ~= nil, "проверка экрана")

print("== gates: изменения нет → ручной выбор")
r = run("gates", { answers = { "1", "н" } })
check(r.ok, "без ошибок " .. tostring(r.err))
check(r.hw and r.hw.inGate == r.gates[1].address and r.hw.outGate == r.gates[2].address, "вход = 1, выход = 2 вручную")

print("== gates: нет гейтов")
r = run("gates", { gates = 0 })
check(r.hw and r.hw.inGate == "" and r.hw.outGate == "", "гейты пустые, программа в ручном режиме")

print("== update: настройки сохраняются")
r = run("update", { hw = '{["inGate"]="keep-in",["outGate"]="keep-out"}' })
check(r.prog and r.hw.inGate == "keep-in", "программа обновлена, гейты не тронуты")

print("== без интернет-карты")
r = run("full", { internet = false })
check(not r.prog and r.text:find("нет интернет%-карты") ~= nil, "понятная ошибка")

print(FAILS == 0 and "ВСЕ ТЕСТЫ УСТАНОВЩИКА ПРОЙДЕНЫ" or ("ПРОВАЛОВ: " .. FAILS))
os.exit(FAILS == 0 and 0 or 1)
