/* Link with -ffunction-sections -Wl,--gc-sections -lpthread. */
#include "../src/QMIThread.c"
#include <assert.h>

static unsigned char *tlv(PQMUX_MSG msg, unsigned short length, unsigned char type)
{
    unsigned char *p = (unsigned char *)(&msg->QMUXMsgHdr + 1);
    unsigned char *end = (unsigned char *)&msg->QMUXMsgHdr + length;
    while (p + 3 <= end) {
        unsigned size = p[1] | ((unsigned)p[2] << 8);
        assert(p + 3 + size <= end);
        if (p[0] == type) return p;
        p += 3 + size;
    }
    assert(p == end);
    return NULL;
}

static uint32_t value(unsigned char *p)
{
    uint32_t v;
    assert(p && p[1] == 4 && p[2] == 0);
    memcpy(&v, p + 3, sizeof(v));
    return le32_to_cpu(v);
}

int main(void)
{
    QMUX_MSG msg = {0};
    QMAP_SETTING settings = {0};
    settings.ep_type = DATA_EP_TYPE_PCIE;
    settings.iface_id = 4;
    unsigned short n = WdaSetDataFormat(&msg, &settings);
    unsigned char *p = tlv(&msg, n, 0x10);
    assert(p && p[1] == 1 && p[3] == 0); /* no QoS header */
    assert(value(tlv(&msg, n, 0x11)) == 2); /* raw IP */
    assert(value(tlv(&msg, n, 0x12)) == 0); /* no uplink aggregation */
    assert(value(tlv(&msg, n, 0x13)) == 0); /* no downlink aggregation */
    p = tlv(&msg, n, 0x17);
    assert(p && p[1] == 8 && p[3] == DATA_EP_TYPE_PCIE && p[7] == 4);
    memset(&msg, 0, sizeof(msg));
    n = WdsBindMhiEndpoint(&msg, &settings);
    p = tlv(&msg, n, 0x10);
    assert(p && p[1] == 8 && p[3] == DATA_EP_TYPE_PCIE && p[7] == 4);
    assert(!tlv(&msg, n, 0x11)); /* no QMAP mux id */
    assert(value(tlv(&msg, n, 0x13)) == 1); /* tethered client */
    puts("PASS: MHI raw-IP/no-QoS/no-aggregation WDA and unmuxed WDS binding");
    return 0;
}
