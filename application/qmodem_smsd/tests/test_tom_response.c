#include "tom_response.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void test_modem_storage(void)
{
    char storage[8];
    struct json_object *messages;
    assert(tom_sms_storage("\r\n+CPMS: \"SM\",1,30,\"ME\",2,100\r\nOK\r\n", storage, sizeof(storage)) == 0);
    assert(!strcmp(storage, "SM"));
    assert(tom_sms_storage("+CPMS: \"ME\" , 0 , 100", storage, sizeof(storage)) == 0);
    assert(!strcmp(storage, "ME"));
    assert(tom_sms_storage("+CPMS: \"MT\",0,100", storage, sizeof(storage)) == 0);
    assert(tom_sms_storage("+CPMS: 0,100", storage, sizeof(storage)) != 0);
    assert(tom_sms_storage("ERROR", storage, sizeof(storage)) != 0);
    assert(tom_sms_storage(NULL, storage, sizeof(storage)) != 0);
    assert(tom_sms_storage("+CPMS: \"SM\",0,10", storage, 2) != 0);

    messages = tom_sms_messages("{\"msg\":[{\"index\":0,\"pdu\":\"00AB\"},{\"index\":7,\"pdu\":\"0102\"}]}");
    assert(messages && json_object_array_length(messages) == 2);
    assert(tom_sms_match(messages, 0, "00ab") == 1);
    assert(tom_sms_match(messages, 0, "0000") == -1);
    assert(tom_sms_match(messages, 6, "00AB") == 0);
    json_object_put(messages);
    messages = tom_sms_messages("{\"received\":[]}");
    assert(messages && json_object_array_length(messages) == 0);
    json_object_put(messages);
    const char *invalid[] = {
        "{}", "not json", "{\"messages\":[{\"id\":1}]}",
        "{\"msg\":[null]}", "{\"msg\":[{\"index\":0}]}",
        "{\"msg\":[{\"index\":-1,\"pdu\":\"00\"}]}",
        "{\"msg\":[{\"index\":4294967296,\"pdu\":\"00\"}]}",
        "{\"msg\":[{\"index\":\"0\",\"pdu\":\"00\"}]}",
        "{\"msg\":[{\"index\":0,\"pdu\":\"xyz\"}]}"
    };
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++)
        assert(!tom_sms_messages(invalid[i]));
    assert(!tom_sms_valid_pdu(NULL));
    assert(!tom_sms_valid_pdu(""));
    assert(!tom_sms_valid_pdu("0"));
}

int main(void)
{
    test_modem_storage();
    assert(tom_sms_send_succeeded("{\"status\":\"success\"}"));
    assert(!tom_sms_send_succeeded("{\"status\":\"failed\",\"reason\":\"comm_error\"}"));
    assert(!tom_sms_send_succeeded("{\"status\":\"failed\",\"reason\":\"send_sms_failed\"}"));
    assert(!tom_sms_send_succeeded("not json"));
    assert(!tom_sms_send_succeeded(""));
    assert(!tom_sms_send_succeeded(NULL));
    puts("PASS: tom_modem SMS response status validation");
    return 0;
}
