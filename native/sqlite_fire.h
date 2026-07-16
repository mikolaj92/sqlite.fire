#ifndef SQLITE_FIRE_H
#define SQLITE_FIRE_H

#include <stddef.h>
#include <sqlite3.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sf_db sf_db;
typedef struct sf_stmt sf_stmt;
typedef struct sf_vfs sf_vfs;

/* SQLite results are SQLite-compatible: 0 means success. */
int sf_open(const char *filename, sf_db **out_db);
int sf_close(sf_db *db);
const char *sf_errmsg(sf_db *db);
int sf_errcode(sf_db *db);
int sf_extended_errcode(sf_db *db);
int sf_changes(sf_db *db);
long long sf_last_insert_rowid(sf_db *db);
int sf_total_changes(sf_db *db);
int sf_autocommit(sf_db *db);

int sf_exec(sf_db *db, const char *sql);
int sf_prepare(sf_db *db, const char *sql, sf_stmt **out_stmt);
int sf_bind_null(sf_stmt *stmt, int index);
int sf_bind_int64(sf_stmt *stmt, int index, long long value);
int sf_bind_double(sf_stmt *stmt, int index, double value);
int sf_bind_text(sf_stmt *stmt, int index, const char *text, int length);
int sf_bind_blob(sf_stmt *stmt, int index, const void *blob, int length);
int sf_parameter_count(sf_stmt *stmt);
const char *sf_parameter_name(sf_stmt *stmt, int index);
int sf_bind_parameter_index(sf_stmt *stmt, const char *name);
const char *sf_stmt_sql(sf_stmt *stmt);
int sf_stmt_readonly(sf_stmt *stmt);
int sf_data_count(sf_stmt *stmt);
int sf_reset(sf_stmt *stmt);
int sf_clear_bindings(sf_stmt *stmt);
int sf_busy_timeout(sf_db *db, int milliseconds);
int sf_step(sf_stmt *stmt);
int sf_finalize(sf_stmt *stmt);

int sf_column_count(sf_stmt *stmt);
const char *sf_column_name(sf_stmt *stmt, int column);
int sf_column_type(sf_stmt *stmt, int column);
long long sf_column_int64(sf_stmt *stmt, int column);
double sf_column_double(sf_stmt *stmt, int column);
const char *sf_column_text(sf_stmt *stmt, int column);
const void *sf_column_blob(sf_stmt *stmt, int column);
int sf_column_bytes(sf_stmt *stmt, int column);
const char *sf_column_database_name(sf_stmt *stmt, int column);
const char *sf_column_table_name(sf_stmt *stmt, int column);
const char *sf_column_origin_name(sf_stmt *stmt, int column);
const char *sf_column_decltype(sf_stmt *stmt, int column);

/* Callback ABI: callbacks are invoked synchronously by SQLite with the registered userdata. */
typedef void (*sf_scalar_fn)(void *userdata, sqlite3_context *context, int argc, sqlite3_value **argv);
typedef int (*sf_collation_fn)(void *userdata, int left_length, const void *left, int right_length, const void *right);
typedef int (*sf_authorizer_fn)(void *userdata, int action, const char *arg1, const char *arg2, const char *database, const char *trigger);
typedef int (*sf_progress_fn)(void *userdata);
typedef int (*sf_trace_fn)(void *userdata, unsigned event, void *event_data, void *event_aux);
typedef void (*sf_update_fn)(void *userdata, int operation, const char *database, const char *table, sqlite3_int64 rowid);
typedef int (*sf_commit_fn)(void *userdata);
typedef void (*sf_rollback_fn)(void *userdata);
typedef int (*sf_wal_fn)(void *userdata, sqlite3 *database, const char *name, int pages);
typedef int (*sf_busy_fn)(void *userdata, int attempts);
/* Opaque lifecycle tokens for safely owned scalar and collation registrations. */
typedef struct sf_callback_token sf_callback_token;
/* Closing is idempotent and releases the token allocation. */
int sf_callback_token_close(sf_callback_token *token);
int sf_register_scalar_function(sf_db *db, const char *name, int argument_count,
                                int text_encoding, sf_scalar_fn callback,
                                void *userdata, sf_callback_token **out_token);
