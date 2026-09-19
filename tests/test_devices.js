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

// ----- makeDevice -----
test('makeDevice: defaults - unpaired available:true', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Test', false);
    if (d.mac !== 'AA:BB:CC:DD:EE:FF') throw new Error('mac');
    if (d.name !== 'Test') throw new Error('name');
    if (d.paired !== false) throw new Error('paired');
    if (d.connected !== false) throw new Error('connected');
    if (d.available !== true) throw new Error('available should be true for unpaired');
    if (d.icon !== '') throw new Error('icon');
    if (d.battery !== null) throw new Error('battery');
    if (d.category !== 'other') throw new Error('category');
    if (d.connecting !== false) throw new Error('connecting');
    if (d.error !== null) throw new Error('error');
});
test('makeDevice: paired defaults - available:false', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Test', true);
    if (d.available !== false) throw new Error('paired should have available=false');
});

// ----- sortDevices -----
test('sortDevices: __scanning__ last', function() {
    var devs = [
        BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Dev1', true),
        BTLogic.makeDevice('__scanning__', 'Scanning...', false),
        BTLogic.makeDevice('11:11:11:11:11:11', 'Dev2', false)
    ];
    var sorted = BTLogic.sortDevices(devs);
    if (sorted[0].mac !== 'AA:BB:CC:DD:EE:FF') throw new Error('first should be Dev1 (paired)');
    if (sorted[1].mac !== '11:11:11:11:11:11') throw new Error('second should be Dev2');
    if (sorted[2].mac !== '__scanning__') throw new Error('last should be scanning');
});
test('sortDevices: connected > paired > available > name', function() {
    var devs = [
        BTLogic.makeDevice('CC:CC:CC:CC:CC:CC', 'Connected', false),  // connected=false, paired=false, available=true (unpaired)
        BTLogic.makeDevice('AA:AA:AA:AA:AA:AA', 'PairedButDisconnected', true),  // paired=true, connected=false, available=false
        BTLogic.makeDevice('BB:BB:BB:BB:BB:BB', 'Available', false)  // unpaired, available=true
    ];
    // Set connected states manually since makeDevice sets connected:false always
    devs[0].connected = true;   // now connected
    var sorted = BTLogic.sortDevices(devs);
    // Order should be: connected (CC), then paired (AA), then available (BB) by name
    if (sorted[0].mac !== 'CC:CC:CC:CC:CC:CC') throw new Error('connected first');
    if (sorted[1].mac !== 'AA:AA:AA:AA:AA:AA') throw new Error('paired second');
    if (sorted[2].mac !== 'BB:BB:BB:BB:BB:BB') throw new Error('available third');
});

// ----- filterDevices -----
test('filterDevices: no query returns paired+scanning+discovered', function() {
    var devs = [
        BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Paired', true),
        BTLogic.makeDevice('__scanning__', 'Scanning...', false),
        BTLogic.makeDevice('00:00:00:00:00:01', 'Discovered', false)
    ];
    var result = BTLogic.filterDevices(devs, null, { discoveredMacs: ['00:00:00:00:00:01'] });
    if (result.length !== 3) throw new Error('expected 3, got ' + result.length);
});
test('filterDevices: query filters by name/MAC/category', function() {
    var devs = [
        BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Mouse', false),
        BTLogic.makeDevice('11:11:11:11:11:11', 'Keyboard', false),
    ];
    // Category test - set category
    devs[0].category = 'input';
    var result = BTLogic.filterDevices(devs, 'keyboard', { trigger: 'bt', discoveredMacs: ['AA:BB:CC:DD:EE:FF', '11:11:11:11:11:11'] });
    if (result.length !== 1) throw new Error('expected 1');
    if (result[0].mac !== '11:11:11:11:11:11') throw new Error('expected keyboard');
});
test('filterDevices: empty query returns pool', function() {
    var devs = [
        BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Device', false)
    ];
    var result = BTLogic.filterDevices(devs, '', { trigger: 'bt', discoveredMacs: ['AA:BB:CC:DD:EE:FF'] });
    if (result.length !== 1) throw new Error('expected 1');
});

