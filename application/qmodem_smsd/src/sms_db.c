#include "sms_db.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MULTIPART_WAIT_SECONDS 300
#define LATE_FRAGMENT_SECONDS 3600

static const char schema_sql[] =
    "PRAGMA foreign_keys=ON;"
    "PRAGMA journal_mode=WAL;"
    "PRAGMA synchronous=FULL;"
    "CREATE TABLE IF NOT EXISTS schema_migrations("
      "version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);"
    "INSERT OR IGNORE INTO schema_migrations VALUES(1,strftime('%s','now'));"
    "CREATE TABLE IF NOT EXISTS modems("
      "id TEXT PRIMARY KEY, mode TEXT NOT NULL DEFAULT 'database_poll',"
      "migration_error TEXT, last_sync_at INTEGER, last_event_sequence INTEGER);"
    "CREATE TABLE IF NOT EXISTS sync_runs("
      "id INTEGER PRIMARY KEY, modem_id TEXT NOT NULL, trigger TEXT NOT NULL,"
      "started_at INTEGER NOT NULL, finished_at INTEGER, imported INTEGER DEFAULT 0,"
      "error TEXT);"
    "CREATE TABLE IF NOT EXISTS multipart_groups("
      "id INTEGER PRIMARY KEY, modem_id TEXT NOT NULL, sender TEXT NOT NULL,"
      "reference INTEGER NOT NULL, total_parts INTEGER NOT NULL,"
      "first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,"
      "UNIQUE(id,modem_id));"
    "CREATE INDEX IF NOT EXISTS groups_lookup ON multipart_groups("
      "modem_id,sender,reference,total_parts,last_seen);"
    "CREATE TABLE IF NOT EXISTS source_messages("
      "id INTEGER PRIMARY KEY, modem_id TEXT NOT NULL, storage TEXT NOT NULL,"
      "source_index INTEGER NOT NULL, pdu TEXT NOT NULL, imported_at INTEGER NOT NULL,"
      "committed INTEGER NOT NULL DEFAULT 0, deleted_at INTEGER,"
      "UNIQUE(modem_id,storage,source_index,pdu));"
    "CREATE TABLE IF NOT EXISTS segments("
      "id INTEGER PRIMARY KEY, group_id INTEGER NOT NULL REFERENCES multipart_groups(id),"
      "source_id INTEGER NOT NULL REFERENCES source_messages(id), part_number INTEGER NOT NULL,"
      "timestamp INTEGER NOT NULL, content TEXT NOT NULL,"
      "UNIQUE(group_id,part_number));"
    "CREATE TABLE IF NOT EXISTS messages("
      "id INTEGER PRIMARY KEY, modem_id TEXT NOT NULL, direction TEXT NOT NULL,"
      "sender TEXT, recipient TEXT, timestamp INTEGER NOT NULL, content TEXT NOT NULL,"
      "group_id INTEGER UNIQUE REFERENCES multipart_groups(id), complete INTEGER NOT NULL,"
      "revision INTEGER NOT NULL DEFAULT 1, is_read INTEGER NOT NULL DEFAULT 0,"
      "send_success INTEGER, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);"
    "CREATE INDEX IF NOT EXISTS messages_modem_time ON messages(modem_id,timestamp DESC,id DESC);"
    "CREATE TABLE IF NOT EXISTS deliveries("
      "id INTEGER PRIMARY KEY, message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,"
      "revision INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,"
      "available_at INTEGER NOT NULL, claimed_at INTEGER, completed_at INTEGER, last_error TEXT,"
      "UNIQUE(message_id,revision));"
    "CREATE INDEX IF NOT EXISTS deliveries_claim ON deliveries(state,available_at,id);"
    "CREATE TABLE IF NOT EXISTS managed_sends("
      "request_id TEXT PRIMARY KEY, modem_id TEXT NOT NULL, recipient TEXT NOT NULL,"
      "content TEXT NOT NULL, state TEXT NOT NULL, parts INTEGER NOT NULL DEFAULT 0,"
      "error TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);"
    "CREATE TABLE IF NOT EXISTS legacy_imports("
      "path TEXT NOT NULL, record_key TEXT NOT NULL, imported_at INTEGER NOT NULL,"
      "PRIMARY KEY(path,record_key));";

static int exec_sql(sqlite3 *sql, const char *statement)
{
    return sqlite3_exec(sql, statement, NULL, NULL, NULL) == SQLITE_OK ? 0 : -1;
}

static int bind_text(sqlite3_stmt *stmt, int index, const char *value);
static int ensure_modem(sqlite3 *sql, const char *modem_id);

