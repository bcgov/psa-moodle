<?php
// Content comparison between two Moodle databases (runbook §8.3 compare-content, R12).
//
// Runs from a Moodle code root whose config.php points at the SOURCE (migrate-config.php). The target is opened with
// Moodle's own DML, so each side's table prefix is handled by its driver. Every table both sides have is read in id
// order and compared row by row; each row is hashed (SHA-256) over all its columns.
//
// Output (never any column VALUES, so it holds no personal data):
//   <out>/summary.tsv   table, source rows, target rows, differing rows, source SHA-256, target SHA-256
//   <out>/rows.tsv      table, id, side (both|source-only|target-only), names of the differing columns
//   <out>/tables.tsv    tables present on one side only
//
// Usage: php compare-content.php --tgttype=pgsql --tgthost=H --tgtname=N --tgtuser=U --tgtpass=P --tgtprefix=mdl_
//                                --out=/data/out [--maxrows=200]
define('CLI_SCRIPT', true);
require(__DIR__ . '/config.php');
require_once($CFG->libdir . '/clilib.php');

[$opt] = cli_get_params(['tgttype' => null, 'tgthost' => null, 'tgtname' => null, 'tgtuser' => null, 'tgtpass' => null,
    'tgtprefix' => '', 'out' => null, 'maxrows' => 200]);
foreach (['tgttype', 'tgthost', 'tgtname', 'tgtuser', 'tgtpass', 'out'] as $k) {
    if ($opt[$k] === null) {
        cli_error("--$k is required");
    }
}
global $DB;
$src = $DB;
$tgt = moodle_database::get_driver_instance($opt['tgttype'], 'native');
$tgt->connect($opt['tgthost'], $opt['tgtuser'], $opt['tgtpass'], $opt['tgtname'], $opt['tgtprefix'],
    ['dbpersist' => 0, 'dbport' => '', 'dbsocket' => '']);

$out = rtrim($opt['out'], '/');
@mkdir($out, 0700, true);
$summary = fopen("$out/summary.tsv", 'w');
$rowsf = fopen("$out/rows.tsv", 'w');
$tablesf = fopen("$out/tables.tsv", 'w');

$srctables = array_keys($src->get_tables(false));
$tgttables = array_keys($tgt->get_tables(false));
sort($srctables);
foreach (array_diff($srctables, $tgttables) as $t) {
    fwrite($tablesf, "$t\tsource-only\n");
}
foreach (array_diff($tgttables, $srctables) as $t) {
    fwrite($tablesf, "$t\ttarget-only\n");
}

// One canonical string per value. Numbers compare by value: drivers may format floats differently.
function rp_canon($value, $meta) {
    if ($value === null) {
        return "\0NULL";
    }
    if ($meta === 'N' || $meta === 'F') {
        return is_numeric($value) ? sprintf('%.12g', (float)$value) : (string)$value;
    }
    if ($meta === 'I' || $meta === 'R') {
        return (string)(int)$value;
    }
    return (string)$value;
}

$totaldiff = 0;
$started = microtime(true);
foreach (array_intersect($srctables, $tgttables) as $table) {
    $scols = $src->get_columns($table, false);
    $tcols = $tgt->get_columns($table, false);
    $cols = array_values(array_intersect(array_keys($scols), array_keys($tcols)));
    sort($cols);
    foreach (array_diff(array_keys($scols), $cols) as $c) {
        fwrite($rowsf, "$table\t-\tcolumn-source-only\t$c\n");
    }
    foreach (array_diff(array_keys($tcols), $cols) as $c) {
        fwrite($rowsf, "$table\t-\tcolumn-target-only\t$c\n");
    }
    // A column binary on one side and text on the other (§5.2) compares as raw bytes; numbers by value.
    $meta = [];
    foreach ($cols as $c) {
        $a = $scols[$c]->meta_type;
        $b = $tcols[$c]->meta_type;
        $meta[$c] = in_array($a, ['N', 'F'], true) || in_array($b, ['N', 'F'], true) ? 'N' :
            (in_array($a, ['I', 'R'], true) && in_array($b, ['I', 'R'], true) ? 'I' : 'S');
    }
    $hasid = in_array('id', $cols, true);
    $order = $hasid ? 'id' : implode(',', $cols);
    $rs1 = $src->get_recordset($table, null, $order, implode(',', $cols));
    $rs2 = $tgt->get_recordset($table, null, $order, implode(',', $cols));
    $h1 = hash_init('sha256');
    $h2 = hash_init('sha256');
    $n1 = $n2 = $diff = 0;
    $r1 = $rs1->valid() ? $rs1->current() : null;
    $r2 = $rs2->valid() ? $rs2->current() : null;
    $rowhash = function($r) use ($cols, $meta) {
        $parts = [];
        foreach ($cols as $c) {
            $v = rp_canon($r->$c, $meta[$c]);
            $parts[] = $c . ':' . strlen($v) . ':' . $v;
        }
        return hash('sha256', implode("\x1f", $parts), true);
    };
    $report = function($id, $side, $names) use ($table, $rowsf, $opt, &$diff) {
        $diff++;
        if ($diff <= (int)$opt['maxrows']) {
            fwrite($rowsf, "$table\t$id\t$side\t$names\n");
        }
    };
    while ($r1 !== null || $r2 !== null) {
        $id1 = $r1 !== null ? ($hasid ? (int)$r1->id : 0) : PHP_INT_MAX;
        $id2 = $r2 !== null ? ($hasid ? (int)$r2->id : 0) : PHP_INT_MAX;
        if ($hasid && $id1 < $id2) {
            $report($id1, 'source-only', '');
            hash_update($h1, $rowhash($r1)); $n1++;
            $rs1->next(); $r1 = $rs1->valid() ? $rs1->current() : null;
            continue;
        }
        if ($hasid && $id2 < $id1) {
            $report($id2, 'target-only', '');
            hash_update($h2, $rowhash($r2)); $n2++;
            $rs2->next(); $r2 = $rs2->valid() ? $rs2->current() : null;
            continue;
        }
        $a = $rowhash($r1);
        $b = $rowhash($r2);
        if ($a !== $b) {
            $names = [];
            foreach ($cols as $c) {
                if (rp_canon($r1->$c, $meta[$c]) !== rp_canon($r2->$c, $meta[$c])) {
                    $names[] = $c;
                }
            }
            $report($hasid ? $id1 : '-', 'both', implode(',', $names));
        }
        hash_update($h1, $a); $n1++;
        hash_update($h2, $b); $n2++;
        $rs1->next(); $r1 = $rs1->valid() ? $rs1->current() : null;
        $rs2->next(); $r2 = $rs2->valid() ? $rs2->current() : null;
    }
    $rs1->close();
    $rs2->close();
    $totaldiff += $diff;
    fwrite($summary, implode("\t", [$table, $n1, $n2, $diff, hash_final($h1), hash_final($h2)]) . "\n");
}
fclose($summary);
fclose($rowsf);
fclose($tablesf);
printf("compared %d tables in %ds; %d differing rows\n", count(array_intersect($srctables, $tgttables)),
    microtime(true) - $started, $totaldiff);
