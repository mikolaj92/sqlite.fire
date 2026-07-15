#include "sqlite_fire.h"

#include <sqlite3.h>
#include <stdlib.h>

struct sf_db {
    sqlite3 *handle;
};

struct sf_stmt {
    sqlite3_stmt *handle;
};

int sf_open(const char *filename, sf_db **out_db) {
    if (filename == NULL || out_db == NULL) {
        return SQLITE_MISUSE;
    }
    *out_db = NULL;

    sf_db *db = (sf_db *)calloc(1, sizeof(*db));
    if (db == NULL) {
        return SQLITE_NOMEM;
    }

    int result = sqlite3_open_v2(
        filename,
        &db->handle,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI,
        NULL
    );
    if (result != SQLITE_OK) {
        sqlite3_close(db->handle);
        free(db);
        return result;
    }

    *out_db = db;
    return SQLITE_OK;
}

int sf_close(sf_db *db) {
    if (db == NULL) {
        return SQLITE_OK;
    }
    int result = sqlite3_close_v2(db->handle);
    free(db);
    return result;
}

const char *sf_errmsg(sf_db *db) {
    return db == NULL ? "sqlite.fire: null database" : sqlite3_errmsg(db->handle);
}

int sf_exec(sf_db *db, const char *sql) {
    if (db == NULL || sql == NULL) {
        return SQLITE_MISUSE;
    }
    return sqlite3_exec(db->handle, sql, NULL, NULL, NULL);
}

int sf_prepare(sf_db *db, const char *sql, sf_stmt **out_stmt) {
    if (db == NULL || sql == NULL || out_stmt == NULL) {
        return SQLITE_MISUSE;
    }
    *out_stmt = NULL;

    sqlite3_stmt *handle = NULL;
    int result = sqlite3_prepare_v2(db->handle, sql, -1, &handle, NULL);
    if (result != SQLITE_OK) {
        return result;
    }

    sf_stmt *stmt = (sf_stmt *)malloc(sizeof(*stmt));
    if (stmt == NULL) {
        sqlite3_finalize(handle);
        return SQLITE_NOMEM;
    }
    stmt->handle = handle;
    *out_stmt = stmt;
    return SQLITE_OK;
}

int sf_step(sf_stmt *stmt) {
    return stmt == NULL ? SQLITE_MISUSE : sqlite3_step(stmt->handle);
}

int sf_finalize(sf_stmt *stmt) {
    if (stmt == NULL) {
        return SQLITE_OK;
    }
    int result = sqlite3_finalize(stmt->handle);
    free(stmt);
    return result;
}

int sf_column_count(sf_stmt *stmt) {
    return stmt == NULL ? 0 : sqlite3_column_count(stmt->handle);
}

const char *sf_column_name(sf_stmt *stmt, int column) {
    return stmt == NULL ? NULL : sqlite3_column_name(stmt->handle, column);
}

int sf_column_type(sf_stmt *stmt, int column) {
    return stmt == NULL ? SQLITE_NULL : sqlite3_column_type(stmt->handle, column);
}

long long sf_column_int64(sf_stmt *stmt, int column) {
    return stmt == NULL ? 0 : sqlite3_column_int64(stmt->handle, column);
}

const char *sf_column_text(sf_stmt *stmt, int column) {
    return stmt == NULL ? NULL : (const char *)sqlite3_column_text(stmt->handle, column);
}