static int apply_migrations(sqlite3 *sql)
{
    sqlite3_stmt *stmt = NULL;
    int version = 0, has_epoch = 0;
    if (sqlite3_prepare_v2(sql, "SELECT COALESCE(MAX(version),0) FROM schema_migrations",
                          -1, &stmt, NULL) != SQLITE_OK)
        return -1;
    if (sqlite3_step(stmt) == SQLITE_ROW)
        version = sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    if (version < 2) {
        if (sqlite3_prepare_v2(sql, "PRAGMA table_info(modems)", -1, &stmt, NULL) != SQLITE_OK)
            return -1;
        while (sqlite3_step(stmt) == SQLITE_ROW)
            if (!strcmp((const char *)sqlite3_column_text(stmt, 1), "last_event_epoch"))
                has_epoch = 1;
        sqlite3_finalize(stmt); stmt = NULL;
        if (exec_sql(sql, "BEGIN IMMEDIATE") != 0)
            return -1;
        if ((!has_epoch && exec_sql(sql,
                "ALTER TABLE modems ADD COLUMN last_event_epoch INTEGER") != 0) ||
            exec_sql(sql, "INSERT OR REPLACE INTO schema_migrations "
                          "VALUES(2,strftime('%s','now'))") != 0 ||
            exec_sql(sql, "COMMIT") != 0) {
            exec_sql(sql, "ROLLBACK");
            return -1;
        }
    }
    if (version < 3) {
        if (exec_sql(sql, "BEGIN IMMEDIATE") != 0)
            return -1;
        if (exec_sql(sql,
                "CREATE TABLE IF NOT EXISTS managed_sends("
                "request_id TEXT PRIMARY KEY,modem_id TEXT NOT NULL,recipient TEXT NOT NULL,"
                "content TEXT NOT NULL,state TEXT NOT NULL,parts INTEGER NOT NULL DEFAULT 0,"
                "error TEXT,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL)") != 0 ||
            exec_sql(sql, "INSERT OR REPLACE INTO schema_migrations "
                          "VALUES(3,strftime('%s','now'))") != 0 ||
            exec_sql(sql, "COMMIT") != 0) {
            exec_sql(sql, "ROLLBACK");
            return -1;
        }
    }
    if (version < 4) {
        if (exec_sql(sql, "BEGIN IMMEDIATE") != 0)
            return -1;
        if (exec_sql(sql, "ALTER TABLE messages ADD COLUMN conversation_contact TEXT") != 0 ||
            exec_sql(sql, "INSERT OR REPLACE INTO schema_migrations "
                          "VALUES(4,strftime('%s','now'))") != 0 ||
            exec_sql(sql, "COMMIT") != 0) {
            exec_sql(sql, "ROLLBACK");
            return -1;
        }
    }
    return 0;
}

int sms_db_open(sms_db_t *db, const char *path)
{
    memset(db, 0, sizeof(*db));
    db->multipart_wait = MULTIPART_WAIT_SECONDS;
    db->late_fragment_window = LATE_FRAGMENT_SECONDS;
    if (sqlite3_open_v2(path, &db->sql,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                        NULL) != SQLITE_OK)
        return -1;
    sqlite3_busy_timeout(db->sql, 5000);
    if (sqlite3_wal_autocheckpoint(db->sql, 64) != SQLITE_OK) {
        sms_db_close(db);
        return -1;
    }
    if (exec_sql(db->sql, schema_sql) != 0 || apply_migrations(db->sql) != 0) {
        sms_db_close(db);
        return -1;
    }
    return 0;
}

int sms_db_checkpoint(sms_db_t *db)
{
    int log_frames = 0, checkpointed_frames = 0;

    if (!db || !db->sql)
        return -1;
    return sqlite3_wal_checkpoint_v2(db->sql, NULL, SQLITE_CHECKPOINT_TRUNCATE,
                                     &log_frames, &checkpointed_frames) == SQLITE_OK
        ? 0 : -1;
}

int sms_db_record_event(sms_db_t *db, const char *modem_id, int64_t epoch,
                        int64_t sequence, int *gap)
{
    sqlite3_stmt *stmt = NULL;
    int64_t previous_epoch = 0, previous_sequence = 0;
    *gap = 0;
    if (ensure_modem(db->sql, modem_id) != 0 ||
        sqlite3_prepare_v2(db->sql,
            "SELECT COALESCE(last_event_epoch,0),COALESCE(last_event_sequence,0) "
            "FROM modems WHERE id=?", -1, &stmt, NULL) != SQLITE_OK)
        return -1;
    bind_text(stmt, 1, modem_id);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        previous_epoch = sqlite3_column_int64(stmt, 0);
        previous_sequence = sqlite3_column_int64(stmt, 1);
    }
    sqlite3_finalize(stmt); stmt = NULL;
    *gap = previous_epoch != 0 && (epoch != previous_epoch || sequence != previous_sequence + 1);
    if (sqlite3_prepare_v2(db->sql,
            "UPDATE modems SET last_event_epoch=?,last_event_sequence=? WHERE id=?",
            -1, &stmt, NULL) != SQLITE_OK)
        return -1;
    sqlite3_bind_int64(stmt, 1, epoch);
    sqlite3_bind_int64(stmt, 2, sequence);
    bind_text(stmt, 3, modem_id);
    if (sqlite3_step(stmt) != SQLITE_DONE) {
        sqlite3_finalize(stmt);
        return -1;
    }
    sqlite3_finalize(stmt);
    return 0;
}

