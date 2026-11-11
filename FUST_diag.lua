-- ============================================================
--  FUST-DIAG v2 — ИЩЕТ ГДЕ ЗАВИСАЕТ ЧИТ
--
--  НЕ запускает чит целиком. Делит исходник на 20 кусков
--  и выполняет их по одному. Каждый кусок логируется в файл.
--  Когда зависнет — в файле будет номер последнего куска.
--
--  ФАЙЛ: FUST_trace.log — какой кусок выполнялся последним
--
--  ИСПОЛЬЗОВАНИЕ: вставь в Delta, Execute. Дождись зависания.
--  После перезапуска — открой FUST_trace.log, там номер куска.
-- ============================================================

local TRACE_FILE = "FUST_trace.log"
local MIRROR = "https://raw.githubusercontent.com/GalinDeonor/Beta/main/"

-- сохраняем оригинальные функции ДО любых перехватов
local _p = print
local _w = warn

local function log(msg)
    _p("[DIAG] " .. msg)
    if type(appendfile) == "function" then
        pcall(appendfile, TRACE_FILE, os.date("%H:%M:%S") .. " " .. msg .. "\n")
    end
end

-- очистка файла
if type(writefile) == "function" then
    pcall(writefile, TRACE_FILE, "")
end

log("=== FUST-DIAG v2 — ПОИСК ЗАВИСАНИЯ ===")
log("Executor: " .. tostring((identifyexecutor and identifyexecutor()) or "?"))

-- функция скачивания
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

-- 1. качаем манифест
log("качаю manifest.json...")
local mj = fetch(MIRROR .. "manifest.json")
if not mj then
    log("ОШИБКА: manifest не скачался")
    return
end

local HttpService = game:GetService("HttpService")
local okM, m = pcall(HttpService.JSONDecode, HttpService, mj)
if not okM or type(m) ~= "table" then
    log("ОШИБКА: manifest битый")
    return
end
log("версия " .. tostring(m.ver) .. ", частей: " .. #m.parts)

-- 2. качаем части
local src = ""
for i = 1, #m.parts do
    log("качаю часть " .. i .. "/" .. #m.parts)
    local part = fetch(MIRROR .. m.parts[i])
    if not part then
        log("ОШИБКА: часть " .. i .. " не скачалась")
        return
    end
    src = src .. part
    task.wait(0.3)
end
log("скачано " .. #src .. " байт")

-- 3. делим на 20 кусков по строкам
local lines = {}
for line in src:gmatch("[^\n]*\n") do
    table.insert(lines, line)
end
-- последняя строка без \n
local last = src:match("\n([^\n]*)$")
if last and #last > 0 then table.insert(lines, last .. "\n") end

local totalLines = #lines
local chunkCount = 20
local chunkSize = math.ceil(totalLines / chunkCount)

log("всего строк: " .. totalLines .. ", кусков: " .. chunkCount .. ", по " .. chunkSize .. " строк")

-- 4. выполняем куски по одному
local allCode = ""  -- накапливаем выполненный код

for chunk = 1, chunkCount do
    local startLine = (chunk - 1) * chunkSize + 1
    local endLine = math.min(chunk * chunkSize, totalLines)
    
    -- собираем кусок
    local chunkCode = ""
    for i = startLine, endLine do
        chunkCode = chunkCode .. lines[i]
    end
    
    -- накапливаем (Lua нужно чтобы функции были определены до использования)
    allCode = allCode .. chunkCode
    
    -- логируем ПЕРЕД выполнением
    log(string.format(">>> КУСОК %d/%d (строки %d-%d, %d байт накоплено)", chunk, chunkCount, startLine, endLine, #allCode))
    
    -- компилируем и выполняем накопленный код
    local fn, err = loadstring(allCode, "=Fust_chunk_" .. chunk)
    if not fn then
        log("  компиляция провалилась на куске " .. chunk .. ": " .. tostring(err):sub(1, 200))
        -- пробуем выполнить только этот кусок (может быть определение функции)
        fn, err = loadstring(chunkCode, "=Fust_part_" .. chunk)
        if fn then
            log("  кусок " .. chunk .. " компилируется отдельно, выполняю...")
        else
            log("  кусок " .. chunk .. " не компилируется — пропускаю")
            -- если кусок не компилируется отдельно, это может быть середина функции
            -- просто продолжаем накопление
            goto nextChunk
        end
    end
    
    -- ВЫПОЛНЯЕМ с таймаутом через task.spawn
    local done = false
    local result = nil
    
    -- watchdog: если кусок не завершится за 5 сек — это зависший кусок
    task.spawn(function()
        task.wait(5)
        if not done then
            log(string.format("!!! КУСОК %d ЗАВИС (не завершился за 5 сек) — это проблемный кусок!", chunk))
            log(string.format("!!! Строки %d-%d содержат зависающий код", startLine, endLine))
            -- пишем содержимое куска в файл для анализа
            if type(writefile) == "function" then
                pcall(writefile, "FUST_frozen_chunk.txt", 
                    string.format("КУСОК %d, строки %d-%d\n\n", chunk, startLine, endLine) .. chunkCode)
            end
            -- не можем продолжить — поток заблокирован
        end
    end)
    
    local ok, err2 = pcall(fn)
    done = true
    
    if not ok then
        log("  кусок " .. chunk .. " ошибка: " .. tostring(err2):sub(1, 200))
    else
        log(string.format("  кусок %d OK", chunk))
    end
    
    -- yield между кусками — движок дышит
    task.wait(0.2)
    
    ::nextChunk::
end

log("=== ВСЕ КУСКИ ВЫПОЛНЕНЫ ===")
log("Если чит не завис — проблема не в инициализации, а в RenderStepped/Heartbeat колбэках")
log("Если завис — смотри FUST_trace.log, последний кусок = проблемный")
log("Содержимое зависшего куска в FUST_frozen_chunk.txt")
