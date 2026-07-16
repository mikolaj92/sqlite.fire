#include "sqlite_fire.h"

#include <ctype.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <stdint.h>
#include <pthread.h>
#if defined(__APPLE__) || defined(__linux__)
#include <dlfcn.h>
#endif

struct sf_trace_callback { sf_trace_fn callback; void *userdata; };
struct sf_callback_state;
struct sf_callback_token;
struct sf_db {
    sqlite3 *handle;
    struct sf_callback_state *callbacks;
    struct sf_trace_callback *trace;
    struct sf_callback_token *callback_tokens;
};
struct sf_stmt { sqlite3_stmt *handle; };

struct sf_vfs {
    sqlite3_vfs vfs;
    sqlite3_vfs *base;
    char *name;
    int registered;
    unsigned active;
    unsigned inflight;
    pthread_mutex_t mutex;
};
struct sf_file_entry {
    struct sf_vfs *owner;
    sqlite3_file *file;
    const sqlite3_io_methods *original;
    sqlite3_io_methods methods;
};
static int sf_vfs_xClose(sqlite3_file *file) {
    if (file == NULL || file->pMethods == NULL) return SQLITE_MISUSE;
    struct sf_file_entry *entry = (struct sf_file_entry *)((char *)file->pMethods - offsetof(struct sf_file_entry, methods));
    const sqlite3_io_methods *original = entry->original;
    sf_vfs *owner = entry->owner;
    file->pMethods = original;
    int result = original != NULL && original->xClose != NULL ? original->xClose(file) : SQLITE_OK;
    if (owner != NULL) {
        (void)pthread_mutex_lock(&owner->mutex);
        if (owner->active > 0) --owner->active;
        (void)pthread_mutex_unlock(&owner->mutex);
    }
    free(entry);
    return result;
}

static sf_vfs *sf_vfs_from(sqlite3_vfs *vfs) {
    return vfs == NULL ? NULL : (sf_vfs *)vfs->pAppData;
}
static sqlite3_vfs *sf_vfs_base(sqlite3_vfs *vfs) {
    sf_vfs *wrapper = sf_vfs_from(vfs);
    return wrapper == NULL ? NULL : wrapper->base;
}
#define SF_VFS_BASE(name) sqlite3_vfs *base = sf_vfs_base(vfs); if (base == NULL || base->name == NULL) return SQLITE_NOTFOUND
static int sf_vfs_xOpen(sqlite3_vfs *vfs, sqlite3_filename n, sqlite3_file *f, int flags, int *out) {
    SF_VFS_BASE(xOpen);
    sf_vfs *owner = sf_vfs_from(vfs);
    if (owner == NULL) return SQLITE_MISUSE;
    (void)pthread_mutex_lock(&owner->mutex);
    ++owner->inflight;
    int result = base->xOpen(base, n, f, flags, out);
    if (result != SQLITE_OK || f == NULL || f->pMethods == NULL) {
        --owner->inflight;
        (void)pthread_mutex_unlock(&owner->mutex);
        return result;
    }
    struct sf_file_entry *entry = (struct sf_file_entry *)calloc(1, sizeof(*entry));
    if (entry == NULL) {
        const sqlite3_io_methods *original = f->pMethods;
        f->pMethods = original;
        if (original->xClose != NULL) original->xClose(f);
        f->pMethods = NULL;
        --owner->inflight;
        (void)pthread_mutex_unlock(&owner->mutex);
        return SQLITE_NOMEM;
    }
    entry->owner = owner;
    entry->file = f;
    entry->original = f->pMethods;
    entry->methods = *entry->original;
    entry->methods.xClose = sf_vfs_xClose;
    f->pMethods = &entry->methods;
    ++owner->active;
    --owner->inflight;
    (void)pthread_mutex_unlock(&owner->mutex);
    return result;
}
static int sf_vfs_xDelete(sqlite3_vfs *vfs, const char *n, int sync) { SF_VFS_BASE(xDelete); return base->xDelete(base, n, sync); }
static int sf_vfs_xAccess(sqlite3_vfs *vfs, const char *n, int flags, int *out) { SF_VFS_BASE(xAccess); return base->xAccess(base, n, flags, out); }
static int sf_vfs_xFullPathname(sqlite3_vfs *vfs, const char *n, int len, char *out) { SF_VFS_BASE(xFullPathname); return base->xFullPathname(base, n, len, out); }
static void *sf_vfs_xDlOpen(sqlite3_vfs *vfs, const char *n) { sqlite3_vfs *base = sf_vfs_base(vfs); return base != NULL && base->xDlOpen != NULL ? base->xDlOpen(base, n) : NULL; }
static void sf_vfs_xDlError(sqlite3_vfs *vfs, int len, char *msg) { sqlite3_vfs *base = sf_vfs_base(vfs); if (base != NULL && base->xDlError != NULL) base->xDlError(base, len, msg); else if (len > 0 && msg != NULL) msg[0] = '\0'; }
static void (*sf_vfs_xDlSym(sqlite3_vfs *vfs, void *h, const char *n))(void) { sqlite3_vfs *base = sf_vfs_base(vfs); return base != NULL && base->xDlSym != NULL ? base->xDlSym(base, h, n) : NULL; }
static void sf_vfs_xDlClose(sqlite3_vfs *vfs, void *h) { sqlite3_vfs *base = sf_vfs_base(vfs); if (base != NULL && base->xDlClose != NULL) base->xDlClose(base, h); }
static int sf_vfs_xRandomness(sqlite3_vfs *vfs, int n, char *out) { SF_VFS_BASE(xRandomness); return base->xRandomness(base, n, out); }
static int sf_vfs_xSleep(sqlite3_vfs *vfs, int us) { SF_VFS_BASE(xSleep); return base->xSleep(base, us); }
static int sf_vfs_xCurrentTime(sqlite3_vfs *vfs, double *out) { SF_VFS_BASE(xCurrentTime); return base->xCurrentTime(base, out); }
static int sf_vfs_xGetLastError(sqlite3_vfs *vfs, int n, char *out) { SF_VFS_BASE(xGetLastError); return base->xGetLastError(base, n, out); }
static int sf_vfs_xCurrentTimeInt64(sqlite3_vfs *vfs, sqlite3_int64 *out) { SF_VFS_BASE(xCurrentTimeInt64); return base->xCurrentTimeInt64(base, out); }
static int sf_vfs_xSetSystemCall(sqlite3_vfs *vfs, const char *n, sqlite3_syscall_ptr p) { SF_VFS_BASE(xSetSystemCall); return base->xSetSystemCall(base, n, p); }
static sqlite3_syscall_ptr sf_vfs_xGetSystemCall(sqlite3_vfs *vfs, const char *n) { sqlite3_vfs *base = sf_vfs_base(vfs); return base != NULL && base->xGetSystemCall != NULL ? base->xGetSystemCall(base, n) : NULL; }
static const char *sf_vfs_xNextSystemCall(sqlite3_vfs *vfs, const char *n) { sqlite3_vfs *base = sf_vfs_base(vfs); return base != NULL && base->xNextSystemCall != NULL ? base->xNextSystemCall(base, n) : NULL; }

