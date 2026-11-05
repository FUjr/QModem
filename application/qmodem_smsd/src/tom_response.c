#include "tom_response.h"

#include <json-c/json.h>
#include <ctype.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

int tom_sms_send_succeeded(const char *output)
{
    struct json_object *root = NULL;
    struct json_object *status = NULL;
    int succeeded = 0;

    if (!output || !*output)
        return 0;
    root = json_tokener_parse(output);
    if (root && json_object_is_type(root, json_type_object) &&
        json_object_object_get_ex(root, "status", &status) &&
        json_object_is_type(status, json_type_string) &&
        !strcmp(json_object_get_string(status), "success"))
        succeeded = 1;
    if (root)
        json_object_put(root);
    return succeeded;
}

int tom_sms_storage(const char *output, char *storage, size_t size)
{
    const char *cpms = output ? strstr(output, "+CPMS:") : NULL;
    char name[8];
    unsigned int used, total;

    if (!cpms || sscanf(cpms, "+CPMS: \"%7[A-Z]\" , %u , %u", name, &used, &total) != 3 ||
        strlen(name) >= size)
        return -1;
    snprintf(storage, size, "%s", name);
    return 0;
}

int tom_sms_valid_pdu(const char *pdu)
{
    size_t length = pdu ? strlen(pdu) : 0;
    if (!length || length > 4096 || (length & 1))
        return 0;
    for (size_t i = 0; i < length; i++)
        if (!isxdigit((unsigned char)pdu[i]))
            return 0;
    return 1;
}

struct json_object *tom_sms_messages(const char *output)
{
    struct json_object *root = output ? json_tokener_parse(output) : NULL;
    struct json_object *messages = NULL;

    if (!root || !json_object_is_type(root, json_type_object) ||
        (!json_object_object_get_ex(root, "msg", &messages) &&
         !json_object_object_get_ex(root, "received", &messages)) ||
        !json_object_is_type(messages, json_type_array))
        goto invalid;
    for (size_t i = 0; i < json_object_array_length(messages); i++) {
        struct json_object *entry = json_object_array_get_idx(messages, i);
        struct json_object *index, *pdu;
        if (!json_object_is_type(entry, json_type_object) ||
            !json_object_object_get_ex(entry, "index", &index) ||
            !json_object_is_type(index, json_type_int) ||
            json_object_get_int64(index) < 0 || json_object_get_int64(index) > INT_MAX ||
            !json_object_object_get_ex(entry, "pdu", &pdu) ||
            !json_object_is_type(pdu, json_type_string) ||
            !tom_sms_valid_pdu(json_object_get_string(pdu)))
            goto invalid;
    }
    json_object_get(messages);
    json_object_put(root);
    return messages;
invalid:
    if (root)
        json_object_put(root);
    return NULL;
}

int tom_sms_match(struct json_object *messages, int index, const char *pdu)
{
    for (size_t i = 0; i < json_object_array_length(messages); i++) {
        struct json_object *entry = json_object_array_get_idx(messages, i);
        struct json_object *value;
        json_object_object_get_ex(entry, "index", &value);
        if (json_object_get_int(value) != index)
            continue;
        json_object_object_get_ex(entry, "pdu", &value);
        return !strcasecmp(json_object_get_string(value), pdu) ? 1 : -1;
    }
    return 0;
}
