module("luci.controller.qmodem_sms", package.seeall)
local http = require "luci.http"
local fs = require "nixio.fs"
local json = require("luci.jsonc")
local util = require "luci.util"
local modem_ctrl = "/usr/share/qmodem/modem_ctrl.sh "

function shell(command)
	local odpall = io.popen(command)
	local odp = odpall:read("*a")
	odpall:close()
	return odp
end

local function valid_token(value)
	return value and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

local function valid_index(value)
	return value and value:match("^[0-9 ]+$") ~= nil
end

local function valid_pdu(value)
	return value and value:match("^[A-Fa-f0-9]+$") ~= nil
end

local function write_error(message)
	http.prepare_content("application/json")
	http.write(json.stringify({ status = "0", error = message }))
end

function index()
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
	if not valid_token(cfg_id) then
		return write_error("Invalid config section")
	end

    response = shell(modem_ctrl .. "get_sms " .. util.shellquote(cfg_id))
    http.prepare_content("application/json")
    http.write(response)
end

function sendSMS()
	local cfg_id = http.formvalue("cfg")
	if not valid_token(cfg_id) then
		return write_error("Invalid config section")
	end

	local pdu = http.formvalue("pdu")
	if pdu then
		if not valid_pdu(pdu) then
			return write_error("Invalid PDU")
		end
		response = shell(modem_ctrl .. "send_raw_pdu " .. util.shellquote(cfg_id) .. " " .. util.shellquote(pdu))
	else
		local phone_number = http.formvalue("phone_number") or ""
		local message_content = http.formvalue("message_content") or ""
		local json_cmd = json.stringify({
			phone_number = phone_number,
			message_content = message_content
		})
		response = shell(modem_ctrl .. "send_sms " .. util.shellquote(cfg_id) .. " " .. util.shellquote(json_cmd))
		
	end
	http.prepare_content("application/json")
	http.write(response)
end

function delSMS()
	local cfg_id = http.formvalue("cfg")
	local index = http.formvalue("index")
	if not valid_token(cfg_id) then
		return write_error("Invalid config section")
	end
	if not valid_index(index) then
		return write_error("Invalid SMS index")
	end

	response = shell(modem_ctrl .. "delete_sms " .. util.shellquote(cfg_id) .. " " .. util.shellquote(index))
	http.prepare_content("application/json")
	http.write(response)
end