void sms_db_set_multipart_windows(sms_db_t *db, int wait_seconds,
                                  int late_seconds)
{
    if (!db)
        return;
    if (wait_seconds > 0)
        db->multipart_wait = wait_seconds;
    if (late_seconds > 0)
        db->late_fragment_window = late_seconds;
}

void sms_db_close(sms_db_t *db)
{
    if (db->sql)
        sqlite3_close(db->sql);
    db->sql = NULL;
}

const char *sms_db_error(sms_db_t *db)
{
    return db->sql ? sqlite3_errmsg(db->sql) : "database closed";
}

static int bind_text(sqlite3_stmt *stmt, int index, const char *value)
{
    return sqlite3_bind_text(stmt, index, value ? value : "", -1, SQLITE_TRANSIENT);
}

static int ensure_modem(sqlite3 *sql, const char *modem_id)
{
    sqlite3_stmt *stmt = NULL;
    int result = -1;
    if (sqlite3_prepare_v2(sql, "INSERT OR IGNORE INTO modems(id) VALUES(?)", -1,
                           &stmt, NULL) != SQLITE_OK)
        return -1;
    bind_text(stmt, 1, modem_id);
    if (sqlite3_step(stmt) == SQLITE_DONE)
        result = 0;
    sqlite3_finalize(stmt);
    return result;
}

static int find_group(sms_db_t *db, const sms_segment_t *segment, int64_t now,
                      int64_t *group_id)
{
    sqlite3_stmt *stmt = NULL;
    const char *query =
        "SELECT g.id FROM multipart_groups g LEFT JOIN messages m ON m.group_id=g.id "
        "WHERE g.modem_id=? AND g.sender=? AND g.reference=? "
        "AND g.total_parts=? AND g.last_seen>=? AND (m.id IS NULL OR m.complete=0) "
        "ORDER BY g.last_seen DESC,g.id DESC LIMIT 1";
    if (sqlite3_prepare_v2(db->sql, query, -1, &stmt, NULL) != SQLITE_OK)
        return -1;
    bind_text(stmt, 1, segment->modem_id);
    bind_text(stmt, 2, segment->sender);
    sqlite3_bind_int(stmt, 3, segment->reference);
    sqlite3_bind_int(stmt, 4, segment->total_parts);
    sqlite3_bind_int64(stmt, 5, now - db->late_fragment_window);
    if (sqlite3_step(stmt) == SQLITE_ROW)
        *group_id = sqlite3_column_int64(stmt, 0);
    else
        *group_id = 0;
    sqlite3_finalize(stmt);
    if (*group_id)
        return 0;
    if (sqlite3_prepare_v2(db->sql,
            "INSERT INTO multipart_groups(modem_id,sender,reference,total_parts,first_seen,last_seen) "
            "VALUES(?,?,?,?,?,?)", -1, &stmt, NULL) != SQLITE_OK)
        return -1;
    bind_text(stmt, 1, segment->modem_id);
    bind_text(stmt, 2, segment->sender);
    sqlite3_bind_int(stmt, 3, segment->reference);
    sqlite3_bind_int(stmt, 4, segment->total_parts);
    sqlite3_bind_int64(stmt, 5, now);
    sqlite3_bind_int64(stmt, 6, now);
    if (sqlite3_step(stmt) != SQLITE_DONE) {
        sqlite3_finalize(stmt);
        return -1;
    }
    *group_id = sqlite3_last_insert_rowid(db->sql);
    sqlite3_finalize(stmt);
    return 0;
}

static char *group_content(sqlite3 *sql, int64_t group_id, int *part_count,
                           int64_t *timestamp)
{
    sqlite3_stmt *stmt = NULL;
    char *content = NULL;
    size_t used = 0;
    *part_count = 0;
    *timestamp = 0;
    if (sqlite3_prepare_v2(sql,
            "SELECT content,timestamp FROM segments WHERE group_id=? ORDER BY part_number", -1,
            &stmt, NULL) != SQLITE_OK)
        return NULL;
    sqlite3_bind_int64(stmt, 1, group_id);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *part = (const char *)sqlite3_column_text(stmt, 0);
        size_t length = strlen(part ? part : "");
        char *grown = realloc(content, used + length + 1);
        if (!grown) {
            free(content);
            sqlite3_finalize(stmt);
            return NULL;
        }
        content = grown;
        memcpy(content + used, part ? part : "", length);
        used += length;
        content[used] = '\0';
        if (*part_count == 0 || sqlite3_column_int64(stmt, 1) < *timestamp)
            *timestamp = sqlite3_column_int64(stmt, 1);
        (*part_count)++;
    }
    sqlite3_finalize(stmt);
    if (!content)
        content = strdup("");
    return content;
}

