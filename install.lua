-- =====================================================================
--  Установщик DRC — Draconic Reactor Control (OpenComputers / OpenOS)
--
--  Первая установка (нужна интернет-карта):
--    wget -f https://raw.githubusercontent.com/EugenPrinz/draconic_reactor_program/main/install.lua /home/drc-install.lua
--    drc-install
--
--  Потом:
--    drc-install          полная установка: скачать, проверить железо, найти гейты, автозапуск
--    drc-install update   только обновить программу (гейты и настройки сохраняются)
--    drc-install gates    заново определить входной и выходной гейты
-- =====================================================================

local INSTALLER_VERSION = "0.1.0"

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local serial    = require("serialization")
local fs        = require("filesystem")

local args = { ... }
local MODE = args[1] or "full"

local REPO   = "https://raw.githubusercontent.com/EugenPrinz/draconic_reactor_program/"
local BRANCH = DRC_BRANCH or "main"                        -- luacheck: ignore (глобал для тестов)
local ROOT   = DRC_ROOT or ""                              -- luacheck: ignore (глобал для тестов)
local WAIT   = DRC_WAIT or 60                              -- luacheck: ignore (с на поиск гейта)

local P = {
  prog      = ROOT .. "/home/drc.lua",
  installer = ROOT .. "/home/drc-install.lua",
  hw        = ROOT .. "/home/drc-hw.cfg",
  shrc      = ROOT .. "/home/.shrc",
}

-- ============================== ВВОД/ВЫВОД ==============================
local function say(s) io.write(s .. "\n") end
local function title(s) say(""); say("== " .. s .. " ==") end

local function ask(q, default)
  io.write(q .. ((default ~= nil and default ~= "") and (" [" .. tostring(default) .. "]") or "") .. ": ")
  local a = io.read()
  if a == nil then error("interrupted", 0) end
  a = a:gsub("^%s+", ""):gsub("%s+$", "")
  if a == "" then return default end
  return a
end

local function yes(q, default)
  while true do
    local a = ask(q .. (default and " (Д/н)" or " (д/Н)"), nil)
    if a == nil then return default end
    a = a:lower()
    if a == "y" or a == "yes" or a == "д" or a == "да" then return true end
    if a == "n" or a == "no" or a == "н" or a == "нет" then return false end
  end
end

local function short(a) return a and a:sub(1, 8) or "—" end

