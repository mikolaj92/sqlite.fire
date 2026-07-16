from std.collections import List
from sqlite_fire.sqlite import Connection, SQLITE_BLOB, SQLITE_INTEGER, SQLITE_NULL, SQLITE_REAL, SQLITE_TEXT

def main() raises:
    var db = Connection(":memory:")

    # Prepared scalar bindings preserve NULL and REAL values and convert integer booleans.
    var scalars = db.query("SELECT ?, ?, ?, ?")
    scalars.bind_null(1)
    scalars.bind_real(2, 2.75)
    scalars.bind_int(3, 1)
    scalars.bind_int(4, 0)
    assert scalars.step()
    assert scalars.column_type(0) == Int(SQLITE_NULL)
    assert scalars.column_null(0)
    assert scalars.column_text(0) == ""
    assert scalars.column_type(1) == Int(SQLITE_REAL)
    assert scalars.column_real(1) == 2.75
    assert scalars.column_type(2) == Int(SQLITE_INTEGER)
    assert scalars.column_int(2) == 1
    assert scalars.column_type(3) == Int(SQLITE_INTEGER)
    assert scalars.column_int(3) == 0
    assert not scalars.step()
    scalars.close()

    # INTEGER affinity stores an integral REAL as INTEGER, while preserving a fraction as REAL.
    db.execute("CREATE TABLE affinity (value INTEGER)")
    var affinity_insert = db.query("INSERT INTO affinity(value) VALUES (?)")
    affinity_insert.bind_real(1, 7.0)
    assert not affinity_insert.step()
    affinity_insert.reset()
    affinity_insert.bind_real(1, 7.5)
    assert not affinity_insert.step()
    affinity_insert.close()

    var affinity_rows = db.query("SELECT value FROM affinity ORDER BY rowid")
    assert affinity_rows.step()
    assert affinity_rows.column_type(0) == Int(SQLITE_INTEGER)
    assert affinity_rows.column_int(0) == 7
    assert affinity_rows.step()
    assert affinity_rows.column_type(0) == Int(SQLITE_REAL)
    assert affinity_rows.column_real(0) == 7.5
    assert not affinity_rows.step()
    affinity_rows.close()

    # bind_null is distinct from an explicitly bound empty BLOB.
    db.execute("CREATE TABLE payloads (payload BLOB)")
    var payload_insert = db.query("INSERT INTO payloads(payload) VALUES (?)")
    payload_insert.bind_null(1)
    assert not payload_insert.step()
    payload_insert.reset()
    var empty = List[UInt8]()
    payload_insert.bind_blob(1, empty)
    assert not payload_insert.step()
    payload_insert.close()

    var payload_rows = db.query("SELECT payload FROM payloads ORDER BY rowid")
    assert payload_rows.step()
    assert payload_rows.column_type(0) == Int(SQLITE_NULL)
    assert payload_rows.column_null(0)
    assert len(payload_rows.column_blob(0)) == 0
    assert payload_rows.step()
    assert payload_rows.column_type(0) == Int(SQLITE_BLOB)
    assert not payload_rows.column_null(0)
    assert len(payload_rows.column_blob(0)) == 0
    assert not payload_rows.step()
    payload_rows.close()

    # clear_bindings on a named INSERT restores unbound parameters to SQL NULL.
    db.execute("CREATE TABLE named_values (left_value TEXT, right_value INTEGER)")
    var named_insert = db.query("INSERT INTO named_values(left_value, right_value) VALUES (:left, :right)")
    named_insert.bind_text(1, "bound")
    named_insert.bind_int(2, 42)
    assert not named_insert.step()
    named_insert.reset()
    named_insert.clear_bindings()
    assert not named_insert.step()
    named_insert.close()

    var named_rows = db.query("SELECT left_value, right_value FROM named_values ORDER BY rowid")
    assert named_rows.step()
    assert named_rows.column_type(0) == Int(SQLITE_TEXT)
    assert named_rows.column_text(0) == "bound"
    assert named_rows.column_type(1) == Int(SQLITE_INTEGER)
    assert named_rows.column_int(1) == 42
    assert named_rows.step()
    assert named_rows.column_type(0) == Int(SQLITE_NULL)
    assert named_rows.column_null(0)
    assert named_rows.column_type(1) == Int(SQLITE_NULL)
    assert named_rows.column_null(1)
    assert not named_rows.step()
    named_rows.close()
    db.close()
