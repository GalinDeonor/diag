-- ============================================================
--  FUST-DIAG — автономный монитор чита «Пьяный Петух»
--  Версия: 1.0  (2026-11-11)
--
--  ЧТО ДЕЛАЕТ:
--  1. Логирует ВСЁ: загрузку чита, каждый RenderStepped кадр,
--     консоль Roblox (print/warn), ошибки, кики, фризы.
--  2. При зависании — пишет последний кадр + стек вызовов в файл.
--  3. При кике/бане — пишет баннер + состояние фич в файл.
--  4. Файл лога ПЕРЕЖИВАЕТ перезапуск Delta и перезаход в Roblox.
--  5. При старте показывает: был ли прошлый запуск аварийным.
--
--  ФАЙЛЫ:
--    FUST_diag.log       — полный лог (ротация при > 1 МБ)
--    FUST_diag_trace.log — последние 200 строк (для быстрого просмотра)
--    FUST_diag_crash.log — информация о краше/фризе (последний кадр)
--
--  ИСПОЛЬЗОВАНИЕ:
--    Вставь этот скрипт в Delta ПЕРЕД запуском чита.
--    Он сам запустит чит и будет мониторить.
--    После зависания — перезапусти Delta, открой файл FUST_diag_crash.log
--    (или FUST_diag.log) — там будет причина.
-- ============================================================

local LOG_FILE = "FUST_diag.log"
local TRACE_FILE = "FUST_diag_trace.log"
local CRASH_FILE = "FUST_diag_crash.log"
local MAX_LOG = 1048576  -- 1 МБ
local MAX_TRACE = 200

-- ===== состояние =====
local diagLines = {}
local diagCount = 0
local lastFrameTime = os.clock()
local lastFrameLine = "(ещё не было кадра)"
local frameCount = 0
local started = false
local frozen = false

-- ===== executor =====
local EXEC = "неизвестен"
pcall(function()
    if type(identifyexecutor) == "function" then
        local name, version = identifyexecutor()
        EXEC = tostring(name or "?") .. " v" .. tostring(version or "?")
    end
end)

-- ===== сохраняем ОРИГИНАЛЬНЫЕ print/warn ДО всего остального =====
local _origPrint = print
local _origWarn = warn

-- ===== утилиты записи =====
local function ts()
    return os.date("%H:%M:%S.") .. string.format("%03d", (os.clock() * 1000) % 1000)
end

local function writeLog(msg)
    local line = "[" .. ts() .. "] " .. msg
    -- в память (trace)
    table.insert(diagLines, line)
    if #diagLines > MAX_TRACE then table.remove(diagLines, 1) end
    diagCount = diagCount + 1
    -- в файл (append)
    if type(appendfile) == "function" then
        pcall(appendfile, LOG_FILE, line .. "\n")
    end
    -- в консоль через ОРИГИНАЛЬНЫЙ print (не перехваченный → нет рекурсии)
    if _origPrint then _origPrint(line) end
end

local function writeCrash(msg, extra)
    -- отдельный файл краша — для быстрого просмотра
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local content = "=== FUST DIAG CRASH REPORT ===\n"
    content = content .. "Время: " .. now .. "\n"
    content = content .. "Executor: " .. EXEC .. "\n"
    content = content .. "PlaceId: " .. tostring(game.PlaceId) .. "\n"
    content = content .. "JobId: " .. tostring(game.JobId) .. "\n"
    content = content .. "\n--- Причина ---\n" .. msg .. "\n"
    if extra then content = content .. "\n--- Дополнительно ---\n" .. extra .. "\n" end
    content = content .. "\n--- Последние " .. #diagLines .. " строк лога ---\n"
    for _, l in ipairs(diagLines) do
        content = content .. l .. "\n"
    end
    content = content .. "\n--- Стек вызовов ---\n"
    if type(debug) == "table" and type(debug.traceback) == "function" then
        content = content .. tostring(debug.traceback("", 2)) .. "\n"
    else
        content = content .. "(debug.traceback недоступен)\n"
    end
    if type(writefile) == "function" then
        pcall(writefile, CRASH_FILE, content)
    end
    if _origPrint then _origPrint("[FUST-DIAG] Crash report → " .. CRASH_FILE) end
end

