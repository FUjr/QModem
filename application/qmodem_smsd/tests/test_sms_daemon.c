/* Native integration test: real UCI/SQLite and daemon handlers, simulated AT I/O. */
#include <assert.h>
#include <libubus.h>
#include <uci.h>

static struct uci_context *test_uci_alloc_context(void);
static int capture_reply(struct ubus_context *, struct ubus_request_data *, struct blob_attr *);
static int capture_timeout(struct uloop_timeout *, int);
#define uci_alloc_context test_uci_alloc_context
#define ubus_send_reply capture_reply
#define uloop_timeout_set capture_timeout
#define TOM_MODEM "/proc/self/exe"
#define main smsd_main
#include "../src/main.c"
#undef main
#undef uci_alloc_context
#undef ubus_send_reply
#undef uloop_timeout_set

static char fixture_dir[256], log_path[280];
static struct json_object *reply;
static int next_timeout;

static struct uci_context *test_uci_alloc_context(void)
{
    struct uci_context *ctx = uci_alloc_context();
    assert(ctx);
    assert(uci_set_confdir(ctx, fixture_dir) == UCI_OK);
    assert(uci_set_savedir(ctx, fixture_dir) == UCI_OK);
    return ctx;
}

static int capture_reply(struct ubus_context *ctx, struct ubus_request_data *req,
                          struct blob_attr *message)
{
    char *json = blobmsg_format_json(message, true);
    (void)ctx; (void)req;
    if (reply) json_object_put(reply);
    reply = json_tokener_parse(json);
    free(json);
    assert(reply);
    return 0;
}

static int capture_timeout(struct uloop_timeout *timeout, int milliseconds)
{
    (void)timeout;
    next_timeout = milliseconds;
    return 0;
}

static int fake_tom(int argc, char **argv)
{
    const char *operation = "", *index = "";
    for (int i = 1; i + 1 < argc; i++) {
        if (!strcmp(argv[i], "-o")) operation = argv[i + 1];
        if (!strcmp(argv[i], "-i")) index = argv[i + 1];
    }
    FILE *log = fopen(getenv("SMS_TEST_LOG"), "a");
    assert(log);
    fprintf(log, "%s %s\n", operation, index);
    fclose(log);
    if (!strcmp(operation, "a")) {
        puts(getenv("SMS_TEST_CPMS"));
        return getenv("SMS_TEST_CPMS_FAIL") ? 1 : 0;
    }
    if (!strcmp(operation, "r")) {
        puts(getenv("SMS_TEST_MESSAGES"));
        return getenv("SMS_TEST_READ_FAIL") ? 1 : 0;
    }
    if (!strcmp(operation, "d")) return getenv("SMS_TEST_DELETE_FAIL") ? 1 : 0;
    return 1;
}

static void configure(const char *mode, int forwarding, int auto_delete)
{
    char path[280];
    snprintf(path, sizeof(path), "%s/qmodem", fixture_dir);
    FILE *file = fopen(path, "w");
    assert(file);
    fprintf(file, "config modem-device 'modem_1'\n"
                  " option at_port '/dev/sms-test'\n"
                  " option use_ubus '1'\n"
                  " option sms_mode '%s'\n"
                  " option sms_storage_mem1 'SM'\n"
                  " option sms_poll_interval '300'\n"
                  " option sms_auto_delete_from_sim '%d'\n"
                  " option sms_forwarding '%d'\n", mode, auto_delete, forwarding);
    fclose(file);
}

