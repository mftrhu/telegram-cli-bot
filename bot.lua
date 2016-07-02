-- bot.lua
-- Use this with `bin/telegram-cli -s bot.lua`

-- 2 seconds between commands (say, `!ping`) should be enough to avoid botloops
-- Of course the other bot could wait 2 seconds between pings, but...
TIMEOUT = 2
-- We shouldn't reply as much if we are busy.
BUSY_TIMEOUT = 10
BUSY_REPLIES = {
    ["Question"] = "Answer"
}
GENERIC_BUSY_REPLY = "I am currently busy - try again later :)"
DEFAULT_CHAT = nil -- (chat|channel)#id<ID>
DEFAULT_SHOO = nil -- @<USERNAME>
DEFAULT_SPAM = "/start"
LOG_MESSAGES = true
LOG_FILE = "log"
RUN_CRON_EVERY = 60.0

started = false
logfile = nil
our_id = 0
blacklist = {}
in_timeout = {}
busy = false
ignore_commands = false
-- Dispatch tables [command] -> function (peer, params, message)
own_commands = {}
commands = {}
-- Use `register_command` or `register_own_command` with `(command, func)`
--  to add commands to the tables.

function ok_cb(extra, success, result)
end

function should_we_not_reply(msg)
    -- Given a telegram message `msg` this checks whether the sender of the
    --  message has been blacklisted or is in timeout. If neither applies this
    --  updated the *last time replied to* of the user in the `in_timeout` table
    --  and returns false.
    from = msg.from.peer_type .. "#id" .. msg.from.peer_id
    -- Ignore blacklisted users
    if blacklist[from] then
        return true
    end
    -- Ignore users in timeout
    local timeout = TIMEOUT
    if busy then
        -- We have a different timeout when we are busy - we don't want to
        --  reply with ten messages to people talking with us in private.
        -- I wonder if this is really necessary.
        timeout = BUSY_TIMEOUT
    end
    if (in_timeout[from] ~= nil) and (msg.date - in_timeout[from]) < timeout then
        return true
    end
    -- Update last message replied to time
    in_timeout[from] = msg.date
    return false
end

function user_string(peer)
    -- Given a telegram peer `peer` it returns a string containing a textual
    --  representation of the peer, according to the following format
    --  specification.
    --
    -- ## Format Specification
    --
    -- ```bnf
    -- <TYPE> "#id" <ID> " - " <NAME>
    --
    -- <NAME> := ["@" <USERNAME> " - "] <FIRST_NAME> [" " <LAST_NAME>]
    --         | <TITLE>
    -- <TYPE> := "user" | "group" | "channel"
    -- ```
    local result = ""
    result = result .. peer.peer_type .. "#id" .. peer.peer_id .. " - "
    if peer.peer_type == "user" then
        if peer.username then
            result = result .. "@" .. peer.username .. " - "
        end
        result = result .. peer.first_name
        if peer.last_name then
            result = result .. " " .. peer.last_name
        end
    else
        result = result .. peer.title
    end
    return result
end

function describe_message(msg)
    -- Given a telegram message `msg` it returns a string containing a textual
    --  representation of the message, according to the following format
    --  specification.
    --
    -- ## Format specification
    --
    -- ```bnf
    -- "[" <DATE> "] [" <FROM:USER> "] [" <TO:USER> "]" <MESSAGE:MESS>
    --
    -- <DATE> := <YEAR> "-" <MONTH> "-" <DAY> " " <HOUR> ":" <MINUTES> ":" <SECONDS>
    -- <USER> := <PEER_TYPE> "#id" <PEER_ID> " - " <PEER_NAME:NAME>
    -- <NAME> := ["@" <PEER_USERNAME> " - "] <PEER_FIRST_NAME> [<PEER_LAST_NAME>] 
    --         | <PEER_TITLE>
    -- <MESS> := ": " <MESSAGE_TEXT>
    --         | " [media: " <MESSAGE_MEDIA_TYPE> "]"
    --         | "[" <MESSAGE_ACTION_TYPE> [": " <MESSAGE_ACTION_USER:USER>] "]" 
    -- <PEER_TYPE> := "user" | "group" | "channel"
    -- ```
    local now = os.date("[%Y-%m-%d %H:%M:%S]", msg.date)
    local result = now .. " [" .. user_string(msg.from) .. "] [" .. user_string(msg.to) .. "]"
    if msg.text then
        result = result .. ": " .. msg.text
    end
    if msg.media then
        result = result .. " [media: " .. msg.media.type  .. "]"
    end
    if msg.action then
        result = result .. " [" .. msg.action.type
        if msg.action.user then
            result = result .. ": " .. user_string(msg.action.user)
        end
        result = result .. "]"
    end
    return result
end

function log_message(msg)
    -- Given a telegram message `msg` it appends to `logfile` the textual
    --  representation of `msg` returned by `describe_message`, plus a newline.
    logfile:write(describe_message(msg) .. "\n")
end

function register_command(command, func)
    commands[command] = func
end

function register_own_command(command, func)
    own_commands[command] = func
end

