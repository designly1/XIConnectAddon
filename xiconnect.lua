_addon.name = 'XIConnect'
_addon.author = 'Jay Simons'
_addon.version = '0.0.1'
_addon.commands = { 'xicon' }

require('luau')
require('functions')
require('config')

local json = require 'lib/dkjson'
local https = require 'ssl/https'
local res = require 'resources'

local PING_TIME_DIVISOR = 2
local UPDATE_TIME_DIVISOR = 10

local defaults = T {
    url = '',
    debug = false,
    token = ''
}

local settings = config.load(defaults)
local run = false

local dump_table = function(t)
    local temp = {}
    for k, v in pairs(t) do
        table.insert(temp, k .. ": " .. tostring(v))
    end
    return table.concat(temp, "\n")
end

local debug_print = function(message)
    if settings.debug then
        windower.send_command('input /echo ' .. os.date('%H:%M:%S') .. ' ' .. message)
    end
end

-- Function to send data to a remote API
local push = function(data, endpoint, method, log_response)
    -- Encode the data as JSON
    local json_data = json.encode(data)

    -- Set up the request
    local response_body = {}
    local res, code, response_headers, status = https.request {
        url = settings.url .. endpoint,
        method = method or "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#json_data),
            ["X-API-Token"] = settings.token
        },
        source = ltn12.source.string(json_data),
        sink = ltn12.sink.table(response_body)
    }

    -- Check the response
    if code == 200 then
        debug_print("Data sent successfully!")
        debug_print("Response: " .. table.concat(response_body))
        if log_response then
            notice("Connection successful")
        end

        local data = json.decode(table.concat(response_body))
        return data
    elseif code == 404 or code == 409 or code == 401 then
        return code
    else
        debug_print("Failed to send data: " .. (status or 'Unknown error'))
        return false
    end
end

local fetch_data = function(endpoint, method)
    local response_body = {}
    local res, code, response_headers, status = https.request {
        url = settings.url .. endpoint,
        method = method or "GET",
        headers = {
            ["X-API-Token"] = settings.token
        },
        sink = ltn12.sink.table(response_body)
    }

    if code == 200 then
        local data = json.decode(table.concat(response_body))
        return data
    elseif code == 404 or code == 409 or code == 401 then
        return code
    else
        debug_print("Failed to fetch data: " .. (status or 'Unknown error'))
        return false
    end
end

local notify_error = function(code)
    if code == 404 then
        notice('Character not registered, stopping')
        return
    end
    if code == 409 then
        notice('Character already registered')
        return
    end
    if code == 401 then
        notice('Invalid API token')
        return
    end
end

local get_current_data = function()
    local player = windower.ffxi.get_player()
    local map_id, x, y = windower.ffxi.get_map_data()
    local info = windower.ffxi.get_info()
    local is_focused = windower.has_focus()

    data = {
        map_id = map_id or 0,
        x = x or 0,
        y = y or 0,
        zone_name = res.zones[windower.ffxi.get_info().zone].english or 'N/A',
        zone_id = info.zone or 0,
        is_focused = is_focused or false,
        player_name = player.name or '',
        linkshell = player.linkshell or '',
        vitals = player.vitals or {},
        in_combat = player.in_combat or false,
        buffs = player.buffs or {}
    }

    return data
end

local get_player_data = function()
    local player = windower.ffxi.get_player()
    local map_id, x, y = windower.ffxi.get_map_data()
    local info = windower.ffxi.get_info()
    local is_focused = windower.has_focus()

    data = {
        map_id = map_id or 0,
        x = x or 0,
        y = y or 0,
        zone_name = res.zones[windower.ffxi.get_info().zone].english or 'N/A',
        zone_id = info.zone or 0,
        is_focused = is_focused or false,
        in_combat = player.in_combat or false,
        player_name = player.name or '',
        player_data = player,
    }

    return data
end

local register_character = function()
    local data = get_player_data()
    local success = push(data, '/characters', 'PUT')
    if type(success) == 'number' then
        notify_error(success)
        return
    end
    if success then
        notice('Character registered: ' .. data.player_name)
    end
end

local unregister_character = function()
    local data = get_player_data()
    local response = fetch_data('/characters/' .. data.player_name, 'DELETE')
    if type(response) == 'number' then
        notify_error(response)
        return
    end
    if response then
        notice('Character unregistered: ' .. data.player_name)
    end
end

local update_character = function()
    local data = get_player_data()
    local response = push(data, '/characters/' .. data.player_name, 'PATCH')
    if type(response) == 'number' then
        notify_error(response)
        run = false
        return
    end
end

local get_characters = function()
    local data = fetch_data('/characters')
    if type(data) == 'number' then
        notify_error(data)
        return
    end
    if data then
        if type(data.characters) == 'table' then
            notice('Registered characters:')
            for _, character in pairs(data.characters) do
                notice('Character: ' .. (character.name) .. ' @ ' .. (character.zoneName))
            end
        else
            notice('Invalid response format from server')
        end
    else
        notice('Failed to fetch characters')
    end
end

local print_message = function(from, message)
    windower.add_to_chat(2, 'New XIConnect message from ' .. from .. ':')
    windower.add_to_chat(7, message)
end

local process_event = function(type, data)
    if type == 'message' then
        print_message(data.from, data.message)
    end
    if type == 'logout' then
        notice('Logout command received, shutting down')
        windower.send_command('input /shutdown')
    end
end

local ping = function(log_response)
    local data = get_current_data()
    local response = push(data, '/ping', nil, log_response)
    if type(response) == 'number' then
        notify_error(response)
        run = false
        return
    end
    if type(response) == 'table' and response.events then
        notice('Received ' .. #response.events .. ' events')
        for _, event in pairs(response.events) do
            notice('Processing event: ' .. event.type)
            process_event(event.type, event.data)
        end
    end
end

windower.register_event('time change', function(old, new)
    if run then
        if new % UPDATE_TIME_DIVISOR == 0 then
            update_character()
            return
        end
        if new % PING_TIME_DIVISOR == 0 then
            ping()
        end
    end
end)

windower.register_event('addon command', function(command)
    command = command and command:lower() or 'help'

    if command == 'start' then
        notice('XIConnect started')
        run = true
    elseif command == 'stop' then
        notice('XIConnect stopped')
        run = false
    elseif command == 'register' then
        register_character()
    elseif command == 'unregister' then
        unregister_character()
    elseif command == 'update' then
        update_character()
    elseif command == 'characters' then
        get_characters()
    elseif command == 'ping' then
        ping(true)
    elseif command == 'help' then
        windower.add_to_chat(17, 'XIConnect  v' .. _addon.version .. ' commands:')
        windower.add_to_chat(17, '//xicon [options]')
        windower.add_to_chat(17, '    start      - Starts XIConnect responder')
        windower.add_to_chat(17, '    stop       - Stops XIConnect responder')
        windower.add_to_chat(17, '    register   - Registers your current character')
        windower.add_to_chat(17, '    unregister - Unregisters your current character')
        windower.add_to_chat(17, '    update     - Updates your current character')
        windower.add_to_chat(17, '    characters - Lists all characters')
        windower.add_to_chat(17, '    ping       - Pings the server')
        windower.add_to_chat(17, '    help       - Displays this help text')
    end
end)