-- ===== ротация лога =====
local function rotateIfNeeded()
    if type(isfile) ~= "function" or not isfile(LOG_FILE) then return end
    local ok, sz = pcall(function() return #readfile(LOG_FILE) end)
    if ok and sz and sz > MAX_LOG then
        if type(writefile) == "function" then
            pcall(writefile, LOG_FILE, "")
        end
    end
end

-- ===== перехват print/warn =====
-- _origPrint уже сохранён выше (до перехвата)
-- Оборачиваем print/warn для логирования консоли
pcall(function()
    print = function(...)
        local args = {...}
        local msg = ""
        for i, v in ipairs(args) do
            if i > 1 then msg = msg .. "\t" end
            msg = msg .. tostring(v)
        end
        writeLog("[PRINT] " .. msg)
    end
end)
pcall(function()
    warn = function(...)
        local args = {...}
        local msg = ""
        for i, v in ipairs(args) do
            if i > 1 then msg = msg .. "\t" end
            msg = msg .. tostring(v)
        end
        writeLog("[WARN] " .. msg)
    end
end)

writeLog("========================================")
writeLog("FUST-DIAG v1.0 — монитор запущен")
writeLog("Executor: " .. EXEC)
writeLog("PlaceId: " .. tostring(game.PlaceId))
local _bid = "неизвестен"
pcall(function() _bid = tostring(game.BuildId) end)
writeLog("Roblox BuildId: " .. _bid)
writeLog("========================================")

-- ===== проверка прошлых запусков =====
if type(isfile) == "function" then
    if isfile(CRASH_FILE) then
        writeLog("⚠ НАЙДЕН ФАЙЛ КРАША — прошлый запуск был аварийным!")
        writeLog("   Прочитай " .. CRASH_FILE .. " для деталей.")
    end
    if isfile(LOG_FILE) then
        local ok, content = pcall(readfile, LOG_FILE)
        if ok and content then
            -- ищем метку завершения
            if not content:find("FUST%-DIAG: нормальное завершение") then
                writeLog("⚠ Прошлый лог НЕ имеет метки нормального завершения — возможен краш/фриз.")
                -- пытаемся найти последнюю запись
                local lastLine = content:match("([^\n]+)\n*$") or "(пусто)"
                writeLog("   Последняя запись прошлого лога: " .. lastLine)
            end
        end
    end
end
rotateIfNeeded()

-- ===== мониторинг Heartbeat — детектор фриза =====
local Heartbeat = game:GetService("RunService").Heartbeat
local lastHb = os.clock()
local hbCount = 0
local featureSnapshot = ""

local function snapshotFeatures()
    local snap = ""
    pcall(function()
        local g = getgenv()
        snap = snap .. "FUST_READY=" .. tostring(g.FUST_READY or "?") .. " "
        snap = snap .. "FUST_SESSION=" .. tostring(g.FUST_SESSION ~= nil) .. " "
        snap = snap .. "FUST_LOAD_OK=" .. tostring(g.FUST_LOAD_OK or "?") .. " "
        snap = snap .. "FUST_STEP=" .. tostring(g.FUST_STEP or "?")
    end)
    return snap
end

local hbConn
pcall(function()
    hbConn = Heartbeat:Connect(function()
        local now = os.clock()
        local gap = now - lastHb
        hbCount = hbCount + 1
        
        -- Если gap > 2 секунды — это фриз!
        if gap > 2.0 and not frozen then
            frozen = true
            local msg = "ДЕТЕКТОР ФРИЗА: gap=" .. string.format("%.2f", gap) .. "с "
            msg = msg .. "(движок не отвечал " .. string.format("%.1f", gap) .. " сек)"
            writeLog("!!! " .. msg)
            writeCrash(msg, 
                "Фичи на момент фриза:\n" .. snapshotFeatures() .. "\n\n" ..
                "Кадров до фриза: " .. frameCount .. "\n" ..
                "Heartbeat'ов до фриза: " .. hbCount)
        end
        
        lastHb = now
        
        -- каждые 100 heartbeat'ов (~1.7с) пишем статус
        if hbCount % 100 == 0 then
            writeLog("[HB] " .. hbCount .. " кадров, gap max=" .. string.format("%.3f", gap) .. " " .. snapshotFeatures())
        end
    end)
end)
writeLog("Heartbeat монитор активен")

-- ===== мониторинг RenderStepped — пишем каждый кадр (упрощённо) =====
local RS
pcall(function()
    RS = game:GetService("RunService").RenderStepped:Connect(function()
        frameCount = frameCount + 1
        local now = os.clock()
        local frameGap = now - lastFrameTime
        lastFrameTime = now
        
        -- Пишем каждый 300-й кадр (~5 сек при 60fps) + аномально долгие кадры
        if frameCount % 300 == 0 or frameGap > 0.5 then
            local msg = "[RS] кадр #" .. frameCount .. " gap=" .. string.format("%.3f", frameGap) .. "с"
            if frameGap > 0.5 then
                msg = msg .. " ⚠ ДОЛГИЙ КАДР!"
                writeLog(msg)
            elseif frameCount % 600 == 0 then  -- каждые ~10 сек
                writeLog(msg)
            end
        end
        
        lastFrameLine = "кадр #" .. frameCount .. " gap=" .. string.format("%.3f", frameGap) .. "с " .. snapshotFeatures()
    end)
end)
writeLog("RenderStepped монитор активен")

-- ===== мониторинг игрока — кик/бан =====
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

pcall(function()
    Players.PlayerRemoving:Connect(function(player)
        if player == LocalPlayer then
            writeLog("!!! PLAYER_REMOVING: LocalPlayer удаляется из игры")
            -- сканируем CoreGui на баннер кика
            local bannerText = "(не найден)"
            pcall(function()
                local cg = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
                for _, v in ipairs(cg:GetDescendants()) do
                    if v:IsA("TextLabel") or v:IsA("TextButton") then
                        local t = v.Text or ""
                        if #t > 5 and (#t < 500) then
                            if t:lower():find("kick") or t:lower():find("ban") or t:lower():find("removed") 
                               or t:lower():find("cheat") or t:lower():find("exploit") or t:lower():find("detected") then
                                bannerText = t:sub(1, 300)
                                break
                            end
                        end
                    end
                end
            end)
            writeCrash("PLAYER_REMOVING — возможный кик/бан",
                "Баннер: " .. bannerText .. "\n\n" ..
                "Фичи:\n" .. snapshotFeatures() .. "\n\n" ..
                "Кадров: " .. frameCount .. ", HB: " .. hbCount)
        end
    end)
end)
writeLog("PlayerRemoving монитор активен")

-- ===== мониторинг LogService — сообщения консоли =====
local LogService
pcall(function()
    LogService = game:GetService("LogService")
    LogService.MessageOut:Connect(function(msg, type_)
        -- логируем только warn/error и важные print'ы
        if type_ == Enum.MessageType.MessageWarning then
            writeLog("[CONSOLE-WARN] " .. msg:sub(1, 300))
        elseif type_ == Enum.MessageType.MessageError then
            writeLog("[CONSOLE-ERROR] " .. msg:sub(1, 300))
        end
    end)
end)
writeLog("LogService монитор активен")

-- ===== мониторинг процессов — Instance.ChildAdded =====
pcall(function()
    Workspace = game:GetService("Workspace")
    Workspace.ChildAdded:Connect(function(child)
        if child:IsA("ScreenGui") or child:IsA("Folder") or child:IsA("Model") then
            -- не логируем каждый — слишком много
        end
    end)
end)

-- ===== финальный heartbeat — проверка зависания при загрузке =====
task.spawn(function()
    local loadTimeout = 60  -- 60 сек на загрузку
    while true do
        task.wait(1)
        loadTimeout = loadTimeout - 1
        if loadTimeout <= 0 then
            if not started then
                writeLog("⚠ Чит НЕ запустился за 60 сек — проверь загрузку")
                writeCrash("Чит не загрузился за 60 секунд",
                    "FUST_STEP=" .. tostring(getgenv().FUST_STEP or "?") .. "\n" ..
                    "Фичи:\n" .. snapshotFeatures())
            end
            break
        end
        if getgenv().FUST_READY or getgenv().FUST_LOAD_OK then
            if not started then
                started = true
                writeLog("✅ Чит загрузился! FUST_LOAD_OK=" .. tostring(getgenv().FUST_LOAD_OK))
            end
        end
    end
end)

-- ===== запуск чита =====
writeLog("=== ЗАПУСК ЧИТА ===")
writeLog("Попытка loadstring Fust с GitHub...")

local MIRROR = "https://raw.githubusercontent.com/GalinDeonor/Beta/main/"
local HttpService = game:GetService("HttpService")

local function fetch(url)
    local f = request or http_request or (syn and syn.request)
    if f then
        local ok, r = pcall(f, { Url = url, Method = "GET", Timeout = 15000 })
        if ok and type(r) == "table" and r.Body and #r.Body > 100 then
            return r.Body
        end
    end
    local ok2, body = pcall(function() return game:HttpGet(url, false) end)
    if ok2 and type(body) == "string" and #body > 100 then return body end
    return nil
end

-- 1. Качаем манифест
writeLog("Качаю manifest.json...")
local mj = fetch(MIRROR .. "manifest.json")
if not mj then
    writeCrash("manifest.json не скачался", "URL: " .. MIRROR .. "manifest.json")
    return
end
writeLog("manifest.json получен (" .. #mj .. " байт)")

local okM, m = pcall(HttpService.JSONDecode, HttpService, mj)
if not okM or type(m) ~= "table" then
    writeCrash("manifest.json битый", tostring(m))
    return
end
writeLog("Версия на репо: " .. tostring(m.ver) .. ", частей: " .. #m.parts)

-- 2. Качаем части
local src = ""
for i = 1, #m.parts do
    writeLog("Качаю часть " .. i .. "/" .. #m.parts .. ": " .. tostring(m.parts[i]) .. "...")
    local part = fetch(MIRROR .. m.parts[i])
    if not part then
        writeCrash("Часть " .. i .. " не скачалась", "URL: " .. MIRROR .. m.parts[i])
        return
    end
    src = src .. part
    writeLog("Часть " .. i .. ": " .. #part .. " байт OK")
    task.wait(0.3)
end
writeLog("Все части скачаны, всего " .. #src .. " байт")

-- 3. Проверка целостности
if m.total and #src ~= m.total then
    writeCrash("Размер не совпал", "Ожидали " .. m.total .. ", получили " .. #src)
    return
end
if m.md5 and type(crypt) == "table" and crypt.hash then
    local okH, h = pcall(crypt.hash, src, "md5")
    if okH and h and h ~= m.md5 then
        writeCrash("MD5 не сошёлся", "Ожидали " .. m.md5 .. ", получили " .. tostring(h))
        return
    end
end
writeLog("Целостность OK")

-- 4. Компиляция
writeLog("Компилирую скрипт (" .. #src .. " байт)...")
local fn, err = (loadstring or load)(src, "=Fust")
if not fn then
    writeCrash("Компиляция провалилась", tostring(err))
    return
end
writeLog("Компиляция OK")

-- 5. Запуск!
writeLog("=== ЗАПУСК FN() ===")
writeLog("Снимок фич ДО запуска: " .. snapshotFeatures())

-- Оборачиваем запуск в pcall с таймаутом
local runOk, runErr
local runDone = false

task.spawn(function()
    -- даём 30 сек на запуск
    task.wait(30)
    if not runDone then
        writeLog("⚠ fn() не завершился за 30 сек — возможно завис в инициализации")
        writeCrash("fn() завис — скрипт блокирует поток при инициализации",
            "FUST_STEP=" .. tostring(getgenv().FUST_STEP or "?") .. "\n" ..
            "Фичи:\n" .. snapshotFeatures() .. "\n" ..
            "Это значит: какая-то функция в скрипте блокирует поток без yield.")
    end
end)

runOk, runErr = pcall(fn)
runDone = true

if runOk then
    writeLog("✅ fn() завершился без ошибок (или вернулся)")
    writeLog("Снимок фич ПОСЛЕ запуска: " .. snapshotFeatures())
else
    writeLog("❌ fn() упал с ошибкой: " .. tostring(runErr))
    writeCrash("fn() ошибка выполнения", tostring(runErr))
end

-- 6. Пост-запуск мониторинг
writeLog("=== ПОСТ-ЗАПУСК МОНКТОРИНГ ===")
writeLog("Теперь мониторю кадры и heartbeat до зависания или кика.")
writeLog("Если зависнет — crash report будет в " .. CRASH_FILE)

-- Вечный цикл проверки состояния
task.spawn(function()
    while true do
        task.wait(5)
        local now = os.clock()
        local hbGap = now - lastHb
        local rsGap = now - lastFrameTime
        
        -- Проверяем: если heartbeat gap > 5 сек — фриз
        if hbGap > 5 and not frozen then
            frozen = true
            writeCrash(
                "ПОСТ-ЗАПУСК ФРИЗ: heartbeat gap=" .. string.format("%.1f", hbGap) .. "с",
                "Фичи:\n" .. snapshotFeatures() .. "\n\n" ..
                "Последний кадр: " .. lastFrameLine .. "\n" ..
                "Кадров всего: " .. frameCount .. "\n" ..
                "Heartbeat'ов: " .. hbCount .. "\n\n" ..
                "Это значит: какая-то фича заблокировала поток (возможно RenderStepped колбэк без yield)."
            )
        end
        
        -- Пишем статус каждые 30 сек
        if hbCount % 1800 == 0 and hbCount > 0 then  -- ~30 сек
            writeLog("[STATUS] кадров=" .. frameCount .. " hb=" .. hbCount .. 
                     " gap_hb=" .. string.format("%.2f", hbGap) .. 
                     " " .. snapshotFeatures())
        end
    end
end)

-- При выгрузке — метка нормального завершения
game:BindToClose(function()
    writeLog("FUST-DIAG: нормальное завершение")
end)
