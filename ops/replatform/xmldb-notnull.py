#!/usr/bin/env python3
"""List every column Moodle's XMLDB defines as NOT NULL, with its default.

Usage: xmldb-notnull.py <moodle code root>
Output, tab-separated: table, column, type, default (the literal string NODEFAULT when XMLDB gives none).

local-pipeline.sh uses it to find columns the legacy database left nullable (§5.2) and fill any NULLs with
Moodle's own default before tool_dbtransfer builds the NOT NULL target (runbook §8.3).
"""
import glob
import sys
import xml.etree.ElementTree as ET

root = sys.argv[1]
for path in sorted(glob.glob(root + '/**/db/install.xml', recursive=True)):
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        sys.exit(f'cannot parse {path}: {exc}')
    for table in tree.iter('TABLE'):
        for field in table.iter('FIELD'):
            if field.get('NOTNULL') == 'true' and field.get('SEQUENCE') != 'true':
                default = field.get('DEFAULT')
                print('\t'.join([table.get('NAME'), field.get('NAME'), field.get('TYPE'),
                                 'NODEFAULT' if default is None else default]))
