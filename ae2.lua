local component = require('component')
local computer = require('computer')
local coroutine = require('coroutine')
local event = require('event')
local filesystem = require('filesystem')
local serialization = require('serialization')
local thread = require('thread')
local tty = require('tty')
local unicode = require('unicode')

-- local inspect = require('inspect')

-- Config --

-- Control how many CPUs to use. 0 is unlimited, negative to keep some CPU free, between 0 and 1 to reserve a share,
-- and greater than 1 to allocate a fixed number.
local allowedCpus = -2
-- Maximum size of the crafting requests
local maxBatch = 256
-- How often to check the AE system, in second
local fullCheckInterval = 20      -- full scan
local craftingCheckInterval = 10     -- only check ongoing crafting
-- Where to save the config
local configPath = '/ae2.cfg'

-- Global State --

-- array of recipe like { item, label, wanted, [current, crafting] }
local recipes = {}
-- various system status data
local status = {}
-- AE2 proxy
local ae2

-- Functions --

function main()

    initAe2()
    loadRecipes()
    ae2Run(true)

    local background = {}
    table.insert(background, event.timer(craftingCheckInterval, failFast(checkCrafting), math.huge))
    table.insert(background, thread.create(failFast(ae2Loop)))
    table.insert(background, thread.create(loadfile('irc')))

    local _, err = event.pull("exit")


    for _, b in ipairs(background) do
        if type(b) == 'table' and b.kill then
            b:kill()
        else
            event.cancel(b)
        end
    end
end

function log(...)
    -- TODO: reserve a part of the screen for logs
    print(...)
end

function logRam(msg)
    --free, total = computer.freeMemory(), computer.totalMemory()
    --log(msg, 'RAM', (total - free) * 100 / total, '%')
end

function pretty(x)
    return serialization.serialize(x, true)
end

function failFast(fn)
    return function(...)
        local res = table.pack(xpcall(fn, debug.traceback, ...))
        if not res[1] then
            event.push('exit', res[2])
        end
        return table.unpack(res, 2)
    end
end