int sf_register_collation(sf_db *db, const char *name, int text_encoding,
                          sf_collation_fn callback, void *userdata,
                          sf_callback_token **out_token);

int sf_create_scalar_function(sf_db *db, const char *name, int argument_count, int text_encoding, sf_scalar_fn callback, void *userdata);
int sf_remove_scalar_function(sf_db *db, const char *name, int argument_count, int text_encoding);
int sf_create_collation(sf_db *db, const char *name, int text_encoding, sf_collation_fn callback, void *userdata);
int sf_remove_collation(sf_db *db, const char *name, int text_encoding);
int sf_set_authorizer(sf_db *db, sf_authorizer_fn callback, void *userdata);
int sf_clear_authorizer(sf_db *db);
int sf_set_progress_handler(sf_db *db, int instruction_count, sf_progress_fn callback, void *userdata);
int sf_clear_progress_handler(sf_db *db);
int sf_set_trace(sf_db *db, unsigned event_mask, sf_trace_fn callback, void *userdata);
int sf_clear_trace(sf_db *db);
int sf_set_update_hook(sf_db *db, sf_update_fn callback, void *userdata);
int sf_clear_update_hook(sf_db *db);
int sf_set_commit_hook(sf_db *db, sf_commit_fn callback, void *userdata);
int sf_clear_commit_hook(sf_db *db);
int sf_set_rollback_hook(sf_db *db, sf_rollback_fn callback, void *userdata);
int sf_clear_rollback_hook(sf_db *db);
int sf_set_wal_hook(sf_db *db, sf_wal_fn callback, void *userdata);
int sf_clear_wal_hook(sf_db *db);
int sf_set_busy_handler(sf_db *db, sf_busy_fn callback, void *userdata);
int sf_clear_busy_handler(sf_db *db);

typedef struct sf_blob sf_blob;
typedef struct sf_backup sf_backup;

/* Open an SQLite database with explicit sqlite3_open_v2 flags and VFS name. */
int sf_open_options(const char *filename, int flags, const char *vfs, sf_db **out_db);

/* Register and unregister a named passthrough VFS over an existing SQLite VFS. */
int sf_vfs_register_passthrough(const char *name, const char *base_name,
                                int make_default, sf_vfs **out_vfs);
int sf_vfs_unregister(sf_vfs *vfs);
const char *sf_db_filename(sf_db *db, const char *schema);
int sf_table_column_metadata(sf_db *db, const char *schema, const char *table,
                             const char *column, const char **data_type,
                             const char **collation, int *not_null,
                             int *primary_key, int *auto_increment);
void sf_interrupt(sf_db *db);
int sf_limit(sf_db *db, int category, int new_value);
int sf_limit_get(sf_db *db, int category);

int sf_blob_open(sf_db *db, const char *schema, const char *table,
                 const char *column, long long rowid, int flags,
                 sf_blob **out_blob);
int sf_blob_close(sf_blob *blob);
int sf_blob_bytes(sf_blob *blob);
int sf_blob_read(sf_blob *blob, void *buffer, int length, int offset);
int sf_blob_write(sf_blob *blob, const void *buffer, int length, int offset);
int sf_blob_reopen(sf_blob *blob, long long rowid);

int sf_backup_start(sf_db *dest, const char *dest_schema, sf_db *src,
                    const char *src_schema, sf_backup **out_backup);
int sf_backup_step(sf_backup *backup, int pages);
int sf_backup_remaining(sf_backup *backup);
int sf_backup_pagecount(sf_backup *backup);
int sf_backup_finish(sf_backup *backup);

void *sf_serialize(sf_db *db, const char *schema, size_t *size, unsigned int flags);
int sf_serialize_status(sf_db *db, const char *schema, size_t *size,
                         unsigned int flags, void **out_data);
int sf_deserialize(sf_db *db, const char *schema, const void *data, size_t size,
                   size_t reserved, unsigned int flags);
void sf_free(void *ptr);

int sf_enable_load_extension(sf_db *db, int onoff);
int sf_load_extension(sf_db *db, const char *path, const char *entrypoint,
                      char **error_message);

#ifdef __cplusplus
}
#endif

#endif
