-- =====================================================================
--  DRC — Draconic Reactor Control (GTNH, Draconic Evolution 1.7.10)
--  OpenComputers / OpenOS. Один компьютер = один реактор.
--
--  Режим «максимальная скорость» (Method 1 с вики GTNH): оба flux gate
--  держатся на максимуме, насыщение у нуля, реактор сам выходит на
--  ~14 000 °C и делает ~1 хаос-осколок за 5 с. Программа:
--   * ведёт запуск: топливо → chargeReactor → activateReactor;
--   * держит оба гейта на максимуме (override) и возвращает уставку,
--     если её кто-то поменял;
--   * аварийно гасит реактор (stopReactor) по полю, конверсии, температуре;
--   * никогда не уменьшает вход: при любом сбое программы гейты остаются
--     в безопасном состоянии (вход на максимуме).
--
--  Железо: adapter у стабилизатора или инжектора (draconic_reactor),
--  adapter у каждого flux gate (flux_gate). Адреса гейтов настраивает
--  установщик (drc-install gates → /home/drc-hw.cfg).
--
--  Экран: T3, видеокарта T3, 160×50. Выход: «ВЫХОД» дважды или Ctrl+Alt+C
--  (реактор продолжает работать, гейты остаются на максимуме).
--
--  Механика — из TileReactorCore.java (GTNewHorizons/Draconic-Evolution):
--   * взрыв только при fieldCharge <= 0;
--   * стабилизаторы отдают RF только в статусе online;
--   * в stopping реактор остывает, только когда насыщение >= 99%
--     и есть несконвертированное топливо; гаснет при T <= 2001 °C;
--   * maxField / maxSaturation фиксируются в начале зарядки по топливу;
--   * OC читает поле уже после расхода тика: при бесконечном входе видно
--     100% − fieldDrainRate/maxField (~88% на 14 000 °C). Защита смотрит на
--     поле до расхода: (fieldStrength + fieldDrainRate) / maxFieldStrength.
-- =====================================================================

local VERSION = "0.1.1"

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local serial    = require("serialization")
local unicode   = require("unicode")

-- ============================== ЖЕЛЕЗО ==============================
local HW = {
  reactor    = "",            -- адрес draconic_reactor ("" — первый найденный)
  inGate     = "",            -- адрес flux_gate на входе (источник → инжектор)
  outGate    = "",            -- адрес flux_gate на выходе (стабилизатор → утилизация)
  inFlow     = 2147483647,    -- RF/t, уставка входа (максимум int)
  outFlow    = 2147483647,    -- RF/t, уставка выхода
  alarmRs    = "",            -- адрес redstone для сигнала тревоги ("" — нет)
  alarmSide  = -1,            -- сторона redstone (0–5), -1 — нет
  maxFuel    = 524880,        -- ёмкость реактора по топливу (конфиг GTNH)
  shardFuel  = 26244,         -- топлива на один хаос-осколок
  resolution = {160, 50},
}
local CFG_PATH = DRC_CFG_PATH or "/home/drc.cfg"       -- luacheck: ignore (глобал для тестов)
local HW_PATH  = DRC_HW_PATH  or "/home/drc-hw.cfg"    -- luacheck: ignore
local LOG_PATH = DRC_LOG_PATH or "/home/drc.log"       -- luacheck: ignore

local HW_SOURCE = "по умолчанию"
do
  local f = io.open(HW_PATH, "r")
  if f then
    local data = f:read("*a")
    f:close()
    local ok, t = pcall(serial.unserialize, data)
    if ok and type(t) == "table" then
      for k, v in pairs(t) do
        if HW[k] ~= nil and type(v) == type(HW[k]) then HW[k] = v end
      end
      HW_SOURCE = HW_PATH
    end
  end
end

local DEFAULTS = {
  auto         = true,   -- сам заряжать и запускать реактор
  minStartFuel = 100,    -- %, сколько топлива нужно перед зарядкой (maxField считается по нему)
  fieldWarn    = 97,     -- %, предупреждение по полю (в норме ~99.4% при входе 2.1 млрд)
  fieldStop    = 90,     -- %, аварийный стоп по полю (сим: 80–95% одинаково, 50% — хуже)
  convWarn     = 8,      -- %, предупреждение по конверсии
  convStop     = 12,     -- %, аварийный стоп по конверсии
  tempWarn     = 16000,  -- °C
  tempStop     = 17500,  -- °C (при 20 000 °C формула температуры уходит в разнос)
  stats = { shards = 0, runSec = 0, starts = 0, estops = 0 },
}
local LIMITS = {
  minStartFuel = {10, 100}, fieldWarn = {5, 99}, fieldStop = {1, 95},
  convWarn = {1, 90}, convStop = {1, 95}, tempWarn = {2500, 19500}, tempStop = {2500, 19500},
}
local STEP = { minStartFuel = 5, fieldWarn = 5, fieldStop = 5, convWarn = 1, convStop = 1, tempWarn = 500, tempStop = 500 }

local unpack = table.unpack or unpack

-- ============================== УТИЛИТЫ ==============================
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

local function copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return r
end

local function pcallr(f, ...)          -- ok, результат…
  if type(f) ~= "function" and type(f) ~= "table" then return false, "нет метода" end
  return pcall(f, ...)
end

local function fmtInt(n)
  if n == nil then return "?" end
  local s = string.format("%.0f", n)
  local neg = s:sub(1, 1) == "-"
  if neg then s = s:sub(2) end
  s = s:reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
  return (neg and "-" or "") .. s
end

local function fmtBig(n)
  if n == nil then return "?" end
  local a = math.abs(n)
  if a >= 1e12 then return string.format("%.2f трлн", n / 1e12)
  elseif a >= 1e9 then return string.format("%.2f млрд", n / 1e9)
  elseif a >= 1e6 then return string.format("%.2f млн", n / 1e6)
  elseif a >= 1e4 then return string.format("%.1f тыс", n / 1e3) end
  return fmtInt(n)
end

local function fmtTime(sec)
  sec = math.floor(sec or 0)
  local h, m, s = sec // 3600, (sec % 3600) // 60, sec % 60
  if h > 0 then return string.format("%d ч %02d мин", h, m) end
  return string.format("%d:%02d", m, s)
