#ifndef SQLITE_FIRE_H
#define SQLITE_FIRE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sf_db sf_db;
typedef struct sf_stmt sf_stmt;

/* SQLite results are SQLite-compatible: 0 means success. */
int sf_open(const char *filename, sf_db **out_db);
int sf_close(sf_db *db);
const char *sf_errmsg(sf_db *db);

int sf_exec(sf_db *db, const char *sql);
int sf_prepare(sf_db *db, const char *sql, sf_stmt **out_stmt);
int sf_step(sf_stmt *stmt);
int sf_finalize(sf_stmt *stmt);

int sf_column_count(sf_stmt *stmt);
const char *sf_column_name(sf_stmt *stmt, int column);
int sf_column_type(sf_stmt *stmt, int column);
long long sf_column_int64(sf_stmt *stmt, int column);
const char *sf_column_text(sf_stmt *stmt, int column);

#ifdef __cplusplus
}
#endif

#endif