static int scalar(const char *query)
{
    sqlite3_stmt *stmt = NULL;
    assert(sqlite3_prepare_v2(app.db.sql, query, -1, &stmt, NULL) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    int value = sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    return value;
}

static const char *text(const char *name)
{
    struct json_object *value = NULL;
    assert(json_object_object_get_ex(reply, name, &value));
    return json_object_get_string(value);
}

static int number(const char *name)
{
    struct json_object *value = NULL;
    assert(json_object_object_get_ex(reply, name, &value));
    return json_object_get_int(value);
}

static int request(int deleting, const char *storage, int index, const char *pdu)
{
    struct blob_buf b = {};
    blob_buf_init(&b, 0);
    blobmsg_add_string(&b, "modem_id", "modem_1");
    if (storage) blobmsg_add_string(&b, "storage", storage);
    blobmsg_add_u32(&b, "index", index);
    if (pdu) blobmsg_add_string(&b, "pdu", pdu);
    int rc = deleting ? sim_delete_method(NULL, NULL, NULL, "sim_delete", b.head)
                      : sim_list_method(NULL, NULL, NULL, "sim_list", b.head);
    blob_buf_free(&b);
    return rc;
}

static int commands(char operation)
{
    FILE *file = fopen(log_path, "r");
    char line[64];
    int count = 0;
    if (!file) return 0;
    while (fgets(line, sizeof(line), file))
        if (!operation || line[0] == operation) count++;
    fclose(file);
    return count;
}

static void test_storage(void)
{
    const char *modes[] = { "direct", "database_poll", "database_urc" };
    setenv("SMS_TEST_CPMS", "+CPMS: \"ME\",1,100,\"SM\",0,30", 1);
    setenv("SMS_TEST_MESSAGES", "{\"msg\":[{\"index\":0,\"pdu\":\"00AB\",\"content\":\"raw\"}]}", 1);
    for (size_t i = 0; i < ARRAY_SIZE(modes); i++) {
        configure(modes[i], 0, 0);
        assert(request(0, NULL, 0, NULL) == 0);
        assert(!strcmp(text("storage"), "ME"));
        assert(!strcmp(text("mode"), modes[i]));
        assert(strstr(text("messages"), "raw"));
        int before = commands('d');
        assert(request(1, "ME", 0, "00ab") == 0);
        assert(!strcmp(text("status"), "success") && number("deleted") == 1);
        assert(commands('d') == before + 1);
        assert(scalar("SELECT count(*) FROM messages") == 0);
    }
    int before = commands('d');
    assert(request(1, "SM", 0, "00AB") == 0);
    assert(!strcmp(text("status"), "error") && commands('d') == before);
    assert(request(1, "ME", 0, "0000") == 0);
    assert(!strcmp(text("status"), "error") && commands('d') == before);
    assert(request(1, "ME", -1, "00AB") == UBUS_STATUS_INVALID_ARGUMENT);
    assert(request(1, "ME", 0, NULL) == UBUS_STATUS_INVALID_ARGUMENT);
    setenv("SMS_TEST_DELETE_FAIL", "1", 1);
    assert(request(1, "ME", 0, "00AB") == 0);
    assert(!strcmp(text("status"), "error"));
    unsetenv("SMS_TEST_DELETE_FAIL");
    before = commands('d');
    setenv("SMS_TEST_MESSAGES", "{\"msg\":[]}", 1);
    assert(request(1, "ME", 0, "00AB") == 0);
    assert(!strcmp(text("status"), "success") && number("already_absent") == 1);
    assert(commands('d') == before);
    setenv("SMS_TEST_CPMS_FAIL", "1", 1);
    assert(request(0, NULL, 0, NULL) == 0 && !strcmp(text("status"), "error"));
    unsetenv("SMS_TEST_CPMS_FAIL");
    setenv("SMS_TEST_MESSAGES", "{\"msg\":[{\"index\":0,\"pdu\":\"00AB\"}]}", 1);
    setenv("SMS_TEST_READ_FAIL", "1", 1);
    assert(request(1, "ME", 0, "00AB") == 0);
    assert(!strcmp(text("status"), "error") && commands('d') == before);
    unsetenv("SMS_TEST_READ_FAIL");
    assert(sqlite3_exec(app.db.sql,
        "CREATE TRIGGER fail_source_update BEFORE UPDATE ON source_messages BEGIN SELECT RAISE(FAIL,'test'); END;"
        "INSERT INTO modems(id) VALUES('modem_1');"
        "INSERT INTO source_messages(modem_id,storage,source_index,pdu,imported_at,committed) "
        "VALUES('modem_1','ME',0,'00AB',1,1);", NULL, NULL, NULL) == SQLITE_OK);
    assert(request(1, "ME", 0, "00AB") == 0);
    assert(!strcmp(text("status"), "error") && number("deleted") == 1);
    assert(sqlite3_exec(app.db.sql, "DROP TRIGGER fail_source_update", NULL, NULL, NULL) == SQLITE_OK);
}

static void test_scheduler(void)
{
    int64_t now = time(NULL);
    sms_segment_t partial = { .modem_id = "modem_1", .storage = "SM", .source_index = 1,
        .pdu = "0011", .sender = "10086", .timestamp = now, .content = "part 1",
        .reference = 9, .total_parts = 2, .part_number = 1 };
    sms_import_result_t imported;
    assert(sms_db_import_segment(&app.db, &partial, now - 301, 1, &imported) == 0);
    assert(!imported.published);
    assert(sms_db_record_sync(&app.db, "modem_1", "test", now, 1, NULL) == 0);
    configure("database_urc", 1, 0);
    int before = commands(0);
    scheduler_cb(NULL);
    assert(next_timeout == SCHEDULER_TICK_MS);
    assert(commands(0) == before); /* Timeout publication does not need AT I/O. */
    assert(scalar("SELECT count(*) FROM messages WHERE complete=0") == 1);
    assert(scalar("SELECT count(*) FROM deliveries") == 1);
    scheduler_cb(NULL);
    assert(scalar("SELECT count(*) FROM messages") == 1);
    assert(scalar("SELECT count(*) FROM deliveries") == 1);
    assert(sqlite3_exec(app.db.sql, "UPDATE modems SET last_sync_at=0", NULL, NULL, NULL) == SQLITE_OK);
    setenv("SMS_TEST_MESSAGES", "{\"msg\":[{\"index\":2,\"pdu\":\"0022\",\"sender\":\"10010\",\"timestamp\":1000,\"content\":\"new\"}]}", 1);
    scheduler_cb(NULL);
    assert(scalar("SELECT count(*) FROM sync_runs WHERE trigger='urc_fallback'") == 1);
    assert(scalar("SELECT count(*) FROM messages WHERE content='new'") == 1);
    before = commands(0);
    scheduler_cb(NULL);
    assert(commands(0) == before); /* Not a scan on every 30-second tick. */
    struct blob_buf event = {};
    blob_buf_init(&event, 0);
    blobmsg_add_string(&event, "port", "/dev/sms-test");
    blobmsg_add_string(&event, "owner", "qmodem.sms");
    blobmsg_add_string(&event, "urc_id", "sms-new");
    urc_event(NULL, NULL, "qmodem.at.urc", event.head);
    blob_buf_free(&event);
    assert(scalar("SELECT count(*) FROM sync_runs WHERE trigger='urc'") == 1);
    assert(scalar("SELECT count(*) FROM messages WHERE content='new'") == 1);
    configure("direct", 1, 0);
    before = commands(0);
    assert(sqlite3_exec(app.db.sql, "UPDATE modems SET last_sync_at=0", NULL, NULL, NULL) == SQLITE_OK);
    scheduler_cb(NULL);
    assert(commands(0) == before);
    configure("database_poll", 1, 0);
    scheduler_cb(NULL);
    assert(scalar("SELECT count(*) FROM sync_runs WHERE trigger='poll'") == 1);
    int history = scalar("SELECT count(*) FROM messages");
    int deliveries = scalar("SELECT count(*) FROM deliveries");
    setenv("SMS_TEST_CPMS", "+CPMS: \"SM\",1,30,\"SM\",1,30", 1);
    assert(request(1, "SM", 2, "0022") == 0 && number("deleted") == 1);
    assert(scalar("SELECT count(*) FROM source_messages WHERE pdu='0022' AND deleted_at IS NOT NULL") == 1);
    assert(scalar("SELECT count(*) FROM messages") == history);
    assert(scalar("SELECT count(*) FROM deliveries") == deliveries);
    configure("database_urc", 1, 1);
    assert(sqlite3_exec(app.db.sql, "UPDATE modems SET last_sync_at=0", NULL, NULL, NULL) == SQLITE_OK);
    setenv("SMS_TEST_MESSAGES", "{\"msg\":[{\"index\":3,\"pdu\":\"0033\",\"sender\":\"10000\",\"timestamp\":1001,\"content\":\"auto archived\"}]}", 1);
    before = commands('d');
    scheduler_cb(NULL);
    assert(commands('d') == before + 1);
    assert(scalar("SELECT count(*) FROM messages WHERE content='auto archived'") == 1);
    assert(scalar("SELECT count(*) FROM source_messages WHERE pdu='0033' AND deleted_at IS NOT NULL") == 1);
    setenv("SMS_TEST_MESSAGES", "{\"msg\":[]}", 1);
    assert(request(0, NULL, 0, NULL) == 0 && number("auto_delete") == 1);
    assert(!strcmp(text("messages"), "[ ]"));
}

int main(int argc, char **argv)
{
    if (argc > 1) return fake_tom(argc, argv);
    snprintf(fixture_dir, sizeof(fixture_dir), "/tmp/qmodem-sms-daemon-XXXXXX");
    assert(mkdtemp(fixture_dir));
    snprintf(log_path, sizeof(log_path), "%s/tom.log", fixture_dir);
    setenv("SMS_TEST_LOG", log_path, 1);
    assert(sms_db_open(&app.db, ":memory:") == 0);
    test_storage();
    test_scheduler();
    json_object_put(reply);
    sms_db_close(&app.db);
    char path[280];
    snprintf(path, sizeof(path), "%s/qmodem", fixture_dir);
    unlink(path); unlink(log_path); rmdir(fixture_dir);
    puts("PASS: daemon module APIs, deletion guards, URC recovery and independent expiry");
    return 0;
}
