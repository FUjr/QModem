#include "sms_db.h"
#include "legacy_migrate.h"
#include "tom_response.h"

#include <errno.h>
#include <fcntl.h>
#include <json-c/json.h>
#include <libubox/blobmsg_json.h>
#include <libubox/uloop.h>
#include <libubus.h>
#include <qmodem-sms/pdu.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <poll.h>
#include <time.h>
#include <uci.h>
#include <unistd.h>

#define DEFAULT_DB "/etc/qmodem/sms.sqlite3"
#define TOM_MODEM "/usr/bin/tom_modem"
#define QMODEM_SETTINGS "/usr/sbin/qmodem-settings"
#define SCHEDULER_TICK_MS 30000

struct modem_config {
    char section[64];
    char at_port[128];
    char mode[32];
    char storage[8];
    char legacy_dir[256];
    char country_code[8];
    int use_ubus;
    int auto_delete;
    int forwarding;
    int poll_interval;
};

struct app_context {
    struct ubus_context *ubus;
    struct ubus_object object;
    struct ubus_event_handler urc_handler;
    struct ubus_event_handler control_handler;
    sms_db_t db;
    char db_path[256];
    char last_sync_section[64];
    char last_sync_error[160];
    int64_t last_sync_at;
    int last_sync_imported;
    int multipart_wait;
    int late_fragment_window;
    int received_retention;
    int sent_retention;
    struct uloop_timeout scheduler;
};

static struct app_context app;
static int forwarder_enabled_for(const char *section_name);

