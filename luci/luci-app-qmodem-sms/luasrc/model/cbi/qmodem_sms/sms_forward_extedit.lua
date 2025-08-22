local uci = require "luci.model.uci".cursor()
local dispatcher = require "luci.dispatcher"
local fs = require "nixio.fs"
local json = require "luci.jsonc"



m = Map("sms_daemon", translate("SMS Forward Advanced Configuration"))
m.redirect = dispatcher.build_url("admin", "modem", "qmodem", "sms_forward")

-- 添加说明信息
m.description = translate("Advanced SMS Forward configuration with type-specific options.")

-- SMS转发实例配置
s2 = m:section(NamedSection, arg[1], "sms_forward_instance",translate("SMS Forward Instances"))
s2.addremove = true
s2.anonymous = false

-- 实例启用开关
instance_enable = s2:option(Flag, "enable", translate("Enable"))
instance_enable.default = "0"

-- 监听端口
listen_port = s2:option(ListValue, "listen_port", translate("Modem Port"))
listen_port.rmempty = false

-- 获取可用的AT端口
uci:foreach("qmodem", "modem-device", function(section)
    local ports = section.ports or {}
    local valid_ports = section.valid_at_ports or {}
    
    if type(ports) == "table" then
        for _, port in ipairs(ports) do
            local valid = false
            if type(valid_ports) == "table" then
                for _, valid_port in ipairs(valid_ports) do
                    if port == valid_port then
                        valid = true
                        break
                    end
                end
            end
            
            local display_name = port
            if valid then
                display_name = port .. " (" .. translate("VALID") .. ")"
            else
                display_name = port .. " (" .. translate("INVALID") .. ")"
            end
            listen_port:value(port, display_name)
        end
    end
end)

-- 如果没有找到端口，添加常见的端口选项
if next(listen_port.keylist) == nil then
    for i = 0, 7 do
        listen_port:value("/dev/ttyUSB" .. i, "/dev/ttyUSB" .. i)
    end
    for i = 0, 3 do
        listen_port:value("/dev/ttyACM" .. i, "/dev/ttyACM" .. i)
    end
end

-- 轮询间隔
poll_interval = s2:option(Value, "poll_interval", translate("Poll Interval"))
poll_interval.datatype = "range(15,600)"
poll_interval.default = "30"
poll_interval.description = translate("Polling interval in seconds (15-600)")

-- API类型
api_type = s2:option(ListValue, "api_type", translate("API Type"))
api_type:value("tgbot", translate("Telegram Bot"))
api_type:value("webhook", translate("Webhook"))
api_type:value("serverchan", translate("ServerChan"))
api_type:value("pushdeer", translate("PushDeer"))
api_type:value("custom_script", translate("Custom Script"))

-- 删除已转发短信选项
delete_after_forward = s2:option(Flag, "delete_after_forward", translate("Delete After Forward"))
delete_after_forward.default = "0"
delete_after_forward.description = translate("Delete SMS messages from modem after successful forwarding. This helps keep the modem's SMS storage clean but messages will be permanently removed.")

-- Telegram Bot 配置
tg_bot_token = s2:option(Value, "tg_bot_token", translate("Bot Token"))
tg_bot_token:depends("api_type", "tgbot")
tg_bot_token.placeholder = "123456:ABC-DEF1234ghIkl"

tg_chat_id = s2:option(Value, "tg_chat_id", translate("Chat ID"))
tg_chat_id:depends("api_type", "tgbot")
tg_chat_id.placeholder = "123456789"

-- Webhook 配置
webhook_url = s2:option(Value, "webhook_url", translate("Webhook URL"))
webhook_url:depends("api_type", "webhook")
webhook_url.placeholder = "https://example.com/webhook"

webhook_headers = s2:option(Value, "webhook_headers", translate("Headers (optional)"))
webhook_headers:depends("api_type", "webhook")
webhook_headers.placeholder = "Authorization: Bearer token"

-- ServerChan 配置
serverchan_token = s2:option(Value, "serverchan_token", translate("Token"))
serverchan_token:depends("api_type", "serverchan")
serverchan_token.placeholder = "SCT123456TCxyz..."
serverchan_token.description = translate("ServerChan API token from https://sctapi.ftqq.com")

serverchan_channel = s2:option(Value, "serverchan_channel", translate("Channel (optional)"))
serverchan_channel:depends("api_type", "serverchan")
serverchan_channel.placeholder = "9|66"
serverchan_channel.description = translate("Message channel, use | to separate multiple channels")

serverchan_noip = s2:option(Flag, "serverchan_noip", translate("Hide IP"))
serverchan_noip:depends("api_type", "serverchan")
serverchan_noip.description = translate("Hide caller IP address")

serverchan_openid = s2:option(Value, "serverchan_openid", translate("OpenID (optional)"))
serverchan_openid:depends("api_type", "serverchan")
serverchan_openid.placeholder = "openid1,openid2"
serverchan_openid.description = translate("OpenID for message forwarding, use comma to separate multiple IDs")

-- PushDeer 配置
pushdeer_push_key = s2:option(Value, "pushdeer_push_key", translate("Push Key"))
pushdeer_push_key:depends("api_type", "pushdeer")
pushdeer_push_key.placeholder = "PDU123456T..."
pushdeer_push_key.description = translate("PushDeer Push Key from http://pushdeer.com")