end

local function ulen(s) return unicode.len(s) end
local function usub(s, i, j) return unicode.sub(s, i, j) end
local function fit(s, w) if ulen(s) > w then return usub(s, 1, math.max(0, w - 1)) .. "…" end return s end

-- ============================== КОНФИГ ==============================
local CFG

local function loadCfg()
  local c = copy(DEFAULTS)
  local f = io.open(CFG_PATH, "r")
  if f then
    local data = f:read("*a")
    f:close()
    local ok, t = pcall(serial.unserialize, data)
    if ok and type(t) == "table" then
      for k, v in pairs(t) do
        if k == "stats" and type(v) == "table" then
          for sk, sv in pairs(v) do if type(sv) == "number" then c.stats[sk] = sv end end
        elseif c[k] ~= nil and type(v) == type(c[k]) then
          c[k] = v
        end
      end
    end
  end
  for k, lim in pairs(LIMITS) do c[k] = clamp(c[k], lim[1], lim[2]) end
  return c
end

local function saveCfg()
  local f = io.open(CFG_PATH, "w")
  if f then f:write(serial.serialize(CFG)); f:close() end
end

-- ============================== КОМПОНЕНТЫ ==============================
local gpu, reactor, gIn, gOut, rs

local function proxyOf(addr, kind)
  if addr and addr ~= "" then
    local full = component.get(addr, kind)
    if full then return component.proxy(full) end
    return nil
  end
  return nil
end

local function bindComponents()
  if not component.isAvailable("gpu") then return false, "Нет видеокарты" end
  gpu = component.gpu
  if HW.reactor ~= "" then
    reactor = proxyOf(HW.reactor, "draconic_reactor")
  elseif component.isAvailable("draconic_reactor") then
    reactor = component.draconic_reactor
  end
  if not reactor then
    return false, "Нет draconic_reactor: поставь adapter вплотную к стабилизатору или инжектору"
  end
  gIn  = proxyOf(HW.inGate, "flux_gate")
  gOut = proxyOf(HW.outGate, "flux_gate")
  if HW.alarmRs ~= "" and HW.alarmSide >= 0 then rs = proxyOf(HW.alarmRs, "redstone") end
  return true
end

-- ============================== СОСТОЯНИЕ ==============================
local STATUS_RU = {
  offline = "ВЫКЛЮЧЕН", charging = "ЗАРЯДКА", charged = "ЗАРЯЖЕН", online = "РАБОТАЕТ",
  stopping = "ОСТАНОВКА", invalid = "НЕВЕРНАЯ СБОРКА", none = "НЕТ СВЯЗИ",
}

local S = {
  running = true, screen = "main", dirty = true,
  info = nil, status = "none", lastStatus = nil,
  alarm = nil,          -- текст аварии (защёлка до «СБРОС»)
  hold = false,         -- ручная пауза после «СТОП»
  startReq = false,     -- «ЗАПУСК» нажат: дойти до online
  warn = {},            -- активные предупреждения: ключ → текст
  gateMode = "?",       -- «программа» / «вручную»
  gateErr = nil,
  lastConv = nil, shardsSession = 0,
  tempRate = 0, lastTemp = nil, lastTempAt = nil,
  chargeProbe = nil, chargeProbeAt = 0,
  lowFuelSince = nil,
  pollFail = 0,
  confirm = {},         -- кнопка → время до которого ждём второе нажатие
  startedAt = 0, onlineSince = nil,
}

-- Реальное время: os.date в OC показывает игровые часы (1 с = 72 игровых).
-- Берём время изменения файла в /tmp (реальные часы хоста) и дальше считаем по uptime.
local CLOCK_BASE
local function initClock()
  local ok, fs = pcall(require, "filesystem")
  if not ok or not fs or not fs.lastModified then return end
  local p = "/tmp/.drc-clock"
  local f = io.open(p, "w")
  if not f then return end
  f:write("t"); f:close()
  local ok2, t = pcall(fs.lastModified, p)
  if not ok2 or type(t) ~= "number" or t <= 0 then return end
  if t > 1e11 then t = t / 1000 end          -- мс → с
  CLOCK_BASE = t - computer.uptime()