static int64_t monotonic_ms(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return 0;
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

enum {
    ARG_MODEM,
    ARG_MODE,
    ARG_POLL_INTERVAL,
    ARG_FORWARDING,
    ARG_AUTO_DELETE,
    ARG_LIMIT,
    ARG_OFFSET,
    ARG_ID,
    ARG_RECIPIENT,
    ARG_CONTENT,
    ARG_INDEX,
    ARG_MEM1,
    ARG_MEM2,
    ARG_MEM3,
    ARG_DELIVERY_ID,
    ARG_SUCCESS,
    ARG_ERROR,
    ARG_REQUEST_ID,
    ARG_CONVERSATION_CONTACT,
    ARG_COUNTRY_CODE,
    __ARG_MAX
};

static const struct blobmsg_policy policy[] = {
    [ARG_MODEM] = { .name = "modem_id", .type = BLOBMSG_TYPE_STRING },
    [ARG_MODE] = { .name = "mode", .type = BLOBMSG_TYPE_STRING },
    [ARG_POLL_INTERVAL] = { .name = "poll_interval", .type = BLOBMSG_TYPE_INT32 },
    [ARG_FORWARDING] = { .name = "forwarding", .type = BLOBMSG_TYPE_BOOL },
    [ARG_AUTO_DELETE] = { .name = "auto_delete", .type = BLOBMSG_TYPE_BOOL },
    [ARG_LIMIT] = { .name = "limit", .type = BLOBMSG_TYPE_INT32 },
    [ARG_OFFSET] = { .name = "offset", .type = BLOBMSG_TYPE_INT32 },
    [ARG_ID] = { .name = "id", .type = BLOBMSG_TYPE_UNSPEC },
    [ARG_RECIPIENT] = { .name = "recipient", .type = BLOBMSG_TYPE_STRING },
    [ARG_CONTENT] = { .name = "content", .type = BLOBMSG_TYPE_STRING },
    [ARG_INDEX] = { .name = "index", .type = BLOBMSG_TYPE_INT32 },
    [ARG_MEM1] = { .name = "mem1", .type = BLOBMSG_TYPE_STRING },
    [ARG_MEM2] = { .name = "mem2", .type = BLOBMSG_TYPE_STRING },
    [ARG_MEM3] = { .name = "mem3", .type = BLOBMSG_TYPE_STRING },
    [ARG_DELIVERY_ID] = { .name = "delivery_id", .type = BLOBMSG_TYPE_UNSPEC },
    [ARG_SUCCESS] = { .name = "success", .type = BLOBMSG_TYPE_BOOL },
    [ARG_ERROR] = { .name = "error", .type = BLOBMSG_TYPE_STRING },
    [ARG_REQUEST_ID] = { .name = "request_id", .type = BLOBMSG_TYPE_STRING },
    [ARG_CONVERSATION_CONTACT] = { .name = "conversation_contact", .type = BLOBMSG_TYPE_STRING },
    [ARG_COUNTRY_CODE] = { .name = "country_code", .type = BLOBMSG_TYPE_STRING },
};

static int valid_id(const char *value)
{
    if (!value || !*value || strlen(value) >= 64)
        return 0;
    for (; *value; value++)
        if (!((*value >= 'a' && *value <= 'z') || (*value >= 'A' && *value <= 'Z') ||
              (*value >= '0' && *value <= '9') || *value == '_' || *value == '-'))
            return 0;
    return 1;
}

static int blobmsg_get_positive_i64(struct blob_attr *attr, int64_t *value)
{
    uint64_t parsed;

    if (!attr || !value)
        return -1;
    switch (blobmsg_type(attr)) {
    case BLOBMSG_TYPE_INT8:
        parsed = blobmsg_get_u8(attr);
        break;
    case BLOBMSG_TYPE_INT16:
        parsed = blobmsg_get_u16(attr);
        break;
    case BLOBMSG_TYPE_INT32:
        parsed = blobmsg_get_u32(attr);
        break;
    case BLOBMSG_TYPE_INT64:
        parsed = blobmsg_get_u64(attr);
        break;
    default:
        return -1;
    }
    if (!parsed || parsed > INT64_MAX)
        return -1;
    *value = (int64_t)parsed;
    return 0;
}

static const char *option_string(struct uci_context *uci, struct uci_section *section,
                                 const char *name, const char *fallback)
{
    const char *value = uci_lookup_option_string(uci, section, name);
    return value && *value ? value : fallback;
}

static void load_service_config(char *db_path, size_t db_path_len, int load_database)
{
    struct uci_context *uci = uci_alloc_context();
    struct uci_package *package = NULL;
    struct uci_section *section;
    const char *value;

    app.multipart_wait = 300;
    app.late_fragment_window = 3600;
    app.received_retention = 5000;
    app.sent_retention = 1000;
    if (!uci || uci_load(uci, "qmodem_sms", &package) != UCI_OK)
        goto out;
    section = uci_lookup_section(uci, package, "main");
    if (!section)
        goto out;
    if (load_database)
        snprintf(db_path, db_path_len, "%s",
                 option_string(uci, section, "database", DEFAULT_DB));
    value = option_string(uci, section, "multipart_wait", "300");
    app.multipart_wait = atoi(value);
    if (app.multipart_wait < 1 || app.multipart_wait > 3600)
        app.multipart_wait = 300;
    value = option_string(uci, section, "late_fragment_window", "3600");
    app.late_fragment_window = atoi(value);
    if (app.late_fragment_window < 1 || app.late_fragment_window > 86400)
        app.late_fragment_window = 3600;
    value = option_string(uci, section, "received_retention", "5000");
    app.received_retention = atoi(value);
    if (app.received_retention < 1)
        app.received_retention = 5000;
    value = option_string(uci, section, "sent_retention", "1000");
    app.sent_retention = atoi(value);
    if (app.sent_retention < 1)
        app.sent_retention = 1000;
out:
    if (package)
        uci_unload(uci, package);
    if (uci)
        uci_free_context(uci);
}

static int load_config(const char *section_name, struct modem_config *cfg)
{
    struct uci_context *uci = uci_alloc_context();
    struct uci_package *package = NULL;
    struct uci_section *section;
    const char *value;

    if (!uci || !valid_id(section_name) ||
        uci_load(uci, "qmodem", &package) != UCI_OK)
        goto fail;
    section = uci_lookup_section(uci, package, section_name);
    if (!section)
        goto fail;
    memset(cfg, 0, sizeof(*cfg));
    snprintf(cfg->section, sizeof(cfg->section), "%s", section_name);
    snprintf(cfg->at_port, sizeof(cfg->at_port), "%s",
             option_string(uci, section, "override_at_port",
             option_string(uci, section, "sms_at_port",
             option_string(uci, section, "at_port", ""))));
    cfg->use_ubus = !strcmp(option_string(uci, section, "use_ubus", "1"), "1");
    snprintf(cfg->mode, sizeof(cfg->mode), "%s",
             option_string(uci, section, "sms_mode",
                           cfg->use_ubus ? "database_poll" : "direct"));
    snprintf(cfg->storage, sizeof(cfg->storage), "%s",
             option_string(uci, section, "sms_storage_mem1", "SM"));
    snprintf(cfg->legacy_dir, sizeof(cfg->legacy_dir), "%s",
             option_string(uci, section, "sms_db_path", "/etc/qmodem"));
    snprintf(cfg->country_code, sizeof(cfg->country_code), "%s",
             option_string(uci, section, "sms_country_code", ""));
    cfg->auto_delete = strcmp(option_string(uci, section,
                              "sms_auto_delete_from_sim", "1"), "0") != 0;
    cfg->forwarding = !strcmp(option_string(uci, section, "sms_forwarding", "0"), "1");
    value = option_string(uci, section, "sms_poll_interval", "300");
    cfg->poll_interval = atoi(value);
    if (cfg->poll_interval < 60 || cfg->poll_interval > 3600)
        cfg->poll_interval = 300;
    uci_unload(uci, package);
    uci_free_context(uci);
    cfg->forwarding = cfg->forwarding || forwarder_enabled_for(section_name);
    return cfg->at_port[0] ? 0 : -1;
fail:
    if (package)
        uci_unload(uci, package);
    if (uci)
        uci_free_context(uci);
    return -1;
}

static int forwarder_enabled_for(const char *section_name)
{
    struct uci_context *uci = uci_alloc_context();
    struct uci_package *package = NULL;
    struct uci_element *element;
    int enabled = 0;

    if (!uci || uci_load(uci, "sms_forwarder", &package) != UCI_OK)
        goto out;
    uci_foreach_element(&package->sections, element) {
        struct uci_section *section = uci_to_section(element);
        if (!strcmp(section->type, "sms_forward") &&
            !strcmp(option_string(uci, section, "enable", "0"), "1"))
            enabled = 1;
    }
    if (!enabled)
        goto out;
    enabled = 0;
    uci_foreach_element(&package->sections, element) {
        struct uci_section *section = uci_to_section(element);
        if (!strcmp(section->type, "sms_forward_instance") &&
            !strcmp(option_string(uci, section, "enable", "0"), "1") &&
            !strcmp(option_string(uci, section, "modem_cfg", ""), section_name)) {
            enabled = 1;
            break;
        }
    }
out:
    if (package)
        uci_unload(uci, package);
    if (uci)
        uci_free_context(uci);
    return enabled;
}

static int prepare_database_mode(const struct modem_config *cfg)
{
    char error[256];
    int imported;

    if (!strcmp(cfg->mode, "direct"))
        return 0;
    if (sms_legacy_migrate(&app.db, cfg->legacy_dir, cfg->section, &imported) != 0)
        return -1;
    return sms_db_migration_error(&app.db, cfg->section, error, sizeof(error)) > 0 ? -1 : 0;
}

static int set_uci_options(const char *section_name, const char **options,
                           const char **values, size_t count)
{
    struct uci_context *uci = uci_alloc_context();
    struct uci_package *package = NULL;
    struct uci_section *section;
    int result = -1;

    if (!uci || !valid_id(section_name) ||
        uci_load(uci, "qmodem", &package) != UCI_OK)
        goto out;
    section = uci_lookup_section(uci, package, section_name);
    if (!section)
        goto out;
    for (size_t i = 0; i < count; i++) {
        struct uci_ptr ptr = { .p = package, .s = section,
                               .option = options[i], .value = values[i] };
        if (!valid_id(options[i]) || !values[i] || uci_set(uci, &ptr) != UCI_OK)
            goto out;
    }
    if (uci_commit(uci, &package, false) != UCI_OK)
        goto out;
    result = 0;
out:
    if (uci)
        uci_free_context(uci);
    return result;
}

static int read_child_output(char *const argv[], char **output)
{
    int pipefd[2], status;
    pid_t child;
    char *buffer = NULL;
    size_t used = 0, capacity = 0;
    int64_t deadline = monotonic_ms() + 15000;

    *output = NULL;
    if (pipe2(pipefd, O_CLOEXEC) != 0)
        return -1;
    child = fork();
    if (child == 0) {
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[0]); close(pipefd[1]);
        execv(argv[0], argv);
        _exit(127);
    }
    close(pipefd[1]);
    if (child < 0) {
        close(pipefd[0]);
        return -1;
    }
    (void)fcntl(pipefd[0], F_SETFL, fcntl(pipefd[0], F_GETFL) | O_NONBLOCK);
    for (;;) {
        ssize_t count;
        struct pollfd pfd = { .fd = pipefd[0], .events = POLLIN };
        if (capacity - used < 4096) {
            char *grown;
            capacity = capacity ? capacity * 2 : 8192;
            grown = realloc(buffer, capacity);
            if (!grown) { free(buffer); close(pipefd[0]); kill(child, SIGKILL); waitpid(child, NULL, 0); return -1; }
            buffer = grown;
        }
        int64_t remaining = deadline - monotonic_ms();
        if (remaining <= 0 || poll(&pfd, 1, (int)remaining) == 0) {
            kill(child, SIGKILL);
            waitpid(child, &status, 0);
            free(buffer); close(pipefd[0]);
            *output = strdup("child command timed out");
            return -1;
        }
        count = read(pipefd[0], buffer + used, capacity - used - 1);
        if (count > 0) { used += (size_t)count; continue; }
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        break;
    }
    close(pipefd[0]);
    waitpid(child, &status, 0);
    if (!buffer)
        buffer = strdup("");
    if (buffer)
        buffer[used] = '\0';
    *output = buffer;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static int run_tom(const struct modem_config *cfg, const char *operation,
                   const char *pdu, int index, const char *at_command,
                   char **output)
{
    char index_string[24];
    char *argv[14];
    int n = 0;

    argv[n++] = TOM_MODEM;
    if (cfg->use_ubus || strcmp(cfg->mode, "direct"))
        argv[n++] = "-u";
    argv[n++] = "-d"; argv[n++] = (char *)cfg->at_port;
    argv[n++] = "-o"; argv[n++] = (char *)operation;
    if (pdu) { argv[n++] = "-p"; argv[n++] = (char *)pdu; }
    if (index >= 0) {
        snprintf(index_string, sizeof(index_string), "%d", index);
        argv[n++] = "-i"; argv[n++] = index_string;
    }
    if (at_command) { argv[n++] = "-c"; argv[n++] = (char *)at_command; }
    argv[n] = NULL;
    return read_child_output(argv, output);
}

static void reply_error(struct ubus_context *ctx, struct ubus_request_data *req,
                        const char *error)
{
    struct blob_buf b = {};
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "status", "error");
    blobmsg_add_string(&b, "error", error);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
}

static int apply_modem_settings(const char *section)
{
    char *argv[] = { QMODEM_SETTINGS, "apply", (char *)section, NULL };
    char *output = NULL;
    int result = read_child_output(argv, &output);
    free(output);
    return result;
}