function handle_our_own_message(msg)
    -- Given an outbound telegram message `msg` this handles the commands
    --  exclusive to ourselves.
    local peer = msg.to.peer_type .. "#id" .. msg.to.peer_id
    -- This is "bugged" - it doesn't handle accented letters in commands
    -- Also, I don't really understand how Lua patterns work :-/
    local command, params = msg.text:match("^(!%a*)%s?(.*)$")
    if command then
        if own_commands[command] then
            own_commands[command](peer, params, msg)
        end
    end
end

function to_whom_should_we_reply(msg)
    -- Given a telegram message `msg` it returns whether this is a private
    --  chat and the id of the peer we should reply to.
    if (msg.to.peer_id == our_id) then
        -- This is a private chat - `from` holds the sender, `to` our id
        -- Don't reply to ourselves, that'd be silly.
        return true, msg.from.peer_type .. "#id" .. msg.from.peer_id
    else
        -- The message was sent to a group - reply in the group
        return false, msg.to.peer_type .. "#id" .. msg.to.peer_id
    end
end

function handle_busy(msg, peer)
    -- Given a telegram message `msg` and a peer id `peer` (which will always
    --  be an user id), this replies with either a generic busy reply or with
    --  a reply taken from the `BUSY_REPLIES` table according to the message
    --  received.
    if busy_replies[msg.text] then
        -- Oh-ho! We matched the message with something from the table!
        send_msg(peer, BUSY_REPLIES[msg.text], ok_cb, false)
    else
        -- Generic bot-ty reply which makes us looks like bots
        send_msg(peer, GENERIC_BUSY_REPLY, ok_cb, false)
    end
end

function on_msg_receive(msg)
    if not started then
        return
    end
    -- Log the message to file
    if LOG_MESSAGES then
        log_message(msg)
    end
    -- Handle outbound messages
    if msg.out then
        handle_our_own_message(msg)
        return
    end
    -- Ignore blacklisted users or users in timeout
    if should_we_not_reply(msg) then
        return
    end

    local is_private_chat, peer = to_whom_should_we_reply(msg)

    if busy then
        if is_private_chat then
            -- If somebody messages us in a private chat when we are busy,
            --  autoresponder FTW.
            handle_busy(msg, peer)
        end
        return
    end
    if ignore_commands then
        return
    end

    -- See `handle_our_own_message`
    local command, params = msg.text:match("^(!%a*)%s?(.*)$")
    if command then
        if commands[command] then
            commands[command](peer, params, msg)
        end
    end
end

function on_our_id (id)
    our_id = id
end

function on_user_update(user, what)
end

function on_chat_update(chat, what)
end

function on_secret_chat_update(chat, what)
end

function on_get_difference_end()
end

function cron()
    -- Insert here the code to run every `RUN_CRON_EVERY` seconds.
    postpone(cron, false, RUN_CRON_EVERY)
end

function on_binlog_replay_end()
    if LOG_MESSAGES then
        logfile = assert(io.open(LOG_FILE, "a"))
    end
    postpone(cron, false, RUN_CRON_EVERY)
    started = true
    print("We are online.")
end

-------------------------------------------------------------------------------
-- Own commands

-- Says "Sciò" to somebody. Extremely silly.
register_own_command("!shoo", function(peer, params, msg)
    if #params == 0 then
        params = DEFAULT_SHOO
    end
    send_msg(peer, params, ok_cb, false)
    postpone(function ()
        send_msg(peer, "Sciò", ok_cb, false)
    end, false, 2.0)
end)

-- Spams a message 10 times - silly, prone to abuse and prolly badly written.
register_own_command("!spam", function(peer, params, msg)
    if #params == 0 or params:match("!spam") then
        params = DEFAULT_SPAM
    end
    for i=1,10 do
        postpone(function () 
            if not ignore_commands then
                send_msg(peer, params, ok_cb, False)
            end
        end, false, i)
    end
end)

--[[
-- Old, spammy version of the command - use this coupled with !spam (!spam)* to
--  absolutely flood a chat with messages.
-- No, this wasn't really what I wanted.
register_own_command("!spam", function(peer, params, msg)
    if #params == 0 then
        params = DEFAULT_SPAM
    end
    for i=1,10 do
        postpone(function () 
            send_msg(peer, params, ok_cb, False)
        end, false, i)
    end
end)
]]

-- Ignore commands - global.
register_own_command("!shtap", function(peer, params, msg)
    ignore_commands = true
end)

-- Accept commands again - global.
register_own_command("!go_for_it", function(peer, params, msg)
    ignore_commands = false
end)

-- Sets `busy` to true - the bot will ignore commands and reply to private
--  messages with strings from the busy messages table.
register_own_command("!busy", function(peer, params, msg)
    busy = true
end)

-- Sets `busy` to false - the bot will now reply to messages and stop replying
--  to private messages.
register_own_command("!free", function(peer, params, msg)
    busy = false
end)

-- Self-destructing messages
-- Doesn't work with private chats or normal groups
-- Didn't test it on supergroups
--[[register_own_command("!sd", function(peer, params, msg)
    postpone(function ()
        delete_msg(msg.id, ok_cb, false)
    end, false, 5.0)
end)]]

-------------------------------------------------------------------------------
-- Commands accessible by other users
-- Take care with these, as they are very prone to abuse

-- Reply to `!ping` with `pong` - yes, silly and prone to abuse
register_command("!ping", function (peer, params, msg)
    send_msg(peer, "pong", ok_cb, false)
end)
