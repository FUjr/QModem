#include "operations.h"

// Helper function to send AT command via UBUS and get response
int ubus_send_at_with_response(PROFILE_T *profile, const char *at_cmd, const char *end_flag, int is_raw, char **response_text)
{
    ubus_client_t *client = get_global_ubus_client();
    if (!client || !client->connected) {
        err_msg("UBUS client not connected");
        return COMM_ERROR;
    }
    
    // Try to open the device first if not already opened
    static int device_opened = 0;
    if (!device_opened) {
        int open_result = ubus_at_open_device(client, profile->tty_dev, 
                                            profile->baud_rate, profile->data_bits, 
                                            0, 1); // parity=0 (none), stopbits=1
        if (open_result != 0) {
            dbg_msg("Failed to open device %s via ubus", profile->tty_dev);
        } else {
            dbg_msg("Opened device %s via ubus", profile->tty_dev);
            device_opened = 1;
        }
    }
    
    ubus_at_response_t response;
    int result = ubus_send_at_command(client, profile->tty_dev, at_cmd, 
                                     profile->timeout, end_flag, is_raw, &response);
    
    if (result == 0 && response_text && response.response) {
        *response_text = strdup(response.response);
    }
    dbg_msg("Response content: %s", response.response);
    dbg_msg("Response status: %d", response.status);

    if (result != 0) {
        err_msg("UBUS AT command failed with status: %d", response.status);
        if (response.response) {
            dbg_msg("Response content: %s", response.response);
        }
        ubus_at_response_free(&response);
        return COMM_ERROR;
    }
    
    ubus_at_response_free(&response);
    return SUCCESS;
}

int at(PROFILE_T *profile)
{
    char *response_text = NULL;
    
    if (profile->at_cmd == NULL)
    {
        err_msg("AT command is empty");
        return INVALID_PARAM;
    }
    
    int result = ubus_send_at_with_response(profile, profile->at_cmd, NULL, 0, &response_text);
    
    if (response_text) {
        user_msg("%s", response_text);
        free(response_text);
    }
    
    return result;
}

int binary_at(PROFILE_T *profile)
{
    char *response_text = NULL;
    
    if (profile->at_cmd == NULL)
    {
        err_msg("AT command is empty");
        return INVALID_PARAM;
    }

    if (strlen(profile->at_cmd) % 2 != 0)
    {
        err_msg("Invalid AT command length");
        return INVALID_PARAM;
    }
    
    // Send as raw hex command via UBUS
    int result = ubus_send_at_with_response(profile, profile->at_cmd, NULL, 1, &response_text);
    
    if (response_text) {
        user_msg("%s", response_text);
        free(response_text);
    }
    
    return result;
}

