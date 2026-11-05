#ifndef QMODEM_SMSD_TOM_RESPONSE_H
#define QMODEM_SMSD_TOM_RESPONSE_H

#include <stddef.h>
#include <json-c/json.h>

int tom_sms_send_succeeded(const char *output);
int tom_sms_storage(const char *output, char *storage, size_t size);
int tom_sms_valid_pdu(const char *pdu);
/* Caller owns the returned array; NULL means an invalid/incomplete response. */
struct json_object *tom_sms_messages(const char *output);
/* 1: same message, 0: already absent, -1: index now holds another message. */
int tom_sms_match(struct json_object *messages, int index, const char *pdu);

#endif