static int queue_delivery(sqlite3 *sql, int64_t message_id, int revision, int64_t now)
{
    sqlite3_stmt *stmt = NULL;
    int result = -1;
    if (sqlite3_prepare_v2(sql,
            "INSERT OR IGNORE INTO deliveries(message_id,revision,available_at) VALUES(?,?,?)",
            -1, &stmt, NULL) != SQLITE_OK)
        return -1;
    sqlite3_bind_int64(stmt, 1, message_id);
    sqlite3_bind_int(stmt, 2, revision);
    sqlite3_bind_int64(stmt, 3, now);
    if (sqlite3_step(stmt) == SQLITE_DONE)
        result = 0;
    sqlite3_finalize(stmt);
    return result;
}

static int publish_group(sqlite3 *sql, int64_t group_id, int64_t now,
                         int forwarding_enabled, sms_import_result_t *result)
{
    sqlite3_stmt *stmt = NULL;
    char modem_id[128] = "";
    char sender[128] = "";
    int total_parts = 0, part_count = 0, complete, revision = 1;
    int64_t timestamp = 0, message_id = 0;
    char *content = NULL;

    if (sqlite3_prepare_v2(sql,
            "SELECT modem_id,sender,total_parts FROM multipart_groups WHERE id=?", -1,
            &stmt, NULL) != SQLITE_OK)
        return -1;
    sqlite3_bind_int64(stmt, 1, group_id);
    if (sqlite3_step(stmt) != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        return -1;
    }
    snprintf(modem_id, sizeof(modem_id), "%s", sqlite3_column_text(stmt, 0));
    snprintf(sender, sizeof(sender), "%s", sqlite3_column_text(stmt, 1));
    total_parts = sqlite3_column_int(stmt, 2);
    sqlite3_finalize(stmt);
    content = group_content(sql, group_id, &part_count, &timestamp);
    if (!content)
        return -1;
    complete = part_count >= total_parts;

    if (sqlite3_prepare_v2(sql,
            "SELECT id,content,complete,revision FROM messages WHERE group_id=?", -1,
            &stmt, NULL) != SQLITE_OK)
        goto fail;
    sqlite3_bind_int64(stmt, 1, group_id);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *old_content = (const char *)sqlite3_column_text(stmt, 1);
        message_id = sqlite3_column_int64(stmt, 0);
        revision = sqlite3_column_int(stmt, 3);
        if (!strcmp(old_content ? old_content : "", content) &&
            sqlite3_column_int(stmt, 2) == complete) {
            sqlite3_finalize(stmt);
            free(content);
            if (result) {
                result->message_id = message_id;
                result->published = 1;
                result->revision = revision;
            }
            return 0;
        }
        revision++;
        sqlite3_finalize(stmt);
        if (sqlite3_prepare_v2(sql,
                "UPDATE messages SET content=?,complete=?,revision=?,updated_at=? WHERE id=?",
                -1, &stmt, NULL) != SQLITE_OK)
            goto fail;
        bind_text(stmt, 1, content);
        sqlite3_bind_int(stmt, 2, complete);
        sqlite3_bind_int(stmt, 3, revision);
        sqlite3_bind_int64(stmt, 4, now);
        sqlite3_bind_int64(stmt, 5, message_id);
    } else {
        sqlite3_finalize(stmt);
        stmt = NULL;
        if (sqlite3_prepare_v2(sql,
                "INSERT INTO messages(modem_id,direction,sender,timestamp,content,group_id,complete,created_at,updated_at) "
                "VALUES(?,'received',?,?,?,?,?,?,?)", -1, &stmt, NULL) != SQLITE_OK)
            goto fail;
        bind_text(stmt, 1, modem_id);
        bind_text(stmt, 2, sender);
        sqlite3_bind_int64(stmt, 3, timestamp);
        bind_text(stmt, 4, content);
        sqlite3_bind_int64(stmt, 5, group_id);
        sqlite3_bind_int(stmt, 6, complete);
        sqlite3_bind_int64(stmt, 7, now);
        sqlite3_bind_int64(stmt, 8, now);
    }
    if (sqlite3_step(stmt) != SQLITE_DONE)
        goto fail;
    if (!message_id)
        message_id = sqlite3_last_insert_rowid(sql);
    sqlite3_finalize(stmt);
    stmt = NULL;
    if (forwarding_enabled && queue_delivery(sql, message_id, revision, now) != 0)
        goto fail;
    if (result) {
        result->message_id = message_id;
        result->published = 1;
        result->revision = revision;
    }
    free(content);
    return 0;

fail:
    sqlite3_finalize(stmt);
    free(content);
    return -1;
}

