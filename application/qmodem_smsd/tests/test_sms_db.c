#include "sms_db.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* The fixture uses synthetic timestamps; retention must use the same clock. */
time_t time(time_t *value)
{
    if (value) *value = 2000;
    return 2000;
}

static int scalar(sqlite3 *sql, const char *query)
{
    sqlite3_stmt *stmt = NULL;
    int value = -1;
    assert(sqlite3_prepare_v2(sql, query, -1, &stmt, NULL) == SQLITE_OK);
    if (sqlite3_step(stmt) == SQLITE_ROW)
        value = sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    return value;
}

static void test_v3_upgrade(void)
{
    char path[] = "/tmp/qmodem-sms-upgrade-XXXXXX";
    sms_db_t db;
    sqlite3_stmt *stmt = NULL;
    int fd = mkstemp(path);
    assert(fd >= 0);
    close(fd);
    assert(sms_db_open(&db, path) == 0);
    /* Recreate a v3 database with an existing read message and stable ID. */
    assert(sqlite3_exec(db.sql,
        "INSERT INTO modems(id) VALUES('modem_1');"
        "INSERT INTO messages(id,modem_id,direction,sender,timestamp,content,complete,is_read,created_at,updated_at) "
        "VALUES(42,'modem_1','received','2025550123',100,'keep',1,1,100,100);"
        "ALTER TABLE messages DROP COLUMN conversation_contact;"
        "DELETE FROM schema_migrations WHERE version=4;", NULL, NULL, NULL) == SQLITE_OK);
    sms_db_close(&db);
    assert(sms_db_open(&db, path) == 0);
    assert(scalar(db.sql, "SELECT MAX(version) FROM schema_migrations") == 4);
    assert(scalar(db.sql, "SELECT is_read FROM messages WHERE id=42 AND content='keep' AND sender='2025550123'") == 1);
    assert(scalar(db.sql, "SELECT COUNT(*) FROM messages WHERE conversation_contact IS NULL") == 1);
    assert(sqlite3_exec(db.sql,
        "INSERT INTO messages(modem_id,direction,recipient,conversation_contact,timestamp,content,complete,created_at,updated_at) "
        "VALUES('modem_1','sent','+12025550123','2025550123',101,'reply',1,101,101);",
        NULL, NULL, NULL) == SQLITE_OK);
    sms_db_close(&db);
    assert(sms_db_open(&db, path) == 0);
    assert(sqlite3_prepare_v2(db.sql,
        "SELECT recipient,conversation_contact FROM messages WHERE direction='sent'", -1, &stmt, NULL) == SQLITE_OK);
    assert(sqlite3_step(stmt) == SQLITE_ROW);
    assert(!strcmp((const char *)sqlite3_column_text(stmt, 0), "+12025550123"));
    assert(!strcmp((const char *)sqlite3_column_text(stmt, 1), "2025550123"));
    sqlite3_finalize(stmt);
    sms_db_close(&db);
    unlink(path);
}

