-- Офлайн-симулятор для drc.lua (Lua 5.3, вне Minecraft).
-- Физика реактора перенесена потиково из GTNewHorizons/Draconic-Evolution:
--   TileReactorCore (runTick / startingTick / offlineTick / injectEnergy / callMethod),
--   TileReactorStabilizer (выдача RF только в ONLINE, до maxSat/100 за тик),
--   TileFluxGate / TileGate (override, transferredThisTick, OC-методы, каст (Double)).
-- Параметры конфига — как в GTNH (см. вики): maxFuelStorage 524880, FuelUsageMultiplier 3035,
-- EnergyOutputMultiplier 1, нелинейный расход (^0.3), топливо: блок 162, осколок 26244.
--
--   lua5.3 tests/sim.lua <сценарий>
--   сценарии: basic, starve, noextract, weakin, inputloss, resume, ctrlc, manual, settings, all
--   DRC_SHOW_LOG=1 — печатать журнал программы; DRC_DUMP=файл — сохранить экран для tests/render.py

local scenario = arg[1] or "basic"
local DIR = (arg[0]:match("^(.*)/tests/") or ".")

-- ======================= реактор (TileReactorCore) =======================
local FUEL_STORAGE, USAGE_MULT, OUT_MULT, LINEAR = 524880, 3035, 1, false
local RATIO = FUEL_STORAGE / 10368
local SHARD = 26244
local INT_MAX = 2147483647

local function newReactor()
  return {
    state = "OFFLINE", init = false,
    fuel = 0, conv = 0, unit = 0, excess = 0,
    temp = 20, maxTemp = 10000,
    field = 0, maxField = 0,
    sat = 0, maxSat = 0,
    gen = 0, drain = 0, fuelRate = 0,
    boom = false, boomTick = nil,
  }
end

local R = newReactor()
local SIM = { tick = 0 }

local function canStart()
  return R.temp >= 2000 and R.field >= R.maxField / 2 and R.sat >= R.maxSat / 2 and R.conv + R.fuel + R.unit >= 144
end
local function canCharge() return R.state ~= "ONLINE" and R.conv + R.fuel + R.unit >= 144 end
local function canStop() return R.state ~= "OFFLINE" end

local function toInt(x) x = math.floor(x); if x > INT_MAX then return INT_MAX end return x end

local function runTick()
  local saturation = R.sat / R.maxSat
  local saturationI = (1 - saturation) * 99
  local temp = (R.temp / R.maxTemp) * 50
  local conversion = (R.conv + R.unit) / (R.conv + R.fuel - R.unit) * 1.3 - 0.3
  local tempRiseExpo = saturationI ^ 3 / (100 - saturationI) + 444.7
  local tempRiseResist = temp ^ 4 / (100 - temp)
  local riseAmount = (tempRiseExpo - tempRiseResist * (1 - conversion) + conversion * 1000) / 10000
  if R.state == "STOPPING" then
    if R.temp <= 2001 then R.state = "OFFLINE"; R.init = false; return end
    if R.sat >= R.maxSat * 0.99 and R.fuel > 0 then
      R.temp = R.temp - (1 - conversion)
    else
      R.temp = R.temp + riseAmount * 10
    end
  else
    R.temp = R.temp + riseAmount * 10
  end
  local baseMaxRFt = toInt((R.maxSat / 1000) * OUT_MULT * 1.5)
  local maxRFt = toInt(baseMaxRFt * (1 + conversion * 2))
  R.gen = (1 - saturation) * maxRFt
  R.sat = toInt(R.sat + R.gen)
  local k = R.temp > 8000 and 1 + (R.temp - 8000) ^ 2 * 0.0000025
    or R.temp > 2000 and 1 or R.temp > 1000 and (R.temp - 1000) / 1000 or 0
  R.k = k
  R.drain = toInt(math.min(k * (1 - saturation) * (baseMaxRFt / 10.923556), INT_MAX))
  R.field = R.field - R.drain
  if LINEAR then
    R.fuelRate = k * (1 - saturation) * (0.001 * USAGE_MULT)
  else
    R.fuelRate = k * (1 - math.max(saturation - 0.1, 0) ^ 0.3) * (0.001 * USAGE_MULT)
  end
  R.unit = R.unit + R.fuelRate
  if R.unit >= 1 and R.fuel > 0 then
    local n = math.floor(R.unit)
    R.fuel = R.fuel - n
    R.conv = R.conv + n
    R.unit = R.unit - n
  end
  if R.field <= 0 and not R.boom then R.boom = true; R.boomTick = SIM.tick end