pushdeer_endpoint = s2:option(Value, "pushdeer_endpoint", translate("API Endpoint (optional)"))
pushdeer_endpoint:depends("api_type", "pushdeer")
pushdeer_endpoint.placeholder = "https://api2.pushdeer.com"
pushdeer_endpoint.description = translate("Custom PushDeer API endpoint, leave empty to use default")

-- Custom Script 配置
custom_script_path = s2:option(Value, "custom_script_path", translate("Script Path"))
custom_script_path:depends("api_type", "custom_script")
custom_script_path.placeholder = "/usr/bin/my_sms_script.sh"

-- 隐藏的api_config字段，用于存储生成的JSON
api_config = s2:option(Value, "api_config", translate("Generated API Config"))
api_config.template = "cbi/tvalue"
api_config.readonly = true
api_config.rows = 3

-- 在保存时生成JSON配置
function m.on_save_apply(self, config)
    local changed = false
    
    uci:foreach("sms_daemon", "sms_forward_instance", function(section)
        local section_name = section[".name"]
        local api_type_val = section.api_type
        local json_config = ""
        
        if api_type_val == "tgbot" then
            local bot_token = section.tg_bot_token or ""
            local chat_id = section.tg_chat_id or ""
            json_config = string.format('{"bot_token":"%s","chat_id":"%s"}', bot_token, chat_id)
            
        elseif api_type_val == "webhook" then
            local webhook_url_val = section.webhook_url or ""
            local headers = section.webhook_headers or ""
            if headers ~= "" then
                json_config = string.format('{"webhook_url":"%s","headers":"%s"}', webhook_url_val, headers)
            else
                json_config = string.format('{"webhook_url":"%s"}', webhook_url_val)
            end
            
        elseif api_type_val == "serverchan" then
            local token = section.serverchan_token or ""
            local channel = section.serverchan_channel or ""
            local noip = section.serverchan_noip or ""
            local openid = section.serverchan_openid or ""
            
            json_config = string.format('{"token":"%s"', token)
            if channel ~= "" then
                json_config = json_config .. string.format(',"channel":"%s"', channel)
            end
            if noip == "1" then
                json_config = json_config .. ',"noip":"1"'
            end
            if openid ~= "" then
                json_config = json_config .. string.format(',"openid":"%s"', openid)
            end
            json_config = json_config .. "}"
            
        elseif api_type_val == "pushdeer" then
            local push_key = section.pushdeer_push_key or ""
            local endpoint = section.pushdeer_endpoint or ""
            
            json_config = string.format('{"push_key":"%s"', push_key)
            if endpoint ~= "" then
                json_config = json_config .. string.format(',"endpoint":"%s"', endpoint)
            end
            json_config = json_config .. "}"
            
        elseif api_type_val == "custom_script" then
            local script_path = section.custom_script_path or ""
            json_config = string.format('{"script_path":"%s"}', script_path)
        end
        
        if json_config ~= "" and json_config ~= section.api_config then
            uci:set("sms_daemon", section_name, "api_config", json_config)
            changed = true
        end
    end)
    
    if changed then
        uci:save("sms_daemon")
        uci:commit("sms_daemon")
    end
end

-- 在加载时解析JSON配置到各个字段
function m.on_init(self)
    uci:foreach("sms_daemon", "sms_forward_instance", function(section)
        local section_name = section[".name"]
        local api_type_val = section.api_type
        local api_config_val = section.api_config or ""
        
        if api_config_val ~= "" then
            local parsed = json.parse(api_config_val)
            if parsed then
                if api_type_val == "tgbot" then
                    if parsed.bot_token then
                        uci:set("sms_daemon", section_name, "tg_bot_token", parsed.bot_token)
                    end
                    if parsed.chat_id then
                        uci:set("sms_daemon", section_name, "tg_chat_id", parsed.chat_id)
                    end
                    
                elseif api_type_val == "webhook" then
                    if parsed.webhook_url then
                        uci:set("sms_daemon", section_name, "webhook_url", parsed.webhook_url)
                    end
                    if parsed.headers then
                        uci:set("sms_daemon", section_name, "webhook_headers", parsed.headers)
                    end
                    
                elseif api_type_val == "serverchan" then
                    if parsed.token then
                        uci:set("sms_daemon", section_name, "serverchan_token", parsed.token)
                    end
                    if parsed.channel then
                        uci:set("sms_daemon", section_name, "serverchan_channel", parsed.channel)
                    end
                    if parsed.noip then
                        uci:set("sms_daemon", section_name, "serverchan_noip", parsed.noip)
                    end
                    if parsed.openid then
                        uci:set("sms_daemon", section_name, "serverchan_openid", parsed.openid)
                    end
                    
                elseif api_type_val == "pushdeer" then
                    if parsed.push_key then
                        uci:set("sms_daemon", section_name, "pushdeer_push_key", parsed.push_key)
                    end
                    if parsed.endpoint then
                        uci:set("sms_daemon", section_name, "pushdeer_endpoint", parsed.endpoint)
                    end
                    
                elseif api_type_val == "custom_script" then
                    if parsed.script_path then
                        uci:set("sms_daemon", section_name, "custom_script_path", parsed.script_path)
                    end
                end
            end
        end
    end)
end

return m