int sf_vfs_register_passthrough(const char *name, const char *base_name, int make_default, sf_vfs **out_vfs) {
    if (out_vfs == NULL) return SQLITE_MISUSE;
    *out_vfs = NULL;
    if (name == NULL || name[0] == '\0' || base_name == NULL || base_name[0] == '\0') return SQLITE_MISUSE;
    if (sqlite3_vfs_find(name) != NULL) return SQLITE_BUSY;
    sqlite3_vfs *base = sqlite3_vfs_find(base_name);
    if (base == NULL) return SQLITE_NOTFOUND;
    sf_vfs *wrapper = (sf_vfs *)calloc(1, sizeof(*wrapper));
    if (wrapper == NULL) return SQLITE_NOMEM;
    if (pthread_mutex_init(&wrapper->mutex, NULL) != 0) { free(wrapper); return SQLITE_NOMEM; }
    size_t name_len = strlen(name) + 1;
    wrapper->name = (char *)malloc(name_len);
    if (wrapper->name == NULL) { pthread_mutex_destroy(&wrapper->mutex); free(wrapper); return SQLITE_NOMEM; }
    memcpy(wrapper->name, name, name_len);
    wrapper->base = base;
    wrapper->vfs.iVersion = base->iVersion;
    wrapper->vfs.szOsFile = base->szOsFile;
    wrapper->vfs.mxPathname = base->mxPathname;
    wrapper->vfs.zName = wrapper->name;
    wrapper->vfs.pAppData = wrapper;
    wrapper->vfs.xOpen = sf_vfs_xOpen;
    wrapper->vfs.xDelete = sf_vfs_xDelete;
    wrapper->vfs.xAccess = sf_vfs_xAccess;
    wrapper->vfs.xFullPathname = sf_vfs_xFullPathname;
    wrapper->vfs.xDlOpen = sf_vfs_xDlOpen;
    wrapper->vfs.xDlError = sf_vfs_xDlError;
    wrapper->vfs.xDlSym = sf_vfs_xDlSym;
    wrapper->vfs.xDlClose = sf_vfs_xDlClose;
    wrapper->vfs.xRandomness = sf_vfs_xRandomness;
    wrapper->vfs.xSleep = sf_vfs_xSleep;
    wrapper->vfs.xCurrentTime = sf_vfs_xCurrentTime;
    wrapper->vfs.xGetLastError = sf_vfs_xGetLastError;
    if (wrapper->vfs.iVersion >= 2 && base->xCurrentTimeInt64 != NULL) wrapper->vfs.xCurrentTimeInt64 = sf_vfs_xCurrentTimeInt64;
    if (wrapper->vfs.iVersion >= 3) {
        if (base->xSetSystemCall != NULL) wrapper->vfs.xSetSystemCall = sf_vfs_xSetSystemCall;
        if (base->xGetSystemCall != NULL) wrapper->vfs.xGetSystemCall = sf_vfs_xGetSystemCall;
        if (base->xNextSystemCall != NULL) wrapper->vfs.xNextSystemCall = sf_vfs_xNextSystemCall;
    }
    int result = sqlite3_vfs_register(&wrapper->vfs, make_default != 0);
    if (result != SQLITE_OK) { free(wrapper->name); pthread_mutex_destroy(&wrapper->mutex); free(wrapper); return result; }
    wrapper->registered = 1;
    *out_vfs = wrapper;
    return SQLITE_OK;
}

int sf_vfs_unregister(sf_vfs *wrapper) {
    if (wrapper == NULL) return SQLITE_MISUSE;
    if (!wrapper->registered) return SQLITE_OK;
    (void)pthread_mutex_lock(&wrapper->mutex);
    unsigned active = wrapper->active;
    unsigned inflight = wrapper->inflight;
    (void)pthread_mutex_unlock(&wrapper->mutex);
    if (active != 0 || inflight != 0) return SQLITE_MISUSE;
    int result = sqlite3_vfs_unregister(&wrapper->vfs);
    if (result == SQLITE_OK) {
        wrapper->registered = 0;
        free(wrapper->name);
        pthread_mutex_destroy(&wrapper->mutex);
        free(wrapper);
    }
    return result;
}
typedef enum { SF_TOKEN_SCALAR = 1, SF_TOKEN_COLLATION = 2 } sf_token_kind;
struct sf_callback_token {
    union { sf_scalar_fn scalar; sf_collation_fn collation; } callback;
    void *userdata;
    int active;
    sf_db *db;
    sf_token_kind kind;
    char *name;
    int argument_count;
    int text_encoding;
    struct sf_callback_token *next;
};

