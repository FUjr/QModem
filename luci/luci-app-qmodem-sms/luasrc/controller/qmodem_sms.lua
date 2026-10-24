module("luci.controller.qmodem_sms", package.seeall)

local http = require "luci.http"
local json = require "luci.jsonc"
local ubus = require "ubus"

local function backend_call(method, arguments)
	local connection = ubus.connect()
	if not connection then
		return { status = "error", error = "SMS backend unavailable" }
	end
	local result = connection:call("qmodem.sms", method, arguments or {})
	connection:close()
	return result or { status = "error", error = "SMS backend call failed" }
end

local function reply(value)
	http.prepare_content("application/json")
	http.write_json(value)
end

local function country_code_get(modem_id)
	return backend_call("config_get", { modem_id = modem_id })
end

local function country_code_set(modem_id, code)
	return backend_call("configure", { modem_id = modem_id, country_code = code })
end

function getCountryCode()
	local result = country_code_get(http.formvalue("cfg"))
	http.prepare_content("application/json")
	http.write_json(result)
end

function setCountryCode()
	local result = country_code_set(http.formvalue("cfg"), http.formvalue("country_code") or "")
	http.prepare_content("application/json")
	http.write_json(result)
end

function index()
	entry({"admin", "modem", "qmodem", "sms_country_code"}, call("getCountryCode"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "set_sms_country_code"}, post("setCountryCode"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "modem_sms"}, template("modem_sms/modem_sms"), luci.i18n.translate("SMS"), 11).leaf = true
	entry({"admin", "modem", "qmodem", "send_sms"}, call("sendSMS"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "get_sms"}, call("getSMS"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "delete_sms"}, call("delSMS"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "sms_storage"}, call("setStorage"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "sms_forward"}, cbi("qmodem_sms/sms_forward"), luci.i18n.translate("SMS Forward"), 12).leaf = true
	entry({"admin", "modem", "qmodem", "sms_forward_extedit"}, cbi("qmodem_sms/sms_forward_extedit")).leaf = true
end

function getSMS()
	local modem_id = http.formvalue("cfg")
	local result = backend_call("list", { modem_id = modem_id, limit = 500, offset = 0 })
	if result.mode == "database_poll" then
		backend_call("sync", { modem_id = modem_id })
		result = backend_call("list", { modem_id = modem_id, limit = 500, offset = 0 })
	end
	local messages = result.messages or result.msg or result.received or {}
	local received = {}
	for _, message in ipairs(messages) do
		if not message.type or message.type == "received" then
			message.index = message.index or message.id
			received[#received + 1] = message
		end
	end
	reply({ msg = received, mode = result.mode, error = result.error })
end

function sendSMS()
	local result = backend_call("send", {
		modem_id = http.formvalue("cfg"),
		recipient = http.formvalue("phone_number"),
		content = http.formvalue("message_content"),
		country_code = http.formvalue("country_code")
	})
	reply({ result = { status = result.status == "success" and 1 or 0 }, backend = result })
end

function delSMS()
	local modem_id = http.formvalue("cfg")
	local changed = 0
	for id in (http.formvalue("index") or ""):gmatch("%d+") do
		local result = backend_call("delete", { modem_id = modem_id, id = tonumber(id), index = tonumber(id) })
		if result.status == "success" then changed = changed + 1 end
	end
	reply({ success = true, deleted = changed })
end

function setStorage()
	local values = json.parse(http.formvalue("storage") or "{}") or {}
	local result = backend_call("storage_set", {
		modem_id = http.formvalue("cfg"), mem1 = values.mem1,
		mem2 = values.mem2, mem3 = values.mem3
	})
	reply(result)
end
