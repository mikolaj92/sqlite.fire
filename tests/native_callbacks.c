#include "sqlite_fire.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static int scalar_calls;

static void scalar_add(void *userdata, sqlite3_context *context, int argc, sqlite3_value **argv) {
    int offset = userdata == NULL ? 0 : *(const int *)userdata;
    assert(argc == 1);
    ++scalar_calls;
    sqlite3_result_int(context, sqlite3_value_int(argv[0]) + offset);
}

static void scalar_replacement(void *userdata, sqlite3_context *context, int argc, sqlite3_value **argv) {
    (void)userdata;
    assert(argc == 1);
    ++scalar_calls;
    sqlite3_result_int(context, sqlite3_value_int(argv[0]) * 10);
}

static int collation_calls;

static int reverse_collation(void *userdata, int left_length, const void *left, int right_length, const void *right) {
    (void)userdata;
    ++collation_calls;
    int result = sqlite3_strnicmp((const char *)left, (const char *)right,
                                  left_length < right_length ? left_length : right_length);
    if (result == 0 && left_length != right_length) result = left_length < right_length ? -1 : 1;
    return -result;
}

static int progress_calls;

static int progress_callback(void *userdata) {
    int *calls = (int *)userdata;
    ++*calls;
    ++progress_calls;
    return 0;
}

static int query_int(sf_db *db, const char *sql) {
    sf_stmt *stmt = NULL;
    assert(sf_prepare(db, sql, &stmt) == SQLITE_OK);
    assert(stmt != NULL);
    assert(sf_step(stmt) == SQLITE_ROW);
    int value = (int)sf_column_int64(stmt, 0);
    assert(sf_step(stmt) == SQLITE_DONE);
    assert(sf_finalize(stmt) == SQLITE_OK);
    return value;
}

static const char *query_text(sf_db *db, const char *sql) {
    static char value[64];
    sf_stmt *stmt = NULL;
    assert(sf_prepare(db, sql, &stmt) == SQLITE_OK);
    assert(stmt != NULL);
    assert(sf_step(stmt) == SQLITE_ROW);
    const char *text = sf_column_text(stmt, 0);
    assert(text != NULL);
    snprintf(value, sizeof(value), "%s", text);
    assert(sf_step(stmt) == SQLITE_DONE);
    assert(sf_finalize(stmt) == SQLITE_OK);
    return value;
}

static void test_scalar_lifecycle(sf_db *db) {
    int offset = 7;
    scalar_calls = 0;
    assert(sf_create_scalar_function(NULL, "native_add", 1, SQLITE_UTF8, scalar_add, &offset) == SQLITE_MISUSE);
    assert(sf_create_scalar_function(db, NULL, 1, SQLITE_UTF8, scalar_add, &offset) == SQLITE_MISUSE);
    assert(sf_create_scalar_function(db, "native_add", 1, SQLITE_UTF8, NULL, &offset) == SQLITE_MISUSE);
    assert(sf_create_scalar_function(db, "native_add", -2, SQLITE_UTF8, scalar_add, &offset) == SQLITE_MISUSE);
    assert(sf_create_scalar_function(db, "native_add", 128, SQLITE_UTF8, scalar_add, &offset) == SQLITE_MISUSE);

    assert(sf_create_scalar_function(db, "native_add", 1, SQLITE_UTF8, scalar_add, &offset) == SQLITE_OK);
    assert(query_int(db, "SELECT native_add(5)") == 12);
    assert(scalar_calls == 1);

    assert(sf_create_scalar_function(db, "native_add", 1, SQLITE_UTF8, scalar_replacement, NULL) == SQLITE_OK);
    assert(query_int(db, "SELECT native_add(5)") == 50);
    assert(scalar_calls == 2);

    assert(sf_remove_scalar_function(db, "native_add", 1, SQLITE_UTF8) == SQLITE_OK);
    assert(sf_remove_scalar_function(db, "native_add", 1, SQLITE_UTF8) == SQLITE_OK);
    sf_stmt *stmt = NULL;
    assert(sf_prepare(db, "SELECT native_add(5)", &stmt) != SQLITE_OK);
    assert(stmt == NULL);
    assert(scalar_calls == 2);
    assert(sf_remove_scalar_function(NULL, "native_add", 1, SQLITE_UTF8) == SQLITE_MISUSE);
    assert(sf_remove_scalar_function(db, NULL, 1, SQLITE_UTF8) == SQLITE_MISUSE);
}