int sf_open(const char *filename, sf_db **out_db) {
    if (filename == NULL || out_db == NULL) return SQLITE_MISUSE;
    *out_db = NULL;
    sf_db *db = (sf_db *)calloc(1, sizeof(*db));
    if (db == NULL) return SQLITE_NOMEM;
    int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI;
    int result = sqlite3_open_v2(filename, &db->handle, flags, NULL);
    if (result != SQLITE_OK) {
        if (db->handle != NULL) sqlite3_close(db->handle);
        free(db);
        return result;
    }
    *out_db = db;
    return SQLITE_OK;
}

int sf_close(sf_db *db) {
    if (db == NULL) return SQLITE_OK;
    for (sf_callback_token *token = db->callback_tokens; token != NULL; token = token->next) {
        token->active = 0;
        token->db = NULL;
        token->callback.scalar = NULL;
    }
    if (db->handle == NULL) { free(db->trace); free(db); return SQLITE_OK; }
    if (db->trace != NULL) {
        int clear_result = sqlite3_trace_v2(db->handle, 0, NULL, NULL);
        if (clear_result != SQLITE_OK) return clear_result;
        free(db->trace);
        db->trace = NULL;
    }
    int result = sqlite3_close_v2(db->handle);
    free(db);
    return result;
}

const char *sf_errmsg(sf_db *db) {
    if (db == NULL) return "sqlite.fire: null database";
    if (db->handle == NULL) return "sqlite.fire: database is closed";
    return sqlite3_errmsg(db->handle);
}
int sf_errcode(sf_db *db) { return db == NULL || db->handle == NULL ? SQLITE_MISUSE : sqlite3_errcode(db->handle); }
int sf_extended_errcode(sf_db *db) { return db == NULL || db->handle == NULL ? SQLITE_MISUSE : sqlite3_extended_errcode(db->handle); }
int sf_changes(sf_db *db) { return db == NULL || db->handle == NULL ? 0 : sqlite3_changes(db->handle); }
long long sf_last_insert_rowid(sf_db *db) { return db == NULL || db->handle == NULL ? 0 : sqlite3_last_insert_rowid(db->handle); }
int sf_total_changes(sf_db *db) { return db == NULL || db->handle == NULL ? 0 : sqlite3_total_changes(db->handle); }
int sf_autocommit(sf_db *db) { return db == NULL || db->handle == NULL ? 1 : sqlite3_get_autocommit(db->handle); }
int sf_busy_timeout(sf_db *db, int milliseconds) { return db == NULL || db->handle == NULL ? SQLITE_MISUSE : sqlite3_busy_timeout(db->handle, milliseconds); }

int sf_exec(sf_db *db, const char *sql) {
    if (db == NULL || db->handle == NULL || sql == NULL) return SQLITE_MISUSE;
    return sqlite3_exec(db->handle, sql, NULL, NULL, NULL);
}

static const char *skip_tail(const char *tail) {
    while (tail != NULL) {
        while (*tail != '\0' && isspace((unsigned char)*tail)) ++tail;
        if (tail[0] == '-' && tail[1] == '-') {
            tail += 2;
            while (*tail != '\0' && *tail != '\n' && *tail != '\r') ++tail;
            continue;
        }
        if (tail[0] == '/' && tail[1] == '*') {
            const char *end = strstr(tail + 2, "*/");
            if (end == NULL) return NULL;
            tail = end + 2;
            continue;
        }
        return tail;
    }
    return tail;
}

int sf_prepare(sf_db *db, const char *sql, sf_stmt **out_stmt) {
    if (db == NULL || db->handle == NULL || sql == NULL || out_stmt == NULL) return SQLITE_MISUSE;
    *out_stmt = NULL;
    sqlite3_stmt *handle = NULL;
    const char *tail = NULL;
    int result = sqlite3_prepare_v2(db->handle, sql, -1, &handle, &tail);
    if (result != SQLITE_OK) return result;
    const char *remaining = skip_tail(tail);
    if (remaining == NULL || *remaining != '\0') {
        if (handle != NULL) sqlite3_finalize(handle);
        return SQLITE_ERROR;
    }
    if (handle == NULL) {
        sf_stmt *empty = (sf_stmt *)calloc(1, sizeof(*empty));
        if (empty == NULL) return SQLITE_NOMEM;
        *out_stmt = empty;
        return SQLITE_OK;
    }
    sf_stmt *stmt = (sf_stmt *)malloc(sizeof(*stmt));
    if (stmt == NULL) { sqlite3_finalize(handle); return SQLITE_NOMEM; }
    stmt->handle = handle;
    *out_stmt = stmt;
    return SQLITE_OK;
}