static int insert_single_message(sqlite3 *sql, const sms_segment_t *segment,
                                 int64_t now, int forwarding_enabled,
                                 sms_import_result_t *result)
{
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(sql,
            "INSERT INTO messages(modem_id,direction,sender,timestamp,content,complete,created_at,updated_at) "
            "VALUES(?,'received',?,?,?,1,?,?)", -1, &stmt, NULL) != SQLITE_OK)
        return -1;
    bind_text(stmt, 1, segment->modem_id);
    bind_text(stmt, 2, segment->sender);
    sqlite3_bind_int64(stmt, 3, segment->timestamp);
    bind_text(stmt, 4, segment->content);
    sqlite3_bind_int64(stmt, 5, now);
    sqlite3_bind_int64(stmt, 6, now);
    if (sqlite3_step(stmt) != SQLITE_DONE) {
        sqlite3_finalize(stmt);
        return -1;
    }
    result->message_id = sqlite3_last_insert_rowid(sql);
    result->published = 1;
    result->revision = 1;
    sqlite3_finalize(stmt);
    if (forwarding_enabled)
        return queue_delivery(sql, result->message_id, 1, now);
    return 0;
}

int sms_db_import_segment(sms_db_t *db, const sms_segment_t *segment,
                          int64_t now, int forwarding_enabled,
                          sms_import_result_t *result)
{
    sqlite3_stmt *stmt = NULL;
    int64_t source_id, group_id = 0;
    int total = segment->total_parts > 1 ? segment->total_parts : 1;
    int rc = -1;

    memset(result, 0, sizeof(*result));
    if (!db || !db->sql || !segment || !segment->modem_id || !segment->pdu ||
        !segment->sender || !segment->content || segment->source_index < 0)
        return -1;
    if (exec_sql(db->sql, "BEGIN IMMEDIATE") != 0)
        return -1;
    if (ensure_modem(db->sql, segment->modem_id) != 0)
        goto rollback;
    if (sqlite3_prepare_v2(db->sql,
            "SELECT id,committed FROM source_messages WHERE modem_id=? AND storage=? AND source_index=? AND pdu=?",
            -1, &stmt, NULL) != SQLITE_OK)
        goto rollback;
    bind_text(stmt, 1, segment->modem_id);
    bind_text(stmt, 2, segment->storage);
    sqlite3_bind_int(stmt, 3, segment->source_index);
    bind_text(stmt, 4, segment->pdu);
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        result->duplicate = 1;
        result->source_id = sqlite3_column_int64(stmt, 0);
        result->safe_to_delete = sqlite3_column_int(stmt, 1) == 1;
        sqlite3_finalize(stmt);
        stmt = NULL;
        if (sqlite3_prepare_v2(db->sql,
                "UPDATE source_messages SET imported_at=? WHERE id=?",
                -1, &stmt, NULL) != SQLITE_OK)
            goto rollback;
        sqlite3_bind_int64(stmt, 1, now);
        sqlite3_bind_int64(stmt, 2, result->source_id);
        if (sqlite3_step(stmt) != SQLITE_DONE)
            goto rollback;
        sqlite3_finalize(stmt);
        stmt = NULL;
        if (exec_sql(db->sql, "COMMIT") != 0)
            return -1;
        return 0;
    }
    sqlite3_finalize(stmt);
    stmt = NULL;
    if (sqlite3_prepare_v2(db->sql,
            "INSERT INTO source_messages(modem_id,storage,source_index,pdu,imported_at) VALUES(?,?,?,?,?)",
            -1, &stmt, NULL) != SQLITE_OK)
        goto rollback;
    bind_text(stmt, 1, segment->modem_id);
    bind_text(stmt, 2, segment->storage);
    sqlite3_bind_int(stmt, 3, segment->source_index);
    bind_text(stmt, 4, segment->pdu);
    sqlite3_bind_int64(stmt, 5, now);
    if (sqlite3_step(stmt) != SQLITE_DONE)
        goto rollback;
    source_id = sqlite3_last_insert_rowid(db->sql);
    result->source_id = source_id;
    sqlite3_finalize(stmt);
    stmt = NULL;

    if (total > 1) {
        if (segment->part_number < 1 || segment->part_number > total ||
            find_group(db, segment, now, &group_id) != 0)
            goto rollback;
        if (sqlite3_prepare_v2(db->sql,
                "INSERT OR IGNORE INTO segments(group_id,source_id,part_number,timestamp,content) VALUES(?,?,?,?,?)",
                -1, &stmt, NULL) != SQLITE_OK)
            goto rollback;
        sqlite3_bind_int64(stmt, 1, group_id);
        sqlite3_bind_int64(stmt, 2, source_id);
        sqlite3_bind_int(stmt, 3, segment->part_number);
        sqlite3_bind_int64(stmt, 4, segment->timestamp);
        bind_text(stmt, 5, segment->content);
        if (sqlite3_step(stmt) != SQLITE_DONE)
            goto rollback;
        sqlite3_finalize(stmt);
        stmt = NULL;
        if (sqlite3_prepare_v2(db->sql,
                "UPDATE multipart_groups SET last_seen=? WHERE id=?", -1, &stmt, NULL) != SQLITE_OK)
            goto rollback;
        sqlite3_bind_int64(stmt, 1, now);
        sqlite3_bind_int64(stmt, 2, group_id);
        if (sqlite3_step(stmt) != SQLITE_DONE)
            goto rollback;
        sqlite3_finalize(stmt);
        stmt = NULL;
        {
            sqlite3_stmt *count_stmt = NULL;
            int count = 0;
            if (sqlite3_prepare_v2(db->sql, "SELECT count(*) FROM segments WHERE group_id=?",
                                   -1, &count_stmt, NULL) != SQLITE_OK)
                goto rollback;
            sqlite3_bind_int64(count_stmt, 1, group_id);
            if (sqlite3_step(count_stmt) == SQLITE_ROW)
                count = sqlite3_column_int(count_stmt, 0);
            sqlite3_finalize(count_stmt);
            if (count >= total && publish_group(db->sql, group_id, now,
                                                forwarding_enabled, result) != 0)
                goto rollback;
        }
    } else if (insert_single_message(db->sql, segment, now, forwarding_enabled,
                                     result) != 0) {
        goto rollback;
    }
    if (sqlite3_prepare_v2(db->sql,
            "UPDATE source_messages SET committed=1 WHERE id=?", -1, &stmt, NULL) != SQLITE_OK)
        goto rollback;
    sqlite3_bind_int64(stmt, 1, source_id);
    if (sqlite3_step(stmt) != SQLITE_DONE)
        goto rollback;
    sqlite3_finalize(stmt);
    stmt = NULL;
    if (exec_sql(db->sql, "COMMIT") != 0)
        return -1;
    result->safe_to_delete = 1;
    return 0;