static void test_collation_lifecycle(sf_db *db) {
    collation_calls = 0;
    assert(sf_exec(db, "CREATE TABLE words(value TEXT)") == SQLITE_OK);
    assert(sf_exec(db, "INSERT INTO words VALUES ('a'), ('b')") == SQLITE_OK);
    assert(sf_create_collation(NULL, "NATIVE_REVERSE", SQLITE_UTF8, reverse_collation, NULL) == SQLITE_MISUSE);
    assert(sf_create_collation(db, NULL, SQLITE_UTF8, reverse_collation, NULL) == SQLITE_MISUSE);
    assert(sf_create_collation(db, "NATIVE_REVERSE", SQLITE_UTF8, NULL, NULL) == SQLITE_MISUSE);
    assert(sf_create_collation(db, "NATIVE_REVERSE", SQLITE_UTF8, reverse_collation, NULL) == SQLITE_OK);
    assert(strcmp(query_text(db, "SELECT value FROM words ORDER BY value COLLATE NATIVE_REVERSE LIMIT 1"), "b") == 0);
    assert(collation_calls > 0);

    assert(sf_remove_collation(db, "NATIVE_REVERSE", SQLITE_UTF8) == SQLITE_OK);
    assert(sf_remove_collation(db, "NATIVE_REVERSE", SQLITE_UTF8) == SQLITE_OK);
    int calls_after_remove = collation_calls;
    sf_stmt *stmt = NULL;
    assert(sf_prepare(db, "SELECT value FROM words ORDER BY value COLLATE NATIVE_REVERSE", &stmt) != SQLITE_OK);
    assert(stmt == NULL);
    assert(collation_calls == calls_after_remove);
    assert(sf_remove_collation(NULL, "NATIVE_REVERSE", SQLITE_UTF8) == SQLITE_MISUSE);
    assert(sf_remove_collation(db, NULL, SQLITE_UTF8) == SQLITE_MISUSE);
}

static void test_progress_lifecycle(sf_db *db) {
    progress_calls = 0;
    int userdata_calls = 0;
    assert(sf_set_progress_handler(NULL, 1, progress_callback, &userdata_calls) == SQLITE_MISUSE);
    assert(sf_set_progress_handler(db, 0, progress_callback, &userdata_calls) == SQLITE_MISUSE);
    assert(sf_set_progress_handler(db, 1, NULL, &userdata_calls) == SQLITE_MISUSE);
    assert(sf_set_progress_handler(db, 1, progress_callback, &userdata_calls) == SQLITE_OK);
    assert(sf_exec(db, "WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM c WHERE x<1000) SELECT sum(x) FROM c") == SQLITE_OK);
    assert(progress_calls > 0);
    assert(userdata_calls == progress_calls);
    assert(sf_clear_progress_handler(db) == SQLITE_OK);
    int calls_after_clear = progress_calls;
    assert(sf_exec(db, "SELECT 1") == SQLITE_OK);
    assert(progress_calls == calls_after_clear);
    assert(sf_clear_progress_handler(db) == SQLITE_OK);
    assert(sf_clear_progress_handler(NULL) == SQLITE_MISUSE);
}

int main(void) {
    sf_db *db = NULL;
    assert(sf_open(":memory:", &db) == SQLITE_OK);
    assert(db != NULL);
    test_scalar_lifecycle(db);
    test_collation_lifecycle(db);
    test_progress_lifecycle(db);
    assert(sf_close(db) == SQLITE_OK);
    puts("native callback tests passed");
    return 0;
}