end

local function coreTick()
  if R.boom then return end
  if R.state == "OFFLINE" then
    if R.temp > 20 then R.temp = R.temp - 0.5 end
    R.field = math.max(0, R.field - R.maxField * 0.0005)
    R.sat = toInt(math.max(0, R.sat - R.maxSat * 0.000001))
  elseif R.state == "STARTING" then
    if not R.init then
      local total = R.fuel + R.conv
      R.maxField = (total / RATIO) * 96.45061728395062 * 100
      R.maxSat = toInt((total / RATIO) * 96.45061728395062 * 1000)
      R.sat = math.min(R.sat, R.maxSat)
      R.field = math.min(R.field, R.maxField)
      R.init = true
    end
  else
    runTick()
  end
  if R.excess > 0 or (R.fuel + R.conv) < FUEL_STORAGE then
    local use = math.min(FUEL_STORAGE - (R.fuel + R.conv), R.excess)
    R.fuel = R.fuel + use
    R.excess = R.excess - use
  end
end

local function injectEnergy(e)
  local inj = 0
  if R.state == "STARTING" then
    if not R.init then return 0 end
    if R.field < R.maxField / 2 then
      inj = math.min(e, toInt(R.maxField / 2) - toInt(R.field) + 1)
      R.field = math.min(R.field + inj, R.maxField / 2)
    elseif R.sat < R.maxSat / 2 then
      inj = math.min(e, toInt(R.maxSat / 2) - R.sat)
      R.sat = R.sat + inj
    elseif R.temp < 2000 then
      inj = e
      R.temp = math.min(2000, R.temp + e / (1000 + (R.fuel / RATIO) * 10))
    end
  elseif R.state == "ONLINE" or R.state == "STOPPING" then
    inj = e
    R.field = math.min(R.maxField, R.field + e * (1 - R.field / R.maxField))
  end
  return inj
end

local function round(x, m) return math.floor(x * m + 0.5) / m end

local function reactorInfo()
  local status
  if R.state == "STARTING" then status = canStart() and "charged" or "charging"
  else status = R.state:lower() end
  return {
    temperature = round(R.temp, 100), fieldStrength = round(R.field, 100), maxFieldStrength = round(R.maxField, 100),
    energySaturation = R.sat, maxEnergySaturation = R.maxSat,
    fuelConversion = round(R.conv + R.unit, 1000), maxFuelConversion = R.fuel + R.conv,
    generationRate = toInt(R.gen), fieldDrainRate = R.drain,
    fuelConversionRate = math.floor(R.fuelRate * 1e6 + 0.5), status = status,
  }
end

-- ======================= гейты, источник, логистика =======================
local function newGate(addr)
  return { address = addr, low = 0, high = 0, override = false, ovFlow = 0, moved = 0, castErr = 0 }
end
local GIN, GOUT = newGate("gate-in-0000"), newGate("gate-out-0000")
local function gateFlow(g) if g.override then return g.ovFlow end return g.low end   -- сигнал 0

local SRC = { rate = math.huge }         -- источник RF на входе (RF/t)
local LOG = { insert = true, extract = true, insRate = 8, extRate = 64 }   -- блоков/тик, осколков/тик
local STAT = { inRF = 0, outRF = 0, shardsOut = 0, fuelIn = 0, maxTemp = 0, minField = 100, maxConv = 0,
               minFieldOnline = 100, timeline = {}, statusAt = {} }