int sf_bind_null(sf_stmt *stmt, int index) { return stmt == NULL || stmt->handle == NULL ? SQLITE_MISUSE : sqlite3_bind_null(stmt->handle, index); }
int sf_bind_int64(sf_stmt *stmt, int index, long long value) { return stmt == NULL || stmt->handle == NULL ? SQLITE_MISUSE : sqlite3_bind_int64(stmt->handle, index, value); }
int sf_bind_double(sf_stmt *stmt, int index, double value) { return stmt == NULL || stmt->handle == NULL ? SQLITE_MISUSE : sqlite3_bind_double(stmt->handle, index, value); }
int sf_bind_text(sf_stmt *stmt, int index, const char *text, int length) {
    if (stmt == NULL || stmt->handle == NULL || (text == NULL && length != 0)) return SQLITE_MISUSE;
    return sqlite3_bind_text(stmt->handle, index, text, length < 0 ? -1 : length, SQLITE_TRANSIENT);
}
int sf_bind_blob(sf_stmt *stmt, int index, const void *blob, int length) {
    if (stmt == NULL || stmt->handle == NULL || length < 0 || (blob == NULL && length != 0)) return SQLITE_MISUSE;
    if (length == 0) return sqlite3_bind_zeroblob(stmt->handle, index, 0);
    return sqlite3_bind_blob(stmt->handle, index, blob, length, SQLITE_TRANSIENT);
}
int sf_parameter_count(sf_stmt *stmt) {
    if (stmt == NULL) return SQLITE_MISUSE;
    return stmt->handle == NULL ? 0 : sqlite3_bind_parameter_count(stmt->handle);
}
const char *sf_parameter_name(sf_stmt *stmt, int index) { return stmt == NULL || stmt->handle == NULL ? NULL : sqlite3_bind_parameter_name(stmt->handle, index); }
int sf_bind_parameter_index(sf_stmt *stmt, const char *name) { return stmt == NULL || stmt->handle == NULL || name == NULL ? 0 : sqlite3_bind_parameter_index(stmt->handle, name); }
const char *sf_stmt_sql(sf_stmt *stmt) { return stmt == NULL || stmt->handle == NULL ? NULL : sqlite3_sql(stmt->handle); }
int sf_stmt_readonly(sf_stmt *stmt) { return stmt == NULL || stmt->handle == NULL ? SQLITE_MISUSE : sqlite3_stmt_readonly(stmt->handle); }
int sf_data_count(sf_stmt *stmt) { return stmt == NULL || stmt->handle == NULL ? SQLITE_MISUSE : sqlite3_data_count(stmt->handle); }
int sf_reset(sf_stmt *stmt) {
    if (stmt == NULL) return SQLITE_MISUSE;
    return stmt->handle == NULL ? SQLITE_OK : sqlite3_reset(stmt->handle);
}
int sf_clear_bindings(sf_stmt *stmt) {
    if (stmt == NULL) return SQLITE_MISUSE;
    return stmt->handle == NULL ? SQLITE_OK : sqlite3_clear_bindings(stmt->handle);
}
int sf_step(sf_stmt *stmt) {
    if (stmt == NULL) return SQLITE_MISUSE;
    return stmt->handle == NULL ? SQLITE_DONE : sqlite3_step(stmt->handle);
}
int sf_finalize(sf_stmt *stmt) {
    if (stmt == NULL) return SQLITE_OK;
    int result = stmt->handle == NULL ? SQLITE_OK : sqlite3_finalize(stmt->handle);
    free(stmt);
    return result;
}
int sf_column_count(sf_stmt *stmt) { return stmt == NULL || stmt->handle == NULL ? 0 : sqlite3_column_count(stmt->handle); }
const char *sf_column_name(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? NULL : sqlite3_column_name(stmt->handle, column); }
int sf_column_type(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? SQLITE_NULL : sqlite3_column_type(stmt->handle, column); }
long long sf_column_int64(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? 0 : sqlite3_column_int64(stmt->handle, column); }
double sf_column_double(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? 0.0 : sqlite3_column_double(stmt->handle, column); }
const char *sf_column_text(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? NULL : (const char *)sqlite3_column_text(stmt->handle, column); }
const void *sf_column_blob(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? NULL : sqlite3_column_blob(stmt->handle, column); }
int sf_column_bytes(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? 0 : sqlite3_column_bytes(stmt->handle, column); }
const char *sf_column_database_name(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? NULL : sqlite3_column_database_name(stmt->handle, column); }
const char *sf_column_table_name(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? NULL : sqlite3_column_table_name(stmt->handle, column); }
const char *sf_column_origin_name(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? NULL : sqlite3_column_origin_name(stmt->handle, column); }
const char *sf_column_decltype(sf_stmt *stmt, int column) { return stmt == NULL || stmt->handle == NULL ? NULL : sqlite3_column_decltype(stmt->handle, column); }

struct sf_scalar_callback { sf_scalar_fn callback; void *userdata; };
struct sf_collation_callback { sf_collation_fn callback; void *userdata; };

static void sf_token_scalar_trampoline(sqlite3_context *context, int argc, sqlite3_value **argv) {
    sf_callback_token *token = (sf_callback_token *)sqlite3_user_data(context);
    if (token != NULL && token->active && token->callback.scalar != NULL)
        token->callback.scalar(token->userdata, context, argc, argv);
    else sqlite3_result_error_code(context, SQLITE_MISUSE);
}
static int sf_token_collation_trampoline(void *p, int left_length, const void *left,
                                         int right_length, const void *right) {
    sf_callback_token *token = (sf_callback_token *)p;
    if (token == NULL || !token->active || token->callback.collation == NULL) return 0;
    return token->callback.collation(token->userdata, left_length, left, right_length, right);
}
static void sf_token_noop_destroy(void *p) { (void)p; }
static void sf_token_mark_replaced(sf_db *db, const char *name, int argument_count,
                                   int text_encoding, sf_token_kind kind) {
    if (db == NULL || name == NULL) return;
    for (sf_callback_token *token = db->callback_tokens; token != NULL; token = token->next) {
        if (token->active && token->kind == kind && token->argument_count == argument_count &&
            token->text_encoding == text_encoding && strcmp(token->name, name) == 0) {
            token->active = 0;
            token->callback.scalar = NULL;
        }
    }
}

