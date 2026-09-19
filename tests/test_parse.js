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

function assertEqual(actual, expected, desc) {
    if (actual !== expected) throw new Error(desc + ': expected ' + JSON.stringify(expected) + ' got ' + JSON.stringify(actual));
}

// ----- isValidMac -----
test('isValidMac: valid upper MAC', function() {
    assertEqual(BTLogic.isValidMac('AA:BB:CC:DD:EE:FF'), true);
});
test('isValidMac: valid lower MAC', function() {
    assertEqual(BTLogic.isValidMac('aa:bb:cc:dd:ee:ff'), true);
});
test('isValidMac: invalid format', function() {
    assertEqual(BTLogic.isValidMac('not-a-mac'), false);
});
test('isValidMac: short MAC', function() {
    assertEqual(BTLogic.isValidMac('AA:BB:CC:DD:EE'), false);
});

// ----- stripLine -----
test('stripLine: removes ANSI escapes', function() {
    var result = BTLogic.stripLine('\x1B[31mhello\x1B[0m');
    assertEqual(result, 'hello');
});
test('stripLine: removes control chars', function() {
    var result = BTLogic.stripLine('hello\x00world\x01');
    assertEqual(result, 'helloworld');
});
test('stripLine: trims whitespace', function() {
    var result = BTLogic.stripLine('  hello  ');
    assertEqual(result, 'hello');
});

// ----- parseMonitorLine -----
test('parseMonitorLine: [NEW] Device line', function() {
    var result = BTLogic.parseMonitorLine('\x1B[34m[bluetoothctl]>\x1B[0m [NEW] Device AA:BB:CC:DD:EE:FF My Headphones');
    if (!result || result.tag !== 'NEW' || result.mac !== 'AA:BB:CC:DD:EE:FF') throw new Error('unexpected');
    // tail should be 'My Headphones' (everything after MAC)
});
test('parseMonitorLine: [DEL] Device line', function() {
    var result = BTLogic.parseMonitorLine('[DEL] Device AA:BB:CC:DD:EE:FF Old Name');
    if (!result || result.tag !== 'DEL' || result.mac !== 'AA:BB:CC:DD:EE:FF') throw new Error('unexpected');
});
test('parseMonitorLine: [CHG] Device line with RSSI', function() {
    var result = BTLogic.parseMonitorLine('[CHG] Device AA:BB:CC:DD:EE:FF RSSI: -70');
    if (!result || result.tag !== 'CHG' || result.mac !== 'AA:BB:CC:DD:EE:FF') throw new Error('unexpected');
});
test('parseMonitorLine: Controller Powered: yes', function() {
    var result = BTLogic.parseMonitorLine('[bluetoothctl]> [CHG] Controller AA:BB:CC:DD:EE:FF Powered: yes');
    if (!result || result.controllerPowered !== true) throw new Error('expected controllerPowered=true');
});
test('parseMonitorLine: Controller Powered: no', function() {
    var result = BTLogic.parseMonitorLine('[bluetoothctl]> [CHG] Controller AA:BB:CC:DD:EE:FF Powered: no');
    if (!result || result.controllerPowered !== false) throw new Error('expected controllerPowered=false');
});
test('parseMonitorLine: non-device non-controller line returns null', function() {
    var result = BTLogic.parseMonitorLine('[bluetoothctl]> Some random line');
    if (result !== null) throw new Error('expected null');
});
test('parseMonitorLine: line without tag returns null', function() {
    var result = BTLogic.parseMonitorLine('Just some text');
    if (result !== null) throw new Error('expected null');
});