static int sync_modem(const char *section, const char *trigger, int *imported,
                      int *deleted)
{
    struct modem_config cfg;
    struct json_object *root = NULL, *messages = NULL;
    char *output = NULL;
    int result = -1;
    int64_t started_at = time(NULL);

    *imported = *deleted = 0;
    snprintf(app.last_sync_section, sizeof(app.last_sync_section), "%s", section);
    app.last_sync_at = time(NULL);
    app.last_sync_error[0] = '\0';
    if (load_config(section, &cfg) != 0) {
        snprintf(app.last_sync_error, sizeof(app.last_sync_error), "modem configuration unavailable");
        return -1;
    }
    if (!strcmp(cfg.mode, "direct")) {
        snprintf(app.last_sync_error, sizeof(app.last_sync_error), "direct mode has no database sync");
        return -1;
    }
    if (!cfg.use_ubus) {
        snprintf(app.last_sync_error, sizeof(app.last_sync_error), "database mode requires use_ubus");
        return -1;
    }
    if (prepare_database_mode(&cfg) != 0) {
        snprintf(app.last_sync_error, sizeof(app.last_sync_error), "legacy SMS database migration failed");
        return -1;
    }
    sms_db_set_multipart_windows(&app.db, app.multipart_wait,
                                 app.late_fragment_window);
    (void)trigger;
    if (run_tom(&cfg, "r", NULL, -1, NULL, &output) != 0)
        goto out;
    root = json_tokener_parse(output);
    if (!root || (!json_object_object_get_ex(root, "msg", &messages) &&
                  !json_object_object_get_ex(root, "received", &messages)) ||
        !json_object_is_type(messages, json_type_array))
        goto out;
    for (size_t i = 0; i < json_object_array_length(messages); i++) {
        struct json_object *entry = json_object_array_get_idx(messages, i);
        struct json_object *field;
        sms_segment_t segment = { .modem_id = section, .storage = cfg.storage,
                                  .total_parts = 1, .part_number = 1 };
        sms_import_result_t import_result;
        char *delete_output = NULL;
        if (!json_object_object_get_ex(entry, "index", &field))
            continue;
        segment.source_index = json_object_get_int(field);
        if (!json_object_object_get_ex(entry, "pdu", &field))
            continue;
        segment.pdu = json_object_get_string(field);
        if (!json_object_object_get_ex(entry, "sender", &field))
            continue;
        segment.sender = json_object_get_string(field);
        if (!json_object_object_get_ex(entry, "timestamp", &field))
            continue;
        segment.timestamp = json_object_get_int64(field);
        if (!json_object_object_get_ex(entry, "content", &field))
            continue;
        segment.content = json_object_get_string(field);
        if (json_object_object_get_ex(entry, "reference", &field))
            segment.reference = json_object_get_int(field);
        if (json_object_object_get_ex(entry, "total", &field))
            segment.total_parts = json_object_get_int(field);
        if (json_object_object_get_ex(entry, "part", &field))
            segment.part_number = json_object_get_int(field);
        if (sms_db_import_segment(&app.db, &segment, time(NULL), cfg.forwarding,
                                  &import_result) != 0)
            goto out;
        if (!import_result.duplicate)
            (*imported)++;
        if (cfg.auto_delete && import_result.safe_to_delete &&
            run_tom(&cfg, "d", NULL, segment.source_index, NULL, &delete_output) == 0) {
            (*deleted)++;
            (void)sms_db_mark_source_deleted(&app.db, import_result.source_id, time(NULL));
        }
        free(delete_output);
    }
    {
        int expired;
        if (sms_db_publish_expired(&app.db, section, time(NULL), cfg.forwarding,
                                   &expired) != 0)
            goto out;
    }
    if (sms_db_finish_scan(&app.db, section, cfg.storage, started_at) != 0)
        goto out;
    app.last_sync_imported = *imported;
    if (sms_db_prune(&app.db, section, app.received_retention,
                     app.sent_retention) != 0)
        goto out;
    result = 0;
out:
    if (result != 0 && !app.last_sync_error[0])
        snprintf(app.last_sync_error, sizeof(app.last_sync_error), "modem read or database import failed");
    if (root)
        json_object_put(root);
    free(output);
    if (sms_db_record_sync(&app.db, section, trigger, started_at, *imported,
                           result == 0 ? NULL : app.last_sync_error) != 0 && result == 0) {
        snprintf(app.last_sync_error, sizeof(app.last_sync_error),
                 "failed to record synchronization result");
        result = -1;
    }
    if (sms_db_checkpoint(&app.db) != 0 && result == 0) {
        snprintf(app.last_sync_error, sizeof(app.last_sync_error),
                 "failed to checkpoint SMS database");
        result = -1;
    }
    return result;
}

static int status_method(struct ubus_context *ctx, struct ubus_object *obj,
                         struct ubus_request_data *req, const char *method,
                         struct blob_attr *msg)
{
    struct blob_buf b = {};
    (void)obj; (void)method; (void)msg;
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "status", "ready");
    blobmsg_add_u32(&b, "api_version", 3);
    blobmsg_add_string(&b, "database", app.db_path);
    blobmsg_add_string(&b, "default_mode", "database_poll");
    blobmsg_add_u32(&b, "default_poll_interval", 300);
    {
        void *modes = blobmsg_open_array(&b, "modes");
        blobmsg_add_string(&b, NULL, "direct");
        blobmsg_add_string(&b, NULL, "database_poll");
        blobmsg_add_string(&b, NULL, "database_urc");
        blobmsg_close_array(&b, modes);
    }
    blobmsg_add_u8(&b, "event_gap_resync", 1);
    blobmsg_add_u8(&b, "idempotent_import", 1);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return UBUS_STATUS_OK;
}

static int sync_status_method(struct ubus_context *ctx, struct ubus_object *obj,
                              struct ubus_request_data *req, const char *method,
                              struct blob_attr *msg)
{
    struct blob_buf b = {};
    (void)obj; (void)method; (void)msg;
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "modem_id", app.last_sync_section);
    blobmsg_add_u64(&b, "last_sync_at", app.last_sync_at);
    blobmsg_add_u32(&b, "imported", app.last_sync_imported);
    blobmsg_add_string(&b, "status", app.last_sync_error[0] ? "error" : "idle");
    if (app.last_sync_error[0])
        blobmsg_add_string(&b, "error", app.last_sync_error);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return UBUS_STATUS_OK;
}

static int sync_method(struct ubus_context *ctx, struct ubus_object *obj,
                       struct ubus_request_data *req, const char *method,
                       struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    struct blob_buf b = {};
    int imported, deleted;
    (void)obj; (void)method;
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM])
        return UBUS_STATUS_INVALID_ARGUMENT;
    if (sync_modem(blobmsg_get_string(tb[ARG_MODEM]), "manual", &imported, &deleted) != 0) {
        reply_error(ctx, req, app.last_sync_error);
        return UBUS_STATUS_OK;
    }
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "status", "success");
    blobmsg_add_u32(&b, "imported", imported);
    blobmsg_add_u32(&b, "deleted_from_modem", deleted);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return UBUS_STATUS_OK;
}