static void sf_scalar_trampoline(sqlite3_context *context, int argc, sqlite3_value **argv) {
    struct sf_scalar_callback *cb = (struct sf_scalar_callback *)sqlite3_user_data(context);
    if (cb != NULL && cb->callback != NULL) cb->callback(cb->userdata, context, argc, argv);
    else sqlite3_result_error_code(context, SQLITE_MISUSE);
}
static void sf_scalar_destroy(void *p) { free(p); }
static int sf_collation_trampoline(void *p, int left_length, const void *left, int right_length, const void *right) {
    struct sf_collation_callback *cb = (struct sf_collation_callback *)p;
    return cb == NULL || cb->callback == NULL ? 0 : cb->callback(cb->userdata, left_length, left, right_length, right);
}
static void sf_collation_destroy(void *p) { free(p); }

int sf_create_scalar_function(sf_db *db, const char *name, int argument_count, int text_encoding, sf_scalar_fn callback, void *userdata) {
    if (db == NULL || db->handle == NULL || name == NULL || name[0] == '\0' || callback == NULL) return SQLITE_MISUSE;
    if (argument_count < -1 || argument_count > 127) return SQLITE_MISUSE;
    struct sf_scalar_callback *cb = (struct sf_scalar_callback *)malloc(sizeof(*cb));
    if (cb == NULL) return SQLITE_NOMEM;
    cb->callback = callback; cb->userdata = userdata;
    int result = sqlite3_create_function_v2(db->handle, name, argument_count, text_encoding, cb, sf_scalar_trampoline, NULL, NULL, sf_scalar_destroy);
    return result;
}
int sf_remove_scalar_function(sf_db *db, const char *name, int argument_count, int text_encoding) {
    if (db == NULL || db->handle == NULL || name == NULL || name[0] == '\0' || argument_count < -1 || argument_count > 127) return SQLITE_MISUSE;
    return sqlite3_create_function_v2(db->handle, name, argument_count, text_encoding, NULL, NULL, NULL, NULL, NULL);
}
static char *sf_token_strdup(const char *text) {
    size_t length = strlen(text) + 1;
    char *copy = (char *)malloc(length);
    if (copy != NULL) memcpy(copy, text, length);
    return copy;
}
int sf_register_scalar_function(sf_db *db, const char *name, int argument_count,
                                int text_encoding, sf_scalar_fn callback,
                                void *userdata, sf_callback_token **out_token) {
    if (out_token != NULL) *out_token = NULL;
    if (db == NULL || db->handle == NULL || name == NULL || name[0] == '\0' ||
        callback == NULL || out_token == NULL || argument_count < -1 || argument_count > 127)
        return SQLITE_MISUSE;
    sf_callback_token *token = (sf_callback_token *)calloc(1, sizeof(*token));
    if (token == NULL) return SQLITE_NOMEM;
    token->name = sf_token_strdup(name);
    if (token->name == NULL) { free(token); return SQLITE_NOMEM; }
    token->callback.scalar = callback; token->userdata = userdata; token->active = 1;
    token->db = db; token->kind = SF_TOKEN_SCALAR; token->argument_count = argument_count;
    sf_token_mark_replaced(db, name, argument_count, text_encoding, SF_TOKEN_SCALAR);
    token->text_encoding = text_encoding;
    int result = sqlite3_create_function_v2(db->handle, name, argument_count, text_encoding,
                                            token, sf_token_scalar_trampoline, NULL, NULL,
                                            sf_token_noop_destroy);
    if (result != SQLITE_OK) { token->active = 0; token->callback.scalar = NULL; free(token->name); free(token); return result; }
    token->next = db->callback_tokens; db->callback_tokens = token; *out_token = token; return SQLITE_OK;
}
int sf_register_collation(sf_db *db, const char *name, int text_encoding,
                          sf_collation_fn callback, void *userdata,
                          sf_callback_token **out_token) {
    if (out_token != NULL) *out_token = NULL;
    if (db == NULL || db->handle == NULL || name == NULL || name[0] == '\0' || callback == NULL || out_token == NULL) return SQLITE_MISUSE;
    sf_callback_token *token = (sf_callback_token *)calloc(1, sizeof(*token));
    if (token == NULL) return SQLITE_NOMEM;
    token->name = sf_token_strdup(name);
    if (token->name == NULL) { free(token); return SQLITE_NOMEM; }
    token->callback.collation = callback; token->userdata = userdata; token->active = 1;
    token->db = db; token->kind = SF_TOKEN_COLLATION; token->text_encoding = text_encoding;
    sf_token_mark_replaced(db, name, 0, text_encoding, SF_TOKEN_COLLATION);
    int result = sqlite3_create_collation_v2(db->handle, name, text_encoding, token,
                                             sf_token_collation_trampoline, sf_token_noop_destroy);
    if (result != SQLITE_OK) { token->active = 0; token->callback.collation = NULL; free(token->name); free(token); return result; }
    token->next = db->callback_tokens; db->callback_tokens = token; *out_token = token; return SQLITE_OK;
}
int sf_callback_token_close(sf_callback_token *token) {
    if (token == NULL || !token->active) return SQLITE_OK;
    sf_db *db = token->db;
    int result = SQLITE_OK;
    token->active = 0;
    if (db != NULL && db->handle != NULL) {
        if (token->kind == SF_TOKEN_SCALAR)
            result = sqlite3_create_function_v2(db->handle, token->name, token->argument_count, token->text_encoding, NULL, NULL, NULL, NULL, NULL);
        else if (token->kind == SF_TOKEN_COLLATION)
            result = sqlite3_create_collation_v2(db->handle, token->name, token->text_encoding, NULL, NULL, NULL);
    }
    token->callback.scalar = NULL;
    token->db = NULL;
    if (db != NULL) {
        sf_callback_token **cursor = &db->callback_tokens;
        while (*cursor != NULL && *cursor != token) cursor = &(*cursor)->next;
        if (*cursor == token) *cursor = token->next;
    }
    free(token->name);
    free(token);
    return result;
}
int sf_create_collation(sf_db *db, const char *name, int text_encoding, sf_collation_fn callback, void *userdata) {
    if (db == NULL || db->handle == NULL || name == NULL || name[0] == '\0' || callback == NULL) return SQLITE_MISUSE;
    struct sf_collation_callback *cb = (struct sf_collation_callback *)malloc(sizeof(*cb));
    if (cb == NULL) return SQLITE_NOMEM;
    cb->callback = callback; cb->userdata = userdata;
    int result = sqlite3_create_collation_v2(db->handle, name, text_encoding, cb, sf_collation_trampoline, sf_collation_destroy);
    if (result != SQLITE_OK) free(cb);
    return result;
}
int sf_remove_collation(sf_db *db, const char *name, int text_encoding) {
    if (db == NULL || db->handle == NULL || name == NULL || name[0] == '\0') return SQLITE_MISUSE;
    return sqlite3_create_collation_v2(db->handle, name, text_encoding, NULL, NULL, NULL);
}