// ----- parseDeviceLine -----
test('parseDeviceLine: standard device line', function() {
    var result = BTLogic.parseDeviceLine('Device AA:BB:CC:DD:EE:FF My Headphones');
    if (!result || result.mac !== 'AA:BB:CC:DD:EE:FF' || result.name !== 'My Headphones') throw new Error('unexpected');
});
test('parseDeviceLine: device with multi-word name', function() {
    var result = BTLogic.parseDeviceLine('Device 00:11:22:33:44:55 Some Device Name');
    if (!result || result.name !== 'Some Device Name') throw new Error('unexpected');
});
test('parseDeviceLine: non-device line returns null', function() {
    var result = BTLogic.parseDeviceLine('Some other line');
    if (result !== null) throw new Error('expected null');
});

// ----- parseInfoUpdate -----
test('parseInfoUpdate: Connected: yes', function() {
    var d = { mac: 'AA:BB:CC:DD:EE:FF', connected: null, paired: null, available: null, icon: null, category: null, battery: null };
    BTLogic.parseInfoUpdate(d, 'Connected: yes');
    if (d.connected !== true) throw new Error('expected connected=true');
});
test('parseInfoUpdate: Connected: no', function() {
    var d = { mac: 'AA:BB:CC:DD:EE:FF', connected: null, paired: null, available: null, icon: null, category: null, battery: null };
    BTLogic.parseInfoUpdate(d, 'Connected: no');
    if (d.connected !== false) throw new Error('expected connected=false');
    if (d.available !== null) throw new Error('expected available unchanged');
});
test('parseInfoUpdate: Paired: yes', function() {
    var d = { mac: 'AA:BB:CC:DD:EE:FF', connected: null, paired: null, available: null, icon: null, category: null, battery: null };
    BTLogic.parseInfoUpdate(d, 'Paired: yes');
    if (d.paired !== true) throw new Error('expected paired=true');
});
test('parseInfoUpdate: Icon: line', function() {
    var d = { mac: 'AA:BB:CC:DD:EE:FF', connected: null, paired: null, available: null, icon: null, category: null, battery: null };
    BTLogic.parseInfoUpdate(d, 'Icon: some-icon');
    if (d.icon !== 'some-icon') throw new Error('expected icon=some-icon');
    if (d.category !== BTLogic.getCategoryFromIcon('some-icon')) throw new Error('expected category');
});
test('parseInfoUpdate: Battery Percentage: (20)', function() {
    var d = { mac: 'AA:BB:CC:DD:EE:FF', connected: null, paired: null, available: null, icon: null, category: null, battery: null };
    BTLogic.parseInfoUpdate(d, 'Battery Percentage: 0x14 (20)');
    if (d.battery !== 20) throw new Error('expected battery=20');
});
test('parseInfoUpdate: RSSI: line sets available', function() {
    var d = { mac: 'AA:BB:CC:DD:EE:FF', connected: null, paired: null, available: null, icon: null, category: null, battery: null };
    BTLogic.parseInfoUpdate(d, 'RSSI: -60');
    if (d.available !== true) throw new Error('expected available=true');
});

// ----- parseBatteryValue -----
test('parseBatteryValue: extracts number from (20)', function() {
    assertEqual(BTLogic.parseBatteryValue('0x14 (20)'), 20);
});
test('parseBatteryValue: no number returns null', function() {
    assertEqual(BTLogic.parseBatteryValue('no battery'), null);
});

// ----- clampScanDuration -----
test('clampScanDuration: normal value 5', function() {
    assertEqual(BTLogic.clampScanDuration(5), 5);
});
test('clampScanDuration: below min clamps to 3', function() {
    assertEqual(BTLogic.clampScanDuration(2), 3);
});
test('clampScanDuration: above max clamps to 30', function() {
    assertEqual(BTLogic.clampScanDuration(99), 30);
});
test('clampScanDuration: NaN defaults to 5', function() {
    assertEqual(BTLogic.clampScanDuration(NaN), 5);
});
test('clampScanDuration: string NaN defaults to 5', function() {
    assertEqual(BTLogic.clampScanDuration('abc'), 5);
});

console.log('\n' + passed + ' passed, ' + failed + ' failed');
if (failed > 0) process.exit(1);