static int configure_method(struct ubus_context *ctx, struct ubus_object *obj,
                            struct ubus_request_data *req, const char *method,
                            struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    struct modem_config cfg;
    struct blob_buf b = {};
    const char *section, *mode_name;
    const char *options[6], *values[6];
    char number[24];
    size_t option_count = 0;
    int pending = 0;
    (void)obj; (void)method;
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM] || !valid_id(section = blobmsg_get_string(tb[ARG_MODEM])))
        return UBUS_STATUS_INVALID_ARGUMENT;
    if (tb[ARG_MODE]) {
        mode_name = blobmsg_get_string(tb[ARG_MODE]);
        if (strcmp(mode_name, "direct") && strcmp(mode_name, "database_poll") &&
            strcmp(mode_name, "database_urc"))
            return UBUS_STATUS_INVALID_ARGUMENT;
        options[option_count] = "sms_mode"; values[option_count++] = mode_name;
        if (strcmp(mode_name, "direct")) {
            options[option_count] = "use_ubus"; values[option_count++] = "1";
        }
    }
    if (tb[ARG_POLL_INTERVAL]) {
        int interval = blobmsg_get_u32(tb[ARG_POLL_INTERVAL]);
        if (interval < 60 || interval > 3600)
            return UBUS_STATUS_INVALID_ARGUMENT;
        snprintf(number, sizeof(number), "%d", interval);
        options[option_count] = "sms_poll_interval"; values[option_count++] = number;
    }
    if (tb[ARG_FORWARDING]) {
        options[option_count] = "sms_forwarding";
        values[option_count++] = blobmsg_get_bool(tb[ARG_FORWARDING]) ? "1" : "0";
    }
    if (tb[ARG_AUTO_DELETE]) {
        options[option_count] = "sms_auto_delete_from_sim";
        values[option_count++] = blobmsg_get_bool(tb[ARG_AUTO_DELETE]) ? "1" : "0";
    }
    if (tb[ARG_COUNTRY_CODE]) {
        const char *code = blobmsg_get_string(tb[ARG_COUNTRY_CODE]);
        char checked[22];
        if (*code && sms_resolve_number("1", code, checked, sizeof(checked)) != 0)
            return UBUS_STATUS_INVALID_ARGUMENT;
        options[option_count] = "sms_country_code"; values[option_count++] = code;
    }
    if (option_count && set_uci_options(section, options, values, option_count) != 0)
        goto error;
    if (load_config(section, &cfg) != 0)
        goto error;
    if ((tb[ARG_MODE] || tb[ARG_POLL_INTERVAL] || tb[ARG_FORWARDING] || tb[ARG_AUTO_DELETE]) &&
        apply_modem_settings(section) != 0)
        pending = 1;
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "status", pending ? "pending" : "success");
    blobmsg_add_string(&b, "mode", cfg.mode);
    blobmsg_add_string(&b, "country_code", cfg.country_code);
    blobmsg_add_u32(&b, "use_ubus", cfg.use_ubus);
    blobmsg_add_u32(&b, "poll_interval", cfg.poll_interval);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return UBUS_STATUS_OK;
error:
    reply_error(ctx, req, "failed to persist SMS configuration");
    return UBUS_STATUS_OK;
}

static int config_get_method(struct ubus_context *ctx, struct ubus_object *obj,
                             struct ubus_request_data *req, const char *method,
                             struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    struct modem_config cfg;
    struct blob_buf b = {};
    (void)obj; (void)method;
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM] ||
        load_config(blobmsg_get_string(tb[ARG_MODEM]), &cfg) != 0)
        return UBUS_STATUS_INVALID_ARGUMENT;
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "status", "success");
    blobmsg_add_string(&b, "mode", cfg.mode);
    blobmsg_add_u8(&b, "use_ubus", cfg.use_ubus);
    blobmsg_add_u8(&b, "auto_delete", cfg.auto_delete);
    blobmsg_add_u8(&b, "forwarding", cfg.forwarding);
    blobmsg_add_u32(&b, "poll_interval", cfg.poll_interval);
    blobmsg_add_string(&b, "country_code", cfg.country_code);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return UBUS_STATUS_OK;
}

static int list_method(struct ubus_context *ctx, struct ubus_object *obj,
                       struct ubus_request_data *req, const char *method,
                       struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    struct modem_config cfg;
    struct blob_buf b = {};
    sqlite3_stmt *stmt = NULL;
    const char *section;
    int limit = 100, offset = 0;
    void *array;
    (void)obj; (void)method;
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM])
        return UBUS_STATUS_INVALID_ARGUMENT;
    section = blobmsg_get_string(tb[ARG_MODEM]);
    if (load_config(section, &cfg) != 0) {
        reply_error(ctx, req, "modem configuration unavailable");
        return UBUS_STATUS_OK;
    }
    if (tb[ARG_LIMIT]) limit = blobmsg_get_u32(tb[ARG_LIMIT]);
    if (tb[ARG_OFFSET]) offset = blobmsg_get_u32(tb[ARG_OFFSET]);
    if (limit < 1 || limit > 500) limit = 100;
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "mode", cfg.mode);
    blobmsg_add_u8(&b, "use_ubus", cfg.use_ubus);
    blobmsg_add_u8(&b, "auto_delete", cfg.auto_delete);
    blobmsg_add_u8(&b, "forwarding", cfg.forwarding);
    blobmsg_add_u32(&b, "poll_interval", cfg.poll_interval);
    if (!strcmp(cfg.mode, "direct")) {
        char *output = NULL;
        if (run_tom(&cfg, "r", NULL, -1, NULL, &output) != 0 ||
            !blobmsg_add_json_from_string(&b, output ? output : "{}")) {
            free(output); blob_buf_free(&b);
            reply_error(ctx, req, "direct modem read failed");
            return UBUS_STATUS_OK;
        }
        free(output);
    } else {
        const char *query =
            "SELECT id,direction,sender,recipient,timestamp,content,complete,revision,is_read,send_success,conversation_contact "
            "FROM messages WHERE modem_id=? ORDER BY timestamp DESC,id DESC LIMIT ? OFFSET ?";
        if (prepare_database_mode(&cfg) != 0) {
            blob_buf_free(&b);
            reply_error(ctx, req, "legacy SMS database migration failed");
            return UBUS_STATUS_OK;
        }
        if (sqlite3_prepare_v2(app.db.sql, query, -1, &stmt, NULL) != SQLITE_OK)
            goto db_error;
        sqlite3_bind_text(stmt, 1, section, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 2, limit);
        sqlite3_bind_int(stmt, 3, offset);
        array = blobmsg_open_array(&b, "messages");
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            void *entry = blobmsg_open_table(&b, NULL);
            blobmsg_add_u64(&b, "id", sqlite3_column_int64(stmt, 0));
            blobmsg_add_string(&b, "type", (const char *)sqlite3_column_text(stmt, 1));
            if (sqlite3_column_type(stmt, 2) != SQLITE_NULL)
                blobmsg_add_string(&b, "sender", (const char *)sqlite3_column_text(stmt, 2));
            if (sqlite3_column_type(stmt, 3) != SQLITE_NULL)
                blobmsg_add_string(&b, "recipient", (const char *)sqlite3_column_text(stmt, 3));
            blobmsg_add_u64(&b, "timestamp", sqlite3_column_int64(stmt, 4));
            blobmsg_add_string(&b, "content", (const char *)sqlite3_column_text(stmt, 5));
            blobmsg_add_u8(&b, "complete", sqlite3_column_int(stmt, 6));
            blobmsg_add_u32(&b, "revision", sqlite3_column_int(stmt, 7));
            blobmsg_add_u8(&b, "is_read", sqlite3_column_int(stmt, 8));
            if (sqlite3_column_type(stmt, 9) != SQLITE_NULL)
                blobmsg_add_u8(&b, "success", sqlite3_column_int(stmt, 9));
            if (sqlite3_column_type(stmt, 10) != SQLITE_NULL)
                blobmsg_add_string(&b, "conversation_contact", (const char *)sqlite3_column_text(stmt, 10));
            blobmsg_close_table(&b, entry);
        }
        blobmsg_close_array(&b, array);
        sqlite3_finalize(stmt);
    }
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return UBUS_STATUS_OK;
db_error:
    sqlite3_finalize(stmt);
    blob_buf_free(&b);
    reply_error(ctx, req, sms_db_error(&app.db));
    return UBUS_STATUS_OK;
}