int sms_delete(PROFILE_T *profile)
{
    if (profile->sms_index < 0)
    {
        err_msg("SMS index is empty");
        return INVALID_PARAM;
    }
    
    char delete_sms_cmd[32];
    snprintf(delete_sms_cmd, 32, DELETE_SMS, profile->sms_index);
    
    int result = ubus_send_at_with_response(profile, delete_sms_cmd, NULL, 0, NULL);
    
    if (result != SUCCESS) {
        dbg_msg("Error deleting SMS, error code: %d", result);
    }
    
    return result;
}
int sms_read(PROFILE_T *profile)
{
    SMS_T *sms_list[SMS_LIST_SIZE];
    SMS_T *sms;
    char *response_text = NULL;
    int result;

    // Set PDU format
    result = ubus_send_at_with_response(profile, SET_PDU_FORMAT, "OK", 0, NULL);
    if (result != SUCCESS)
    {
        dbg_msg("Error setting PDU format, error code: %d", result);
        return result;
    }
    dbg_msg("Set PDU format success");

    // Read all SMS
    result = ubus_send_at_with_response(profile, READ_ALL_SMS, NULL, 0, &response_text);
    if (result != SUCCESS)
    {
        dbg_msg("Error reading SMS, error code: %d", result);
        return result;
    }

    if (response_text)
    {
        char *line = strtok(response_text, "\n");
        int sms_count = 0;

        while (line != NULL)
        {
            if (strncmp(line, "+CMGL:", 6) == 0)
            {
                sms = (SMS_T *)malloc(sizeof(SMS_T));
                memset(sms, 0, sizeof(SMS_T));
                char *pdu = strtok(NULL, "\n");
                sms->sms_pdu = (char *)malloc(strlen(pdu));
                sms->sender = (char *)malloc(PHONE_NUMBER_SIZE);
                sms->sms_text = (char *)malloc(SMS_TEXT_SIZE);
                sms->sms_index = get_sms_index(line);
                memcpy(sms->sms_pdu, pdu, strlen(pdu));
                int sms_len = decode_pdu(sms);
                if (sms_len > 0)
                {
                    sms_list[sms_count] = sms;
                    sms_count++;
                }
                else
                {
                    dbg_msg("Error decoding SMS in line: %s", line);
                    destroy_sms(sms);
                }
            }
            line = strtok(NULL, "\n");
        }

        display_sms_in_json(sms_list, sms_count);
        free(response_text);
    }

    dbg_msg("Read SMS success");
    return SUCCESS;
}
int sms_send(PROFILE_T *profile) 
{
    ubus_client_t *client = get_global_ubus_client();
    if (!client || !client->connected) {
        err_msg("UBUS client not connected");
        return COMM_ERROR;
    }

    if (profile->sms_pdu == NULL) {
        err_msg("SMS PDU is empty");
        return INVALID_PARAM;
    }

    int pdu_len = strlen(profile->sms_pdu);
    int pdu_expected_len = (pdu_len) / 2 - 1;
    char send_sms_cmd[32];
    char pdu_hex[512];
    char send_sms_cmd2[514];
    int result;
    int ascii_code;
    // Set PDU format
    result = ubus_send_at_with_response(profile, SET_PDU_FORMAT, NULL, 0, NULL);
    if (result != SUCCESS) {
        dbg_msg("Error setting PDU format, error code: %d", result);
        return result;
    }
    dbg_msg("Set PDU format success");

    snprintf(send_sms_cmd, 32, SEND_SMS, pdu_expected_len);
    for (int i = 0; i < pdu_len; i++) {
        //将字符串转换成字符串对应的十六进制的字符串
        ascii_code = profile->sms_pdu[i];
        snprintf(pdu_hex + (i * 2), 3, "%02X", ascii_code);
    }
    pdu_hex[pdu_len * 2] = '\0'; // Add the end of transmission character
    snprintf(send_sms_cmd2, 514, "%s%s", pdu_hex, "1A"); // Append Ctrl+Z to indicate end of SMS

    // Send first AT command and wait for > prompt
    ubus_send_at_only(profile, send_sms_cmd, 0);
    dbg_msg("Send SMS command: %s", send_sms_cmd);
    dbg_msg("Write PDU command: %s", send_sms_cmd2);
    usleep(10000); // 10ms delay

    // Send PDU data and wait for +CMGS response
    ubus_at_response_t response2;
    result = ubus_send_at_with_response(profile,send_sms_cmd2 , NULL, 1, &response2);
    if (result != SUCCESS) {
        dbg_msg("Error setting PDU format, error code: %d", result);
        return result;
    }
    return SUCCESS;
}

// Helper function to send AT command via UBUS without waiting for response (sendonly)
int ubus_send_at_only(PROFILE_T *profile, const char *at_cmd, int is_raw)
{
    ubus_client_t *client = get_global_ubus_client();
    if (!client || !client->connected) {
        err_msg("UBUS client not connected");
        return COMM_ERROR;
    }
    
    // Try to open the device first if not already opened
    static int device_opened = 0;
    if (!device_opened) {
        int open_result = ubus_at_open_device(client, profile->tty_dev, 
                                            profile->baud_rate, profile->data_bits, 
                                            0, 1); // parity=0 (none), stopbits=1
        if (open_result != 0) {
            dbg_msg("Failed to open device %s via ubus", profile->tty_dev);
        } else {
            dbg_msg("Opened device %s via ubus", profile->tty_dev);
            device_opened = 1;
        }
    }
    
    int result = ubus_send_at_command_only(client, profile->tty_dev, at_cmd, is_raw);
    
    if (result != 0) {
        err_msg("UBUS AT command (sendonly) failed with result: %d", result);
        return COMM_ERROR;
    }
    
    dbg_msg("AT command sent successfully (sendonly): %s", at_cmd);
    return SUCCESS;
}
