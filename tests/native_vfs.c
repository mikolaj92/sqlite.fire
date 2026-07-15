#include "sqlite_fire.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    const char *path = "/tmp/sqlite_fire_vfs_test.db";
    remove(path);
    sf_vfs *vfs = NULL;
    assert(sf_vfs_register_passthrough("sqlite_fire_test_vfs", "unix", 0, &vfs) == SQLITE_OK);
    assert(vfs != NULL);
    sf_db *db = NULL;
    assert(sf_open_options(path, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                           "sqlite_fire_test_vfs", &db) == SQLITE_OK);
    assert(db != NULL);
    assert(sf_exec(db, "CREATE TABLE t(value INTEGER)") == SQLITE_OK);
    assert(sf_exec(db, "INSERT INTO t VALUES (7)") == SQLITE_OK);
    assert(sf_vfs_unregister(vfs) == SQLITE_MISUSE);
    assert(sf_close(db) == SQLITE_OK);
    assert(sf_vfs_unregister(vfs) == SQLITE_OK);
    assert(sf_vfs_unregister(vfs) == SQLITE_OK);
    assert(sf_vfs_register_passthrough("", "unix", 0, &vfs) == SQLITE_MISUSE);
    assert(sf_vfs_register_passthrough("sqlite_fire_missing_vfs", "missing", 0, &vfs) == SQLITE_NOTFOUND);
    remove(path);
    puts("native VFS tests passed");
    return 0;
}
