module("luci.controller.qmodem_sms", package.seeall)
local http = require "luci.http"
local fs = require "nixio.fs"
local json = require("luci.jsonc")
local modem_ctrl = "/usr/share/qmodem/modem_ctrl.sh "

function shell(command)
	local odpall = io.popen(command)
	local odp = odpall:read("*a")
	odpall:close()
	return odp
end

local function country_code_get(modem_id)
	local uci = require("luci.model.uci").cursor()
	if not modem_id or not uci:get("qmodem", modem_id) then
		return { error = "Failed to get modem configuration" }
	end
	return { country_code = uci:get("qmodem", modem_id, "sms_country_code") or "" }
end

local function country_code_set(modem_id, code)
	if code == "+" then return { error = "Invalid country calling code" } end
	code = code:gsub("^%+", "")
	if code ~= "" and (not code:match("^[1-9]%d*$") or #code > 3) then
		return { error = "Invalid country calling code" }
	end
	local uci = require("luci.model.uci").cursor()
	if not modem_id or not uci:get("qmodem", modem_id) then
		return { error = "Failed to get modem configuration" }
	end
	if not uci:set("qmodem", modem_id, "sms_country_code", code) or not uci:commit("qmodem") then
		return { error = "Failed to save country calling code" }
	end
	return { country_code = code }
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
    --sim卡配置
	entry({"admin", "modem", "qmodem", "modem_sms"},template("modem_sms/modem_sms"), luci.i18n.translate("SMS"), 11).leaf = true
	entry({"admin", "modem", "qmodem", "send_sms"}, call("sendSMS"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "get_sms"}, call("getSMS"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "delete_sms"}, call("delSMS"), nil).leaf = true
	entry({"admin", "modem", "qmodem", "sms_forward"}, cbi("qmodem_sms/sms_forward"), luci.i18n.translate("SMS Forward"), 12).leaf = true
	entry({"admin", "modem", "qmodem", "sms_forward_extedit"}, cbi("qmodem_sms/sms_forward_extedit")).leaf = true
end

function getSMS()
    local cfg_id = http.formvalue("cfg")
    response = shell(modem_ctrl .. "get_sms " .. cfg_id)
    http.prepare_content("application/json")
    http.write(response)
end

function sendSMS()
	local cfg_id = http.formvalue("cfg")
	local pdu = http.formvalue("pdu")
	if pdu then
		response = shell(modem_ctrl .. "send_raw_pdu " .. cfg_id .. " \"" .. pdu .. "\"")
	else
		local phone_number = http.formvalue("phone_number")
		local message_content = http.formvalue("message_content")
		json_cmd = string.format('{\\"phone_number\\":\\"%s\\",\\"message_content\\":\\"%s\\"}', phone_number, message_content)
		response = shell(modem_ctrl .. "send_sms " .. cfg_id .." \"".. json_cmd .. "\"")
		
	end
	http.prepare_content("application/json")
		http.write(response)
end

function delSMS()
	local cfg_id = http.formvalue("cfg")
	local index = http.formvalue("index")
	response = shell(modem_ctrl .. "delete_sms " .. cfg_id .. " \"" ..index.."\"")
	http.prepare_content("application/json")
	http.write(response)
end