int sf_set_authorizer(sf_db *db, sf_authorizer_fn callback, void *userdata) {
    if (db == NULL || db->handle == NULL || callback == NULL) return SQLITE_MISUSE;
    return sqlite3_set_authorizer(db->handle, callback, userdata);
}
int sf_clear_authorizer(sf_db *db) { return db == NULL || db->handle == NULL ? SQLITE_MISUSE : sqlite3_set_authorizer(db->handle, NULL, NULL); }
int sf_set_progress_handler(sf_db *db, int instruction_count, sf_progress_fn callback, void *userdata) {
    if (db == NULL || db->handle == NULL || instruction_count <= 0 || callback == NULL) return SQLITE_MISUSE;
    sqlite3_progress_handler(db->handle, instruction_count, callback, userdata); return SQLITE_OK;
}
int sf_clear_progress_handler(sf_db *db) { if (db == NULL || db->handle == NULL) return SQLITE_MISUSE; sqlite3_progress_handler(db->handle, 0, NULL, NULL); return SQLITE_OK; }

static int sf_trace_trampoline(unsigned event, void *ctx, void *event_data, void *event_aux) {
    struct sf_trace_callback *cb = (struct sf_trace_callback *)ctx;
    if (cb == NULL || cb->callback == NULL) return 0;
    return cb->callback(cb->userdata, event, event_data, event_aux);
}
int sf_set_trace(sf_db *db, unsigned event_mask, sf_trace_fn callback, void *userdata) {
    if (db == NULL || db->handle == NULL || event_mask == 0 || callback == NULL) return SQLITE_MISUSE;
    if (db->trace != NULL) {
        int clear_result = sqlite3_trace_v2(db->handle, 0, NULL, NULL);
        if (clear_result != SQLITE_OK) return clear_result;
        free(db->trace); db->trace = NULL;
    }
    struct sf_trace_callback *cb = (struct sf_trace_callback *)malloc(sizeof(*cb));
    if (cb == NULL) return SQLITE_NOMEM;
    cb->callback = callback; cb->userdata = userdata;
    int result = sqlite3_trace_v2(db->handle, event_mask, sf_trace_trampoline, cb);
    if (result != SQLITE_OK) free(cb); else db->trace = cb;
    return result;
}
int sf_clear_trace(sf_db *db) {
    if (db == NULL || db->handle == NULL) return SQLITE_MISUSE;
    int result = sqlite3_trace_v2(db->handle, 0, NULL, NULL);
    if (result == SQLITE_OK && db->trace != NULL) { free(db->trace); db->trace = NULL; }
    return result;
}
int sf_set_update_hook(sf_db *db, sf_update_fn callback, void *userdata) { if (db == NULL || db->handle == NULL || callback == NULL) return SQLITE_MISUSE; sqlite3_update_hook(db->handle, callback, userdata); return SQLITE_OK; }
int sf_clear_update_hook(sf_db *db) { if (db == NULL || db->handle == NULL) return SQLITE_MISUSE; sqlite3_update_hook(db->handle, NULL, NULL); return SQLITE_OK; }
int sf_set_commit_hook(sf_db *db, sf_commit_fn callback, void *userdata) { if (db == NULL || db->handle == NULL || callback == NULL) return SQLITE_MISUSE; sqlite3_commit_hook(db->handle, callback, userdata); return SQLITE_OK; }
int sf_clear_commit_hook(sf_db *db) { if (db == NULL || db->handle == NULL) return SQLITE_MISUSE; sqlite3_commit_hook(db->handle, NULL, NULL); return SQLITE_OK; }
int sf_set_rollback_hook(sf_db *db, sf_rollback_fn callback, void *userdata) { if (db == NULL || db->handle == NULL || callback == NULL) return SQLITE_MISUSE; sqlite3_rollback_hook(db->handle, callback, userdata); return SQLITE_OK; }
int sf_clear_rollback_hook(sf_db *db) { if (db == NULL || db->handle == NULL) return SQLITE_MISUSE; sqlite3_rollback_hook(db->handle, NULL, NULL); return SQLITE_OK; }
int sf_set_wal_hook(sf_db *db, sf_wal_fn callback, void *userdata) { if (db == NULL || db->handle == NULL || callback == NULL) return SQLITE_MISUSE; sqlite3_wal_hook(db->handle, callback, userdata); return SQLITE_OK; }
int sf_clear_wal_hook(sf_db *db) { if (db == NULL || db->handle == NULL) return SQLITE_MISUSE; sqlite3_wal_hook(db->handle, NULL, NULL); return SQLITE_OK; }
int sf_set_busy_handler(sf_db *db, sf_busy_fn callback, void *userdata) { if (db == NULL || db->handle == NULL || callback == NULL) return SQLITE_MISUSE; return sqlite3_busy_handler(db->handle, callback, userdata); }
int sf_clear_busy_handler(sf_db *db) { return db == NULL || db->handle == NULL ? SQLITE_MISUSE : sqlite3_busy_handler(db->handle, NULL, NULL); }
struct sf_blob { sqlite3_blob *handle; };
struct sf_backup { sqlite3_backup *handle; int finished; };

