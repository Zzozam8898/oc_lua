local component = require('component')
local computer = require('computer')
local coroutine = require('coroutine')
local event = require('event')
local filesystem = require('filesystem')
local serialization = require('serialization')
local thread = require('thread')
local unicode = require('unicode')
local internet = require('internet')
local os = require('os')
-- local inspect = require('inspect')

-- Config --


-- Where to save the config
local configPath = '/ae2.cfg'

-- Global State --

-- array of recipe like { item, label, wanted, [current, crafting] }
recipes = {}

local search = {}
local sel = nil
local evs = {}
local TC = 1
function getDif( a, b )
    local result = {}
    for k,v in pairs(a) do
        if table.concat(v) == table.concat(b[k]) then
            v['prev'] = b[k]['wanted']
            table.insert(result, v)
        end
    end

    return result
end



function loadRecipes()
    print('Loading config from '..configPath)
    local f, err = io.open(configPath, 'r')
    if not f then
        -- usually the file does not exist, on the first run
        print('Loading failed:', err)
        return
    end

    local content = serialization.unserialize(f:read('a'))

    f:close()

    local recipes = content.recipes
    print('Loaded '..#recipes..' recipes')
    return recipes
end



function saveRecipes()
    local tmpPath = configPath..'.tmp'
    local content = { recipes={} }

    for _, recipe in ipairs(recipes) do
        table.insert(content.recipes, {
            item = recipe.item,
            label = recipe.label,
            wanted = recipe.wanted,
        })
    end

    local f = io.open(tmpPath, 'w')
    f:write(serialization.serialize(content))
    f:close()

    filesystem.remove(configPath) -- may fail

    local ok, err = os.rename(tmpPath, configPath)
    if not ok then error(err) end
end

local function getTPS()
    local function time()
        local f = io.open("/tmp/TF", "w")
        f:write("test")
        f:close()
        return(filesystem.lastModified("/tmp/TF"))
    end
    local RO, RN, RD, TPS =  0, 0, 0
    local RO = time()
    os.sleep(TC) 
    local RN = time()
    local RD = RN - RO
    local TPS = 20000 * TC / RD
    local TPS = string.sub(TPS, 1, 5)
    local nTPS = tonumber(TPS)
    nTPS = tostring(math.min(20, nTPS))
    return nTPS
end

SERVER = 'irc.esper.net:6667'
CHANNEL = '#aestock'
nick = 'me'
 
recipes = loadRecipes()

print("Init Fs..")



local function prettyItem(i)
    return i['label'].." wanted "..i['wanted'].." ("..i['item']['name']..") "
end

function map2(t)
    local out = ''
    for _, v in pairs(t) do
      out = joinbyspace(out, v)
    end
    return out
end

function joinbyspace(k, v) 
  return k .. ' ' .. v 
end

function sendIRCMessageRaw(message)
  socket:write(message .. '\r\n')
  socket:flush()
end

local function sendMsg(message)
    sendIRCMessageRaw('PRIVMSG ' .. CHANNEL..' :' .. message)
end

local function prettySave(t)
    local result = "Changes: "
    sendMsg(result)
    for k,v in pairs(t) do
        if v['prev'] ~= v['wanted'] then
            local to_add = v['label']..' wanted '..v['prev']..' > '..v['wanted']
            sendMsg(to_add)
            os.sleep(0.05)
        end
    end
end

local function prettyPrintItems(items)
    for k,v in pairs(items) do
        sendMsg('['..k..'] '..prettyItem(v))
        os.sleep(0.05)
    end
end

function dump(o)
    if type(o) == 'table' then
       local s = '{ '
       for k,v in pairs(o) do
          if type(k) ~= 'number' then k = '"'..k..'"' end
          s = s .. '['..k..'] = ' .. dump(v) .. ','
       end
       return s .. '} '
    else
       return tostring(o)
    end
end

local function processMessage(raw)
    local words = {}
    for word in raw:gmatch("%S+") do table.insert(words, word) end
    table.remove(words,1)
    return words
end

local function sendCrafting(recipe, amount, needed)
    sendMsg("Requested "..recipe['label'].." X"..amount.." ("..i['item']['name']..") "..tostring(recipe['wanted']-needed).."/"..tostring(recipe['wanted']))
end

local function stop()

    for _, b in ipairs(evs) do
        if type(b) == 'table' and b.kill then
            b:kill()
        else
            event.cancel(b)
        end
    end
end

local function listen()
    table.insert(evs, event.listen("crafting", sendCrafting))
    table.insert(evs, event.listen("exit", stop))

end


function setWanted(id, count)
    recipes[id]['wanted']=count
end

local function login()
  if socket then socket:close() end
  socket = internet.open(SERVER)
  socket:setTimeout(0.05)
  sendIRCMessageRaw('USER ' .. nick .. ' 0 * :' .. nick)
  sendIRCMessageRaw('NICK ' .. nick)
end

local function starts(String,Start)
    return string.sub(String,1,string.len(Start))==Start
end

local function callback(message)
    if starts(message, "search") then
        local words = processMessage(message)
        if words[1] then
            local str = map2(words)
            print(str)
            search = {}
            for k,r in pairs(recipes) do
                
                if string.find(string.lower(r.label), string.lower(str)) then
                    print(dump(r))
                    r["key"] = k
                    table.insert(search, r)
                end
            end
        prettyPrintItems(search)
        return
        end
    elseif starts(message, "select") then
        local words = processMessage(message)
        if words[1] then
            if #search ~= 0 then
                sel = search[tonumber(words[1])]
            else
                sendMsg "use 'search' first"
                return
            end
        end
        sendMsg ("Now selected: "..dump(sel))
        return
    elseif starts(message, "exit") then
        sendMsg("Stopping..")
        socket:close()
        event.push("exit")
        os.exit()
    elseif starts(message, "want") then
        local words = processMessage(message)
        local key = sel.key
        local want = recipes[key]['wanted']
        if #words == 1 then
            if sel ~= nil then
                if tonumber(words[1]) ~= nil then
                    print(dump(words))
                    setWanted(key,tonumber(words[1]))
                else
                    sendMsg ("arg must be int")
                    return
                end
            else
                sendMsg ("use 'select' first")
                return
            end
        end 
        --recipes[key]['wanted'] = want
        sendMsg(dump(recipes[key]))
        sendMsg ("Now want "..tostring(recipes[key]['wanted']).." of "..recipes[key]['label'])
        return
    elseif starts(message, 'save') then
        local difs = getDif(recipes, loadRecipes())
        if difs ~= {} then
            prettySave(difs)
        end
        sendMsg ("WARNING: Saving will reboot pc. Type 'continue' to reboot")
        return
    elseif starts(message, 'continue') then
        saveRecipes()
        sendMsg("Saved. Rebooting...")
        computer.shutdown(true)
    elseif starts(message, 'dsel') then
        local words = processMessage(message)
        sendMsg(dump(recipes[tonumber(words[1])]))
    elseif starts(message, 'upgrade') then
        sendMsg("https://github.com/Zzozam8898/oc_lua/raw/main/ae2.lua".."  /home/ae2")
        loadfile("/bin/wget.lua")("-f", "https://pastebin.com/raw/eCd3P2SB", "/home/ae2")
        sendMsg("https://github.com/Zzozam8898/oc_lua/raw/main/edit.lua".."  /home/irc")
        loadfile("/bin/wget.lua")("-f", "https://pastebin.com/raw/PFNc0fZe", "/home/irc")
        os.sleep(2)
        sendMsg("Bye!")
        socket:close()
        event.push("exit")
        computer.shutdown(true)
    elseif starts(message, 'count') then
        if sel ~= nil then
            sendMsg(dump(component.me_controller.getItemsInNetwork(sel['item'])))
        else
            sendMsg ("use 'select' first")
            return
        end
    elseif starts(message, "forceup") then
        event.push("ae2_loop")
    elseif starts(message, 'checke') then
        event.push("crafting", {label="Cum", wanted=9}, 5, 6)
    elseif starts(message, "tps") then
        sendMsg(getTPS())
    elseif starts(message, "download") then
        local words = processMessage(message)
        sendMsg(words[1].."  /home/"..words[2])
        loadfile("/bin/wget.lua")("-f", words[1], "/home/"..words[2])
    else
        sendMsg("Unknown command, use 'help'")
    end
end


print("Fs loaded")
login()
listen()





while true do
    os.sleep(0)
    if not socket then login() end
        repeat
            local ok, line = pcall(socket.read, socket)
            if ok then
                if not line then login() end
                print(line)
                local match, prefix = line:match('^(:(%S+) )')
                if prefix then prefix = prefix:match('^[^!]+') end
                if match then line = line:sub(#match + 1) end
                local match, command = line:match('^(([^:]%S*))')
                if match then line = line:sub(#match + 1) end
                repeat
                    local match = line:match('^( ([^:]%S*))')
                    if match then
                      line = line:sub(#match + 1)
                    end
                until not match
                local message = line:match('^ :(.*)$')
                if command == '001' or command == '404' then
                  sendIRCMessageRaw('JOIN ' .. CHANNEL)
                elseif command == '433' or command == '436' then
                  nick = nick .. string.char(math.random(97,122))
                  sendIRCMessageRaw('NICK ' .. nick)
                elseif command == 'PING' then
                  sendIRCMessageRaw('PONG :' .. message)
                elseif command == 'PRIVMSG' then
                  callback(message)
                end
            end
        until not ok
end
