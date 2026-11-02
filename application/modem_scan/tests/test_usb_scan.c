/* Exercise real USB enumeration against a temporary sysfs tree. */
#define main scanner_main
#include "../src/modem_scand.c"
#undef main
#include <assert.h>

static void check(const char *rule, size_t ports, int pcm)
{
    struct scan_result res = {0};
    char json[512];
    snprintf(json, sizeof(json), "{\"modem_port_rule\":{\"usb\":{\"2dee:4d23\":%s}}}", rule);
    g.port_rule_json = json_tokener_parse(json);
    assert(g.port_rule_json);
    scan_usb_slot("4-1", &res);
    assert(res.at_ports.len == ports);
    assert(sl_contains(&res.at_ports, "/dev/ttyUSB1"));
    assert(res.net_devices.len == 1);
    assert(sl_contains(&res.net_devices, "usb0"));
    if (pcm) {
        assert(!strcmp(res.voice_pcm_port, "/dev/ttyUSB4"));
        assert(!sl_contains(&res.at_ports, "/dev/ttyUSB4"));
    } else {
        assert(!res.voice_pcm_port[0]);
    }
    sl_free(&res.at_ports);
    sl_free(&res.net_devices);
    json_object_put(g.port_rule_json);
}

int main(void)
{
    g.log_level = LOG_L_ERR;
    check("{\"include\":[\"1.1\"]}", 1, 0);
    check("{\"include\":[\"1.1\"],\"voice_pcm_interface\":\"1.4\"}", 1, 1);
    check("{\"include\":[],\"voice_pcm_interface\":\"1.4\"}", 2, 1);
    check("{}", 3, 0);
    check("null", 3, 0);
    puts("PASS: USB AT include filtering, independent network discovery, PCM separation and unrestricted rules");
    return 0;
}
