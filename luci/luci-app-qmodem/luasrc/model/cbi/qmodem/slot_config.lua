local fs = require "nixio.fs"

local function safe_dir(path)
    return fs.dir(path) or function() return nil end
end

m = Map("qmodem", translate("Slot Configuration"))
m.redirect = luci.dispatcher.build_url("admin", "modem", "qmodem","settings")

s = m:section(NamedSection, arg[1], "modem-slot", "")

slot_type = s:option(ListValue, "type", translate("Slot Type"))
slot_type:value("usb", translate("USB"))
slot_type:value("pcie", translate("PCIE"))

slot = s:option(Value, "slot", translate("Slot ID"))


for line in safe_dir("/sys/bus/pci/devices/") do
    slot:value(line,line.."[pcie]")
end



sim_led = s:option(Value, "sim_led", translate("SIM LED"))
sim_led.rmempty = true


net_led = s:option(Value, "net_led", translate("NET LED"))
net_led.rmempty = true
for line in safe_dir("/sys/class/leds/") do
    net_led:value(line,line)
    sim_led:value(line,line)
end

ethernet_5g = s:option(Value, "ethernet_5g", translate("Enable 5G Ethernet"))
ethernet_5g.rmempty = true
ethernet_5g.description = translate("For 5G modules using the Ethernet PHY connection, please specify the network interface name. (e.g., eth0, eth1)") 
for line in safe_dir("/sys/class/net/") do
    ethernet_5g:value(line,line)
end

bridge_port = s:option(Value, "bridge_port", translate("Bridge Port"))
bridge_port.rmempty = true
bridge_port.description = translate("Default bridge port for passthrough. Device-level bridge_port overrides this slot default.")
for line in safe_dir("/sys/class/net/") do
    bridge_port:value(line, line)
end

default_alias = s:option(Value, "alias", translate("Default Alias"))
default_alias.description = translate("After setting this option, the first module loaded into this slot will automatically be assigned this default alias.")



associated_usb = s:option(Value, "associated_usb", translate("Associated USB"))
associated_usb.rmempty = true
associated_usb.description = translate("For M.2 slots with both PCIe and USB support, specify the associated USB port (for ttyUSB access)")
associated_usb:depends("type", "pcie")
for line in safe_dir("/sys/bus/usb/devices/") do
    if not line:match("usb%d+") then
        slot:value(line,line.."[usb]")
        associated_usb:value(line,line)
    end
    
end

default_metric = s:option(Value, "default_metric", translate("Default Metric"))
default_metric.rmempty = true
default_metric.description = translate("The first module loaded into this slot will automatically be assigned this default metric.")
default_metric.datatype = "range(1, 255)"

pwr_gpio = s:option(Value, "gpio", translate("Power GPIO"))
pwr_gpio.rmempty = true

gpio_down = s:option(Value,"gpio_down",translate("GPIO Down Value"))


gpio_up = s:option(Value,"gpio_up",translate("GPIO Up Value"))
return m