local function worldTick()
  SIM.tick = SIM.tick + 1
  coreTick()
  -- источник → входной гейт → инжектор
  GIN.moved = 0
  local offer = math.min(SRC.rate, INT_MAX)
  local pass = math.min(math.max(0, gateFlow(GIN) - GIN.moved), INT_MAX)   -- target.receiveEnergy(sim)=MAX
  local inj = injectEnergy(math.min(offer, pass))
  GIN.moved = GIN.moved + inj
  STAT.inRF = inj
  -- стабилизатор → выходной гейт → мусорка
  GOUT.moved = 0
  if R.state == "ONLINE" and not R.boom then
    local want = math.min(R.sat, toInt(R.maxSat / 100))
    local got = math.min(want, math.max(0, gateFlow(GOUT) - GOUT.moved))
    R.sat = R.sat - got
    GOUT.moved = GOUT.moved + got
    STAT.outRF = got
  else
    STAT.outRF = 0
  end
  -- логистика: кондуит вынимает осколки, транслокатор кладёт блоки
  if LOG.extract and R.conv > SHARD then
    local n = math.min(math.floor(R.conv / SHARD), LOG.extRate)
    R.conv = R.conv - n * SHARD
    STAT.shardsOut = STAT.shardsOut + n
  end
  if LOG.insert and (R.fuel + R.conv) < FUEL_STORAGE then
    local v = LOG.insRate * 162
    STAT.fuelIn = STAT.fuelIn + v
    if v > FUEL_STORAGE - (R.fuel + R.conv) then
      v = v - (FUEL_STORAGE - (R.fuel + R.conv))
      R.fuel = FUEL_STORAGE - R.conv
      R.excess = R.excess + v
    else
      R.fuel = R.fuel + v
    end
  end
  -- статистика
  if R.temp > STAT.maxTemp then STAT.maxTemp = R.temp end
  local cp = (R.conv + R.fuel) > 0 and R.conv / (R.conv + R.fuel) * 100 or 0
  if R.maxField > 0 and R.state ~= "OFFLINE" then
    local fp = R.field / R.maxField * 100
    if fp < STAT.minField then STAT.minField = fp end
    if R.state == "ONLINE" and fp < STAT.minFieldOnline then STAT.minFieldOnline = fp end
  end
  if cp > STAT.maxConv then STAT.maxConv = cp end
  if R.state ~= STAT.lastState then
    STAT.timeline[#STAT.timeline + 1] = string.format("%6.1f с  %s", SIM.tick / 20, R.state)
    STAT.statusAt[R.state] = STAT.statusAt[R.state] or SIM.tick
    STAT.lastState = R.state
  end
  if SIM.onTick then SIM.onTick() end
  local f = SIM.script and SIM.script[SIM.tick]
  if f then SIM.script[SIM.tick] = nil; f() end
end

-- ======================= моки OpenComputers =======================
local function cost() worldTick() end   -- непрямой вызов компонента = 1 тик

local function gateProxy(g)
  local function num(v, name)
    if type(v) ~= "number" then error("Expected Number got " .. type(v)) end
    if math.type(v) == "integer" then   -- как (Double) args[0] в TileGate при целом из Lua 5.3
      g.castErr = g.castErr + 1
      error("java.lang.ClassCastException: java.lang.Integer cannot be cast to java.lang.Double (" .. name .. ")")
    end
    return toInt(v)
  end
  return {
    address = g.address, type = "flux_gate",
    getFlow = function() cost(); return gateFlow(g) end,
    getOverrideEnabled = function() cost(); return g.override end,
    setOverrideEnabled = function(v) cost(); if type(v) ~= "boolean" then error("Expected Boolean") end g.override = v end,
    setFlowOverride = function(v) cost(); g.ovFlow = num(v, "setFlowOverride") end,
    setSignalLowFlow = function(v) cost(); g.low = num(v, "setSignalLowFlow") end,
    setSignalHighFlow = function(v) cost(); g.high = num(v, "setSignalHighFlow") end,
    getSignalLowFlow = function() cost(); return g.low end,
    getSignalHighFlow = function() cost(); return g.high end,
  }
end

local reactorProxy = {
  address = "reactor-0000", type = "draconic_reactor",
  getReactorInfo = function() cost(); if R.boom then error("tile removed") end return reactorInfo() end,
  chargeReactor = function() cost(); if canCharge() then R.state = "STARTING"; return true end return false end,
  activateReactor = function() cost(); if canStart() then R.state = "ONLINE"; return true end return false end,
  stopReactor = function() cost(); if canStop() then R.state = "STOPPING"; return true end return false end,
}

local SCREEN = { W = 160, H = 50, fg = 0xFFFFFF, bg = 0, cells = {} }
local gpuProxy = {
  address = "gpu-0000", type = "gpu",
  maxResolution = function() return 160, 50 end,
  getResolution = function() return SCREEN.W, SCREEN.H end,
  setResolution = function(w, h) SCREEN.W, SCREEN.H = w, h; return true end,
  setForeground = function(c) SCREEN.fg = c end,
  setBackground = function(c) SCREEN.bg = c end,
  set = function(x, y, s)
    local i = 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      SCREEN.cells[y * 1000 + x + i] = { ch, SCREEN.fg, SCREEN.bg }
      i = i + 1
    end
    return true
  end,
  fill = function(x, y, w, h, ch)
    for yy = y, y + h - 1 do for xx = x, x + w - 1 do SCREEN.cells[yy * 1000 + xx] = { ch, SCREEN.fg, SCREEN.bg } end end
    return true
  end,
}

local COMPS = { [reactorProxy.address] = reactorProxy, [gpuProxy.address] = gpuProxy }
local GATES_CONNECTED = true
local function regGates()
  if GATES_CONNECTED then
    COMPS[GIN.address] = gateProxy(GIN)
    COMPS[GOUT.address] = gateProxy(GOUT)
  end
end

local component = {
  isAvailable = function(t) for _, c in pairs(COMPS) do if c.type == t then return true end end return false end,
  get = function(a, t)
    for addr, c in pairs(COMPS) do
      if addr:sub(1, #a) == a and (not t or c.type == t) then return addr end
    end
    return nil, "no such component"
  end,
  proxy = function(a) return COMPS[a] end,
  list = function(t)
    local r = {}
    for addr, c in pairs(COMPS) do if not t or c.type == t then r[addr] = c.type end end
    local k
    return setmetatable(r, { __call = function() k = next(r, k); return k, k and r[k] end })
  end,
}
setmetatable(component, { __index = function(_, k)
  for _, c in pairs(COMPS) do if c.type == k then return c end end
end })

local QUEUE, SCRIPT = {}, {}
SIM.script = SCRIPT
local computer = {
  uptime = function() return SIM.tick / 20 end,
  beep = function() end,
}
local event = {
  pull = function(timeout)
    if #QUEUE > 0 then return table.unpack(table.remove(QUEUE, 1)) end
    local n = math.max(1, math.floor((timeout or 0.05) * 20 + 0.5))
    for _ = 1, n do
      worldTick()
      if #QUEUE > 0 then return table.unpack(table.remove(QUEUE, 1)) end
    end
    return nil
  end,
}

local serialization = {
  serialize = function(v)
    local function ser(x)
      if type(x) == "table" then
        local parts = {}
        for k, val in pairs(x) do
          local key = type(k) == "string" and ("[%q]"):format(k) or ("[" .. tostring(k) .. "]")
          parts[#parts + 1] = key .. "=" .. ser(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      elseif type(x) == "string" then return ("%q"):format(x)
      else return tostring(x) end
    end
    return ser(v)
  end,
  unserialize = function(s) local f = load("return " .. s, "ser", "t", {}); return f and f() end,
}
local unicodeLib = {
  len = function(s) return utf8.len(s) or #s end,
  sub = function(s, i, j)
    local n = utf8.len(s) or #s
    j = j or n
    if i < 0 then i = n + i + 1 end
    if j < 0 then j = n + j + 1 end
    if i < 1 then i = 1 end
    if j > n then j = n end
    if i > j then return "" end
    local a = utf8.offset(s, i)
    local b = utf8.offset(s, j + 1)
    return s:sub(a, (b or #s + 1) - 1)
  end,
}

package.loaded.component = component
package.loaded.computer = computer
package.loaded.event = event
package.loaded.serialization = serialization
package.loaded.unicode = unicodeLib

-- ======================= запуск программы =======================
local TMP = os.tmpname()
os.remove(TMP)
DRC_CFG_PATH = TMP .. "-drc.cfg"     -- luacheck: ignore
DRC_HW_PATH  = TMP .. "-drc-hw.cfg"  -- luacheck: ignore
DRC_LOG_PATH = TMP .. "-drc.log"     -- luacheck: ignore
local PLOG = {}
DRC_ON_LOG = function(m, k)          -- luacheck: ignore
  PLOG[#PLOG + 1] = { t = SIM.tick / 20, m = m, k = k }
  if os.getenv("DRC_SHOW_LOG") then print(string.format("  [%7.1f с] %-4s %s", SIM.tick / 20, k, m)) end
end

local function writeHW(t)
  local f = io.open(DRC_HW_PATH, "w"); f:write(serialization.serialize(t)); f:close()
end

local function at(sec, f) SCRIPT[math.floor(sec * 20)] = f end
local function touch(x, y) QUEUE[#QUEUE + 1] = { "touch", "screen", x, y, 0, "player" } end
local function interrupt() QUEUE[#QUEUE + 1] = { "interrupted" } end
local function press(x, y) touch(x, y); touch(x, y) end   -- двойное нажатие (кнопки с подтверждением)

-- координаты кнопок (RX = 160 − 48 = 112)
local BTN = {
  start = { 115, 30 }, stop = { 140, 30 }, reset = { 115, 34 }, auto = { 140, 34 },
  settings = { 115, 38 }, exit = { 140, 38 },
}

local function dumpScreen(path)
  local f = io.open(path, "w")
  f:write(SCREEN.W, "\t", SCREEN.H, "\n")
  for y = 1, SCREEN.H do
    for x = 1, SCREEN.W do
      local c = SCREEN.cells[y * 1000 + x]
      if c then f:write(y, "\t", x, "\t", c[2], "\t", c[3], "\t", c[1], "\n") end
    end
  end
  f:close()
end

local function screenText(y)
  local t = {}
  for x = 1, SCREEN.W do local c = SCREEN.cells[y * 1000 + x]; t[#t + 1] = c and c[1] or " " end
  return table.concat(t)
end
local function screenFind(s)
  for y = 1, SCREEN.H do if screenText(y):find(s, 1, true) then return y end end
end

local function hasLog(pat, kind)
  for _, e in ipairs(PLOG) do if e.m:find(pat) and (not kind or e.k == kind) then return e end end
end

local function fillFuel() R.fuel = FUEL_STORAGE end

-- прогон физики без программы (ручной Method 1) — для resume
local function preRun(sec)
  GIN.low, GOUT.low = 2000000000, 2000000000
  R.state = "STARTING"
  for _ = 1, 20 * 30 do worldTick(); if canStart() then break end end
  R.state = "ONLINE"
  for _ = 1, sec * 20 do worldTick() end
end

local FAILS = 0
local function check(cond, msg)
  print((cond and "  ✔ " or "  ✘ ") .. msg)
  if not cond then FAILS = FAILS + 1 end
end

local function runProgram(stopSec)
  at(stopSec, interrupt)
  local ok, err = pcall(dofile, DIR .. "/drc.lua")
  if not ok then print("  программа упала: " .. tostring(err)); FAILS = FAILS + 1 end
end

local function summary()
  print(string.format("  итог: %s, T=%.0f °C (макс %.0f), поле мин %.2f%% (в работе %.2f%%), конверсия макс %.2f%%",
    R.boom and ("ВЗРЫВ на " .. string.format("%.1f с", R.boomTick / 20)) or R.state, R.temp, STAT.maxTemp,
    STAT.minField, STAT.minFieldOnline, STAT.maxConv))
  print(string.format("  осколков вынуто: %d за %.0f с, топлива подано: %d", STAT.shardsOut, SIM.tick / 20, STAT.fuelIn))
  print("  статусы: " .. table.concat(STAT.timeline, " | "))
  local fail = 0
  for _, g in ipairs({ GIN, GOUT }) do fail = fail + g.castErr end
  if fail > 0 then print("  ClassCastException в гейтах: " .. fail) end
end

-- ======================= сценарии =======================
local SC = {}

function SC.basic()
  writeHW({ inGate = GIN.address, outGate = GOUT.address })
  fillFuel()
  local rateAt = {}
  at(600, function() rateAt[1] = STAT.shardsOut end)
  at(900, function() rateAt[2] = STAT.shardsOut end)
  at(899, function() if os.getenv("DRC_DUMP") then QUEUE[#QUEUE + 1] = { "noop" } end end)
  at(900.5, function() if os.getenv("DRC_DUMP") then dumpScreen(os.getenv("DRC_DUMP")) end end)
  runProgram(901)
  summary()
  local perMin = (rateAt[2] - rateAt[1]) / 5
  print(string.format("  скорость в равновесии: %.1f осколков/мин", perMin))
  check(not R.boom, "без взрыва")
  check(R.state == "ONLINE", "реактор работает")
  check(GIN.override and GIN.ovFlow == INT_MAX and GOUT.override and GOUT.ovFlow == INT_MAX, "оба гейта на override 2 147 483 647")
  check(GIN.castErr == 0 and GOUT.castErr == 0, "нет ClassCastException (числа передаются дробными)")
  check(perMin > 10, "больше 10 осколков/мин (вики: ~12)")
  check(STAT.maxTemp > 13000 and STAT.maxTemp < 16000, "равновесная температура 13–16 тыс °C")
  check(STAT.minFieldOnline > 99, "поле в работе > 99%")
  check(not hasLog("АВАРИЙНЫЙ"), "без аварий")
end

function SC.starve()
  writeHW({ inGate = GIN.address, outGate = GOUT.address })
  fillFuel()
  at(300, function() LOG.insert = false end)
  runProgram(1800)
  summary()
  check(hasLog("АВАРИЙНЫЙ СТОП: конверсия"), "аварийный стоп по конверсии")
  check(not R.boom, "без взрыва")
  check(R.state == "OFFLINE", "реактор погашен до конца")
  check(R.fuel > 0, "несконвертированное топливо осталось (остывание возможно)")
  check(not hasLog("Зарядка:", "ok") or select(2, pcall(function() return #PLOG end)) and
    (function() local n = 0 for _, e in ipairs(PLOG) do if e.m:find("^Зарядка:") then n = n + 1 end end return n == 1 end)(),
    "после аварии сам не перезапустился")
end

function SC.noextract()
  writeHW({ inGate = GIN.address, outGate = GOUT.address })
  fillFuel()
  at(300, function() LOG.extract = false end)
  runProgram(1800)
  summary()
  check(hasLog("АВАРИЙНЫЙ СТОП: конверсия"), "аварийный стоп по конверсии")
  check(not R.boom, "без взрыва")
  check(R.state == "OFFLINE", "реактор погашен до конца")
end

function SC.weakin()
  writeHW({ inGate = GIN.address, outGate = GOUT.address })
  fillFuel()
  local rate = tonumber(os.getenv("DRC_WEAK") or "") or 14e6
  local fstop = tonumber(os.getenv("DRC_FSTOP") or "")
  if fstop then
    local f = io.open(DRC_CFG_PATH, "w")
    f:write(serialization.serialize({ fieldStop = fstop, fieldWarn = math.min(99, fstop + 4) }))
    f:close()
  end
  at(300, function() SRC.rate = rate end)
  runProgram(1800)
  summary()
  print(string.format("  источник после 300 с: %s RF/t", rate))
  check(hasLog("АВАРИЙНЫЙ СТОП: поле"), "аварийный стоп по полю")
  check(not R.boom, "без взрыва")
  check(R.state == "OFFLINE", "реактор погашен до конца")
end

function SC.inputloss()
  writeHW({ inGate = GIN.address, outGate = GOUT.address })
  fillFuel()
  at(300, function() SRC.rate = 0 end)
  runProgram(400)
  summary()
  print("  (ожидаемо: при полной потере входа на ~14 000 °C поле кончается за доли секунды)")
  check(R.boom and (R.boomTick - 6000) < 40, "взрыв меньше чем за 2 с — программа не может его предотвратить")
end

function SC.resume()
  writeHW({ inGate = GIN.address, outGate = GOUT.address })
  fillFuel()
  preRun(400)
  local t0 = SIM.tick
  runProgram(t0 / 20 + 120)
  summary()
  check(not hasLog("Зарядка:"), "работающий реактор не трогает (без перезарядки)")
  check(R.state == "ONLINE", "реактор работает")
  check(GIN.override and GOUT.override, "гейты переведены на override")
  check(not hasLog("АВАРИЙНЫЙ"), "без аварий")
end

function SC.ctrlc()
  writeHW({ inGate = GIN.address, outGate = GOUT.address })
  fillFuel()
  runProgram(360)
  local st = R.state
  for _ = 1, 20 * 60 do worldTick() end
  summary()
  check(st == "ONLINE" and R.state == "ONLINE" and not R.boom, "после Ctrl+C реактор работает дальше")
  check(GIN.override and GIN.ovFlow == INT_MAX, "вход остался на максимуме")
end

function SC.manual()
  writeHW({ inGate = GIN.address, outGate = GOUT.address })
  fillFuel()
  local offAt, restarted
  at(300, function() press(BTN.stop[1], BTN.stop[2]) end)
  SIM.onTick = function()
    if R.state == "OFFLINE" and SIM.tick > 6000 and not offAt then
      offAt = SIM.tick
      SCRIPT[SIM.tick + 1200] = function() touch(BTN.start[1], BTN.start[2]) end
    end
    if offAt and R.state == "ONLINE" and not restarted then restarted = SIM.tick end
  end
  runProgram(2400)
  summary()
  check(offAt ~= nil, "СТОП (двойное нажатие) погасил реактор")
  check(offAt and (not restarted or restarted > offAt + 1200), "до «ЗАПУСК» сам не перезапускается")
  check(restarted ~= nil, "«ЗАПУСК» снова вывел на online")
  check(not R.boom, "без взрыва")
  if offAt then print(string.format("  остановка заняла %.0f с", (offAt - 6000) / 20)) end
end

function SC.settings()
  writeHW({ inGate = GIN.address, outGate = GOUT.address })
  fillFuel()
  at(5, function() touch(BTN.settings[1], BTN.settings[2]) end)
  at(6, function()
    local y = screenFind("Конверсия: аварийный стоп")
    check(y ~= nil, "экран настроек открыт")
    if y then touch(160 - 40 + 20 - 34 + 23 + 2, y) end       -- «+» у convStop
  end)
  at(7, function()
    local y = screenFind("Конверсия: аварийный стоп")
    check(y and screenText(y):find("13%%") ~= nil, "convStop 12% → 13% по «+»")
    if os.getenv("DRC_DUMP") then dumpScreen(os.getenv("DRC_DUMP")) end
    local by = screenFind("НАЗАД"); if by then touch(80, by) end
  end)
  at(8, function() check(screenFind("Журнал") ~= nil, "«НАЗАД» вернул главный экран") end)
  runProgram(10)
end

function SC.nogates()
  writeHW({})
  GIN.low, GOUT.low = 2000000000, 2000000000          -- игрок выставил гейты руками, как на вики
  fillFuel()
  runProgram(400)
  summary()
  check(hasLog("Гейты не заданы"), "предупреждение «гейты не заданы»")
  check(R.state == "ONLINE" and not R.boom, "работает и без управления гейтами")
end

local list = scenario == "all"
  and { "basic", "starve", "noextract", "weakin", "inputloss", "resume", "ctrlc", "manual", "settings", "nogates" }
  or { scenario }
if #list > 1 then
  -- каждый сценарий в отдельном процессе: у программы и мира своё состояние
  local total = 0
  for _, s in ipairs(list) do
    print("== " .. s)
    local h = io.popen("lua5.3 " .. DIR .. "/tests/sim.lua " .. s .. " 2>&1")
    local out = h:read("a"); h:close()
    io.write(out)
    for _ in out:gmatch("  ✘ ") do total = total + 1 end
    if out:find("программа упала") then total = total + 1 end
  end
  print(total == 0 and "ВСЕ СЦЕНАРИИ ПРОЙДЕНЫ" or ("ПРОВАЛОВ: " .. total))
  os.exit(total == 0 and 0 or 1)
end

if not SC[scenario] then print("нет сценария " .. scenario); os.exit(2) end
regGates()
SC[scenario]()
for _, p in ipairs({ DRC_CFG_PATH, DRC_HW_PATH, DRC_LOG_PATH }) do os.remove(p) end
os.exit(FAILS == 0 and 0 or 1)
