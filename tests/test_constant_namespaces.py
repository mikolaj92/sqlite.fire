import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SQLITE_MOJO = (ROOT / "src/sqlite_fire/sqlite.mojo").read_text()
INIT_MOJO = (ROOT / "src/sqlite_fire/__init__.mojo").read_text()
README = (ROOT / "README.md").read_text()
HEADER = (ROOT / "native/sqlite_fire.h").read_text()
LOCKING = (ROOT / "tests/test_go_uri_locking.mojo").read_text()
PACKAGE_MOJO = sorted((ROOT / "src/sqlite_fire").glob("*.mojo"))


def _comptime_int32(name: str) -> int:
    match = re.search(rf"comptime {name}: Int32 = (\d+)", SQLITE_MOJO)
    assert match is not None, name
    return int(match.group(1))


BARE_DATATYPES = (
    "SQLITE_NULL",
    "SQLITE_INTEGER",
    "SQLITE_REAL",
    "SQLITE_TEXT",
    "SQLITE_BLOB",
)


def _comptime_names(text: str) -> set[str]:
    return set(re.findall(r"^comptime (SQLITE_[A-Z0-9_]+)[:\s=]", text, re.M))


def _exported_names(text: str) -> set[str]:
    names: set[str] = set()
    for block in re.findall(
        r"from \.\w+ import\s+(\([^)]*\)|[^\n]+)", text
    ):
        names.update(re.findall(r"\bSQLITE_[A-Z0-9_]+\b", block))
    return names


def _imported_sqlite_names(text: str) -> set[str]:
    names: set[str] = set()
    for block in re.findall(
        r"from sqlite_fire(?:\.\w+)? import\s+(\([^)]*\)|[^\n]+)", text
    ):
        names.update(re.findall(r"\bSQLITE_[A-Z0-9_]+\b", block))
    return names


def test_column_types_use_distinct_names_from_result_codes():
    exported = _exported_names(INIT_MOJO)
    names = set(exported)
    for path in PACKAGE_MOJO:
        names |= _comptime_names(path.read_text())
    # Public package export, not a substring in a comment or a private comptime.
    for name in (
        "SQLITE_INTEGER_TYPE",
        "SQLITE_REAL_TYPE",
        "SQLITE_TEXT_TYPE",
        "SQLITE_BLOB_TYPE",
        "SQLITE_NULL_TYPE",
        "SQLITE_ERROR",
        "SQLITE_BUSY",
        "SQLITE_OK",
    ):
        assert name in exported, name
        assert name in names, name
    # Bare datatype names collide with result codes 1 and 5. Keep them off the
    # public module — aliases such as SQLITE_NULL = SQLITE_NULL_TYPE are the
    # same footgun as comptime SQLITE_NULL: Int32 = 5.
    for bare in BARE_DATATYPES:
        assert bare not in exported, bare
        assert bare not in names, bare


def test_public_modules_do_not_alias_bare_datatype_names():
    # SQLITE_NULL = SQLITE_NULL_TYPE is the same public footgun as comptime SQLITE_NULL = 5.
    for path in PACKAGE_MOJO:
        text = path.read_text()
        for bare in BARE_DATATYPES:
            assert (
                re.search(
                    rf"^(?:(?:comptime|alias)\s+)?{bare}(?:\s*:\s*\w+)?\s*=",
                    text,
                    re.M,
                )
                is None
            ), f"{path.name}: {bare}"
            assert (
                re.search(rf"\bas\s+{bare}\b", text) is None
            ), f"{path.name}: as {bare}"


def _code_lines(text: str):
    # Mask literals before comments: a # inside SQL is not a Mojo comment.
    literals = re.compile(r'''"""[\s\S]*?"""|\x27\x27\x27[\s\S]*?\x27\x27\x27|"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27|\#[^\n]*''')
    text = literals.sub(lambda m: " " + "\n" * m.group().count("\n"), text)
    yield from text.splitlines()


def _code_statements(text: str):
    # error_code(e) == Int(\n SQLITE_NULL_TYPE) is the original footgun split
    # across lines. Join on paren depth so a wrap is one statement.
    # error_code(e)\n== Int(SQLITE_NULL_TYPE) is the same footgun without an
    # open paren; join == / != continuations too.
    buf = []
    current = ""
    depth = 0
    for line in _code_lines(text):
        stripped = line.strip()
        if not stripped and depth == 0:
            continue
        join = bool(current) and (
            depth > 0
            or current.endswith(("==", "!="))
            or stripped.startswith(("==", "!="))
        )
        if current and not join:
            buf.append(current)
            current = ""
            depth = 0
        current = f"{current} {stripped}".strip() if current else stripped
        depth += stripped.count("(") - stripped.count(")")
        if depth < 0:
            depth = 0
    if current:
        buf.append(current)
    return buf


def _mojo_sources():
    for directory in ("src", "tests", "examples"):
        yield from sorted((ROOT / directory).rglob("*.mojo"))