int main(void)
{
    char path[] = "/tmp/qmodem-sms-db-XXXXXX";
    sms_db_t db;
    sms_import_result_t result;
    int fd = mkstemp(path);
    int published = 0;
    int gap = 0;
    sms_segment_t first = {
        .modem_id = "usb-1-1", .storage = "ME", .source_index = 7,
        .pdu = "PDU-A", .sender = "+100", .timestamp = 1000,
        .content = "hello ", .reference = 42, .total_parts = 2, .part_number = 1,
    };
    sms_segment_t second = {
        .modem_id = "usb-1-1", .storage = "ME", .source_index = 8,
        .pdu = "PDU-B", .sender = "+100", .timestamp = 1001,
        .content = "world", .reference = 42, .total_parts = 2, .part_number = 2,
    };

    test_v3_upgrade();
    assert(fd >= 0);
    close(fd);
    assert(sms_db_open(&db, path) == 0);
    assert(scalar(db.sql, "SELECT MAX(version) FROM schema_migrations") == 4);
    assert(scalar(db.sql, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='managed_sends'") == 1);
    assert(sms_db_record_event(&db, "usb-1-1", 10, 1, &gap) == 0 && !gap);
    assert(sms_db_record_event(&db, "usb-1-1", 10, 2, &gap) == 0 && !gap);
    assert(sms_db_record_event(&db, "usb-1-1", 10, 4, &gap) == 0 && gap);
    assert(sms_db_record_event(&db, "usb-1-1", 11, 1, &gap) == 0 && gap);
    assert(!strcmp((const char *)sqlite3_db_filename(db.sql, "main"), path));
    assert(sms_db_import_segment(&db, &first, 2000, 1, &result) == 0);
    assert(result.safe_to_delete && !result.published);
    assert(scalar(db.sql, "SELECT count(*) FROM messages") == 0);
    assert(sms_db_prune(&db, "usb-1-1", 100, 100) == 0);
    assert(scalar(db.sql, "SELECT count(*) FROM multipart_groups") == 1);
    assert(scalar(db.sql, "SELECT count(*) FROM segments") == 1);
    sms_db_close(&db);

    assert(sms_db_open(&db, path) == 0);
    assert(sms_db_import_segment(&db, &first, 2001, 1, &result) == 0);
    assert(result.duplicate && result.safe_to_delete);
    assert(scalar(db.sql, "SELECT count(*) FROM source_messages") == 1);
    sms_db_set_multipart_windows(&db, 10, 3600);
    assert(sms_db_publish_expired(&db, "usb-1-1", 2011, 1, &published) == 0);
    assert(published == 1);
    assert(scalar(db.sql, "SELECT complete FROM messages") == 0);
    assert(scalar(db.sql, "SELECT revision FROM messages") == 1);
    assert(scalar(db.sql, "SELECT count(*) FROM deliveries") == 1);

    assert(sms_db_import_segment(&db, &second, 2400, 1, &result) == 0);
    assert(result.safe_to_delete && result.published && result.revision == 2);
    assert(scalar(db.sql, "SELECT complete FROM messages") == 1);
    assert(scalar(db.sql, "SELECT revision FROM messages") == 2);
    assert(scalar(db.sql, "SELECT count(*) FROM deliveries") == 2);
    {
        sqlite3_stmt *stmt = NULL;
        assert(sqlite3_prepare_v2(db.sql, "SELECT content FROM messages", -1,
                                  &stmt, NULL) == SQLITE_OK);
        assert(sqlite3_step(stmt) == SQLITE_ROW);
        assert(!strcmp((const char *)sqlite3_column_text(stmt, 0), "hello world"));
        sqlite3_finalize(stmt);
    }
	{
		int deleted = 0;
		int64_t original_message_id = result.message_id;
		sms_segment_t reused_first = first;
		sms_segment_t reused_second = second;

		reused_first.source_index = 11;
		reused_first.pdu = "PDU-REUSED-A";
		reused_first.timestamp = 2450;
		reused_first.content = "fresh ";
		reused_second.source_index = 12;
		reused_second.pdu = "PDU-REUSED-B";
		reused_second.timestamp = 2451;
		reused_second.content = "message";
		assert(sms_db_import_segment(&db, &reused_first, 2450, 1, &result) == 0);
		assert(!result.published);
		assert(sms_db_import_segment(&db, &reused_second, 2451, 1, &result) == 0);
		assert(result.published && result.message_id != original_message_id);
		assert(scalar(db.sql, "SELECT count(*) FROM messages") == 2);
		assert(scalar(db.sql, "SELECT count(*) FROM multipart_groups") == 2);
		assert(scalar(db.sql, "SELECT count(*) FROM deliveries") == 3);
		assert(sms_db_delete_message(&db, "usb-1-1", result.message_id, &deleted) == 0);
		assert(deleted == 1);
		result.message_id = original_message_id;
	}
	{
		int deleted = 0;
		assert(sms_db_delete_message(&db, "usb-1-1", result.message_id, &deleted) == 0);
		assert(deleted == 1);
		assert(sms_db_publish_expired(&db, "usb-1-1", 2500, 1, &published) == 0);
		assert(scalar(db.sql, "SELECT count(*) FROM messages") == 0);
	}

    second.source_index = 9;
    second.pdu = "PDU-C";
    second.part_number = 1;
    second.content = "new";
    assert(sms_db_import_segment(&db, &second, 7001, 0, &result) == 0);
    assert(scalar(db.sql, "SELECT count(*) FROM multipart_groups") == 1);
    {
        sms_segment_t single = {
            .modem_id = "usb-1-1", .storage = "ME", .source_index = 10,
            .pdu = "PDU-D", .sender = "+101", .timestamp = 7002,
            .content = "single", .total_parts = 1, .part_number = 1,
        };
        assert(sms_db_import_segment(&db, &single, 7002, 0, &result) == 0);
        assert(sms_db_finish_scan(&db, "usb-1-1", "ME", 7003) == 0);
        assert(scalar(db.sql,
            "SELECT count(*) FROM source_messages WHERE pdu='PDU-D'") == 0);
        assert(scalar(db.sql,
            "SELECT count(*) FROM source_messages WHERE pdu='PDU-C'") == 1);
    }
    assert(scalar(db.sql, "PRAGMA foreign_keys") == 1);
    assert(sms_db_checkpoint(&db) == 0);
    {
        char wal[256];
        struct stat info;
        snprintf(wal, sizeof(wal), "%s-wal", path);
        assert(stat(wal, &info) != 0 || info.st_size == 0);
    }
    sms_db_close(&db);
    unlink(path);
    {
        char wal[256];
        snprintf(wal, sizeof(wal), "%s-wal", path); unlink(wal);
        snprintf(wal, sizeof(wal), "%s-shm", path); unlink(wal);
    }
    puts("PASS durable idempotent multipart import, timeout, and late revision");
    return 0;
}