// ----- createDeviceItem -----
test('createDeviceItem: unpaired shows [ Name ]', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'My Headphones', false);
    var item = BTLogic.createDeviceItem(d);
    if (item.name !== '[ My Headphones ]') throw new Error('expected bracketed name');
    if (item.action !== 'pair:AA:BB:CC:DD:EE:FF') throw new Error('expected pair action');
    if (item.comment !== 'Not paired · tap to pair') throw new Error('expected unpaired comment');
});
test('createDeviceItem: paired shows name with battery', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'My Headphones', true);
    d.battery = 85;
    d.connected = true;
    var item = BTLogic.createDeviceItem(d);
    if (item.name !== '🔋 85%  My Headphones') throw new Error('expected battered name');
    if (item.action !== 'device:AA:BB:CC:DD:EE:FF') throw new Error('expected device action');
    if (item.comment !== '✓ Connected') throw new Error('expected connected status');
});
test('createDeviceItem: error overrides comment', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'My Headphones', true);
    d.error = 'Pairing failed';
    var item = BTLogic.createDeviceItem(d);
    if (item.comment !== 'Pairing failed') throw new Error('expected error comment');
});

// ----- getDeviceIcon -----
test('getDeviceIcon: audio-headset', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Headphones', true);
    d.icon = 'audio-headset';
    if (BTLogic.getDeviceIcon(d) !== 'material:headphones') throw new Error('expected headphones icon');
});
test('getDeviceIcon: input-mouse', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Mouse', true);
    d.icon = 'input-mouse';
    if (BTLogic.getDeviceIcon(d) !== 'material:mouse') throw new Error('expected mouse icon');
});
test('getDeviceIcon: phone', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Phone', true);
    d.icon = 'phone';
    if (BTLogic.getDeviceIcon(d) !== 'material:mobile_3') throw new Error('expected phone icon');
});
test('getDeviceIcon: unknown icon defaults to bluetooth', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Device', true);
    d.icon = 'random-icon';
    if (BTLogic.getDeviceIcon(d) !== 'material:bluetooth') throw new Error('expected bluetooth default');
});

// ----- getStatusText -----
test('getStatusText: error priority', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Device', true);
    d.error = 'Connection failed';
    if (BTLogic.getStatusText(d) !== 'Connection failed') throw new Error('error priority');
});
test('getStatusText: connecting', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Device', false);
    d.connecting = true;
    if (BTLogic.getStatusText(d) !== 'Connecting...') throw new Error('connecting');
});
test('getStatusText: connected', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Device', true);
    d.connected = true;
    if (BTLogic.getStatusText(d) !== '✓ Connected') throw new Error('connected');
});
test('getStatusText: available', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Device', false);
    d.available = true;
    d.connected = false;
    if (BTLogic.getStatusText(d) !== 'In Range') throw new Error('in-range');
});
test('getStatusText: out of range', function() {
    var d = BTLogic.makeDevice('AA:BB:CC:DD:EE:FF', 'Device', true);
    // paired default: connected=false, available=false
    if (BTLogic.getStatusText(d) !== 'Out of Range') throw new Error('out-of-range');
});

// ----- getCategoryFromIcon -----
test('getCategoryFromIcon: audio-card', function() {
    if (BTLogic.getCategoryFromIcon('audio-card') !== 'audio') throw new Error('audio-card');
});
test('getCategoryFromIcon: audio-speaker', function() {
    if (BTLogic.getCategoryFromIcon('audio-speaker') !== 'audio') throw new Error('audio-speaker');
});
test('getCategoryFromIcon: input-keyboard', function() {
    if (BTLogic.getCategoryFromIcon('input-keyboard') !== 'input') throw new Error('input-keyboard');
});
test('getCategoryFromIcon: phone', function() {
    if (BTLogic.getCategoryFromIcon('phone') !== 'phone') throw new Error('phone');
});
test('getCategoryFromIcon: unknown returns other', function() {
    if (BTLogic.getCategoryFromIcon('unknown') !== 'other') throw new Error('unknown->other');
});

console.log('\n' + passed + ' passed, ' + failed + ' failed');
if (failed > 0) process.exit(1);