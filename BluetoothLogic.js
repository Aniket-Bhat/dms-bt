.pragma library

function isValidMac(mac) {
    return /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(mac);
}

function stripLine(line) {
    return line
        .replace(/\x1B\[[0-9;]*[A-Za-z]/g, "")
        .replace(/[\x00-\x09\x0b-\x1f\x7f]/g, "")
        .trim();
}

// Parses a bluetoothctl --monitor line.
// Returns {tag: "NEW"|"DEL"|"CHG", mac: String, tail: String} or
// {controllerPowered: bool} or null.
function parseMonitorLine(line) {
    var stripped = stripLine(line);
    var match = stripped.match(/\[(NEW|DEL|CHG)\]\s+(.+)$/);
    if (!match) return null;

    var tag = match[1];
    var rest = match[2].trim();

    // Controller power on/off
    if (rest.startsWith("Controller ")) {
        var ctrlColonIdx = rest.indexOf(": ");
        if (ctrlColonIdx === -1) return null;
        var ctrlProp = rest.substring(rest.lastIndexOf(" ", ctrlColonIdx - 1) + 1, ctrlColonIdx);
        if (ctrlProp !== "Powered") return null;
        var ctrlVal = rest.substring(ctrlColonIdx + 2).trim();
        return { controllerPowered: (ctrlVal === "yes") };
    }

    // Only Device events
    if (!rest.startsWith("Device ")) return null;

    var afterDevice = rest.substring(7);
    var spaceIdx = afterDevice.indexOf(" ");
    var mac = spaceIdx === -1 ? afterDevice : afterDevice.substring(0, spaceIdx);
    var tail = spaceIdx === -1 ? "" : afterDevice.substring(spaceIdx + 1).trim();

    if (!isValidMac(mac)) return null;
    return { tag: tag, mac: mac, tail: tail };
}

// Parses `bluetoothctl devices [Paired]` output line.
// Returns {mac: String, name: String} or null.
function parseDeviceLine(line) {
    var stripped = stripLine(line);
    if (!stripped.startsWith("Device ")) return null;
    var parts = stripped.substring(7).split(" ");
    if (parts.length < 2) return null;
    var mac = parts[0];
    var name = parts.slice(1).join(" ");
    if (!isValidMac(mac)) return null;
    return { mac: mac, name: name };
}

// Parses a bluetoothctl info line into a device object.
// device is an object with at least: mac, connected, paired, available, icon, category, battery
// line is a single line from bluetoothctl info output.
function parseInfoUpdate(device, line) {
    var stripped = line.trim();
    if (stripped.startsWith("Connected: ")) {
        device.connected = stripped.indexOf("yes") !== -1;
        if (device.connected) device.available = true;
    } else if (stripped.startsWith("Paired: ")) {
        device.paired = stripped.indexOf("yes") !== -1;
    } else if (stripped.startsWith("Icon: ")) {
        device.icon = stripped.substring(6).trim();
        device.category = getCategoryFromIcon(device.icon);
    } else if (stripped.startsWith("Battery Percentage: ")) {
        var match = stripped.match(/Battery Percentage:.*\((\d+)\)/);
        if (match) device.battery = parseInt(match[1]);
    } else if (stripped.startsWith("RSSI: ")) {
        device.available = true;
    }
}

// Extracts a battery percentage number from "(20)" style text.
function parseBatteryValue(val) {
    var match = val.match(/\((\d+)\)/);
    if (match) return parseInt(match[1]);
    return null;
}

// Creates a device object with default state.
// Unpaired (discovered) devices default to available:true; paired default to available:false.
function makeDevice(mac, name, paired) {
    return {
        mac: mac, name: name,
        paired: paired, connected: false, available: paired ? false : true,
        icon: "", battery: null, category: "other",
        connecting: false, error: null
    };
}

// Sort devices: __scanning__ last, then connected > paired > available > name.
// Returns a new sorted array (does not mutate the input).
function sortDevices(devices) {
    var copy = [...devices];
    copy.sort(function(a, b) {
        if (a.mac === "__scanning__") return 1;
        if (b.mac === "__scanning__") return -1;
        if (a.connected !== b.connected) return b.connected ? 1 : -1;
        if (a.paired !== b.paired) return a.paired ? -1 : 1;
        if (a.available !== b.available) return a.available ? -1 : 1;
        return a.name.localeCompare(b.name);
    });
    return copy;
}

// Filter devices shown in the launcher list.
// query is a string or null/undefined.
// {trigger, scanning, discoveredMacs} are optional context params.
function filterDevices(deviceList, query, context) {
    context = context || {};
    var discovered = context.discoveredMacs || [];
    var pool = deviceList.filter(function(d) {
        return d.paired ||
            d.mac === "__scanning__" ||
            context.scanning ||
            discovered.includes(d.mac);
    });

    if (!query || query.trim().length === 0) return pool;
    var q = query.toLowerCase().trim();
    if (q === context.trigger || q === context.trigger + " ") return pool;

    return pool.filter(function(d) {
        return d.mac === "__scanning__" ||
            d.name.toLowerCase().includes(q) ||
            d.mac.toLowerCase().includes(q) ||
            (d.category && d.category.toLowerCase().includes(q));
    });
}

// Build a device item object for launcher rendering.
// Returns a plain object with: name, icon, comment, action, categories, keywords.
function createDeviceItem(device) {
    if (device.mac === "__scanning__") {
        return {
            name: device.name,
            icon: "material:bluetooth_searching",
            comment: "Discovered devices appear below automatically",
            action: "",
            categories: ["Bluetooth"],
            keywords: []
        };
    }

    var batteryText = device.battery !== null ? "🔋 " + device.battery + "%  " : "";
    var name = device.paired
        ? batteryText + device.name
        : "[ " + device.name + " ]";
    var comment = device.paired
        ? getStatusText(device)
        : "Not paired · tap to pair";

    if (device.error) comment = device.error;

    var action = device.paired ? "device:" + device.mac : "pair:" + device.mac;

    return {
        name: name,
        icon: getDeviceIcon(device),
        comment: comment,
        action: action,
        categories: ["Bluetooth"],
        keywords: [device.category || "other", device.paired ? "paired" : "discovered"]
    };
}

// Maps a device icon string (from bluetoothctl Info: Icon:) to a material icon name.
function getDeviceIcon(device) {
    var iconMap = {
        "audio-headset": "material:headphones",
        "audio-card": "material:media_output",
        "input-mouse": "material:mouse",
        "input-keyboard": "material:keyboard",
        "input-gaming": "material:sports_esports",
        "phone": "material:mobile_3",
        "audio-speaker": "material:speaker"
    };
    return iconMap[device.icon || ""] || "material:bluetooth";
}

// Priority-ordered status text for a device.
function getStatusText(device) {
    if (device.error) return device.error;
    if (device.connecting && device.connected) return "Disconnecting...";
    if (device.connecting) return "Connecting...";
    if (device.connected) return "✓ Connected";
    if (device.available) return "In Range";
    return "Out of Range";
}

// Maps a bluetoothctl icon string to a category string.
function getCategoryFromIcon(icon) {
    if (icon.startsWith("audio-") || icon === "audio-card" || icon === "audio-speaker") return "audio";
    if (icon.startsWith("input-")) return "input";
    if (icon === "phone" || icon === "phone-android") return "phone";
    return "other";
}

// Clamp scan duration to 3–30 seconds, default 5.
function clampScanDuration(n) {
    var num = Number(n);
    if (isNaN(num)) return 5;
    return Math.min(30, Math.max(3, num));
}