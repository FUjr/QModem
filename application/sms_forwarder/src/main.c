#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <time.h>
#include <errno.h>
#include <fcntl.h>
#include <syslog.h>
#include <json-c/json.h>
#include "sms_forwarder.h"

static volatile int g_running = 1;
static sms_forwarder_config_t g_config;

static void signal_handler(int sig) {
    switch (sig) {
        case SIGTERM:
        case SIGINT:
            syslog(LOG_INFO, "Received signal %d, shutting down", sig);
            g_running = 0;
            break;
        case SIGCHLD:
            wait(NULL);
            break;
    }
}

static void setup_signals() {
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    signal(SIGCHLD, signal_handler);
    signal(SIGPIPE, SIG_IGN);
}

static int parse_config_file(const char *config_file, sms_forwarder_config_t *config) {
    FILE *fp = fopen(config_file, "r");
    if (!fp) {
        syslog(LOG_ERR, "Cannot open config file: %s", config_file);
        return -1;
    }

    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    char *json_string = malloc(size + 1);
    if (!json_string) {
        fclose(fp);
        syslog(LOG_ERR, "Memory allocation failed");
        return -1;
    }
    
    fread(json_string, 1, size, fp);
    json_string[size] = '\0';
    fclose(fp);

    json_object *root = json_tokener_parse(json_string);
    free(json_string);

    if (!root) {
        syslog(LOG_ERR, "Invalid JSON in config file");
        return -1;
    }

    // Initialize config structure
    memset(config, 0, sizeof(sms_forwarder_config_t));
    config->poll_interval = 30; // default value

    // Parse configuration
    json_object *obj;
    const char *str_val;
    
    if (json_object_object_get_ex(root, "modem_port", &obj)) {
        str_val = json_object_get_string(obj);
        if (str_val) {
            strncpy(config->modem_port, str_val, sizeof(config->modem_port) - 1);
            config->modem_port[sizeof(config->modem_port) - 1] = '\0';
        }
    }
    
    if (json_object_object_get_ex(root, "poll_interval", &obj)) {
        config->poll_interval = json_object_get_int(obj);
    }
    
    if (json_object_object_get_ex(root, "api_type", &obj)) {
        str_val = json_object_get_string(obj);
        if (str_val) {
            strncpy(config->api_type, str_val, sizeof(config->api_type) - 1);
            config->api_type[sizeof(config->api_type) - 1] = '\0';
        }
    }
    
    if (json_object_object_get_ex(root, "api_config", &obj)) {
        str_val = json_object_get_string(obj);
        if (str_val) {
            strncpy(config->api_config, str_val, sizeof(config->api_config) - 1);
            config->api_config[sizeof(config->api_config) - 1] = '\0';
        }
    }

    json_object_put(root);
    return 0;
}

static int check_dependencies() {
    // Check if curl is available
    if (system("which curl > /dev/null 2>&1") == 0) {
        return USE_CURL;
    }
    
    // Check if wget is available
    if (system("which wget > /dev/null 2>&1") == 0) {
        return USE_WGET;
    }
    
    syslog(LOG_WARNING, "Neither curl nor wget found, only custom scripts will work");
    return USE_NONE;
}

static char* read_sms_from_modem(const char *modem_port) {
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "tom_modem -d %s -u -o u 2>/dev/null", modem_port);
    
    FILE *fp = popen(cmd, "r");
    if (!fp) {
        syslog(LOG_ERR, "Failed to execute tom_modem command");
        return NULL;
    }
    
    char *result = malloc(SMS_BUFFER_SIZE);
    if (!result) {
        pclose(fp);
        syslog(LOG_ERR, "Memory allocation failed");
        return NULL;
    }
    
    size_t total_read = 0;
    size_t bytes_read;
    
    while ((bytes_read = fread(result + total_read, 1, SMS_BUFFER_SIZE - total_read - 1, fp)) > 0) {
        total_read += bytes_read;
        if (total_read >= SMS_BUFFER_SIZE - 1) {
            break;
        }
    }
    
    result[total_read] = '\0';
    pclose(fp);
    
    if (total_read == 0) {
        free(result);
        return NULL;
    }
    
    return result;
}