rollback:
    sqlite3_finalize(stmt);
    exec_sql(db->sql, "ROLLBACK");
    return rc;
}

int sms_db_publish_expired(sms_db_t *db, const char *modem_id, int64_t now,
                           int forwarding_enabled, int *published_count)
{
    sqlite3_stmt *stmt = NULL;
    int64_t *groups = NULL;
    size_t count = 0;
    int rc = -1;

    *published_count = 0;
    if (exec_sql(db->sql, "BEGIN IMMEDIATE") != 0)
        return -1;
    if (sqlite3_prepare_v2(db->sql,
            "SELECT g.id FROM multipart_groups g LEFT JOIN messages m ON m.group_id=g.id "
            "WHERE g.modem_id=? AND g.first_seen<=? AND (m.id IS NULL OR m.complete=0)",
            -1, &stmt, NULL) != SQLITE_OK)
        goto out;
    bind_text(stmt, 1, modem_id);
    sqlite3_bind_int64(stmt, 2, now - db->multipart_wait);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        int64_t *grown = realloc(groups, (count + 1) * sizeof(*groups));
        if (!grown)
            goto out;
        groups = grown;
        groups[count++] = sqlite3_column_int64(stmt, 0);
    }
    sqlite3_finalize(stmt);
    stmt = NULL;
    for (size_t i = 0; i < count; i++) {
        sms_import_result_t result = { 0 };
        if (publish_group(db->sql, groups[i], now, forwarding_enabled, &result) != 0)
            goto out;
        if (result.published)
            (*published_count)++;
    }
    if (exec_sql(db->sql, "COMMIT") != 0)
        goto out_no_rollback;
    rc = 0;
    goto out_no_rollback;

out:
    sqlite3_finalize(stmt);
    exec_sql(db->sql, "ROLLBACK");
out_no_rollback:
    free(groups);
    return rc;
}

int sms_db_record_sync(sms_db_t *db, const char *modem_id, const char *trigger,
                       int64_t started_at, int imported, const char *error)
{
    sqlite3_stmt *stmt = NULL;
    int rc = -1;

    if (exec_sql(db->sql, "BEGIN IMMEDIATE") != 0 ||
        ensure_modem(db->sql, modem_id) != 0)
        goto out;
    if (sqlite3_prepare_v2(db->sql,
            "INSERT INTO sync_runs(modem_id,trigger,started_at,finished_at,imported,error) "
            "VALUES(?,?,?,strftime('%s','now'),?,?)", -1, &stmt, NULL) != SQLITE_OK)
        goto rollback;
    bind_text(stmt, 1, modem_id);
    bind_text(stmt, 2, trigger);
    sqlite3_bind_int64(stmt, 3, started_at);
    sqlite3_bind_int(stmt, 4, imported);
    if (error && *error)
        bind_text(stmt, 5, error);
    else
        sqlite3_bind_null(stmt, 5);
    if (sqlite3_step(stmt) != SQLITE_DONE)
        goto rollback;
    sqlite3_finalize(stmt);
    stmt = NULL;
    if (sqlite3_prepare_v2(db->sql,
            "UPDATE modems SET last_sync_at=strftime('%s','now') WHERE id=?", -1,
            &stmt, NULL) != SQLITE_OK)
        goto rollback;
    bind_text(stmt, 1, modem_id);
    if (sqlite3_step(stmt) != SQLITE_DONE)
        goto rollback;
    sqlite3_finalize(stmt);
    stmt = NULL;
    if (exec_sql(db->sql, "COMMIT") == 0)
        rc = 0;
    return rc;
rollback:
    sqlite3_finalize(stmt);
    exec_sql(db->sql, "ROLLBACK");
out:
    return -1;
}