int sf_open_options(const char *filename, int flags, const char *vfs, sf_db **out_db) {
    if (filename == NULL || filename[0] == '\0' || out_db == NULL || flags == 0) return SQLITE_MISUSE;
    *out_db = NULL;
    sf_db *db = (sf_db *)calloc(1, sizeof(*db));
    if (db == NULL) return SQLITE_NOMEM;
    int result = sqlite3_open_v2(filename, &db->handle, flags, (vfs != NULL && vfs[0] != '\0') ? vfs : NULL);
    if (result != SQLITE_OK) {
        if (db->handle != NULL) sqlite3_close_v2(db->handle);
        free(db);
        return result;
    }
    *out_db = db;
    return SQLITE_OK;
}

const char *sf_db_filename(sf_db *db, const char *schema) {
    if (db == NULL || db->handle == NULL || schema == NULL || schema[0] == '\0') return NULL;
    return sqlite3_db_filename(db->handle, schema);
}

int sf_table_column_metadata(sf_db *db, const char *schema, const char *table,
                             const char *column, const char **data_type,
                             const char **collation, int *not_null,
                             int *primary_key, int *auto_increment) {
    if (db == NULL || db->handle == NULL || schema == NULL || schema[0] == '\0' ||
        table == NULL || table[0] == '\0' || column == NULL || column[0] == '\0') return SQLITE_MISUSE;
    return sqlite3_table_column_metadata(db->handle, schema, table, column,
                                         data_type, collation, not_null,
                                         primary_key, auto_increment);
}

void sf_interrupt(sf_db *db) { if (db != NULL && db->handle != NULL) sqlite3_interrupt(db->handle); }
int sf_limit(sf_db *db, int category, int new_value) {
    return db == NULL || db->handle == NULL ? SQLITE_MISUSE : sqlite3_limit(db->handle, category, new_value);
}
int sf_limit_get(sf_db *db, int category) {
    return db == NULL || db->handle == NULL ? SQLITE_MISUSE : sqlite3_limit(db->handle, category, -1);
}

int sf_blob_open(sf_db *db, const char *schema, const char *table,
                 const char *column, long long rowid, int flags,
                 sf_blob **out_blob) {
    if (db == NULL || db->handle == NULL || schema == NULL || schema[0] == '\0' ||
        table == NULL || table[0] == '\0' || column == NULL || column[0] == '\0' ||
        out_blob == NULL || (flags != 0 && flags != 1)) return SQLITE_MISUSE;
    *out_blob = NULL;
    sf_blob *blob = (sf_blob *)calloc(1, sizeof(*blob));
    if (blob == NULL) return SQLITE_NOMEM;
    int result = sqlite3_blob_open(db->handle, schema, table, column, (sqlite3_int64)rowid,
                                   flags, &blob->handle);
    if (result != SQLITE_OK) { free(blob); return result; }
    *out_blob = blob;
    return SQLITE_OK;
}
int sf_blob_close(sf_blob *blob) {
    if (blob == NULL) return SQLITE_OK;
    int result = blob->handle == NULL ? SQLITE_OK : sqlite3_blob_close(blob->handle);
    free(blob);
    return result;
}
int sf_blob_bytes(sf_blob *blob) { return blob == NULL || blob->handle == NULL ? SQLITE_MISUSE : sqlite3_blob_bytes(blob->handle); }
int sf_blob_read(sf_blob *blob, void *buffer, int length, int offset) {
    if (blob == NULL || blob->handle == NULL || length < 0 || offset < 0 || (buffer == NULL && length != 0)) return SQLITE_MISUSE;
    return length == 0 ? SQLITE_OK : sqlite3_blob_read(blob->handle, buffer, length, offset);
}
int sf_blob_write(sf_blob *blob, const void *buffer, int length, int offset) {
    if (blob == NULL || blob->handle == NULL || length < 0 || offset < 0 || (buffer == NULL && length != 0)) return SQLITE_MISUSE;
    return length == 0 ? SQLITE_OK : sqlite3_blob_write(blob->handle, buffer, length, offset);
}
int sf_blob_reopen(sf_blob *blob, long long rowid) {
    return blob == NULL || blob->handle == NULL ? SQLITE_MISUSE : sqlite3_blob_reopen(blob->handle, (sqlite3_int64)rowid);
}