static sms_message_t* parse_sms_json(const char *json_str, int *count) {
    json_object *root = json_tokener_parse(json_str);
    if (!root) {
        syslog(LOG_ERR, "Failed to parse SMS JSON");
        return NULL;
    }
    
    json_object *msg_array;
    if (!json_object_object_get_ex(root, "msg", &msg_array)) {
        json_object_put(root);
        return NULL;
    }
    
    int array_len = json_object_array_length(msg_array);
    if (array_len == 0) {
        json_object_put(root);
        *count = 0;
        return NULL;
    }
    
    sms_message_t *messages = malloc(array_len * sizeof(sms_message_t));
    if (!messages) {
        json_object_put(root);
        syslog(LOG_ERR, "Memory allocation failed for messages");
        *count = 0;
        return NULL;
    }
    *count = array_len;
    
    for (int i = 0; i < array_len; i++) {
        json_object *msg_obj = json_object_array_get_idx(msg_array, i);
        json_object *field;
        const char *str_val;
        
        memset(&messages[i], 0, sizeof(sms_message_t));
        
        if (json_object_object_get_ex(msg_obj, "index", &field)) {
            messages[i].index = json_object_get_int(field);
        }
        
        if (json_object_object_get_ex(msg_obj, "sender", &field)) {
            str_val = json_object_get_string(field);
            if (str_val) {
                strncpy(messages[i].sender, str_val, sizeof(messages[i].sender) - 1);
                messages[i].sender[sizeof(messages[i].sender) - 1] = '\0';
            }
        }
        
        if (json_object_object_get_ex(msg_obj, "timestamp", &field)) {
            messages[i].timestamp = json_object_get_int64(field);
        }
        
        if (json_object_object_get_ex(msg_obj, "content", &field)) {
            str_val = json_object_get_string(field);
            if (str_val) {
                strncpy(messages[i].content, str_val, sizeof(messages[i].content) - 1);
                messages[i].content[sizeof(messages[i].content) - 1] = '\0';
            }
        }
        
        if (json_object_object_get_ex(msg_obj, "reference", &field)) {
            messages[i].reference = json_object_get_int(field);
        }
        
        if (json_object_object_get_ex(msg_obj, "total", &field)) {
            messages[i].total = json_object_get_int(field);
        }
        
        if (json_object_object_get_ex(msg_obj, "part", &field)) {
            messages[i].part = json_object_get_int(field);
        }
    }
    
    json_object_put(root);
    return messages;
}

static char* merge_multipart_sms(sms_message_t *messages, int count) {
    // Group messages by reference number and sender
    for (int i = 0; i < count; i++) {
        if (messages[i].total <= 1) {
            // Single part message, process immediately
            char *result = malloc(strlen(messages[i].content) + 1);
            strcpy(result, messages[i].content);
            return result;
        }
    }
    
    // Find complete multipart messages
    for (int i = 0; i < count; i++) {
        if (messages[i].total > 1) {
            int ref = messages[i].reference;
            char *sender = messages[i].sender;
            int total_parts = messages[i].total;
            
            // Collect all parts
            sms_message_t *parts = malloc(total_parts * sizeof(sms_message_t));
            int found_parts = 0;
            
            for (int j = 0; j < count; j++) {
                if (messages[j].reference == ref && 
                    strcmp(messages[j].sender, sender) == 0) {
                    parts[found_parts++] = messages[j];
                }
            }
            
            if (found_parts == total_parts) {
                // Sort parts by part number
                for (int x = 0; x < found_parts - 1; x++) {
                    for (int y = x + 1; y < found_parts; y++) {
                        if (parts[x].part > parts[y].part) {
                            sms_message_t temp = parts[x];
                            parts[x] = parts[y];
                            parts[y] = temp;
                        }
                    }
                }
                
                // Concatenate content
                int total_len = 0;
                for (int k = 0; k < found_parts; k++) {
                    total_len += strlen(parts[k].content);
                }
                
                char *merged = malloc(total_len + 1);
                merged[0] = '\0';
                
                for (int k = 0; k < found_parts; k++) {
                    strcat(merged, parts[k].content);
                }
                
                free(parts);
                return merged;
            }
            
            free(parts);
        }
    }
    
    return NULL;
}