int sms_db_finish_scan(sms_db_t *db, const char *modem_id, const char *storage,
                       int64_t started_at)
{
    sqlite3_stmt *stmt = NULL;
    int rc = -1;

    if (sqlite3_prepare_v2(db->sql,
            "DELETE FROM source_messages WHERE modem_id=? AND storage=? "
            "AND committed=1 AND imported_at<? AND NOT EXISTS "
            "(SELECT 1 FROM segments WHERE source_id=source_messages.id)",
            -1, &stmt, NULL) != SQLITE_OK)
        return -1;
    bind_text(stmt, 1, modem_id);
    bind_text(stmt, 2, storage);
    sqlite3_bind_int64(stmt, 3, started_at);
    if (sqlite3_step(stmt) == SQLITE_DONE)
        rc = 0;
    sqlite3_finalize(stmt);
    return rc;
}

int sms_db_migration_error(sms_db_t *db, const char *modem_id,
                           char *error, size_t error_size)
{
    sqlite3_stmt *stmt = NULL;
    int found = 0;

    if (!error || !error_size || sqlite3_prepare_v2(db->sql,
            "SELECT migration_error FROM modems WHERE id=?", -1, &stmt, NULL) != SQLITE_OK)
        return -1;
    bind_text(stmt, 1, modem_id);
    error[0] = '\0';
    if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL) {
        snprintf(error, error_size, "%s", (const char *)sqlite3_column_text(stmt, 0));
        found = 1;
    }
    sqlite3_finalize(stmt);
    return found;
}

static int prune_direction(sqlite3 *sql, const char *modem_id,
                           const char *direction, int limit)
{
    sqlite3_stmt *stmt = NULL;
    int rc = -1;
    if (sqlite3_prepare_v2(sql,
            "DELETE FROM messages WHERE modem_id=? AND direction=? AND id NOT IN "
            "(SELECT id FROM messages WHERE modem_id=? AND direction=? "
            "ORDER BY timestamp DESC,id DESC LIMIT ?)", -1, &stmt, NULL) != SQLITE_OK)
        return -1;
    bind_text(stmt, 1, modem_id);
    bind_text(stmt, 2, direction);
    bind_text(stmt, 3, modem_id);
    bind_text(stmt, 4, direction);
    sqlite3_bind_int(stmt, 5, limit);
    if (sqlite3_step(stmt) == SQLITE_DONE)
        rc = 0;
    sqlite3_finalize(stmt);
    return rc;
}

int sms_db_prune(sms_db_t *db, const char *modem_id,
                 int received_limit, int sent_limit)
{
    sqlite3_stmt *stmt = NULL;
    int64_t orphan_before;

    if (received_limit < 1 || sent_limit < 1 ||
        exec_sql(db->sql, "BEGIN IMMEDIATE") != 0)
        return -1;
    if (prune_direction(db->sql, modem_id, "received", received_limit) != 0 ||
        prune_direction(db->sql, modem_id, "sent", sent_limit) != 0)
        goto fail;

    orphan_before = (int64_t)time(NULL) -
        (db->late_fragment_window > db->multipart_wait ?
         db->late_fragment_window : db->multipart_wait);
    if (sqlite3_prepare_v2(db->sql,
            "DELETE FROM segments WHERE group_id IN ("
            "SELECT g.id FROM multipart_groups g LEFT JOIN messages m ON m.group_id=g.id "
            "WHERE m.id IS NULL AND g.last_seen<?)", -1, &stmt, NULL) != SQLITE_OK)
        goto fail;
    sqlite3_bind_int64(stmt, 1, orphan_before);
    if (sqlite3_step(stmt) != SQLITE_DONE)
        goto fail;
    sqlite3_finalize(stmt);
    stmt = NULL;
    if (sqlite3_prepare_v2(db->sql,
            "DELETE FROM multipart_groups WHERE id NOT IN "
            "(SELECT group_id FROM messages WHERE group_id IS NOT NULL) AND last_seen<?",
            -1, &stmt, NULL) != SQLITE_OK)
        goto fail;
    sqlite3_bind_int64(stmt, 1, orphan_before);
    if (sqlite3_step(stmt) != SQLITE_DONE)
        goto fail;
    sqlite3_finalize(stmt);
    stmt = NULL;
    if (exec_sql(db->sql,
            "DELETE FROM source_messages WHERE committed=1 AND deleted_at IS NOT NULL "
            "AND deleted_at < strftime('%s','now')-604800 "
            "AND NOT EXISTS (SELECT 1 FROM segments WHERE source_id=source_messages.id);"
            "DELETE FROM sync_runs WHERE finished_at IS NOT NULL "
            "AND finished_at < strftime('%s','now')-2592000;") != 0)
        goto fail;
    if (exec_sql(db->sql, "COMMIT") != 0)
        return -1;
    return 0;

fail:
    sqlite3_finalize(stmt);
    exec_sql(db->sql, "ROLLBACK");
    return -1;
}

