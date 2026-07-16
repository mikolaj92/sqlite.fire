from sqlite_fire.sqlite import Connection, SQLITE_DONE

def main() raises:
    var db = Connection(":memory:\0")

    # go-sqlite3 accepts an empty SQL string for both Exec and Query.
    db.execute("\0")
    var empty = db.query("\0")
    assert empty.column_count() == 0
    assert empty.step_code() == Int(SQLITE_DONE)
    empty.close()

    # Whitespace-only input is also a successful no-op.
    db.execute("  \n\t  \0")
    var whitespace = db.query("  \n\t  \0")
    assert whitespace.column_count() == 0
    assert whitespace.step_code() == Int(SQLITE_DONE)
    whitespace.close()

    # A line comment with no statement is a successful no-op.
    db.execute("-- line comment only\n\0")
    var line_comment = db.query("-- line comment only\n\0")
    assert line_comment.column_count() == 0
    assert line_comment.step_code() == Int(SQLITE_DONE)
    line_comment.close()

    # A block comment with no statement is a successful no-op.
    db.execute("/* block comment only */\0")
    var block_comment = db.query("/* block comment only */\0")
    assert block_comment.column_count() == 0
    assert block_comment.step_code() == Int(SQLITE_DONE)
    block_comment.close()

    # Semicolon-only input prepares an empty statement and executes cleanly.
    db.execute(";;;\0")
    var semicolons = db.query(";;;\0")
    assert semicolons.column_count() == 0
    assert semicolons.step_code() == Int(SQLITE_DONE)
    semicolons.close()

    db.close()