end
local function clock(fmt)
  if CLOCK_BASE then return os.date(fmt or "%H:%M:%S", math.floor(CLOCK_BASE + computer.uptime())) end
  local s = math.floor(computer.uptime() - (S.startedAt or 0))
  return string.format("+%d:%02d:%02d", s // 3600, (s % 3600) // 60, s % 60)
end

local LOG = {}
local function logFile(line)
  local f = io.open(LOG_PATH, "a")
  if f then f:write(line, "\n"); f:close() end
end

local function log(msg, kind)
  kind = kind or "info"
  local e = { t = clock(), m = msg, k = kind }
  table.insert(LOG, 1, e)
  while #LOG > 60 do table.remove(LOG) end
  S.dirty = true
  if kind ~= "info" then logFile(clock("%Y-%m-%d %H:%M:%S") .. " [" .. kind .. "] " .. msg) end
  if DRC_ON_LOG then DRC_ON_LOG(msg, kind) end   -- luacheck: ignore (хук для тестов)
end

local function setWarn(key, text)
  if text then
    if S.warn[key] ~= text then
      if not S.warn[key] then log(text, "warn") end
      S.warn[key] = text
      S.dirty = true
    end
  elseif S.warn[key] then
    S.warn[key] = nil
    S.dirty = true
  end
end

local function alarmOut(on)
  if rs then pcall(rs.setOutput, HW.alarmSide, on and 15 or 0) end
end

-- ============================== ГЕЙТЫ ==============================
local function enforceGate(g, flow, name)
  if not g then return true end
  local ok1, ov = pcallr(g.getOverrideEnabled)
  local ok2, cur = pcallr(g.getFlow)
  if not ok1 or not ok2 then return false, name .. ": нет ответа" end
  -- число передаётся дробным: в TileGate стоит каст (Double) args[0]
  if ov ~= true then
    local ok, e = pcallr(g.setFlowOverride, flow + 0.0)
    if not ok then return false, name .. ": " .. tostring(e) end
    ok, e = pcallr(g.setOverrideEnabled, true)
    if not ok then return false, name .. ": " .. tostring(e) end
    return true, name .. ": override включён, " .. fmtBig(flow) .. " RF/t"
  elseif math.abs((tonumber(cur) or 0) - flow) > 0.5 then
    local ok, e = pcallr(g.setFlowOverride, flow + 0.0)
    if not ok then return false, name .. ": " .. tostring(e) end
    return true, name .. ": уставка возвращена " .. fmtBig(cur) .. " → " .. fmtBig(flow)
  end
  return true
end

local function enforceGates()
  if not gIn and not gOut then S.gateMode = "вручную"; return end
  S.gateMode = (gIn and gOut) and "программа" or "частично"
  local errs = {}
  for _, g in ipairs({ { gIn, HW.inFlow, "Вход" }, { gOut, HW.outFlow, "Выход" } }) do
    local ok, msg = enforceGate(g[1], g[2], g[3])
    if not ok then errs[#errs + 1] = msg elseif msg then log(msg, "info") end
  end
  local e = #errs > 0 and table.concat(errs, "; ") or nil
  if e ~= S.gateErr then
    S.gateErr = e
    if e then log("Гейт: " .. e, "err") end
  end
end

-- ============================== РЕАКТОР ==============================
local function pct(a, b) if not a or not b or b <= 0 then return 0 end return a / b * 100 end

local function derive(d)
  d.fieldRaw = pct(d.fieldStrength, d.maxFieldStrength)            -- как в GUI: после расхода тика
  d.fieldP = math.min(100, pct((d.fieldStrength or 0) + (d.fieldDrainRate or 0), d.maxFieldStrength))   -- до расхода
  local c = (d.maxFuelConversion or 0) > 0 and d.fuelConversion / d.maxFuelConversion * 1.3 - 0.3 or 0
  d.chaos = c
  -- оценка остановки: насыщение до 99% (экспонента), потом остывание на (1 − c) °C за тик
  local s = (d.maxEnergySaturation or 0) > 0 and d.energySaturation / d.maxEnergySaturation or 0
  local maxRFt = (s < 1 and (d.generationRate or 0) > 0) and d.generationRate / (1 - s) or 0
  if maxRFt > 0 and s < 0.99 then
    d.etaSat = math.log((1 - s) / 0.01) / (maxRFt / d.maxEnergySaturation) / 20
  else
    d.etaSat = 0
  end
  d.etaCool = math.max(0, ((d.temperature or 0) - 2001) / math.max(0.05, 1 - c)) / 20
  d.satP   = pct(d.energySaturation, d.maxEnergySaturation)
  d.convP  = pct(d.fuelConversion, d.maxFuelConversion)
  d.total  = d.maxFuelConversion or 0
  d.fuel   = math.max(0, (d.maxFuelConversion or 0) - (d.fuelConversion or 0))
  d.fuelPerTick = (d.fuelConversionRate or 0) / 1e6
  d.shardsMin = d.fuelPerTick * 1200 / HW.shardFuel
  local t = d.temperature or 0
  d.k = t > 8000 and 1 + (t - 8000) ^ 2 * 0.0000025 or t > 2000 and 1 or t > 1000 and (t - 1000) / 1000 or 0
  return d
end

local function poll()
  local ok, d = pcallr(reactor.getReactorInfo)
  if not ok or type(d) ~= "table" then
    S.pollFail = S.pollFail + 1
    if S.pollFail == 3 then log("Нет ответа от реактора: " .. tostring(d), "err") end
    if S.pollFail >= 3 then S.info = nil; S.status = "none" end
    return nil
  end
  S.pollFail = 0
  S.info = derive(d)
  S.status = d.status or "none"
  return S.info
end

local function call(name)
  local ok, r = pcallr(reactor[name])
  if not ok then log(name .. ": " .. tostring(r), "err"); return false end
  return r == true
end

local function emergency(reason)
  if S.alarm then return end
  S.alarm = reason
  CFG.stats.estops = CFG.stats.estops + 1
  log("АВАРИЙНЫЙ СТОП: " .. reason, "err")
  enforceGates()                         -- вход точно на максимуме
  if S.status == "online" or S.status == "charging" or S.status == "charged" then
    if not call("stopReactor") then log("stopReactor не принят", "err") end
  end
  alarmOut(true)
  pcall(computer.beep, 1200, 0.2)
  saveCfg()
end

local function startCharge(manual)
  local d = S.info
  local need = HW.maxFuel * CFG.minStartFuel / 100
  if d.total < need then
    if manual then log(("Мало топлива: %s из %s нужных"):format(fmtInt(d.total), fmtInt(need)), "warn") end
    return false
  end
  enforceGates()
  if call("chargeReactor") then
    log(("Зарядка: топливо %s (%.0f%% ёмкости)"):format(fmtInt(d.total), pct(d.total, HW.maxFuel)), "ok")
    S.chargeProbe, S.chargeProbeAt = nil, computer.uptime()
    return true
  end
  log("chargeReactor не принят (сборка? топливо?)", "warn")
  return false
end

local function onStatusChange(old, new)
  log(("Статус: %s → %s"):format(STATUS_RU[old] or tostring(old), STATUS_RU[new] or new),
    new == "online" and "ok" or "info")
  if new == "online" then
    S.onlineSince = computer.uptime()
    S.startReq = false
  elseif old == "online" then
    if S.onlineSince then CFG.stats.runSec = CFG.stats.runSec + (computer.uptime() - S.onlineSince) end
    S.onlineSince = nil
    saveCfg()
  end
  if new == "offline" and old == "stopping" then
    log("Реактор остановлен" .. (S.alarm and " после аварии — нажми «СБРОС»" or ""), S.alarm and "warn" or "ok")
  end
  if new == "invalid" then log("Сборка реактора нарушена (стабилизаторы/инжектор)", "err") end
  S.lowFuelSince = nil
end

-- проверки работающего реактора
local function protect(d, now)
  if d.fieldP < CFG.fieldStop then
    emergency(("поле %.1f%% < %d%%"):format(d.fieldP, CFG.fieldStop)); return
  end
  if d.convP >= CFG.convStop then
    emergency(("конверсия %.1f%% ≥ %d%%"):format(d.convP, CFG.convStop)); return
  end
  if d.temperature >= CFG.tempStop then
    emergency(("температура %s °C ≥ %s"):format(fmtInt(d.temperature), fmtInt(CFG.tempStop))); return
  end
  setWarn("field", d.fieldP < CFG.fieldWarn and ("Поле %.1f%% — вход не держит расход?"):format(d.fieldP) or nil)
  setWarn("conv", d.convP >= CFG.convWarn and ("Конверсия %.1f%% — осколки не вынимаются или нет топлива"):format(d.convP) or nil)
  setWarn("temp", d.temperature >= CFG.tempWarn and ("Температура %s °C"):format(fmtInt(d.temperature)) or nil)
  if d.total < HW.maxFuel * 0.95 then
    S.lowFuelSince = S.lowFuelSince or now
    if now - S.lowFuelSince > 10 then
      setWarn("fuel", ("Топливо %.0f%% ёмкости — подача не успевает"):format(pct(d.total, HW.maxFuel)))
    end
  else
    S.lowFuelSince = nil
    setWarn("fuel", nil)
  end
end

local function trackShards(d)
  local c = d.fuelConversion or 0
  if S.lastConv and c < S.lastConv - HW.shardFuel * 0.5 then
    local n = math.floor((S.lastConv - c) / HW.shardFuel + 0.5)
    S.shardsSession = S.shardsSession + n
    CFG.stats.shards = CFG.stats.shards + n
  end
  S.lastConv = c
end

local function trackTemp(d, now)
  if S.lastTemp and S.lastTempAt and now > S.lastTempAt then
    local r = (d.temperature - S.lastTemp) / (now - S.lastTempAt)
    S.tempRate = S.tempRate * 0.7 + r * 0.3
  end
  S.lastTemp, S.lastTempAt = d.temperature, now
end

local function tick(now)
  local d = poll()
  if not d then
    if S.pollFail >= 3 then setWarn("link", "Нет связи с реактором (adapter?)") end
    return
  end
  setWarn("link", nil)
  if S.status ~= S.lastStatus then
    if S.lastStatus then onStatusChange(S.lastStatus, S.status) end
    S.lastStatus = S.status
  end
  trackShards(d)
  trackTemp(d, now)

  local st = S.status
  if st == "online" then
    protect(d, now)
  else
    for _, k in ipairs({ "field", "conv", "temp", "fuel" }) do setWarn(k, nil) end
  end

  if st == "stopping" then
    if d.fieldP < CFG.fieldStop then setWarn("sfield", ("Поле %.1f%% при остановке!"):format(d.fieldP))
    else setWarn("sfield", nil) end
  else
    setWarn("sfield", nil)
  end

  if st == "offline" then
    if not S.alarm and not S.hold and (CFG.auto or S.startReq) then
      if d.total >= HW.maxFuel * CFG.minStartFuel / 100 then
        startCharge(S.startReq)
      end
    end
  elseif st == "charging" then
    local probe = (d.fieldStrength or 0) + (d.energySaturation or 0) + (d.temperature or 0)
    if S.chargeProbe == nil or probe > S.chargeProbe + 1 then
      S.chargeProbe, S.chargeProbeAt = probe, now
      setWarn("charge", nil)
    elseif now - S.chargeProbeAt > 20 then
      setWarn("charge", "Зарядка стоит 20 с: нет RF на входе? (гейт, источник)")
    end
  elseif st == "charged" then
    setWarn("charge", nil)
    if not S.alarm and not S.hold and (CFG.auto or S.startReq) then
      if call("activateReactor") then
        CFG.stats.starts = CFG.stats.starts + 1
        log(("Запуск: поле макс %s, насыщение макс %s"):format(fmtBig(d.maxFieldStrength), fmtBig(d.maxEnergySaturation)), "ok")
      end
    end
  end
  S.dirty = true
end

-- ============================== ЭКРАН ==============================
local W, H
local FB, FR, BTN = {}, {}, {}

local C = {
  bg = 0x0B0E14, panel = 0x131822, border = 0x2A3344, text = 0xD8DEE9, dim = 0x7A8599,
  accent = 0xFF8A3D, ok = 0x4CD07D, warn = 0xFFC247, red = 0xFF4848, info = 0x6FB7FF,
  barBg = 0x1C2230,
  btn = 0x24324A, btnFg = 0xFFFFFF, btnRed = 0x7A1E1E, btnGreen = 0x1E6A3A, btnAmber = 0x7A5A12,
  hot = 0xFF5A2A, warm = 0xFFAA33, cool = 0x3FA8FF, purple = 0xB070FF,
}

local function cellsOf(s)
  local t = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
  return t
end

local function put(x, y, s, fg, bg)
  if y < 1 or y > H then return end
  local cs = cellsOf(s)
  for i = 1, #cs do
    local xx = x + i - 1
    if xx >= 1 and xx <= W then
      local c = FB[(y - 1) * W + xx]
      c[1], c[2], c[3] = cs[i], fg, bg
    end
  end
end

local function fill(x, y, w, h, ch, fg, bg)
  for yy = y, y + h - 1 do
    if yy >= 1 and yy <= H then
      for xx = x, x + w - 1 do
        if xx >= 1 and xx <= W then
          local c = FB[(yy - 1) * W + xx]
          c[1], c[2], c[3] = ch, fg, bg
        end
      end
    end
  end
end

local function initBuffers()
  FB, FR = {}, {}
  for i = 1, W * H do FB[i] = { " ", C.text, C.bg }; FR[i] = { nil, nil, nil } end
end

local curFg, curBg
local function flush()
  for y = 1, H do
    local x = 1
    while x <= W do
      local i = (y - 1) * W + x
      local b, f = FB[i], FR[i]
      if b[1] ~= f[1] or b[2] ~= f[2] or b[3] ~= f[3] then
        local fg, bg, x0, parts, trail = b[2], b[3], x, {}, 0
        while x <= W do
          local j = (y - 1) * W + x
          local bb, ff = FB[j], FR[j]
          if bb[2] ~= fg or bb[3] ~= bg then break end
          if bb[1] == ff[1] and bb[2] == ff[2] and bb[3] == ff[3] then
            if trail >= 6 then break end
            trail = trail + 1
          else
            trail = 0
          end
          parts[#parts + 1] = bb[1]
          ff[1], ff[2], ff[3] = bb[1], bb[2], bb[3]
          x = x + 1
        end
        for _ = 1, trail do parts[#parts] = nil end
        if curFg ~= fg then gpu.setForeground(fg); curFg = fg end
        if curBg ~= bg then gpu.setBackground(bg); curBg = bg end
        gpu.set(x0, y, table.concat(parts))
        x = x0 + #parts
      else
        x = x + 1
      end
    end
  end
end

local function button(x, y, w, h, label, fg, bg, fn)
  fill(x, y, w, h, " ", fg, bg)
  put(x + math.floor((w - ulen(label)) / 2), y + math.floor((h - 1) / 2), label, fg, bg)
  BTN[#BTN + 1] = { x, y, x + w - 1, y + h - 1, fn }
end

local function box(x, y, w, h, title, tcol)
  fill(x, y, w, h, " ", C.text, C.panel)
  put(x, y, "┌" .. string.rep("─", w - 2) .. "┐", C.border, C.panel)
  for yy = y + 1, y + h - 2 do
    put(x, yy, "│", C.border, C.panel)
    put(x + w - 1, yy, "│", C.border, C.panel)
  end
  put(x, y + h - 1, "└" .. string.rep("─", w - 2) .. "┘", C.border, C.panel)
  if title then put(x + 2, y, " " .. title .. " ", tcol or C.accent, C.panel) end
end

local function kv(x, y, w, key, val, vcol)
  put(x, y, key, C.dim, C.panel)
  put(x + w - ulen(val), y, val, vcol or C.text, C.panel)
end

-- крупные цифры 3×5, «пиксель» = 2 символа
local GLYPH = {
  ["0"] = { "###", "#.#", "#.#", "#.#", "###" }, ["1"] = { ".#.", "##.", ".#.", ".#.", "###" },
  ["2"] = { "###", "..#", "###", "#..", "###" }, ["3"] = { "###", "..#", "###", "..#", "###" },
  ["4"] = { "#.#", "#.#", "###", "..#", "..#" }, ["5"] = { "###", "#..", "###", "..#", "###" },
  ["6"] = { "###", "#..", "###", "#.#", "###" }, ["7"] = { "###", "..#", "..#", "..#", "..#" },
  ["8"] = { "###", "#.#", "###", "#.#", "###" }, ["9"] = { "###", "#.#", "###", "..#", "###" },
  ["-"] = { "...", "...", "###", "...", "..." }, ["?"] = { "###", "..#", ".##", "...", ".#." },
}
local function bigWidth(str) return #str * 7 - 1 end
local function bigText(x, y, str, fg)
  for i = 1, #str do
    local g = GLYPH[str:sub(i, i)] or GLYPH["?"]
    for row = 1, 5 do
      for c = 1, 3 do
        if g[row]:sub(c, c) == "#" then fill(x + (i - 1) * 7 + (c - 1) * 2, y + row - 1, 2, 1, " ", fg, fg) end
      end
    end
  end
end

-- шкала: value в [0, max], marks = { {значение, цвет, подпись}, … }
local function gauge(x, y, w, title, valueStr, value, max, col, marks)
  box(x, y, w, 4, title, C.accent)
  put(x + w - 2 - ulen(valueStr), y, " " .. valueStr .. " ", col, C.panel)
  local bw = w - 4
  local n = math.floor(clamp(value / max, 0, 1) * bw + 0.5)
  fill(x + 2, y + 1, bw, 1, " ", C.text, C.barBg)
  if n > 0 then fill(x + 2, y + 1, n, 1, " ", col, col) end
  fill(x + 2, y + 2, bw, 1, " ", C.dim, C.panel)
  for _, m in ipairs(marks or {}) do
    local mx = x + 2 + math.floor(clamp(m[1] / max, 0, 1) * (bw - 1) + 0.5)
    local cell = FB[(y) * W + mx]
    if cell then
      local inBar = mx < x + 2 + n
      put(mx, y + 1, "┃", m[2], inBar and col or C.barBg)
    end
    if m[3] then
      local lx = clamp(mx - math.floor(ulen(m[3]) / 2), x + 2, x + w - 2 - ulen(m[3]))
      put(lx, y + 2, m[3], m[2], C.panel)
    end
  end
end

local function tempCol(t)
  if t >= CFG.tempWarn then return C.red elseif t >= 8000 then return C.hot elseif t >= 2000 then return C.warm end
  return C.cool
end
local function fieldCol(p)
  if p < CFG.fieldStop then return C.red elseif p < CFG.fieldWarn then return C.warn end
  return C.info
end
local function convCol(p)
  if p >= CFG.convStop then return C.red elseif p >= CFG.convWarn then return C.warn end
  return C.purple
end

local function statusText()
  if S.alarm then return "АВАРИЯ: " .. S.alarm, C.red end
  local st = S.status
  if st == "none" then return "Нет связи с реактором", C.red end
  if st == "invalid" then return "Сборка нарушена: проверь 4 стабилизатора и инжектор", C.red end
  local w = next(S.warn) and S.warn[next(S.warn)]
  if w then return w, C.warn end
  if S.hold and st == "offline" then return "Остановлен вручную. «ЗАПУСК» — запустить снова", C.warn end
  local d = S.info
  if st == "offline" then
    local need = HW.maxFuel * CFG.minStartFuel / 100
    if d and d.total < need then
      return ("Ждём топливо: %s из %s"):format(fmtInt(d.total), fmtInt(need)), C.dim
    end
    return CFG.auto and "Готов к зарядке" or "Автозапуск выключен — «ЗАПУСК»", C.dim
  end
  if st == "charging" then return "Зарядка поля, насыщения и разогрев до 2000 °C", C.info end
  if st == "charged" then return (CFG.auto or S.startReq) and "Заряжен, запускаю" or "Заряжен — «ЗАПУСК»", C.ok end
  if st == "online" then return "Работает: максимальная скорость", C.ok end
  if st == "stopping" then
    if d and d.satP < 99 then
      return ("Остановка: насыщение %.1f%% → 99%% через ~%s, затем остывание (это механика мода)"):format(d.satP, fmtTime(d.etaSat)), C.warn
    end
    return ("Остановка: остывание до 2000 °C, ~%s"):format(fmtTime(d and d.etaCool or 0)), C.warn
  end
  return st, C.text
end

local function confirmBtn(key, fn)
  return function()
    local now = computer.uptime()
    if (S.confirm[key] or 0) >= now then
      S.confirm[key] = nil
      fn()
    else
      S.confirm[key] = now + 3
      log("Нажми ещё раз для подтверждения", "info")
    end
  end
end

local function btnLabel(key, label)
  if (S.confirm[key] or 0) >= computer.uptime() then return "ТОЧНО? " .. label end
  return label
end

-- кнопки
local function doStart()
  if S.alarm then log("Сначала «СБРОС» аварии", "warn"); return end
  S.hold = false
  S.startReq = true
  log("ЗАПУСК нажат", "info")
  if S.status == "offline" and S.info then startCharge(true) end
end
local function doStop()
  S.hold = true
  S.startReq = false
  if call("stopReactor") then log("СТОП: реактор останавливается", "warn")
  else log("СТОП: реактор не принял команду (уже выключен?)", "info") end
  enforceGates()
end
local function doReset()
  if not S.alarm then return end
  log("Авария сброшена: " .. S.alarm, "info")
  S.alarm = nil
  S.hold = true          -- после аварии сам не запускается, только «ЗАПУСК»
  alarmOut(false)
end
local function doAuto() CFG.auto = not CFG.auto; saveCfg(); log("Автозапуск: " .. (CFG.auto and "вкл" or "выкл"), "info") end

local LX, LW, RX, RW

local function drawHeader()
  fill(1, 1, W, 1, " ", C.text, 0x1A2030)
  put(2, 1, "DRACONIC REACTOR CONTROL", C.accent, 0x1A2030)
  put(27, 1, VERSION, C.dim, 0x1A2030)
  local st = STATUS_RU[S.status] or S.status
  local col = S.status == "online" and C.ok or (S.status == "stopping" or S.status == "charging") and C.warn
    or (S.status == "none" or S.status == "invalid") and C.red or C.info
  local chip = " " .. st .. " "
  put(math.floor((W - ulen(chip)) / 2), 1, chip, 0x000000, col)
  local r = clock()
  put(W - ulen(r), 1, r, C.dim, 0x1A2030)
end

local function drawLeft()
  local d = S.info or derive({})
  local y = 3
  local txt, col = statusText()
  box(LX, y, LW, 3, "Состояние", C.accent)
  put(LX + 2, y + 1, fit(txt, LW - 4), col, C.panel)
  y = y + 3

  local t = d.temperature or 0
  gauge(LX, y, LW, "Температура", fmtInt(t) .. " °C", t, 20000, tempCol(t), {
    { 2000, C.dim, "2000" }, { 8000, C.dim, "8000" },
    { CFG.tempWarn, C.warn, nil }, { CFG.tempStop, C.red, "стоп " .. fmtInt(CFG.tempStop) },
  })
  y = y + 4
  gauge(LX, y, LW, "Поле", string.format("%.2f%%  (в GUI %.1f%% — после расхода тика)  макс %s", d.fieldP or 0, d.fieldRaw or 0, fmtBig(d.maxFieldStrength)),
    d.fieldP or 0, 100, fieldCol(d.fieldP or 0), {
      { CFG.fieldStop, C.red, "стоп " .. CFG.fieldStop .. "%" }, { CFG.fieldWarn, C.warn, CFG.fieldWarn .. "%" },
    })
  y = y + 4
  gauge(LX, y, LW, "Насыщение", string.format("%.2f%%  %s / %s", d.satP or 0, fmtBig(d.energySaturation), fmtBig(d.maxEnergySaturation)),
    d.satP or 0, 100, C.cool, { { 50, C.dim, "50%" }, { 99, C.dim, "99%" } })
  y = y + 4
  gauge(LX, y, LW, "Конверсия топлива", string.format("%.2f%%  %s", d.convP or 0, fmtInt(d.fuelConversion)),
    d.convP or 0, 25, convCol(d.convP or 0), {
      { 5, C.dim, "1 осколок" }, { CFG.convWarn, C.warn, CFG.convWarn .. "%" }, { CFG.convStop, C.red, "стоп " .. CFG.convStop .. "%" },
    })
  y = y + 4

  local hw = math.floor((LW - 1) / 2)
  box(LX, y, hw, 7, "Энергия", C.accent)
  local ix, iw = LX + 2, hw - 4
  kv(ix, y + 1, iw, "Вход (гейт)", gIn and (fmtBig(HW.inFlow) .. " RF/t") or "вручную", gIn and C.text or C.dim)
  kv(ix, y + 2, iw, "Выход (гейт)", gOut and (fmtBig(HW.outFlow) .. " RF/t") or "вручную", gOut and C.text or C.dim)
  kv(ix, y + 3, iw, "Генерация", fmtBig(d.generationRate) .. " RF/t")
  kv(ix, y + 4, iw, "Расход поля", fmtBig(d.fieldDrainRate) .. " RF/t", (d.fieldDrainRate or 0) > 1e7 and C.warn or C.text)
  kv(ix, y + 5, iw, "Множитель k", string.format("%.1f", d.k or 0))

  local fx = LX + hw + 1
  local fw = LW - hw - 1
  box(fx, y, fw, 7, "Топливо", C.accent)
  ix, iw = fx + 2, fw - 4
  kv(ix, y + 1, iw, "В реакторе", fmtInt(d.total) .. " / " .. fmtInt(HW.maxFuel),
    (d.total or 0) < HW.maxFuel * 0.95 and C.warn or C.text)
  kv(ix, y + 2, iw, "Не сконвертировано", fmtInt(d.fuel))
  kv(ix, y + 3, iw, "Хаос внутри", string.format("%s (%.2f осколка)", fmtInt(d.fuelConversion), (d.fuelConversion or 0) / HW.shardFuel))
  kv(ix, y + 4, iw, "Расход топлива", string.format("%.1f /тик", d.fuelPerTick or 0))
  kv(ix, y + 5, iw, "Скорость", string.format("%.1f осколков/мин", d.shardsMin or 0), C.purple)
  y = y + 7

  local lh = H - y
  box(LX, y, LW, lh, "Журнал", C.accent)
  local KCOL = { ok = C.ok, info = C.dim, warn = C.warn, err = C.red }
  local KTAG = { ok = "OK  ", info = "INFO", warn = "WARN", err = "ERR " }
  for i = 1, lh - 2 do
    local e = LOG[i]
    if not e then break end
    put(LX + 2, y + i, e.t, C.dim, C.panel)
    put(LX + 11, y + i, KTAG[e.k] or "    ", KCOL[e.k] or C.dim, C.panel)
    put(LX + 16, y + i, fit(e.m, LW - 18), e.k == "info" and C.text or (KCOL[e.k] or C.text), C.panel)
  end
end

local function drawRight()
  local d = S.info or derive({})
  local y = 3
  box(RX, y, RW, 9, "Температура", C.accent)
  local t = math.floor((d.temperature or 0) + 0.5)
  local s = tostring(t)
  local bw = bigWidth(s)
  local bx = RX + math.floor((RW - bw - 4) / 2)
  bigText(bx, y + 2, s, tempCol(t))
  put(bx + bw + 1, y + 2, "°C", C.dim, C.panel)
  local rate = S.tempRate or 0
  local rs_ = string.format("%+.0f °C/с", rate)
  put(RX + 2, y + 7, "тренд", C.dim, C.panel)
  put(RX + RW - 2 - ulen(rs_), y + 7, rs_, math.abs(rate) < 5 and C.dim or (rate > 0 and C.warm or C.cool), C.panel)
  y = y + 9

  box(RX, y, RW, 10, "Сессия", C.accent)
  local ix, iw = RX + 2, RW - 4
  local now = computer.uptime()
  local runNow = S.onlineSince and (now - S.onlineSince) or 0
  kv(ix, y + 1, iw, "Осколков за сессию", fmtInt(S.shardsSession), C.purple)
  kv(ix, y + 2, iw, "Осколков всего", fmtInt(CFG.stats.shards))
  kv(ix, y + 3, iw, "Работает сейчас", S.onlineSince and fmtTime(runNow) or "—")
  kv(ix, y + 4, iw, "Наработка всего", fmtTime(CFG.stats.runSec + runNow))
  kv(ix, y + 5, iw, "Запусков / аварий", fmtInt(CFG.stats.starts) .. " / " .. fmtInt(CFG.stats.estops),
    CFG.stats.estops > 0 and C.warn or C.text)
  kv(ix, y + 6, iw, "Гейты", S.gateMode, S.gateErr and C.red or (S.gateMode == "программа" and C.ok or C.warn))
  kv(ix, y + 7, iw, "Автозапуск", CFG.auto and "вкл" or "выкл", CFG.auto and C.ok or C.warn)
  kv(ix, y + 8, iw, "Программа", fmtTime(now - S.startedAt), C.dim)
  y = y + 10

  box(RX, y, RW, 7, "Защита", C.accent)
  kv(ix, y + 1, iw, "Поле: предупр. / стоп", CFG.fieldWarn .. "% / " .. CFG.fieldStop .. "%")
  kv(ix, y + 2, iw, "Конверсия: предупр. / стоп", CFG.convWarn .. "% / " .. CFG.convStop .. "%")
  kv(ix, y + 3, iw, "Температура: стоп", fmtInt(CFG.tempStop) .. " °C")
  kv(ix, y + 4, iw, "Топливо для зарядки", CFG.minStartFuel .. "%")
  kv(ix, y + 5, iw, "Сигнал тревоги", rs and ("redstone, сторона " .. HW.alarmSide) or "нет", C.dim)
  y = y + 7

  local bh = 3
  local bw2 = math.floor((RW - 1) / 2)
  button(RX, y, bw2, bh, "ЗАПУСК", C.btnFg, C.btnGreen, doStart)
  button(RX + bw2 + 1, y, RW - bw2 - 1, bh, btnLabel("stop", "СТОП"), C.btnFg, C.btnRed, confirmBtn("stop", doStop))
  y = y + bh + 1
  button(RX, y, bw2, bh, "СБРОС АВАРИИ", C.btnFg, S.alarm and C.btnAmber or C.btn, doReset)
  button(RX + bw2 + 1, y, RW - bw2 - 1, bh, "АВТО: " .. (CFG.auto and "ВКЛ" or "ВЫКЛ"), C.btnFg, C.btn, doAuto)
  y = y + bh + 1
  button(RX, y, bw2, bh, "НАСТРОЙКИ", C.btnFg, C.btn, function() S.screen = "settings" end)
  button(RX + bw2 + 1, y, RW - bw2 - 1, bh, btnLabel("exit", "ВЫХОД"), C.btnFg, C.btn,
    confirmBtn("exit", function() S.running = false end))
end

local SETTINGS = {
  { "minStartFuel", "Топливо перед зарядкой", "%", "maxField и maxSaturation считаются по топливу в момент зарядки" },
  { "fieldWarn", "Поле: предупреждение", "%", "" },
  { "fieldStop", "Поле: аварийный стоп", "%", "Поле до расхода тика (в GUI на ~12% ниже). Не спасает при полном отказе входа" },
  { "convWarn", "Конверсия: предупреждение", "%", "Норма — до ~5% (1 осколок внутри)" },
  { "convStop", "Конверсия: аварийный стоп", "%", "Во время остановки конверсия ещё растёт — нужен запас" },
  { "tempWarn", "Температура: предупреждение", "°C", "" },
  { "tempStop", "Температура: аварийный стоп", "°C", "Равновесие в режиме максимума ~14 000 °C" },
}

local function drawSettings()
  local x, w = 20, W - 40
  box(x, 3, w, 4 + #SETTINGS * 4, "Настройки защиты", C.accent)
  local y = 5
  for _, s in ipairs(SETTINGS) do
    local key, name, unit, hint = s[1], s[2], s[3], s[4]
    put(x + 3, y, name, C.text, C.panel)
    local vx = x + w - 34
    put(x + 3, y + 1, fit(hint, vx - x - 5), C.dim, C.panel)
    local val = (unit == "°C") and fmtInt(CFG[key]) .. " °C" or (CFG[key] .. unit)
    button(vx, y, 7, 2, "−", C.btnFg, C.btn, function()
      CFG[key] = clamp(CFG[key] - STEP[key], LIMITS[key][1], LIMITS[key][2]); saveCfg()
    end)
    put(vx + 8 + math.floor((14 - ulen(val)) / 2), y, val, C.accent, C.panel)
    button(vx + 23, y, 7, 2, "+", C.btnFg, C.btn, function()
      CFG[key] = clamp(CFG[key] + STEP[key], LIMITS[key][1], LIMITS[key][2]); saveCfg()
    end)
    y = y + 4
  end
  -- согласованность порогов
  if CFG.fieldStop >= CFG.fieldWarn then CFG.fieldWarn = math.min(99, CFG.fieldStop + 5) end
  if CFG.convWarn >= CFG.convStop then CFG.convWarn = math.max(1, CFG.convStop - 1) end
  if CFG.tempWarn >= CFG.tempStop then CFG.tempWarn = math.max(2500, CFG.tempStop - 500) end

  local by = 3 + 4 + #SETTINGS * 4 + 1
  put(x + 2, by, "Гейты: вход " .. (HW.inGate ~= "" and HW.inGate:sub(1, 8) or "—") ..
    ", выход " .. (HW.outGate ~= "" and HW.outGate:sub(1, 8) or "—") .. "   (drc-install gates)", C.dim, C.bg)
  put(x + 2, by + 1, "Железо: " .. HW_SOURCE, C.dim, C.bg)
  button(math.floor((W - 24) / 2), by + 3, 24, 3, "НАЗАД", C.btnFg, C.btnGreen, function() S.screen = "main" end)
end

local function draw()
  BTN = {}
  fill(1, 1, W, H, " ", C.text, C.bg)
  drawHeader()
  if S.screen == "settings" then drawSettings() else drawLeft(); drawRight() end
  flush()
  S.dirty = false
end

local function onTouch(x, y)
  for i = #BTN, 1, -1 do
    local b = BTN[i]
    if x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then
      local ok, err = pcall(b[5])
      if not ok then log("Ошибка кнопки: " .. tostring(err), "err") end
      S.dirty = true
      return
    end
  end
end

-- ============================== ЗАПУСК ==============================
local oldW, oldH

local function shutdown()
  if CFG then
    if S.onlineSince then CFG.stats.runSec = CFG.stats.runSec + (computer.uptime() - S.onlineSince) end
    saveCfg()
  end
  alarmOut(false)
  if gpu and oldW then
    pcall(gpu.setBackground, 0x000000); pcall(gpu.setForeground, 0xFFFFFF)
    pcall(gpu.setResolution, oldW, oldH)
    pcall(gpu.fill, 1, 1, oldW, oldH, " ")
  end
  if S.status == "online" or S.status == "stopping" then
    print("DRC: программа закрыта, реактор " .. (STATUS_RU[S.status] or S.status) .. ".")
    print("     Гейты остаются на уставках (вход " .. fmtBig(HW.inFlow) .. " RF/t). Защиты сейчас нет!")
  end
end

local function main()
  local ok, err = bindComponents()
  if not ok then error(err, 0) end
  CFG = loadCfg()
  local mw, mh = gpu.maxResolution()
  W, H = HW.resolution[1], HW.resolution[2]
  if mw < W or mh < H then
    error(("Нужны видеокарта и экран T3 (нужно %dx%d, доступно %dx%d)"):format(W, H, mw, mh), 0)
  end
  oldW, oldH = gpu.getResolution()
  gpu.setResolution(W, H)
  initBuffers()
  RW = 48; RX = W - RW; LX = 2; LW = RX - LX - 1

  S.startedAt = computer.uptime()
  initClock()
  log("DRC " .. VERSION .. " запущен", "ok")
  if not CLOCK_BASE then log("Реальные часы недоступны: время в журнале — от запуска программы", "info") end
  log("Железо: " .. HW_SOURCE, HW_SOURCE == HW_PATH and "info" or "warn")
  if not gIn or not gOut then
    log("Гейт" .. ((not gIn and not gOut) and "ы не заданы" or (not gIn and " входа не задан" or " выхода не задан")) ..
      ": выставь их вручную или drc-install gates", "warn")
  end
  enforceGates()
  if poll() then
    S.lastStatus = S.status
    log("Реактор: " .. (STATUS_RU[S.status] or S.status), "info")
    if S.status == "online" then S.onlineSince = computer.uptime() end
  end

  local nextTick, nextGate, nextDraw, nextSave = 0, 0, 0, 0
  while S.running do
    local ev = { event.pull(0.1) }
    local name = ev[1]
    if name == "touch" then
      onTouch(ev[3], ev[4])
    elseif name == "interrupted" then
      S.running = false
    end
    local now = computer.uptime()
    if now >= nextTick then tick(now); nextTick = now + 0.2 end
    if now >= nextGate then enforceGates(); nextGate = now + 5 end
    if now >= nextSave then saveCfg(); nextSave = now + 60 end
    if S.dirty and now >= nextDraw or now >= nextDraw + 0.5 then draw(); nextDraw = now + 0.5 end
  end
end

local ok, err = xpcall(main, debug.traceback)
local okS, errS = pcall(shutdown)
if not ok and not tostring(err):find("interrupted") then
  io.stderr:write("DRC: " .. tostring(err) .. "\n")
end
if not okS then io.stderr:write("DRC shutdown: " .. tostring(errS) .. "\n") end