int sms_db_mark_source_deleted(sms_db_t *db, int64_t source_id, int64_t deleted_at)
{
    sqlite3_stmt *stmt = NULL;
    int rc = -1;
    if (sqlite3_prepare_v2(db->sql,
            "UPDATE source_messages SET deleted_at=? WHERE id=? AND committed=1", -1,
            &stmt, NULL) != SQLITE_OK)
        return -1;
    sqlite3_bind_int64(stmt, 1, deleted_at);
    sqlite3_bind_int64(stmt, 2, source_id);
    if (sqlite3_step(stmt) == SQLITE_DONE)
        rc = 0;
    sqlite3_finalize(stmt);
    return rc;
}

int sms_db_delete_message(sms_db_t *db, const char *modem_id, int64_t message_id,
                          int *deleted)
{
    sqlite3_stmt *stmt = NULL;
    int64_t group_id = 0;
    *deleted = 0;
    if (exec_sql(db->sql, "BEGIN IMMEDIATE") != 0 ||
        sqlite3_prepare_v2(db->sql,
            "SELECT group_id FROM messages WHERE id=? AND modem_id=?", -1,
            &stmt, NULL) != SQLITE_OK)
        goto fail;
    sqlite3_bind_int64(stmt, 1, message_id);
    bind_text(stmt, 2, modem_id);
    if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL)
        group_id = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    stmt = NULL;
    if (sqlite3_prepare_v2(db->sql,
            "DELETE FROM messages WHERE id=? AND modem_id=?", -1, &stmt, NULL) != SQLITE_OK)
        goto fail;
    sqlite3_bind_int64(stmt, 1, message_id);
    bind_text(stmt, 2, modem_id);
    if (sqlite3_step(stmt) != SQLITE_DONE)
        goto fail;
    *deleted = sqlite3_changes(db->sql);
    sqlite3_finalize(stmt);
    stmt = NULL;
    if (group_id) {
        if (sqlite3_prepare_v2(db->sql, "DELETE FROM segments WHERE group_id=?", -1,
                               &stmt, NULL) != SQLITE_OK)
            goto fail;
        sqlite3_bind_int64(stmt, 1, group_id);
        if (sqlite3_step(stmt) != SQLITE_DONE)
            goto fail;
        sqlite3_finalize(stmt);
        stmt = NULL;
        if (sqlite3_prepare_v2(db->sql, "DELETE FROM multipart_groups WHERE id=?", -1,
                               &stmt, NULL) != SQLITE_OK)
            goto fail;
        sqlite3_bind_int64(stmt, 1, group_id);
        if (sqlite3_step(stmt) != SQLITE_DONE)
            goto fail;
    }
    sqlite3_finalize(stmt);
    return exec_sql(db->sql, "COMMIT");
fail:
    sqlite3_finalize(stmt);
    exec_sql(db->sql, "ROLLBACK");
    return -1;
}

int sms_db_delete_modem_messages(sms_db_t *db, const char *modem_id, int *deleted)
{
    sqlite3_stmt *stmt = NULL;
    const char *queries[] = {
        "DELETE FROM messages WHERE modem_id=?",
        "DELETE FROM segments WHERE group_id IN (SELECT id FROM multipart_groups WHERE modem_id=?)",
        "DELETE FROM multipart_groups WHERE modem_id=?"
    };
    *deleted = 0;
    if (exec_sql(db->sql, "BEGIN IMMEDIATE") != 0)
        return -1;
    for (size_t i = 0; i < sizeof(queries) / sizeof(queries[0]); i++) {
        if (sqlite3_prepare_v2(db->sql, queries[i], -1, &stmt, NULL) != SQLITE_OK)
            goto fail;
        bind_text(stmt, 1, modem_id);
        if (sqlite3_step(stmt) != SQLITE_DONE)
            goto fail;
        if (i == 0)
            *deleted = sqlite3_changes(db->sql);
        sqlite3_finalize(stmt);
        stmt = NULL;
    }
    return exec_sql(db->sql, "COMMIT");
fail:
    sqlite3_finalize(stmt);
    exec_sql(db->sql, "ROLLBACK");
    return -1;
}