static int get_method(struct ubus_context *ctx, struct ubus_object *obj,
                      struct ubus_request_data *req, const char *method,
                      struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    sqlite3_stmt *stmt = NULL;
    struct blob_buf b = {};
    const char *section;
    int64_t id;
    (void)obj; (void)method;

    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM] || blobmsg_get_positive_i64(tb[ARG_ID], &id) != 0)
        return UBUS_STATUS_INVALID_ARGUMENT;
    section = blobmsg_get_string(tb[ARG_MODEM]);
    if (sqlite3_prepare_v2(app.db.sql,
            "SELECT id,direction,sender,recipient,timestamp,content,complete,revision,is_read,send_success,conversation_contact "
            "FROM messages WHERE id=? AND modem_id=?", -1, &stmt, NULL) != SQLITE_OK)
        goto error;
    sqlite3_bind_int64(stmt, 1, id);
    sqlite3_bind_text(stmt, 2, section, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        return UBUS_STATUS_NOT_FOUND;
    }
    blob_buf_init(&b, 0);
    blobmsg_add_u64(&b, "id", sqlite3_column_int64(stmt, 0));
    blobmsg_add_string(&b, "type", (const char *)sqlite3_column_text(stmt, 1));
    if (sqlite3_column_type(stmt, 2) != SQLITE_NULL)
        blobmsg_add_string(&b, "sender", (const char *)sqlite3_column_text(stmt, 2));
    if (sqlite3_column_type(stmt, 3) != SQLITE_NULL)
        blobmsg_add_string(&b, "recipient", (const char *)sqlite3_column_text(stmt, 3));
    blobmsg_add_u64(&b, "timestamp", sqlite3_column_int64(stmt, 4));
    blobmsg_add_string(&b, "content", (const char *)sqlite3_column_text(stmt, 5));
    blobmsg_add_u8(&b, "complete", sqlite3_column_int(stmt, 6));
    blobmsg_add_u32(&b, "revision", sqlite3_column_int(stmt, 7));
    blobmsg_add_u8(&b, "is_read", sqlite3_column_int(stmt, 8));
    if (sqlite3_column_type(stmt, 9) != SQLITE_NULL)
        blobmsg_add_u8(&b, "success", sqlite3_column_int(stmt, 9));
    if (sqlite3_column_type(stmt, 10) != SQLITE_NULL)
        blobmsg_add_string(&b, "conversation_contact", (const char *)sqlite3_column_text(stmt, 10));
    sqlite3_finalize(stmt);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return UBUS_STATUS_OK;
error:
    sqlite3_finalize(stmt);
    reply_error(ctx, req, sms_db_error(&app.db));
    return UBUS_STATUS_OK;
}

static int send_method(struct ubus_context *ctx, struct ubus_object *obj,
                       struct ubus_request_data *req, const char *method,
                       struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    struct modem_config cfg;
    unsigned char pdus[SMS_MAX_PARTS][SMS_MAX_PDU_LENGTH];
    int lengths[SMS_MAX_PARTS];
    char hex[SMS_MAX_PDU_LENGTH * 2 + 1];
    const char *recipient, *content, *request_id = NULL;
    char number[22], conversation_contact[22] = {0};
    int parts, success = 1, managed, managed_record_created = 0;
    char *output = NULL;
    sqlite3_stmt *stmt = NULL;
    struct blob_buf b = {};
    (void)obj;
    managed = !strcmp(method, "send_managed");
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM] || !tb[ARG_RECIPIENT] || !tb[ARG_CONTENT])
        return UBUS_STATUS_INVALID_ARGUMENT;
    if (load_config(blobmsg_get_string(tb[ARG_MODEM]), &cfg) != 0)
        goto error;
    if (managed && !strcmp(cfg.mode, "direct")) {
        reply_error(ctx, req, "managed send requires database mode");
        return UBUS_STATUS_OK;
    }
    if (managed) {
        if (!tb[ARG_REQUEST_ID] ||
            !valid_id(blobmsg_get_string(tb[ARG_REQUEST_ID])))
            return UBUS_STATUS_INVALID_ARGUMENT;
        request_id = blobmsg_get_string(tb[ARG_REQUEST_ID]);
    }
    if (strcmp(cfg.mode, "direct") && prepare_database_mode(&cfg) != 0)
        goto error;
    recipient = blobmsg_get_string(tb[ARG_RECIPIENT]);
    content = blobmsg_get_string(tb[ARG_CONTENT]);
    const char *country_code = tb[ARG_COUNTRY_CODE] ? blobmsg_get_string(tb[ARG_COUNTRY_CODE]) : cfg.country_code;
    if (sms_resolve_number(recipient, country_code, number, sizeof(number)) != 0)
        return UBUS_STATUS_INVALID_ARGUMENT;
    if (tb[ARG_CONVERSATION_CONTACT]) {
        const char *contact = blobmsg_get_string(tb[ARG_CONVERSATION_CONTACT]);
        if (sms_normalize_number(contact, conversation_contact, sizeof(conversation_contact)) != 0)
            return UBUS_STATUS_INVALID_ARGUMENT;
        /* An explicit reply may add a country code, never alias an unrelated
         * destination or a different complete international address. */
        size_t contact_length = strlen(conversation_contact), number_length = strlen(number);
        if (strcmp(number, conversation_contact) &&
            (number[0] != '+' || conversation_contact[0] == '+' ||
             number_length <= contact_length ||
             strcmp(number + number_length - contact_length, conversation_contact)))
            return UBUS_STATUS_INVALID_ARGUMENT;
    }
    parts = pdu_encode_ucs2_parts(number, content, pdus, lengths, SMS_MAX_PARTS,
                                  (unsigned int)time(NULL));
    if (parts < 1)
        goto error;
    if (managed) {
        if (sqlite3_prepare_v2(app.db.sql,
                "INSERT OR IGNORE INTO managed_sends(request_id,modem_id,recipient,content,state,created_at,updated_at) "
                "VALUES(?,?,?,?,'sending',strftime('%s','now'),strftime('%s','now'))",
                -1, &stmt, NULL) != SQLITE_OK)
            goto error;
        sqlite3_bind_text(stmt, 1, request_id, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, cfg.section, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, recipient, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 4, content, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) != SQLITE_DONE)
            goto error;
        managed_record_created = sqlite3_changes(app.db.sql) > 0;
        sqlite3_finalize(stmt); stmt = NULL;
        if (!managed_record_created) {
            const char *stored_modem, *stored_recipient, *stored_content, *state;
            int stored_parts;
            if (sqlite3_prepare_v2(app.db.sql,
                    "SELECT modem_id,recipient,content,state,parts FROM managed_sends WHERE request_id=?",
                    -1, &stmt, NULL) != SQLITE_OK)
                goto error;
            sqlite3_bind_text(stmt, 1, request_id, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) != SQLITE_ROW)
                goto error;
            stored_modem = (const char *)sqlite3_column_text(stmt, 0);
            stored_recipient = (const char *)sqlite3_column_text(stmt, 1);
            stored_content = (const char *)sqlite3_column_text(stmt, 2);
            state = (const char *)sqlite3_column_text(stmt, 3);
            stored_parts = sqlite3_column_int(stmt, 4);
            if (strcmp(stored_modem, cfg.section) || strcmp(stored_recipient, recipient) ||
                strcmp(stored_content, content)) {
                sqlite3_finalize(stmt);
                reply_error(ctx, req, "request_id payload conflict");
                return UBUS_STATUS_OK;
            }
            blob_buf_init(&b, 0);
            blobmsg_add_string(&b, "status", !strcmp(state, "success") ? "success" : "error");
            blobmsg_add_u32(&b, "parts", stored_parts);
            blobmsg_add_u8(&b, "replayed", 1);
            if (!strcmp(state, "sending"))
                blobmsg_add_string(&b, "error", "request is already in progress");
            ubus_send_reply(ctx, req, b.head);
            blob_buf_free(&b);
            sqlite3_finalize(stmt);
            return UBUS_STATUS_OK;
        }
    }
    for (int part = 0; part < parts; part++) {
        free(output); output = NULL;
        for (int i = 0; i < lengths[part]; i++)
            snprintf(hex + i * 2, 3, "%02X", pdus[part][i]);
        hex[lengths[part] * 2] = '\0';
        if (run_tom(&cfg, "s", hex, -1, NULL, &output) != 0 ||
            !tom_sms_send_succeeded(output)) {
            success = 0;
            break;
        }
    }
    if (strcmp(cfg.mode, "direct")) {
        if (sqlite3_prepare_v2(app.db.sql,
                "INSERT INTO messages(modem_id,direction,recipient,timestamp,content,complete,send_success,created_at,updated_at,conversation_contact) "
                "VALUES(?,'sent',?,strftime('%s','now'),?,1,?,strftime('%s','now'),strftime('%s','now'),?)",
                -1, &stmt, NULL) != SQLITE_OK)
            goto error;
        sqlite3_bind_text(stmt, 1, cfg.section, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, number, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, content, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 4, success);
        if (conversation_contact[0])
            sqlite3_bind_text(stmt, 5, conversation_contact, -1, SQLITE_TRANSIENT);
        else
            sqlite3_bind_null(stmt, 5);
        if (sqlite3_step(stmt) != SQLITE_DONE)
            goto error;
        sqlite3_finalize(stmt); stmt = NULL;
    }
    if (managed) {
        if (sqlite3_prepare_v2(app.db.sql,
                "UPDATE managed_sends SET state=?,parts=?,error=?,updated_at=strftime('%s','now') WHERE request_id=?",
                -1, &stmt, NULL) != SQLITE_OK)
            goto error;
        sqlite3_bind_text(stmt, 1, success ? "success" : "error", -1, SQLITE_STATIC);
        sqlite3_bind_int(stmt, 2, parts);
        if (success)
            sqlite3_bind_null(stmt, 3);
        else
            sqlite3_bind_text(stmt, 3, "modem send failed", -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 4, request_id, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) != SQLITE_DONE)
            goto error;
        sqlite3_finalize(stmt); stmt = NULL;
    }
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "status", success ? "success" : "error");
    blobmsg_add_string(&b, "recipient", number);
    blobmsg_add_u32(&b, "parts", parts);
    if (output && *output)
        blobmsg_add_string(&b, "modem_response", output);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    free(output);
    return UBUS_STATUS_OK;