-- ============================== ФАЙЛЫ ==============================
local function download(path)
  if not component.isAvailable("internet") then return nil, "нет интернет-карты" end
  local internet = require("internet")
  local ok, handle = pcall(internet.request, REPO .. BRANCH .. "/" .. path)
  if not ok or not handle then return nil, tostring(handle) end
  local parts = {}
  local ok2, err = pcall(function() for chunk in handle do parts[#parts + 1] = chunk end end)
  if not ok2 then return nil, tostring(err) end
  local data = table.concat(parts)
  if #data == 0 then return nil, "пустой ответ" end
  return data
end

local function writeFile(path, data)
  local dir = fs.path(path)
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDirectory(dir) end
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(data); f:close()
  return true
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local d = f:read("*a"); f:close()
  return d
end

local function loadHW()
  local d = readFile(P.hw)
  if not d then return {} end
  local ok, t = pcall(serial.unserialize, d)
  return (ok and type(t) == "table") and t or {}
end

local function saveHW(t)
  return writeFile(P.hw, serial.serialize(t))
end

local function installFile(remote, dst, marker, minSize)
  local code, err = download(remote)
  if not code then say("Не удалось скачать " .. remote .. ": " .. tostring(err)); return false end
  if not code:find(marker, 1, true) or #code < minSize then
    say(("Скачанный %s не похож на нужный файл (%d байт). Установка прервана."):format(remote, #code))
    return false
  end
  local fn, cerr = load(code, "=" .. remote)
  if not fn then say("Файл " .. remote .. " не компилируется: " .. tostring(cerr)); return false end
  if fs.exists(dst) then fs.copy(dst, dst .. ".bak") end
  local ok, werr = writeFile(dst, code)
  if not ok then say("Не удалось записать " .. dst .. ": " .. tostring(werr)); return false end
  return true, code:match('VERSION = "([^"]+)"') or "?"
end

local function installProgram()
  title("Загрузка программы")
  local ok, ver = installFile("drc.lua", P.prog, "DRACONIC REACTOR CONTROL", 20000)
  if not ok then return false end
  say("drc.lua " .. ver .. " → " .. P.prog .. (fs.exists(P.prog .. ".bak") and " (старая версия в drc.lua.bak)" or ""))
  local ok2, iver = installFile("install.lua", P.installer, "Установщик DRC", 4000)
  if ok2 then say("Установщик " .. iver .. " → " .. P.installer) end
  return true
end

-- ============================== ЖЕЛЕЗО ==============================
local function addrs(kind)
  local r = {}
  for a in component.list(kind) do r[#r + 1] = a end
  table.sort(r)
  return r
end

local function checkHardware()
  title("Проверка железа")
  local bad = false
  if component.isAvailable("gpu") then
    local w, h = component.gpu.maxResolution()
    if w < 160 or h < 50 then
      say(("✘ Видеокарта/экран дают %dx%d, нужно 160x50 (T3)"):format(w, h)); bad = true
    else say("✔ Экран 160x50") end
  else say("✘ Нет видеокарты"); bad = true end

  local reactors = addrs("draconic_reactor")
  if #reactors == 0 then
    say("✘ Нет draconic_reactor: adapter должен касаться стабилизатора или инжектора"); bad = true
  else
    local ok, d = pcall(component.proxy(reactors[1]).getReactorInfo)
    if ok and type(d) == "table" then
      say(("✔ Реактор %s: статус %s, топливо %s"):format(short(reactors[1]), tostring(d.status),
        tostring(d.maxFuelConversion)))
    else
      say("✘ Реактор не отвечает: " .. tostring(d)); bad = true
    end
    if #reactors > 1 then say("  ! Найдено " .. #reactors .. " адаптера реактора — это нормально, если они на одном реакторе") end
  end
  local gates = addrs("flux_gate")
  say((#gates == 2 and "✔ " or "! ") .. "Flux gate: " .. #gates .. (#gates == 2 and "" or " (нужно 2: вход и выход)"))
  return not bad
end

-- ============================== ГЕЙТЫ ==============================
local function lows(gates)
  local r = {}
  for i, a in ipairs(gates) do
    local ok, v = pcall(component.proxy(a).getSignalLowFlow)
    r[i] = ok and v or nil
  end
  return r
end

local function findGates()
  title("Входной и выходной гейты")
  local hw = loadHW()
  local gates = addrs("flux_gate")
  if #gates == 0 then
    say("Flux gate не найдены. Программа будет работать без управления гейтами —")
    say("выставь их вручную (Low = 2 000 000 000 RF/t, как на вики).")
    hw.inGate, hw.outGate = "", ""
    saveHW(hw)
    return
  end
  for i, a in ipairs(gates) do
    local g = component.proxy(a)
    local _, low = pcall(g.getSignalLowFlow)
    local _, ov = pcall(g.getOverrideEnabled)
    say(("  %d) %s  low=%s  override=%s"):format(i, a, tostring(low), tostring(ov)))
  end
  local inIdx
  if #gates >= 2 then
    say("")
    say("Открой GUI ВХОДНОГО гейта (источник → инжектор) и УВЕЛИЧЬ нижнюю уставку")
    say("на любой шаг (колесо мыши вверх). Уменьшать не надо: на работающем реакторе это опасно.")
    say(("Жду до %d с… (Enter — выбрать номер вручную)"):format(WAIT))
    local base = lows(gates)
    local deadline = computer.uptime() + WAIT
    while computer.uptime() < deadline and not inIdx do
      local ev = { event.pull(0.5) }
      if ev[1] == "key_down" and ev[4] == 28 then break end
      if ev[1] == "interrupted" then error("interrupted", 0) end
      local now = lows(gates)
      for i = 1, #gates do
        if base[i] and now[i] and now[i] ~= base[i] then inIdx = i; break end
      end
    end
    if inIdx then
      say(("✔ Входной гейт: %d) %s"):format(inIdx, gates[inIdx]))
    else
      say("Изменение не поймано.")
    end
  end
  while not inIdx do
    local a = tonumber(ask("Номер ВХОДНОГО гейта", #gates == 1 and "1" or nil))
    if a and gates[a] then inIdx = a end
  end
  local outIdx
  if #gates == 2 then
    outIdx = 3 - inIdx
    say(("✔ Выходной гейт: %d) %s"):format(outIdx, gates[outIdx]))
  elseif #gates > 2 then
    while not outIdx do
      local a = tonumber(ask("Номер ВЫХОДНОГО гейта (0 — нет)", "0"))
      if a == 0 then break end
      if a and gates[a] and a ~= inIdx then outIdx = a end
    end
  end
  hw.inGate = gates[inIdx]
  hw.outGate = outIdx and gates[outIdx] or ""

  local rss = addrs("redstone")
  if #rss > 0 and yes("Подавать redstone-сигнал тревоги (лампа, сирена)?", false) then
    hw.alarmRs = rss[1]
    local s = tonumber(ask("Сторона redstone (0 низ, 1 верх, 2 север, 3 юг, 4 запад, 5 восток)", "1"))
    hw.alarmSide = (s and s >= 0 and s <= 5) and math.floor(s) or 1
  end
  saveHW(hw)
  say("Сохранено в " .. P.hw)
  say("При запуске drc переведёт оба гейта на override 2 147 483 647 RF/t.")
end

local function autostart()
  local cur = readFile(P.shrc) or ""
  if cur:find("drc", 1, true) then say("Автозапуск уже есть в " .. P.shrc); return end
  if yes("Запускать drc при загрузке компьютера?", true) then
    writeFile(P.shrc, cur .. (cur ~= "" and not cur:match("\n$") and "\n" or "") .. "drc\n")
    say("Добавлено в " .. P.shrc)
  end
end

-- ============================== MAIN ==============================
local function main()
  say("Установщик DRC " .. INSTALLER_VERSION)
  if MODE == "update" then
    if installProgram() then say(""); say("Готово. Запуск: drc") end
    return
  elseif MODE == "gates" then
    findGates()
    return
  end
  if not installProgram() then return end
  if not checkHardware() then
    say("")
    say("Исправь железо и запусти «drc-install gates», потом «drc».")
    return
  end
  findGates()
  autostart()
  say("")
  say("Готово. Запуск: drc")
  say("Перед первым запуском: реактор заправлен, мусорка за выходным гейтом, источник за входным.")
end

local ok, err = pcall(main)
if not ok and err ~= "interrupted" then io.stderr:write("Ошибка: " .. tostring(err) .. "\n") end
