from sqlite_fire.sqlite import Connection, SQLITE_INTEGER, SQLITE_MISUSE, SQLITE_NULL, SQLITE_RANGE, error_code

def main() raises:
    var db = Connection(":memory:\0")
    db.execute("CREATE TABLE binding_values (id INTEGER PRIMARY KEY, label TEXT)\0")

    # Parameter count and names follow SQLite's left-to-right numbering.
    var named = db.query("SELECT ?1, :label, @other, ?\0")
    assert named.parameter_count() == 4
    assert named.parameter_name(1) == "?1"
    assert named.parameter_name(2) == ":label"
    assert named.parameter_name(3) == "@other"

    # Name and binding indexes are one-based; both boundaries reject cleanly.
    try:
        _ = named.parameter_name(0)
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_RANGE)
    try:
        _ = named.parameter_name(5)
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_RANGE)
    try:
        named.bind_int(0, 1)
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_RANGE)
    try:
        named.bind_int(5, 1)
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_RANGE)
    named.close()

    # Repeated names share one slot; an unbound positional slot remains NULL.
    var repeated = db.query("SELECT :same, :same, ?\0")
    assert repeated.parameter_count() == 2
    assert repeated.parameter_name(1) == ":same"
    repeated.bind_int(1, 7)
    assert repeated.step()
    assert repeated.column_type(0) == Int(SQLITE_INTEGER)
    assert repeated.column_int(0) == 7
    assert repeated.column_int(1) == 7
    assert repeated.column_type(2) == Int(SQLITE_NULL)
    assert not repeated.step()
    repeated.close()

    # Binding and metadata access after close produce SQLITE_MISUSE.
    var closed = db.query("SELECT ?\0")
    closed.close()
    try:
        closed.bind_null(1)
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_MISUSE)
    try:
        _ = closed.parameter_count()
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_MISUSE)
    try:
        _ = closed.parameter_name(1)
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_MISUSE)
    try:
        _ = closed.step_code()
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_MISUSE)
    try:
        closed.clear_bindings()
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_MISUSE)
    closed.close()

    # A statement without placeholders has count zero and rejects index one.
    var no_params = db.query("SELECT 123\0")
    assert no_params.parameter_count() == 0
    try:
        no_params.bind_text(1, "unexpected")
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_RANGE)
    assert no_params.step()
    assert no_params.column_int(0) == 123
    no_params.close()

    # Column bounds are typed range errors instead of native crashes.
    var columns = db.query("SELECT 1\0")
    try:
        _ = columns.column_int(-1)
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_RANGE)
    try:
        _ = columns.column_text(1)
        assert False
    except e:
        assert error_code(e) == Int(SQLITE_RANGE)
    columns.close()
    db.close()