error:
    sqlite3_finalize(stmt);
    if (managed && managed_record_created && request_id && app.db.sql &&
        sqlite3_prepare_v2(app.db.sql,
            "UPDATE managed_sends SET state='error',error='internal send failure',updated_at=strftime('%s','now') WHERE request_id=?",
            -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, request_id, -1, SQLITE_TRANSIENT);
        (void)sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
    free(output);
    reply_error(ctx, req, "SMS encoding, transport, or history write failed");
    return UBUS_STATUS_OK;
}

static int delete_method(struct ubus_context *ctx, struct ubus_object *obj,
                         struct ubus_request_data *req, const char *method,
                         struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    struct modem_config cfg;
    struct blob_buf b = {};
    int changed = 0;
    int64_t id;
    char *output = NULL;
    (void)obj; (void)method;
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM] || load_config(blobmsg_get_string(tb[ARG_MODEM]), &cfg) != 0)
        return UBUS_STATUS_INVALID_ARGUMENT;
    if (!strcmp(cfg.mode, "direct")) {
        if (!tb[ARG_INDEX] || run_tom(&cfg, "d", NULL, blobmsg_get_u32(tb[ARG_INDEX]),
                                     NULL, &output) != 0)
            goto error;
        changed = 1;
    } else {
        if (blobmsg_get_positive_i64(tb[ARG_ID], &id) != 0 ||
            sms_db_delete_message(&app.db, cfg.section, id, &changed) != 0)
            goto error;
    }
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "status", "success");
    blobmsg_add_u32(&b, "deleted", changed);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    free(output);
    return UBUS_STATUS_OK;
error:
    free(output);
    reply_error(ctx, req, "delete failed");
    return UBUS_STATUS_OK;
}

static int mark_read_method(struct ubus_context *ctx, struct ubus_object *obj,
                            struct ubus_request_data *req, const char *method,
                            struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    sqlite3_stmt *stmt = NULL;
    struct blob_buf b = {};
    int64_t id;
    (void)obj; (void)method;
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM] || blobmsg_get_positive_i64(tb[ARG_ID], &id) != 0)
        return UBUS_STATUS_INVALID_ARGUMENT;
    if (sqlite3_prepare_v2(app.db.sql,
            "UPDATE messages SET is_read=1,updated_at=strftime('%s','now') WHERE id=? AND modem_id=? AND direction='received'",
            -1, &stmt, NULL) != SQLITE_OK)
        goto error;
    sqlite3_bind_int64(stmt, 1, id);
    sqlite3_bind_text(stmt, 2, blobmsg_get_string(tb[ARG_MODEM]), -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) != SQLITE_DONE)
        goto error;
    sqlite3_finalize(stmt);
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "status", "success");
    blobmsg_add_u32(&b, "marked", sqlite3_changes(app.db.sql));
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return UBUS_STATUS_OK;
error:
    sqlite3_finalize(stmt);
    reply_error(ctx, req, "mark read failed");
    return UBUS_STATUS_OK;
}

static int storage_get_method(struct ubus_context *ctx, struct ubus_object *obj,
                              struct ubus_request_data *req, const char *method,
                              struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    struct modem_config cfg;
    struct blob_buf b = {};
    char *output = NULL;
    (void)obj; (void)method;
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM] || load_config(blobmsg_get_string(tb[ARG_MODEM]), &cfg) != 0)
        return UBUS_STATUS_INVALID_ARGUMENT;
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "configured", cfg.storage);
    if (run_tom(&cfg, "a", NULL, -1, "AT+CPMS?", &output) == 0) {
        blobmsg_add_string(&b, "status", "success");
        blobmsg_add_string(&b, "response", output);
    } else {
        blobmsg_add_string(&b, "status", "pending_use_ubus");
    }
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    free(output);
    return UBUS_STATUS_OK;
}

static int storage_set_method(struct ubus_context *ctx, struct ubus_object *obj,
                              struct ubus_request_data *req, const char *method,
                              struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    struct modem_config cfg;
    struct blob_buf b = {};
    const char *section, *mem1, *mem2, *mem3;
    (void)obj; (void)method;
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM] || !tb[ARG_MEM1] || !tb[ARG_MEM2])
        return UBUS_STATUS_INVALID_ARGUMENT;
    section = blobmsg_get_string(tb[ARG_MODEM]);
    mem1 = blobmsg_get_string(tb[ARG_MEM1]); mem2 = blobmsg_get_string(tb[ARG_MEM2]);
    mem3 = tb[ARG_MEM3] ? blobmsg_get_string(tb[ARG_MEM3]) : mem2;
    if ((strcmp(mem1, "SM") && strcmp(mem1, "ME")) ||
        (strcmp(mem2, "SM") && strcmp(mem2, "ME")) ||
        (strcmp(mem3, "SM") && strcmp(mem3, "ME")))
        return UBUS_STATUS_INVALID_ARGUMENT;
    {
        const char *options[] = { "sms_storage_mem1", "sms_storage_mem2", "sms_storage_mem3" };
        const char *values[] = { mem1, mem2, mem3 };
        if (set_uci_options(section, options, values, 3) != 0 ||
        load_config(section, &cfg) != 0) {
            reply_error(ctx, req, "failed to save storage configuration");
            return UBUS_STATUS_OK;
        }
    }
    blob_buf_init(&b, 0);
    if (!cfg.use_ubus)
        blobmsg_add_string(&b, "status", "pending_use_ubus");
    else if (apply_modem_settings(section) == 0)
        blobmsg_add_string(&b, "status", "success");
    else
        blobmsg_add_string(&b, "status", "ready_degraded");
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    return UBUS_STATUS_OK;
}

