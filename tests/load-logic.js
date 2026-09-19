const fs = require('fs');
const path = require('path');

const code = fs.readFileSync(path.join(__dirname, '..', 'BluetoothLogic.js'), 'utf8')
    .replace('.pragma library', '');

const BTLogic = new Function(code + '\nreturn { isValidMac, stripLine, parseMonitorLine, parseDeviceLine, parseInfoUpdate, parseBatteryValue, makeDevice, sortDevices, filterDevices, createDeviceItem, getDeviceIcon, getStatusText, getCategoryFromIcon, clampScanDuration };')();

module.exports = BTLogic;
