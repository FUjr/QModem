#ifndef QMODEM_SMS_DB_H
#define QMODEM_SMS_DB_H

#include <sqlite3.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    sqlite3 *sql;
    int multipart_wait;
    int late_fragment_window;
} sms_db_t;

typedef struct {
    const char *modem_id;
    const char *storage;
    int source_index;
    const char *pdu;
    const char *sender;
    int64_t timestamp;
    const char *content;
    int reference;
    int total_parts;
    int part_number;
} sms_segment_t;

typedef struct {
    int duplicate;
    int safe_to_delete;
    int64_t message_id;
    int published;
    int revision;
    int64_t source_id;
} sms_import_result_t;

int sms_db_open(sms_db_t *db, const char *path);
int sms_db_checkpoint(sms_db_t *db);
void sms_db_set_multipart_windows(sms_db_t *db, int wait_seconds,
                                  int late_seconds);
void sms_db_close(sms_db_t *db);
const char *sms_db_error(sms_db_t *db);
int sms_db_import_segment(sms_db_t *db, const sms_segment_t *segment,
                          int64_t now, int forwarding_enabled,
                          sms_import_result_t *result);
int sms_db_publish_expired(sms_db_t *db, const char *modem_id, int64_t now,
                           int forwarding_enabled, int *published_count);
int sms_db_record_sync(sms_db_t *db, const char *modem_id, const char *trigger,
                       int64_t started_at, int imported, const char *error);
int sms_db_finish_scan(sms_db_t *db, const char *modem_id, const char *storage,
                       int64_t started_at);
int sms_db_record_event(sms_db_t *db, const char *modem_id, int64_t epoch,
                        int64_t sequence, int *gap);
int sms_db_migration_error(sms_db_t *db, const char *modem_id,
                           char *error, size_t error_size);
int sms_db_prune(sms_db_t *db, const char *modem_id,
                 int received_limit, int sent_limit);
int sms_db_mark_source_deleted(sms_db_t *db, int64_t source_id, int64_t deleted_at);
int sms_db_mark_modem_source_deleted(sms_db_t *db, const char *modem_id,
                                     const char *storage, int index,
                                     const char *pdu, int64_t deleted_at);
int sms_db_delete_message(sms_db_t *db, const char *modem_id, int64_t message_id,
                          int *deleted);
int sms_db_delete_modem_messages(sms_db_t *db, const char *modem_id, int *deleted);

#endif