function initAe2()
    local function test_ae2(id)
        local proxy = component.proxy(id)
        proxy.getCpus()
        return proxy
    end

    for id, type in pairs(component.list()) do
        -- print('Testing ' .. type .. ' ' .. id)
        local ok, p = pcall(test_ae2, id)
        if ok then
            print('Component ' .. type .. ' (' .. id .. ') is suitable')
            ae2 = p
        end
    end

    if ae2 == nil then
        error('No AE2 component found')
    else
        print('Using component ' .. ae2.type .. ' (' .. ae2.address .. ')')
    end
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

    recipes = content.recipes
    print('Loaded '..#recipes..' recipes')
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

-- Main loop --

function ae2Loop()
    while true do
        local e1, e2 = event.pull(fullCheckInterval, 'ae2_loop')
        logRam('loop')
        --log('AE2 loop in')
        ae2Run(e2 == 'reload_recipes')
        --log('AE2 loop out')
    end
end


function ae2Run(learnNewRecipes)
    local start = computer.uptime()
    updateRecipes(learnNewRecipes)
    logRam('recipes')
    -- logRam('recipes (post-gc)')

    local finder = coroutine.create(findRecipeWork)
    while hasFreeCpu() do
        -- Find work
        local _, recipe, needed, craft = coroutine.resume(finder)
        if recipe then
            -- Request crafting
            local amount = math.min(needed, maxBatch)
            --log('Requesting ' .. amount .. ' ' .. recipe.label)
            event.push("crafting", recipe, amount, needed)
            recipe.crafting = craft.request(amount)
            yield('yield crafting')
            checkFuture(recipe) -- might fail very quickly (missing resource, ...)
        else
            break
        end
    end

    local duration = computer.uptime() - start
    updateStatus(duration)
end

function checkCrafting()
    for _, recipe in ipairs(recipes) do
        if checkFuture(recipe) then
            log('checkCrafting event !')
            event.push('ae2_loop')
            return
        end
    end
end

function yield(msg)
    --local gpu = tty.gpu()
    --local _, h = gpu.getViewport()
    --gpu.set(1, h, msg)
    os.sleep()
end



function updateRecipes(learnNewRecipes)
    local start = computer.uptime()

    -- Index our recipes
    local index = {}
    for _, recipe in ipairs(recipes) do
        local key = itemKey(recipe.item, recipe.item.label ~= nil)
        index[key] = { recipe=recipe, matches={} }
    end
    log('recipe index', computer.uptime() - start)

    -- Get all items in the network
    --local items, err = ae2.getItemsInNetwork()  -- takes a full tick (to sync with the main thread?)
    --if err then error(err) end
    local items, err = ae2.getItemsInNetwork() -- takes a full tick (to sync with the main thread?)
    if err then error(err) end
    log('ae2.getItemsInNetwork', computer.uptime() - start, 'with', #items, 'items')

    -- Match all items with our recipes
    for _, item in ipairs(items) do
        local key = itemKey(item, item.hasTag)
        local indexed = index[key]
        if indexed then
            table.insert(indexed.matches, item)
        elseif learnNewRecipes then
            local recipe = {
                item = {
                    name = item.name,
                    damage = math.floor(item.damage)
                },
                label = item.label,
                wanted = 0,
            }
            if item.hasTag then
                -- By default, OC doesn't expose items NBT, so as a workaround we use the label as
                -- an additional discriminant. This is not perfect (still some collisions, and locale-dependent)
                recipe.item.label = recipe.label
            end
            table.insert(recipes, recipe)
            index[key] = { recipe=recipe, matches={item} }

        end
    end
    log('group items', computer.uptime() - start)

    -- Check the recipes
    for _, entry in pairs(index) do
        local recipe = entry.recipe
        local matches = filter(entry.matches, function(e) return contains(e, recipe.item) end)
        --log(recipe.label, 'found', #matches, 'matches')
        local craftable = false
        recipe.error = nil

        checkFuture(recipe)

        if #matches == 0 then
            recipe.stored = 0
        elseif #matches == 1 then
            local item = matches[1]
            recipe.stored = math.floor(item.size)
            craftable = true
        else
            local id = recipe.item.name .. ':' .. recipe.item.damage
            recipe.stored = 0
            recipe.error = id .. ' match ' .. #matches .. ' items'
            -- log('Recipe', recipe.label, 'matches:', pretty(matches))
        end

        if not recipe.error and recipe.wanted > 0 and not craftable then
            -- Warn the user as soon as an item is not craftable rather than wait to try
            recipe.error = 'Нет рецепта'
        end
    end
    log('recipes check', computer.uptime() - start)

    if learnNewRecipes then
        event.push('save')
    end
end

function itemKey(item, withLabel)
    local key = item.name .. '$' .. math.floor(item.damage)
    if withLabel then
        --log('using label for', item.label)
        key = key .. '$' .. item.label
    end
    return key
end

function updateStatus(duration)
    status.update = {
        duration = duration
    }

    -- CPU data
    local cpus = ae2.getCpus()
    status.cpu = {
        all = #cpus,
        free = 0,
    }
    for _, cpu in ipairs(cpus) do
        status.cpu.free = status.cpu.free + (cpu.busy and 0 or 1)
    end

    -- Recipe stats
    status.recipes = {
        error = 0,
        crafting = 0,
        queue = 0,
    }
    for _, recipe in ipairs(recipes) do
        if recipe.error then
            status.recipes.error = status.recipes.error + 1
        elseif recipe.crafting then
            status.recipes.crafting = status.recipes.crafting + 1
        elseif (recipe.stored or 0) < (recipe.wanted or 0) then
            status.recipes.queue = status.recipes.queue + 1
        end
    end
end

function checkFuture(recipe)
    if not recipe.crafting then return end

    local canceled, err = recipe.crafting.isCanceled()
    if canceled or err then
        --log('Crafting of ' .. recipe.label .. ' was cancelled')
        recipe.crafting = nil
        recipe.error = err or 'canceled'
        return true
    end

    local done, err = recipe.crafting.isDone()
    if err then error('isDone ' .. err) end
    if done then
        --log('Crafting of ' .. recipe.label .. ' is done')
        recipe.crafting = nil
        return true
    end

    return false
end

function equals(t1, t2)
    if t1 == t2 then return true end
    if type(t1) ~= type(t2) or type(t1) ~= 'table' then return false end

    for k1, v1 in pairs(t1) do
        local v2 = t2[k1]
        if not equals(v1, v2) then return false end
    end

    for k2, _ in pairs(t2) do
        if t1[k2] == nil then return false end
    end

    return true
end

function filter(array, predicate)
    local res = {}
    for _, v in ipairs(array) do
        if predicate(v) then table.insert(res, v) end
    end
    return res
end

function contains(haystack, needle)
    if haystack == needle then return true end
    if type(haystack) ~= type(needle) or type(haystack) ~= 'table' then return false end

    for k, v in pairs(needle) do
        if not contains(haystack[k], v) then return false end
    end

    return true
end

function hasFreeCpu()
    local cpus = ae2.getCpus()
    local free = 0
    for i, cpu in ipairs(cpus) do
        if not cpu.busy then free = free + 1 end
    end
    local ongoing = 0
    for _, recipe in ipairs(recipes) do
        if recipe.crafting then ongoing = ongoing + 1 end
    end

    if enoughCpus(#cpus, ongoing, free) then
        return true
    else
        --log('No CPU available')
        return false
    end
end

function enoughCpus(available, ongoing, free)
    if free == 0 then return false end
    if ongoing == 0 then return true end
    if allowedCpus == 0 then return true end
    if allowedCpus > 0 and allowedCpus < 1 then
        return  (ongoing + 1) / available <= allowedCpus
    end
    if allowedCpus >= 1 then
        return ongoing < allowedCpus
    end
    if allowedCpus > -1 then
        return (free - 1) / available <= -allowedCpus
    end
    return free > -allowedCpus
end

function findRecipeWork() --> yield (recipe, needed, craft)
    for i, recipe in ipairs(recipes) do
        if recipe.error or recipe.crafting then goto continue end

        local needed = recipe.wanted - recipe.stored
        if needed <= 0 then goto continue end

        yield('yield '..i)
        local craftables, err = ae2.getCraftables(recipe.item)
        log('get_craftable', recipe.item.name)
        if err then
            recipe.error = 'ae2.getCraftables ' .. tostring(err)
        elseif #craftables == 0 then
            recipe.error = 'No crafting pattern found'
        elseif #craftables == 1 then
            coroutine.yield(recipe, needed, craftables[1])
        else
            recipe.error = 'Multiple crafting patterns'
        end

        ::continue::
    end
end





-- Start the program
main()