def test_mojo_tests_do_not_import_bare_datatype_names():
    for path in sorted((ROOT / "tests").glob("*.mojo")):
        imported = _imported_sqlite_names(path.read_text())
        for bare in BARE_DATATYPES:
            assert bare not in imported, f"{path.name}: {bare}"


def test_mojo_sources_do_not_use_bare_datatype_names():
    token = re.compile(r"\b(" + "|".join(BARE_DATATYPES) + r")\b")
    for path in _mojo_sources():
        for line in _code_lines(path.read_text()):
            match = token.search(line)
            assert match is None, f"{path}: {match.group(1)}"


def _crosses_namespaces(text: str) -> bool:
    # error_code(e) == Int(SQLITE_NULL_TYPE) is the original BUSY/NULL footgun.
    # SQLiteError.code == SQLITE_NULL_TYPE is the same collision on the field.
    # SQLITE_ERROR == SQLITE_INTEGER_TYPE is the same collision under renamed types.
    result_api = re.compile(
        r"\b(?:error_code|step_code|extended_error_code)\s*\(|\bcode\b"
    )
    type_api = re.compile(r"\bcolumn_type\s*\(|\bkind\b")
    type_name = re.compile(r"\bSQLITE_(?:INTEGER|REAL|TEXT|BLOB|NULL)_TYPE\b")
    result_name = re.compile(
        r"\bSQLITE_(?:OK|ERROR|BUSY|READONLY|NOTFOUND|CANTOPEN|CONSTRAINT|MISUSE|RANGE|ROW|DONE|NOMEM)\b"
    )
    for stmt in _code_statements(text):
        # These direct expressions share Python syntax; this is a bounded
        # source contract, not a Mojo parser or a dataflow/type checker.
        stmt = re.sub(r"^(?:var|comptime)\s+", "", stmt)
        stmt = re.sub(r"^(?:if|elif|while)\s+", "", stmt).removesuffix(":")
        try:
            tree = ast.parse(stmt)
        except SyntaxError:
            continue
        for node in ast.walk(tree):
            if isinstance(node, ast.Compare):
                operands = [node.left, *node.comparators]
                for left, right in zip(operands, operands[1:]):
                    pair = ast.unparse(left) + " " + ast.unparse(right)
                    if (result_api.search(pair) and type_name.search(pair)
                        or type_api.search(pair) and result_name.search(pair)
                        or result_name.search(pair) and type_name.search(pair)):
                        return True
            elif isinstance(node, ast.keyword) and node.arg in ("kind", "code"):
                value = ast.unparse(node.value)
                if (node.arg == "kind" and result_name.search(value)
                    or node.arg == "code" and type_name.search(value)):
                    return True
            elif isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                value = ast.unparse(node.value) if node.value is not None else ""
                for target in targets:
                    name = ast.unparse(target).split(".")[-1]
                    if (name == "kind" and result_name.search(value)
                        or name == "code" and type_name.search(value)):
                        return True
    return False


def test_mojo_does_not_cross_compare_result_codes_with_column_types():
    for path in _mojo_sources():
        assert not _crosses_namespaces(path.read_text()), str(path)


def test_namespace_scanner_ignores_literals_and_independent_operands():
    valid = '''assert db.error_code() == Int(SQLITE_OK) and rows.column_type(0) == Int(SQLITE_INTEGER_TYPE)
assert (rows.kind == Int(SQLITE_NULL_TYPE)) or (db.code == Int(SQLITE_BUSY))
return Value(kind=Int(SQLITE_NULL_TYPE), code=Int(SQLITE_BUSY))
var sql = "SELECT 'SQLITE_NULL', '# SQLITE_INTEGER'"
"""SQLITE_NULL and error_code(e) == SQLITE_NULL_TYPE"""
# SQLITE_INTEGER
'''
    assert not _crosses_namespaces(valid)
    assert "SQLITE_NULL" not in "\n".join(_code_lines(valid)).split("var sql", 1)[1]
    for invalid in (
        "assert db.error_code() == Int(SQLITE_NULL_TYPE)",
        "assert rows.column_type(0) != Int(SQLITE_BUSY)",
        "assert SQLITE_ERROR == SQLITE_INTEGER_TYPE",
        "return Value(kind=Int(SQLITE_BUSY), code=Int(SQLITE_ERROR))",
        "return Value(kind=Int(SQLITE_NULL_TYPE), code=Int(SQLITE_NULL_TYPE))",
        "var kind = Int(SQLITE_BUSY)",
        "db.code = Int(SQLITE_INTEGER_TYPE)",
        "assert error_code(e) == Int(\nSQLITE_NULL_TYPE)",
    ):
        assert _crosses_namespaces(invalid), invalid


