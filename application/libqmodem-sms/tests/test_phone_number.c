#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <qmodem-sms/pdu.h>

static void check(const char *input, const char *code, const char *expected,
                  const unsigned char *address, size_t address_length)
{
    char resolved[22];
    unsigned char pdu[SMS_MAX_PDU_LENGTH];
    unsigned char parts[SMS_MAX_PARTS][SMS_MAX_PDU_LENGTH];
    int lengths[SMS_MAX_PARTS];
    assert(sms_resolve_number(input, code, resolved, sizeof(resolved)) == 0);
    assert(!strcmp(resolved, expected));
    assert(pdu_encode(NULL, resolved, "hello", pdu, sizeof(pdu)) > 0);
    assert(!memcmp(pdu + 3, address, address_length));
    assert(pdu_encode_ucs2_parts(resolved, "hello", parts, lengths, SMS_MAX_PARTS, 1) == 1);
    assert(!memcmp(parts[0] + 3, address, address_length));
}

int main(void)
{
    char output[22];
    static const unsigned char us[] = {11, 0x91, 0x21, 0x20, 0x55, 0x05, 0x21, 0xf3};
    static const unsigned char uk[] = {12, 0x91, 0x44, 0x97, 0x11, 0x21, 0x43, 0x65};
    static const unsigned char cn[] = {13, 0x91, 0x68, 0x31, 0x08, 0x10, 0x83, 0x00, 0xf0};
    static const unsigned char local[] = {10, 0x81, 0x02, 0x52, 0x55, 0x10, 0x32};
    static const unsigned char service[] = {5, 0x81, 0x21, 0x43, 0xf5};
    check("(202) 555-0123", "1", "+12025550123", us, sizeof(us));
    check("+1 (202) 555-0123", "44", "+12025550123", us, sizeof(us));
    check("7911123456", "+44", "+447911123456", uk, sizeof(uk));
    check("13800138000", "86", "+8613800138000", cn, sizeof(cn));
    check("2025550123", "", "2025550123", local, sizeof(local));
    check("12345", NULL, "12345", service, sizeof(service));
    /* Neither an international access prefix nor a trunk prefix is guessed. */
    assert(sms_resolve_number("0201234567", "44", output, sizeof(output)) == 0);
    assert(!strcmp(output, "+440201234567"));
    assert(sms_resolve_number("0012025550123", "", output, sizeof(output)) == 0);
    assert(!strcmp(output, "0012025550123"));
    const char *invalid[] = {"", "+", "++123", "+0123", "12+34", "12x34", "１２３", "123\n", "+1234567890123456", "123456789012345678901"};
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        assert(sms_resolve_number(invalid[i], "", output, sizeof(output)) < 0);
        assert(pdu_encode(NULL, invalid[i], "hello", (unsigned char[256]){0}, 256) < 0);
    }
    const char *bad_codes[] = {"+", "0", "01", "1234", "+1234", "x", "1;id"};
    for (size_t i = 0; i < sizeof(bad_codes) / sizeof(bad_codes[0]); i++)
        assert(sms_resolve_number("2025550123", bad_codes[i], output, sizeof(output)) < 0);
    assert(sms_resolve_number("123456789012345", "1", output, sizeof(output)) < 0);
    assert(sms_normalize_number("+123456789012345", output, 16) < 0);
    assert(sms_normalize_number("+123456789012345", output, 17) == 0);
    puts("PASS optional country codes, explicit international TOA, local/service TOA, BCD and invalid addresses");
    return 0;
}