static int modem_list_method(struct ubus_context *ctx, struct ubus_object *obj,
                             struct ubus_request_data *req, const char *method,
                             struct blob_attr *msg)
{
    struct uci_context *uci = uci_alloc_context();
    struct uci_package *package = NULL;
    struct uci_element *element;
    struct blob_buf b = {};
    void *array;
    (void)obj; (void)method; (void)msg;
    if (!uci || uci_load(uci, "qmodem", &package) != UCI_OK) {
        if (uci) uci_free_context(uci);
        reply_error(ctx, req, "qmodem UCI unavailable");
        return UBUS_STATUS_OK;
    }
    blob_buf_init(&b, 0);
    array = blobmsg_open_array(&b, "modems");
    uci_foreach_element(&package->sections, element) {
        struct uci_section *section = uci_to_section(element);
        int use_ubus;
        if (strcmp(section->type, "modem-device"))
            continue;
        void *entry = blobmsg_open_table(&b, NULL);
        char state_path[256];
        struct json_object *state = NULL, *state_value = NULL;
        use_ubus = !strcmp(option_string(uci, section, "use_ubus", "1"), "1");
        blobmsg_add_string(&b, "modem_id", section->e.name);
        blobmsg_add_string(&b, "name", option_string(uci, section, "name", section->e.name));
        blobmsg_add_string(&b, "mode", option_string(uci, section, "sms_mode",
                           use_ubus ? "database_poll" : "direct"));
        blobmsg_add_u8(&b, "use_ubus", use_ubus);
        blobmsg_add_u8(&b, "enabled", strcmp(option_string(uci, section, "enabled", "1"), "0") != 0);
        snprintf(state_path, sizeof(state_path), "/var/run/qmodem/settings/%s.json", section->e.name);
        state = json_object_from_file(state_path);
        if (state && json_object_object_get_ex(state, "state", &state_value))
            blobmsg_add_string(&b, "settings_state", json_object_get_string(state_value));
        else
            blobmsg_add_string(&b, "settings_state", "unknown");
        if (state)
            json_object_put(state);
        blobmsg_close_table(&b, entry);
    }
    blobmsg_close_array(&b, array);
    ubus_send_reply(ctx, req, b.head);
    blob_buf_free(&b);
    uci_unload(uci, package); uci_free_context(uci);
    return UBUS_STATUS_OK;
}

static int modem_delete_method(struct ubus_context *ctx, struct ubus_object *obj,
                               struct ubus_request_data *req, const char *method,
                               struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX];
    struct blob_buf b = {};
    int deleted;
    (void)obj; (void)method;
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[ARG_MODEM]) return UBUS_STATUS_INVALID_ARGUMENT;
    if (sms_db_delete_modem_messages(&app.db, blobmsg_get_string(tb[ARG_MODEM]),
                                     &deleted) != 0) goto error;
    blob_buf_init(&b, 0); blobmsg_add_string(&b, "status", "success");
    blobmsg_add_u32(&b, "deleted", deleted);
    ubus_send_reply(ctx, req, b.head); blob_buf_free(&b); return UBUS_STATUS_OK;
error:
    reply_error(ctx, req, "modem database delete failed"); return UBUS_STATUS_OK;
}