int sf_backup_start(sf_db *dest, const char *dest_schema, sf_db *src,
                    const char *src_schema, sf_backup **out_backup) {
    if (dest == NULL || dest->handle == NULL || src == NULL || src->handle == NULL ||
        dest_schema == NULL || dest_schema[0] == '\0' || src_schema == NULL || src_schema[0] == '\0' || out_backup == NULL) return SQLITE_MISUSE;
    *out_backup = NULL;
    sf_backup *backup = (sf_backup *)calloc(1, sizeof(*backup));
    if (backup == NULL) return SQLITE_NOMEM;
    backup->handle = sqlite3_backup_init(dest->handle, dest_schema, src->handle, src_schema);
    if (backup->handle == NULL) {
        int result = sqlite3_errcode(dest->handle);
        free(backup);
        return result;
    }
    *out_backup = backup;
    return SQLITE_OK;
}
int sf_backup_step(sf_backup *backup, int pages) {
    if (backup == NULL || backup->handle == NULL || backup->finished || pages < 1) return SQLITE_MISUSE;
    return sqlite3_backup_step(backup->handle, pages);
}
int sf_backup_remaining(sf_backup *backup) { return backup == NULL || backup->handle == NULL || backup->finished ? SQLITE_MISUSE : sqlite3_backup_remaining(backup->handle); }
int sf_backup_pagecount(sf_backup *backup) { return backup == NULL || backup->handle == NULL || backup->finished ? SQLITE_MISUSE : sqlite3_backup_pagecount(backup->handle); }
int sf_backup_finish(sf_backup *backup) {
    if (backup == NULL) return SQLITE_OK;
    if (backup->finished) { free(backup); return SQLITE_OK; }
    backup->finished = 1;
    int result = backup->handle == NULL ? SQLITE_OK : sqlite3_backup_finish(backup->handle);
    backup->handle = NULL;
    free(backup);
    return result;
}

void *sf_serialize(sf_db *db, const char *schema, size_t *size, unsigned int flags) {
    if (size != NULL) *size = 0;
    if (db == NULL || db->handle == NULL || schema == NULL || schema[0] == '\0' || size == NULL) return NULL;
    sqlite3_int64 n = 0;
    void *data = sqlite3_serialize(db->handle, schema, &n, flags);
    if (n >= 0) *size = (size_t)n;
    return data;
}
int sf_serialize_status(sf_db *db, const char *schema, size_t *size,
                         unsigned int flags, void **out_data) {
    if (size != NULL) *size = 0;
    if (out_data != NULL) *out_data = NULL;
    if (db == NULL || db->handle == NULL || schema == NULL || schema[0] == '\0' ||
        size == NULL || out_data == NULL) return SQLITE_MISUSE;
    sqlite3_int64 n = 0;
    void *data = sqlite3_serialize(db->handle, schema, &n, flags);
    if (data == NULL) {
        int result = sqlite3_errcode(db->handle);
        return result == SQLITE_OK ? SQLITE_NOMEM : result;
    }
    if (n < 0 || (sqlite3_uint64)n > (sqlite3_uint64)SIZE_MAX) {
        sqlite3_free(data);
        return SQLITE_NOMEM;
    }
    *size = (size_t)n;
    *out_data = data;
    return SQLITE_OK;
}
int sf_deserialize(sf_db *db, const char *schema, const void *data, size_t size,
                   size_t reserved, unsigned int flags) {
    if (db == NULL || db->handle == NULL || schema == NULL || schema[0] == '\0' ||
        (data == NULL && size != 0) || size > (size_t)0x7fffffffffffffffULL ||
        reserved > (size_t)0x7fffffffffffffffULL - size) return SQLITE_MISUSE;
    size_t capacity = size + reserved;
    unsigned char *copy = (unsigned char *)sqlite3_malloc64((sqlite3_uint64)capacity);
    if (copy == NULL && capacity != 0) return SQLITE_NOMEM;
    if (size != 0) memcpy(copy, data, size);
    unsigned int effective_flags = flags | SQLITE_DESERIALIZE_FREEONCLOSE;
    int result = sqlite3_deserialize(db->handle, schema, copy, (sqlite3_int64)size,
                                     (sqlite3_int64)capacity, effective_flags);
    return result;
}
void sf_free(void *ptr) { if (ptr != NULL) sqlite3_free(ptr); }

int sf_enable_load_extension(sf_db *db, int onoff) {
    if (db == NULL || db->handle == NULL || (onoff != 0 && onoff != 1)) return SQLITE_MISUSE;
    return sqlite3_db_config(db->handle, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, onoff, NULL);
}

int sf_load_extension(sf_db *db, const char *path, const char *entrypoint, char **error_message) {
    if (error_message != NULL) *error_message = NULL;
    if (db == NULL || db->handle == NULL || path == NULL || path[0] == '\0' || error_message == NULL) return SQLITE_MISUSE;
#if defined(__APPLE__) || defined(__linux__)
    typedef int (*sf_load_extension_fn)(sqlite3 *, const char *, const char *, char **);
    sf_load_extension_fn loader = (sf_load_extension_fn)dlsym(RTLD_DEFAULT, "sqlite3_load_extension");
    if (loader == NULL) {
        *error_message = sqlite3_mprintf("sqlite.fire: SQLite was built without extension loading support");
        return SQLITE_ERROR;
    }
    return loader(db->handle, path, (entrypoint != NULL && entrypoint[0] != '\0') ? entrypoint : NULL, error_message);
#else
    *error_message = sqlite3_mprintf("sqlite.fire: extension loading is unsupported on this platform");
    return SQLITE_ERROR;
#endif
}