static int execute_callback(const char *api_type, const char *api_config, 
                           const char *sender, time_t timestamp, const char *content) {
    
    char time_str[32];
    struct tm *tm_info = localtime(&timestamp);
    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", tm_info);
    
    // Set environment variables
    setenv("SMS_SENDER", sender, 1);
    setenv("SMS_TIME", time_str, 1);
    setenv("SMS_CONTENT", content, 1);
    
    char script_path[256];
    char cmd[512];
    
    if (strcmp(api_type, "custom_script") == 0) {
        json_object *config_obj = json_tokener_parse(api_config);
        if (!config_obj) {
            syslog(LOG_ERR, "Invalid API config JSON");
            return -1;
        }
        
        json_object *script_obj;
        if (json_object_object_get_ex(config_obj, "script_path", &script_obj)) {
            strncpy(script_path, json_object_get_string(script_obj), sizeof(script_path) - 1);
        }
        json_object_put(config_obj);
        
        snprintf(cmd, sizeof(cmd), "%s", script_path);
    } else {
        snprintf(script_path, sizeof(script_path), "/usr/bin/sms_forward_%s.sh", api_type);
        snprintf(cmd, sizeof(cmd), "%s '%s'", script_path, api_config);
    }
    
    // Execute script
    int ret = system(cmd);
    if (ret != 0) {
        syslog(LOG_ERR, "Failed to execute callback script: %s", script_path);
        return -1;
    }
    
    syslog(LOG_INFO, "SMS forwarded successfully via %s", api_type);
    return 0;
}

static void process_sms_messages(sms_forwarder_config_t *config) {
    char *sms_json = read_sms_from_modem(config->modem_port);
    if (!sms_json) {
        return;
    }
    
    int count;
    sms_message_t *messages = parse_sms_json(sms_json, &count);
    free(sms_json);
    
    if (!messages || count == 0) {
        return;
    }
    
    char *merged_content = merge_multipart_sms(messages, count);
    if (merged_content) {
        // Use first message for sender and timestamp
        execute_callback(config->api_type, config->api_config,
                        messages[0].sender, messages[0].timestamp, merged_content);
        free(merged_content);
    }
    
    free(messages);
}

int main(int argc, char *argv[]) {
    printf("SMS Forwarder starting...\n");
    fflush(stdout);
    
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <config_file>\n", argv[0]);
        return 1;
    }
    
    printf("Opening syslog...\n");
    fflush(stdout);
    openlog("sms_forwarder", LOG_PID, LOG_DAEMON);
    
    printf("Parsing config file: %s\n", argv[1]);
    fflush(stdout);
    
    // Parse configuration
    if (parse_config_file(argv[1], &g_config) < 0) {
        syslog(LOG_ERR, "Failed to parse config file: %s", argv[1]);
        printf("Failed to parse config file\n");
        return 1;
    }
    
    printf("Config parsed successfully\n");
    printf("Modem port: %s\n", g_config.modem_port);
    printf("Poll interval: %d\n", g_config.poll_interval);
    printf("API type: %s\n", g_config.api_type);
    fflush(stdout);
    
    // Check dependencies
    printf("Checking dependencies...\n");
    fflush(stdout);
    check_dependencies();
    
    // Setup signal handlers
    printf("Setting up signal handlers...\n");
    fflush(stdout);
    setup_signals();
    
    syslog(LOG_INFO, "SMS Forwarder started with config: %s", argv[1]);
    printf("Entering main loop...\n");
    fflush(stdout);
    
    // Main loop
    while (g_running) {
        printf("Processing SMS messages...\n");
        fflush(stdout);
        process_sms_messages(&g_config);
        printf("Sleeping for %d seconds...\n", g_config.poll_interval);
        fflush(stdout);
        sleep(g_config.poll_interval);
    }
    
    syslog(LOG_INFO, "SMS Forwarder stopped");
    closelog();
    return 0;
}