static int delivery_claim_method(struct ubus_context *ctx, struct ubus_object *obj,
                                 struct ubus_request_data *req, const char *method,
                                 struct blob_attr *msg)
{
    sqlite3_stmt *stmt = NULL, *update = NULL;
    struct blob_buf b = {};
    int64_t id = 0;
    (void)obj; (void)method; (void)msg;
    if (sqlite3_exec(app.db.sql, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) goto error;
    if (sqlite3_exec(app.db.sql,
            "UPDATE deliveries SET state='pending',claimed_at=NULL,"
            "available_at=strftime('%s','now') WHERE state='claimed' "
            "AND claimed_at<strftime('%s','now')-300", NULL, NULL, NULL) != SQLITE_OK)
        goto rollback;
    if (sqlite3_prepare_v2(app.db.sql,
            "SELECT d.id,m.id,m.modem_id,m.sender,m.timestamp,m.content,m.complete,m.revision "
            "FROM deliveries d JOIN messages m ON m.id=d.message_id "
            "WHERE d.state='pending' AND d.available_at<=strftime('%s','now') ORDER BY d.id LIMIT 1",
            -1, &stmt, NULL) != SQLITE_OK) goto rollback;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        id = sqlite3_column_int64(stmt, 0);
        blob_buf_init(&b, 0);
        blobmsg_add_string(&b, "status", "claimed");
        blobmsg_add_u64(&b, "delivery_id", id);
        blobmsg_add_u64(&b, "message_id", sqlite3_column_int64(stmt, 1));
        blobmsg_add_string(&b, "modem_id", (const char *)sqlite3_column_text(stmt, 2));
        blobmsg_add_string(&b, "sender", (const char *)sqlite3_column_text(stmt, 3));
        blobmsg_add_u64(&b, "timestamp", sqlite3_column_int64(stmt, 4));
        blobmsg_add_string(&b, "content", (const char *)sqlite3_column_text(stmt, 5));
        blobmsg_add_u8(&b, "complete", sqlite3_column_int(stmt, 6));
        blobmsg_add_u32(&b, "revision", sqlite3_column_int(stmt, 7));
    } else {
        blob_buf_init(&b, 0); blobmsg_add_string(&b, "status", "empty");
    }
    sqlite3_finalize(stmt); stmt = NULL;
    if (id) {
        if (sqlite3_prepare_v2(app.db.sql,
                "UPDATE deliveries SET state='claimed',attempts=attempts+1,claimed_at=strftime('%s','now') WHERE id=?",
                -1, &update, NULL) != SQLITE_OK) goto rollback;
        sqlite3_bind_int64(update, 1, id);
        if (sqlite3_step(update) != SQLITE_DONE) goto rollback;
        sqlite3_finalize(update); update = NULL;
    }
    if (sqlite3_exec(app.db.sql, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) goto error;
    ubus_send_reply(ctx, req, b.head); blob_buf_free(&b); return UBUS_STATUS_OK;
rollback:
    sqlite3_finalize(stmt); sqlite3_finalize(update);
    sqlite3_exec(app.db.sql, "ROLLBACK", NULL, NULL, NULL);
error:
    if (b.head) blob_buf_free(&b);
    reply_error(ctx, req, "delivery claim failed"); return UBUS_STATUS_OK;
}

static int delivery_complete_method(struct ubus_context *ctx, struct ubus_object *obj,
                                    struct ubus_request_data *req, const char *method,
                                    struct blob_attr *msg)
{
    struct blob_attr *tb[__ARG_MAX]; sqlite3_stmt *stmt = NULL; struct blob_buf b = {};
    const char *state, *error = NULL;
    int64_t delivery_id;
    (void)obj; (void)method;
    blobmsg_parse(policy, __ARG_MAX, tb, blob_data(msg), blob_len(msg));
    if (blobmsg_get_positive_i64(tb[ARG_DELIVERY_ID], &delivery_id) != 0 ||
        !tb[ARG_SUCCESS]) return UBUS_STATUS_INVALID_ARGUMENT;
    state = blobmsg_get_bool(tb[ARG_SUCCESS]) ? "done" : "pending";
    if (tb[ARG_ERROR]) error = blobmsg_get_string(tb[ARG_ERROR]);
    if (sqlite3_prepare_v2(app.db.sql,
            "UPDATE deliveries SET state=?,completed_at=CASE WHEN ?='done' THEN strftime('%s','now') END,"
            "available_at=CASE WHEN ?='pending' THEN strftime('%s','now')+MIN(3600,30*(1<<MIN(attempts,7))) ELSE available_at END,last_error=? "
            "WHERE id=? AND state='claimed'", -1, &stmt, NULL) != SQLITE_OK) goto error;
    sqlite3_bind_text(stmt, 1, state, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, state, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, state, -1, SQLITE_TRANSIENT);
    if (error) sqlite3_bind_text(stmt, 4, error, -1, SQLITE_TRANSIENT); else sqlite3_bind_null(stmt, 4);
    sqlite3_bind_int64(stmt, 5, delivery_id);
    if (sqlite3_step(stmt) != SQLITE_DONE) goto error;
    sqlite3_finalize(stmt); blob_buf_init(&b, 0); blobmsg_add_string(&b, "status", "success");
    ubus_send_reply(ctx, req, b.head); blob_buf_free(&b); return UBUS_STATUS_OK;
error:
    sqlite3_finalize(stmt); reply_error(ctx, req, "delivery completion failed"); return UBUS_STATUS_OK;
}

static void urc_event(struct ubus_context *ctx, struct ubus_event_handler *handler,
                      const char *type, struct blob_attr *msg)
{
    enum { URC_PORT, URC_OWNER, URC_ID, URC_EPOCH, URC_SEQUENCE, __URC_MAX };
    static const struct blobmsg_policy urc_policy[] = {
        [URC_PORT] = { .name = "port", .type = BLOBMSG_TYPE_STRING },
        [URC_OWNER] = { .name = "owner", .type = BLOBMSG_TYPE_STRING },
        [URC_ID] = { .name = "urc_id", .type = BLOBMSG_TYPE_STRING },
        [URC_EPOCH] = { .name = "restart_epoch", .type = BLOBMSG_TYPE_INT64 },
        [URC_SEQUENCE] = { .name = "sequence", .type = BLOBMSG_TYPE_INT64 },
    };
    struct blob_attr *tb[__URC_MAX];
    struct uci_context *uci; struct uci_package *package = NULL; struct uci_element *element;
    (void)ctx; (void)handler; (void)type;
    blobmsg_parse(urc_policy, __URC_MAX, tb, blob_data(msg), blob_len(msg));
    if (!tb[URC_PORT] || !tb[URC_OWNER] || !tb[URC_ID] ||
        strcmp(blobmsg_get_string(tb[URC_OWNER]), "qmodem.sms") ||
        strcmp(blobmsg_get_string(tb[URC_ID]), "sms-new")) return;
    uci = uci_alloc_context();
    if (!uci || uci_load(uci, "qmodem", &package) != UCI_OK) goto out;
    uci_foreach_element(&package->sections, element) {
        struct uci_section *section = uci_to_section(element);
        int imported, deleted, gap = 0;
        if (!strcmp(option_string(uci, section, "override_at_port",
                option_string(uci, section, "sms_at_port",
                option_string(uci, section, "at_port", ""))),
                blobmsg_get_string(tb[URC_PORT])) &&
            !strcmp(option_string(uci, section, "sms_mode", "database_poll"), "database_urc")) {
            if (tb[URC_EPOCH] && tb[URC_SEQUENCE])
                (void)sms_db_record_event(&app.db, section->e.name,
                    blobmsg_get_u64(tb[URC_EPOCH]), blobmsg_get_u64(tb[URC_SEQUENCE]), &gap);
            sync_modem(section->e.name, gap ? "urc_gap" : "urc", &imported, &deleted);
            break;
        }
    }
out:
    if (package) uci_unload(uci, package);
    if (uci) uci_free_context(uci);
}

static void control_event(struct ubus_context *ctx, struct ubus_event_handler *handler,
                          const char *type, struct blob_attr *msg)
{
    enum { CONTROL_MODEM, __CONTROL_MAX };
    static const struct blobmsg_policy control_policy[] = {
        [CONTROL_MODEM] = { .name = "modem_id", .type = BLOBMSG_TYPE_STRING },
    };
    struct blob_attr *tb[__CONTROL_MAX];
    int imported, deleted;
    (void)ctx; (void)handler; (void)type;
    blobmsg_parse(control_policy, __CONTROL_MAX, tb, blob_data(msg), blob_len(msg));
    if (tb[CONTROL_MODEM] && valid_id(blobmsg_get_string(tb[CONTROL_MODEM])))
        (void)sync_modem(blobmsg_get_string(tb[CONTROL_MODEM]), "settings_reapplied",
                         &imported, &deleted);
}

static void scheduler_cb(struct uloop_timeout *timeout)
{
    struct uci_context *uci = uci_alloc_context();
    struct uci_package *package = NULL;
    struct uci_element *element;
    int64_t now = time(NULL);
    (void)timeout;

    if (!uci || uci_load(uci, "qmodem", &package) != UCI_OK)
        goto out;
    uci_foreach_element(&package->sections, element) {
        struct uci_section *section = uci_to_section(element);
        struct modem_config cfg;
        sqlite3_stmt *stmt = NULL;
        int64_t last_sync = 0;
        int imported, deleted;

        if (strcmp(section->type, "modem-device") ||
            load_config(section->e.name, &cfg) != 0)
            continue;
        if (!strcmp(cfg.mode, "database_urc")) {
            continue;
        }
		/* Polling imports SMS independently of optional forwarding sinks. */
		if (strcmp(cfg.mode, "database_poll") || !cfg.use_ubus)
            continue;
        if (sqlite3_prepare_v2(app.db.sql,
                "SELECT COALESCE(last_sync_at,0) FROM modems WHERE id=?", -1,
                &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, section->e.name, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) == SQLITE_ROW)
                last_sync = sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
        if (last_sync + cfg.poll_interval <= now)
            (void)sync_modem(section->e.name, "poll", &imported, &deleted);
    }
out:
    if (package)
        uci_unload(uci, package);
    if (uci)
        uci_free_context(uci);
    uloop_timeout_set(&app.scheduler, SCHEDULER_TICK_MS);
}

static const struct ubus_method methods[] = {
    UBUS_METHOD_NOARG("status", status_method),
    UBUS_METHOD("config_get", config_get_method, policy),
    UBUS_METHOD("configure", configure_method, policy),
    UBUS_METHOD("sync", sync_method, policy),
    UBUS_METHOD_NOARG("sync_status", sync_status_method),
    UBUS_METHOD("list", list_method, policy),
    UBUS_METHOD("get", get_method, policy),
    UBUS_METHOD("send", send_method, policy),
    UBUS_METHOD("send_managed", send_method, policy),
    UBUS_METHOD("delete", delete_method, policy),
    UBUS_METHOD("mark_read", mark_read_method, policy),
    UBUS_METHOD_NOARG("modem_list", modem_list_method),
    UBUS_METHOD("modem_delete", modem_delete_method, policy),
    UBUS_METHOD("storage_get", storage_get_method, policy),
    UBUS_METHOD("storage_set", storage_set_method, policy),
    UBUS_METHOD_NOARG("delivery_claim", delivery_claim_method),
    UBUS_METHOD("delivery_complete", delivery_complete_method, policy),
};

static struct ubus_object_type object_type = UBUS_OBJECT_TYPE("qmodem.sms", methods);

int main(int argc, char **argv)
{
    char db_path[256];
    memset(&app, 0, sizeof(app));
    snprintf(db_path, sizeof(db_path), "%s", argc > 1 ? argv[1] : DEFAULT_DB);
    load_service_config(db_path, sizeof(db_path), argc <= 1);
    snprintf(app.db_path, sizeof(app.db_path), "%s", db_path);
    umask(0077);
    uloop_init();
    if (sms_db_open(&app.db, db_path) != 0) {
        fprintf(stderr, "qmodem-smsd: database open failed: %s\n", sms_db_error(&app.db));
        return 1;
    }
    sms_db_set_multipart_windows(&app.db, app.multipart_wait,
                                 app.late_fragment_window);
    app.ubus = ubus_connect(NULL);
    if (!app.ubus) { sms_db_close(&app.db); return 1; }
    ubus_add_uloop(app.ubus);
    app.object.name = "qmodem.sms"; app.object.type = &object_type;
    app.object.methods = methods; app.object.n_methods = ARRAY_SIZE(methods);
    if (ubus_add_object(app.ubus, &app.object) != UBUS_STATUS_OK) {
        ubus_free(app.ubus); sms_db_close(&app.db); return 1;
    }
    app.urc_handler.cb = urc_event;
    ubus_register_event_handler(app.ubus, &app.urc_handler, "qmodem.at.urc");
    app.control_handler.cb = control_event;
    ubus_register_event_handler(app.ubus, &app.control_handler, "qmodem.sms.control");
    app.scheduler.cb = scheduler_cb;
    uloop_timeout_set(&app.scheduler, 1000);
    uloop_run();
    ubus_free(app.ubus); sms_db_close(&app.db); uloop_done();
    return 0;
}