def test_canonical_runner_gates_name_families():
    runner = (ROOT / "scripts/test.sh").read_text()
    assert "python3 tests/test_constant_namespaces.py" in runner
    source = Path(__file__).read_text()
    module = ast.parse(source)
    main = None
    for node in module.body:
        if not isinstance(node, ast.If) or not isinstance(node.test, ast.Compare):
            continue
        test = node.test
        if not isinstance(test.left, ast.Name) or test.left.id != "__name__":
            continue
        if any(
            isinstance(comparator, ast.Constant) and comparator.value == "__main__"
            for comparator in test.comparators
        ):
            main = node
            break
    assert main is not None
    # pixi run test invokes this file via python3, not pytest. Named test_*()
    # calls in __main__ would drop new contract tests from the canonical gate.
    named = [
        call.func.id
        for call in ast.walk(main)
        if isinstance(call, ast.Call)
        and isinstance(call.func, ast.Name)
        and call.func.id.startswith("test_")
    ]
    assert named == []
    main_src = ast.get_source_segment(source, main) or ast.unparse(main)
    assert 'startswith("test_")' in main_src or "startswith('test_')" in main_src


def test_c_abi_does_not_export_mojo_type_names():
    header = (ROOT / "native/sqlite_fire.h").read_text()
    source = (ROOT / "native/sqlite_fire.c").read_text()
    for name in (
        "SQLITE_INTEGER_TYPE",
        "SQLITE_REAL_TYPE",
        "SQLITE_TEXT_TYPE",
        "SQLITE_BLOB_TYPE",
        "SQLITE_NULL_TYPE",
    ):
        assert name not in header
        assert name not in source


def test_docs_forbid_crossing_result_codes_with_column_types():
    # Names distinguish the domains; Int32 does not enforce type safety.
    assert "typed SQLite result codes" not in README
    assert "SQLITE_INTEGER_TYPE" in README
    assert "SQLITE_NULL_TYPE" in README
    assert "result code" in README.lower() or "kody wyniku" in README.lower()
    assert "SQLITE_BUSY" in README and "SQLITE_NULL_TYPE" in README
    assert "datatype" in HEADER or "column type" in HEADER or "sqlite3_column_type" in HEADER
    assert "Result code from sqlite3_errcode, not a column datatype." in HEADER
    assert "Result code from sqlite3_extended_errcode, not a column datatype." in HEADER
    assert "Result code from sqlite3_step, not a column datatype." in HEADER
    assert "not a result code" in SQLITE_MOJO
    assert "never with column datatypes" in SQLITE_MOJO
    assert "Do not compare it with ``SQLITE_INTEGER_TYPE`` or" in SQLITE_MOJO
    assert "``SQLITE_NULL_TYPE``." in SQLITE_MOJO
    assert SQLITE_MOJO.count(
        "Do not compare it with ``SQLITE_INTEGER_TYPE`` or ``SQLITE_NULL_TYPE``."
    ) >= 3
    assert "Return sqlite3_errcode, a result code, not a column datatype." in SQLITE_MOJO
    assert "Return sqlite3_extended_errcode, a result code, not a column datatype." in SQLITE_MOJO
    assert "Return sqlite3_step, a result code, not a column datatype." in SQLITE_MOJO
    assert "Return sqlite3_column_type, a column datatype (``SQLITE_INTEGER_TYPE`` ... ``SQLITE_NULL_TYPE``), not a result code." in SQLITE_MOJO
    assert "Do not compare it with ``SQLITE_ERROR`` or ``SQLITE_BUSY``." in SQLITE_MOJO
    assert "SQLITE_INTEGER_TYPE" in INIT_MOJO
    assert "SQLITE_REAL_TYPE" in INIT_MOJO
    assert "SQLITE_TEXT_TYPE" in INIT_MOJO
    assert "SQLITE_BLOB_TYPE" in INIT_MOJO
    assert "SQLITE_NULL_TYPE" in INIT_MOJO
    assert "SQLITE_ERROR" in INIT_MOJO
    assert "SQLITE_BUSY" in INIT_MOJO


def test_busy_lock_assert_uses_result_code_name():
    assert "error_code(e) == Int(SQLITE_BUSY)" in LOCKING
    assert "SQLITE_NULL)" not in LOCKING
    assert "null_row.column_type(0) == Int(SQLITE_NULL_TYPE)" in LOCKING
    assert "contender.error_code() == Int(SQLITE_BUSY)" in LOCKING


def test_colliding_integers_keep_distinct_names():
    assert _comptime_int32("SQLITE_OK") == 0
    assert _comptime_int32("SQLITE_ERROR") == 1
    assert _comptime_int32("SQLITE_INTEGER_TYPE") == 1
    assert _comptime_int32("SQLITE_REAL_TYPE") == 2
    assert _comptime_int32("SQLITE_TEXT_TYPE") == 3
    assert _comptime_int32("SQLITE_BLOB_TYPE") == 4
    assert _comptime_int32("SQLITE_BUSY") == 5
    assert _comptime_int32("SQLITE_NULL_TYPE") == 5


if __name__ == "__main__":
    expected = [
        node.name
        for node in ast.parse(Path(__file__).read_text()).body
        if isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
    ]
    tests = [
        value
        for name, value in sorted(globals().items())
        if name.startswith("test_") and callable(value)
    ]
    found = [test.__name__ for test in tests]
    if found != sorted(expected):
        raise SystemExit(
            f"name-contract discovery mismatch: {found} != {sorted(expected)}"
        )
    if not tests:
        raise SystemExit("no name-contract tests discovered")
    for test in tests:
        test()
