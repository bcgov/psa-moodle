#!/usr/bin/env python3
"""Statement-level allowlist for a return dump (runbook §8.3 Return, RB13; review V1014).

Reads a `mariadb-dump <one database>` file on stdin (decompressed) and accepts only the forms that dump writes. Each
INSERT line must be EXACTLY one statement: `INSERT INTO `t` [(`c`,...)] VALUES (v,...),(v,...);` where every value is a
complete literal (a quoted string with MariaDB's backslash escapes, a number, NULL, 0x hex, b'bits', or _binary '...'),
so nothing can follow the row data on that line. Row data is never printed. Writes the table list to argv[1].
Exit 0 = accepted, 1 = rejected.
"""
import re
import sys

T = r"`[A-Za-z0-9_]+`"
STRING = r"'(?:[^'\\]++|\\.|'')*+'"
# Order matters: the repetitions below are possessive (no backtracking into a matched value), so 0x... and b'...'
# must be tried before a plain number would take their leading 0.
VALUE = (r"(?:NULL|0x[0-9A-Fa-f]++|b'[01]*+'|(?:_binary )?" + STRING
         + r"|-?[0-9]++(?:\.[0-9]++)?+(?:[eE][-+]?[0-9]++)?+)")
TUPLE = r"\(" + VALUE + r"(?:," + VALUE + r")*+\)"
INSERT = re.compile(r"INSERT INTO " + T + r" (?:\(" + T + r"(?:," + T + r")*+\) )?VALUES " + TUPLE
                    + r"(?:," + TUPLE + r")*+;", re.S)
SIMPLE = [re.compile(p) for p in (
    r"DROP TABLE IF EXISTS " + T + ";",
    r"LOCK TABLES " + T + " WRITE;",
    r"UNLOCK TABLES;",
    r"/\*M!999999\\- enable the sandbox mode \*/ *",
    r"/\*![0-9]+ SET [A-Za-z0-9_@ =,()'+:.-]*\*/;",
    r"/\*![0-9]+ ALTER TABLE " + T + r" (?:DISABLE|ENABLE) KEYS \*/;",
)]
CREATE = re.compile(r"CREATE TABLE (" + T + r") \(")
CREATE_LINE = re.compile(r"  (?:`[A-Za-z0-9_]+` |PRIMARY KEY |UNIQUE KEY |KEY |FULLTEXT KEY ).*")
CREATE_END = re.compile(r"\) ENGINE=[A-Za-z0-9_= ]+.*;")
FORBIDDEN = re.compile(r"(DATABASE|TRIGGER|DEFINER|PROCEDURE|FUNCTION|EVENT|VIEW|GRANT|USE )")


def main():
    tables, inserts, bad, increate = [], 0, 0, False

    def reject(n, why, line):
        nonlocal bad
        bad += 1
        if bad <= 20:
            print(f"REJECT line {n}: {why}: {line[:60]}")

    for n, raw in enumerate(sys.stdin.buffer, 1):
        line = raw.decode("utf-8", "surrogateescape").rstrip("\n")
        if increate:
            if CREATE_END.fullmatch(line):
                increate = False
            elif not CREATE_LINE.fullmatch(line):
                reject(n, "unexpected line inside CREATE TABLE", line)
            continue
        if line == "" or line.startswith("--"):
            continue
        if line.startswith("INSERT INTO "):
            if INSERT.fullmatch(line):
                inserts += 1
            else:
                reject(n, "not exactly one well-formed INSERT into an unqualified table", line)
            continue
        if line.startswith("/*!") and FORBIDDEN.search(line):
            reject(n, "forbidden statement in versioned comment", line)
            continue
        if any(p.fullmatch(line) for p in SIMPLE):
            continue
        m = CREATE.fullmatch(line)
        if m:
            increate = True
            tables.append(m.group(1).strip("`"))
            continue
        reject(n, "statement not allowed in a single-database dump", line)
    if increate:
        print("REJECT: dump ends inside a CREATE TABLE")
        bad += 1
    with open(sys.argv[1], "w") as f:
        f.writelines(t + "\n" for t in tables)
    print(f"tables: {len(tables)}, INSERT statements: {inserts}, problems: {bad}")
    return 1 if bad or not tables else 0


if __name__ == "__main__":
    sys.exit(main())
