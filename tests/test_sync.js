// Drift test: BluetoothLauncher.qml must stay single-file (no BTLogic import —
// DMS reload appends ?t= to the component URL, which breaks relative .js
// imports), while BluetoothLogic.js mirrors its pure functions for node tests.
// This file enforces both rules + behavioral equivalence of the 4 mirrored
// functions (QML body eval'd in node vs JS oracle, shared fixtures).
const fs = require('fs');
const path = require('path');
const BTLogic = require('./load-logic');

var passed = 0;
var failed = 0;

function test(desc, fn) {
    try {
        fn();
        passed++;
        console.log('PASS:', desc);
    } catch (e) {
        failed++;
        console.log('FAIL:', desc, '-', e.message);
    }
}

const qmlSrc = fs.readFileSync(path.join(__dirname, '..', 'BluetoothLauncher.qml'), 'utf8');
const jsSrc = fs.readFileSync(path.join(__dirname, '..', 'BluetoothLogic.js'), 'utf8');

// ----- structural rules -----
test('QML has no BTLogic references (single-file rule)', function() {
    if (/BTLogic/.test(qmlSrc)) throw new Error('found BTLogic reference in QML');
});

test('BluetoothLogic.js has no module.exports/require (QML-importable rule)', function() {
    if (/module\.exports/.test(jsSrc)) throw new Error('found module.exports');
    if (/require\(/.test(jsSrc)) throw new Error('found require()');
});

// ----- QML function extractor (balanced braces) -----
function extractQmlFunc(src, name) {
    var m = src.match(new RegExp('function ' + name + '\\s*\\(([^)]*)\\)\\s*\\{'));
    if (!m) throw new Error('QML function not found: ' + name);
    var params = m[1].split(',').map(function(p) { return p.trim(); }).filter(function(p) { return p; });
    var i = m.index + m[0].length - 1;
    var depth = 0;
    for (var j = i; j < src.length; j++) {
        if (src[j] === '{') depth++;
        else if (src[j] === '}') {
            depth--;
            if (depth === 0) return { params: params, body: src.slice(i + 1, j) };
        }
    }
    throw new Error('unbalanced braces: ' + name);
}

function qmlFunc(name) {
    var f = extractQmlFunc(qmlSrc, name);
    var args = f.params.concat([f.body]);
    return Function.apply(null, args);
}

function eq(a, b, what) {
    if (JSON.stringify(a) !== JSON.stringify(b))
        throw new Error(what + ': QML=' + JSON.stringify(a) + ' JS=' + JSON.stringify(b));
}

// ----- behavioral equivalence -----
test('makeDevice: QML matches JS oracle', function() {
    var qmlMake = qmlFunc('makeDevice');
    [['AA:BB:CC:DD:EE:FF', 'Test', true], ['11:22:33:44:55:66', 'X', false]].forEach(function(f) {
        eq(qmlMake(f[0], f[1], f[2]), BTLogic.makeDevice(f[0], f[1], f[2]), 'makeDevice ' + f[0]);
    });
});

test('getDeviceIcon: QML matches JS oracle', function() {
    var qmlIcon = qmlFunc('getDeviceIcon');
    ['audio-headset', 'audio-card', 'input-mouse', 'input-keyboard', 'input-gaming',
     'phone', 'audio-speaker', 'unknown', ''].forEach(function(icon) {
        eq(qmlIcon({ icon: icon }), BTLogic.getDeviceIcon({ icon: icon }), 'icon ' + icon);
    });
});

test('getStatusText: QML matches JS oracle', function() {
    var qmlStatus = qmlFunc('getStatusText');
    var base = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'D', true);
    function variant(mut) {
        var d = JSON.parse(JSON.stringify(base));
        Object.keys(mut).forEach(function(k) { d[k] = mut[k]; });
        return d;
    }
    [{ error: 'E' }, { connecting: true, connected: true }, { connecting: true },
     { connected: true }, { available: true }, {}].forEach(function(mut, i) {
        var d = variant(mut);
        eq(qmlStatus(d), BTLogic.getStatusText(d), 'status case ' + i);
    });
});

test('getCategoryFromIcon: QML matches JS oracle', function() {
    var qmlCat = qmlFunc('getCategoryFromIcon');
    ['audio-headset', 'audio-card', 'audio-speaker', 'input-mouse', 'phone',
     'phone-android', 'video-camera', ''].forEach(function(icon) {
        eq(qmlCat(icon), BTLogic.getCategoryFromIcon(icon), 'category ' + icon);
    });
});

console.log('\n' + passed + ' passed, ' + failed + ' failed');
if (failed > 0) process.exit(1);
