from sqlite_fire.sqlite import Connection

# Mojo's current wrapper does not expose a thread/callback-concurrency API.  This
# stress test therefore exercises the supported model directly: each iteration
# owns a fresh connection and verifies that its in-memory state is isolated.
def main() raises:
    var worker = 0
    while worker < 8:
        var db = Connection(":memory:\0")
        db.execute("CREATE TABLE values_for_worker (value INTEGER NOT NULL)\0")

        # The prepared statement belongs to this connection for its whole use.
        var insert = db.query("INSERT INTO values_for_worker(value) VALUES (?)\0")
        var row = 0
        while row < 64:
            insert.bind_int(1, worker * 1000 + row)
            assert not insert.step()
            insert.reset()
            row += 1
        insert.close()

        var check = db.query("SELECT count(*), min(value), max(value), sum(value) FROM values_for_worker\0")
        assert check.step()
        assert check.column_int(0) == 64
        assert check.column_int(1) == worker * 1000
        assert check.column_int(2) == worker * 1000 + 63
        assert check.column_int(3) == worker * 64000 + 2016
        assert not check.step()
        check.close()
        db.close()

        worker += 1
