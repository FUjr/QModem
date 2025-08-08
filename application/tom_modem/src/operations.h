#ifndef OPERATION_H
#define OPERATION_H
#include "modem_types.h"
#include "ttydevice.h"
#include "utils.h"
#include "ubus_client.h"

int str_to_hex(char *str, char *hex);
int tty_open_device(PROFILE_T *profile, FDS_T *fds);
int tty_read(FILE *fdi, AT_MESSAGE_T *message, PROFILE_T *profile);
int tty_read_keyword(FILE *fdi, AT_MESSAGE_T *message, char *key_word, PROFILE_T *profile);
int tty_write_raw(FILE *fdo, char *input);
int tty_write(FILE *fdo, char *input);

// UBUS wrapper functions for AT operations
int ubus_send_at_with_response(PROFILE_T *profile, const char *at_cmd, const char *end_flag, int is_raw, char **response_text);
int ubus_send_at_only(PROFILE_T *profile, const char *at_cmd, int is_raw);

#endif
