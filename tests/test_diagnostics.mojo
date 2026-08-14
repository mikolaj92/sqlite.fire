from sqlite_fire import Connection, OpenOptions
from sqlite_fire.sqlite import SQLITE_MISUSE, SQLITE_READONLY, SQLITE_RANGE, error_code


def main() raises:
    var options = OpenOptions()
    options.flags = 0
    var invalid = False
    try:
        var bad = Connection(":memory:", options)
        assert False
    except:
        invalid = True
    assert invalid

    var db = Connection(":memory:")
    db.execute("CREATE TABLE diagnostics (id INTEGER PRIMARY KEY, note TEXT COLLATE BINARY NOT NULL)")
    var filename = db.filename()
    assert filename != ""
    var metadata = db.table_column_metadata("main", "diagnostics", "note")
    assert metadata.declared_type == "TEXT"
    assert metadata.collation == "BINARY"
    assert metadata.not_null
    assert not metadata.primary_key
    assert not metadata.auto_increment

    var stmt = db.query("SELECT id, note FROM diagnostics")
    assert stmt.parameter_count() == 0
    assert stmt.bind_parameter_index(":missing") == 0
    assert stmt.readonly()
    assert stmt.data_count() == 0
    assert stmt.sql() != ""
    assert stmt.column_database_name(0) == "main"
    assert stmt.column_table_name(0) == "diagnostics"
    assert stmt.column_origin_name(0) == "id"
    assert stmt.column_decltype(0) == "INTEGER"
    stmt.close()

    var prior = db.get_limit(0)
    assert prior > 0
    assert db.limit(0, prior) == prior
    var range_failed = False
    try:
        _ = db.limit(-1, 1)
        assert False
    except e:
        range_failed = True
        assert error_code(e) == Int(SQLITE_RANGE)
    assert range_failed
    db.close()
