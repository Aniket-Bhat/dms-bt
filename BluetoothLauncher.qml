import QtQuick
import Quickshell.Io
import qs.Services
import qs.Common

QtObject {
    id: root

    property var pluginService: null
    property string pluginId: "bluetoothLauncher"
    property string trigger: "bt"

    property int _countdownDuration: 5

    property var devices: []
    property var pairedMacs: []
    property bool scanning: false
    property bool btPowered: true   // tracks adapter power state; assume on until told otherwise

    // Serial info-fetch queue
    property var _infoQueue: []
    property var _currentInfoDevice: null
    // MACs discovered during a scan — shown even after scanning ends, until next refreshDevices()
    property var _discoveredMacs: []

    // Suppress connect/connected toasts when called internally (e.g. after pair)
    property bool _silentConnect: false
    // If user tries to connect while BT is off, store the MAC and connect after power-on
    property string _pendingConnectMac: ""

    signal itemsChanged

    Component.onCompleted: {
        loadSettings()
        // Check initial adapter power state before starting monitor
        powerStateProc.running = true
        // Start monitor so we don't miss any events during initial load
        monitorProc.running = true
        refreshDevices()
    }

    // =========================================================================
    // MONITOR — long-running, streams all BT events in real time
    // Format of relevant lines:
    //   [NEW]  Device AA:BB:CC:DD:EE:FF  Some Name   ← device discovered/appeared
    //   [DEL]  Device AA:BB:CC:DD:EE:FF  Some Name   ← device removed/unpaired
    //   [CHG]  Device AA:BB:CC:DD:EE:FF  Connected: yes/no
    //   [CHG]  Device AA:BB:CC:DD:EE:FF  Paired: yes/no
    //   [CHG]  Device AA:BB:CC:DD:EE:FF  RSSI: -60
    //   [CHG]  Device AA:BB:CC:DD:EE:FF  Battery Percentage: 0x14 (20)
    // =========================================================================
    // One-shot process to read the initial adapter power state
    property var _powerStateProc: Process {
        id: powerStateProc
        command: ["bluetoothctl", "show"]
        stdout: SplitParser {
            onRead: data => {
                var line = data.trim()
                if (line.startsWith("Powered: ")) {
                    root.btPowered = line.indexOf("yes") !== -1
                }
            }
        }
    }

    property var _monitorProc: Process {
        id: monitorProc
        command: ["bluetoothctl", "--monitor"]
        stdout: SplitParser {
            onRead: data => {
                // Strip ANSI escape sequences
                var line = data.replace(/\x1B\[[0-9;]*[A-Za-z]/g, "")
                               .replace(/[\x00-\x09\x0b-\x1f\x7f]/g, "")
                               .trim()

                // The prompt is always prepended to the event on the same line, e.g.:
                //   "[bluetoothctl]> [CHG] Device 88:0E:85:6A:45:70 Connected: no"
                //   "[realme Buds Wireless 5 ANC]> [DEL] Device ..."
                // So we search for the tag anywhere in the line, not just at start.
                var match = line.match(/\[(NEW|DEL|CHG)\]\s+(.+)$/)
                if (!match) return

                var tag  = match[1]
                var rest = match[2].trim()

                // Handle Controller (adapter) power on/off
                if (rest.startsWith("Controller ")) {
                    var ctrlColonIdx = rest.indexOf(": ")
                    if (ctrlColonIdx === -1) return
                    var ctrlProp = rest.substring(rest.lastIndexOf(" ", ctrlColonIdx - 1) + 1, ctrlColonIdx)
                    if (ctrlProp !== "Powered") return
                    var ctrlVal = rest.substring(ctrlColonIdx + 2).trim()
                    root.btPowered = (ctrlVal === "yes")
                    if (root.btPowered) {
                        ToastService.showInfo("Bluetooth enabled")
                        root.refreshDevices()
                        // _pendingConnectMac is handled inside refreshDevices callback
                    } else {
                        ToastService.showInfo("Bluetooth disabled")
                        root._pendingConnectMac = ""
                    }
                    root.refreshItems()
                    return
                }

                // Only handle Device events
                if (!rest.startsWith("Device ")) return

                var afterDevice = rest.substring(7)
                var spaceIdx    = afterDevice.indexOf(" ")
                var mac  = spaceIdx === -1 ? afterDevice : afterDevice.substring(0, spaceIdx)
                var tail = spaceIdx === -1 ? "" : afterDevice.substring(spaceIdx + 1).trim()

                // Validate MAC
                if (!/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(mac)) return

                if (tag === "NEW") {
                    if (!root.findDevice(mac))
                        root.devices.push(root.makeDevice(mac, tail || mac, false))
                    // Track as discovered so it stays visible after scan ends
                    if (!root._discoveredMacs.includes(mac)) root._discoveredMacs.push(mac)
                    root.fetchDeviceInfo(mac)

                } else if (tag === "DEL") {
                    root.devices = root.devices.filter(d => d.mac !== mac)
                    root.pairedMacs = root.pairedMacs.filter(m => m !== mac)
                    root.sortDevices()
                    root.refreshItems()

                } else if (tag === "CHG") {
                    var device = root.findDevice(mac)
                    if (!device) return

                    var colonIdx = tail.indexOf(": ")
                    if (colonIdx === -1) return
                    var prop = tail.substring(0, colonIdx).trim()
                    var val  = tail.substring(colonIdx + 2).trim()

                    if (prop === "Connected") {
                        device.connected = (val === "yes")
                        device.connecting = false
                        device.error = null
                        if (device.connected) {
                            device.available = true
                            if (!root._silentConnect) {
                                ToastService.showInfo("Connected to " + device.name)
                            }
                            root._silentConnect = false
                        } else {
                            ToastService.showInfo("Disconnected from " + device.name)
                        }
                        root.sortDevices()
                        root.refreshItems()

                    } else if (prop === "ServicesResolved") {
                        // Fires when all GATT services are ready — fetch info to get
                        // battery, icon, connected state etc.
                        if (val === "yes") {
                            root.fetchDeviceInfo(mac)
                            // Schedule a retry in case battery GATT isn't ready yet
                            root._batteryRetryMac = mac
                            batteryRetryTimer.restart()
                        }

                    } else if (prop === "Paired") {
                        device.paired = (val === "yes")
                        if (device.paired) {
                            if (!root.pairedMacs.includes(mac)) root.pairedMacs.push(mac)
                        } else {
                            root.pairedMacs = root.pairedMacs.filter(m => m !== mac)
                            ToastService.showInfo("Unpaired " + device.name)
                        }
                        root.sortDevices()
                        root.refreshItems()

                    } else if (prop === "RSSI") {
                        device.available = true
                        root.refreshItems()

                    } else if (prop === "Battery Percentage") {
                        var bMatch = val.match(/\((\d+)\)/)
                        if (bMatch) {
                            device.battery = parseInt(bMatch[1])
                            // Cancel retry — monitor already gave us the battery
                            if (root._batteryRetryMac === mac) {
                                root._batteryRetryMac = ""
                                batteryRetryTimer.stop()
                            }
                            root.refreshItems()
                        }
                    }
                }
            }
        }
        // If monitor dies (e.g. bluetoothd restart), restart it after a short delay
        onExited: (code, status) => {
            if (!monitorRestartTimer.running) monitorRestartTimer.start()
        }
    }

    property var _monitorRestartTimer: Timer {
        id: monitorRestartTimer
        interval: 2000
        repeat: false
        onTriggered: monitorProc.running = true
    }

    // =========================================================================
    // INITIAL LOAD — list paired devices once on startup, then fetch each info
    // After this, monitor handles all updates
    // =========================================================================
    property var _pairedCallback: null

    property var _pairedDevicesProc: Process {
        id: pairedDevicesProc
        command: ["bluetoothctl", "devices", "Paired"]
        stdout: SplitParser {
            onRead: data => {
                var line = data.trim()
                if (!line.startsWith("Device ")) return
                var parts = line.substring(7).split(" ")
                if (parts.length < 2) return
                var mac = parts[0]
                var name = parts.slice(1).join(" ")
                if (!root.pairedMacs.includes(mac)) root.pairedMacs.push(mac)
                var existing = root.findDevice(mac)
                if (existing) existing.paired = true
                else root.devices.push(root.makeDevice(mac, name, true))
            }
        }
        onExited: (code, status) => {
            if (root._pairedCallback) {
                var cb = root._pairedCallback
                root._pairedCallback = null
                cb()
            }
        }
    }

    // =========================================================================
    // INFO FETCHER — serial queue, one Process reused for all devices
    // =========================================================================
    property var _infoProc: Process {
        id: infoProc
        command: root._currentInfoDevice
                 ? ["bluetoothctl", "info", root._currentInfoDevice.mac]
                 : ["bluetoothctl", "info"]
        stdout: SplitParser {
            onRead: data => {
                var line = data.trim()
                var device = root._currentInfoDevice
                if (!device) return

                if (line.startsWith("Connected: ")) {
                    device.connected = line.indexOf("yes") !== -1
                    if (device.connected) device.available = true
                } else if (line.startsWith("Paired: ")) {
                    device.paired = line.indexOf("yes") !== -1
                    if (device.paired && !root.pairedMacs.includes(device.mac))
                        root.pairedMacs.push(device.mac)
                } else if (line.startsWith("Icon: ")) {
                    device.icon = line.substring(6).trim()
                    device.category = root.getCategoryFromIcon(device.icon)
                } else if (line.startsWith("Battery Percentage: ")) {
                    var match = line.match(/Battery Percentage:.*\((\d+)\)/)
                    if (match) device.battery = parseInt(match[1])
                } else if (line.startsWith("RSSI: ")) {
                    device.available = true
                }
            }
        }
        onExited: (code, status) => {
            if (root._infoQueue.length > 0) {
                root._currentInfoDevice = root._infoQueue.shift()
                infoProc.running = true
            } else {
                root._currentInfoDevice = null
                root.sortDevices()
                root.refreshItems()
            }
        }
    }

    // Kick off info fetch for a single MAC (used by monitor on [NEW] events too)
    function fetchDeviceInfo(mac) {
        var device = findDevice(mac)
        if (!device) return
        // If the queue is idle, start immediately; otherwise just enqueue
        if (_currentInfoDevice === null) {
            _currentInfoDevice = device
            infoProc.running = true
        } else {
            // Don't double-queue the same device
            if (!_infoQueue.some(d => d.mac === mac)) _infoQueue.push(device)
        }
    }

    // =========================================================================
    // ACTION PROCESSES
    // =========================================================================
    property string _connectMac: ""
    property string _disconnectMac: ""
    property string _unpairMac: ""
    property string _pairMac: ""

    property var _connectProc: Process {
        id: connectProc
        command: ["bluetoothctl", "connect", root._connectMac]
        onExited: (code, status) => {
            var device = root.findDevice(root._connectMac)
            if (!device) return
            device.connecting = false
            if (code !== 0) {
                device.error = "Connection failed"
                ToastService.showError("Failed to connect to " + device.name)
            }
            // Success case handled by monitor (Connected: yes toast)
            root.refreshItems()
        }
    }

    property var _disconnectProc: Process {
        id: disconnectProc
        command: ["bluetoothctl", "disconnect", root._disconnectMac]
        onExited: (code, status) => {
            var device = root.findDevice(root._disconnectMac)
            if (!device) return
            device.connecting = false
            if (code !== 0) {
                device.error = "Disconnect failed"
                ToastService.showError("Failed to disconnect " + device.name)
            }
            // Success case handled by monitor (Connected: no toast)
            root.refreshItems()
        }
    }

    property var _unpairProc: Process {
        id: unpairProc
        command: ["bluetoothctl", "remove", root._unpairMac]
        onExited: (code, status) => {
            if (code !== 0)
                ToastService.showError("Failed to unpair device")
            // Success: monitor fires [DEL] + [CHG] Paired: no which handles the toast
        }
    }

    // Pair a discovered (unpaired) device, then connect on success
    property var _pairProc: Process {
        id: pairProc
        command: ["bluetoothctl", "pair", root._pairMac]
        onExited: (code, status) => {
            var device = root.findDevice(root._pairMac)
            if (!device) return
            if (code === 0) {
                root._silentConnect = true
                root.connectDevice(root._pairMac)
                return
            }
            device.connecting = false
            device.error = "Pairing failed"
            ToastService.showError("Failed to pair " + device.name)
            root.refreshItems()
        }
    }

    // Scan processes — scan on runs for _countdownDuration seconds then we stop it
    property var _allDevicesProc: Process {
        id: allDevicesProc
        command: ["bluetoothctl", "devices"]
        stdout: SplitParser {
            onRead: data => {
                var line = data.trim()
                if (!line.startsWith("Device ")) return
                var parts = line.substring(7).split(" ")
                if (parts.length < 2) return
                var mac  = parts[0]
                var name = parts.slice(1).join(" ")
                if (!/^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/.test(mac)) return
                if (!root.findDevice(mac)) {
                    var isPaired = root.pairedMacs.includes(mac)
                    root.devices.push(root.makeDevice(mac, name, isPaired))
                    if (!isPaired && !root._discoveredMacs.includes(mac))
                        root._discoveredMacs.push(mac)
                    root.fetchDeviceInfo(mac)
                }
            }
        }
        onExited: (code, status) => root.refreshItems()
    }

    property var _scanProc: Process {
        id: scanProc
        command: ["bluetoothctl", "scan", "on"]
    }

    property var _scanOffProc: Process {
        id: scanOffProc
        command: ["bluetoothctl", "scan", "off"]
        onExited: (code, status) => {
            root.scanning = false
            root.devices = root.devices.filter(d => d.mac !== "__scanning__")
            var newCount = root.devices.filter(d => !d.paired && root._discoveredMacs.includes(d.mac)).length
            if (newCount > 0)
                ToastService.showInfo("Scan complete — " + newCount + " device" + (newCount === 1 ? "" : "s") + " found")
            else
                ToastService.showInfo("Scan complete — no new devices found")
            root.refreshItems()
        }
    }

    property var _scanTimer: Timer {
        id: scanTimer
        interval: root._countdownDuration * 1000
        repeat: false
        onTriggered: {
            scanProc.running = false
            scanOffProc.running = true
        }
    }

    // After ServicesResolved, battery may still not be in bluetoothctl info immediately.
    // Retry once after a short delay if it's still null.
    property string _batteryRetryMac: ""
    property var _batteryRetryTimer: Timer {
        id: batteryRetryTimer
        interval: 3000
        repeat: false
        onTriggered: {
            var mac = root._batteryRetryMac
            root._batteryRetryMac = ""
            if (!mac) return
            var device = root.findDevice(mac)
            if (device && device.battery === null && device.connected)
                root.fetchDeviceInfo(mac)
        }
    }

    property var _powerProc: Process {
        id: powerProc
        command: ["bluetoothctl", "power", "on"]
        onExited: (code, status) => {
            if (code !== 0)
                ToastService.showError("Failed to enable Bluetooth")
            // Success: monitor fires Controller Powered: yes which handles toast + refresh
        }
    }

    property var _powerOffProc: Process {
        id: powerOffProc
        command: ["bluetoothctl", "power", "off"]
        onExited: (code, status) => {
            if (code !== 0)
                ToastService.showError("Failed to disable Bluetooth")
            // Success: monitor fires Controller Powered: no which handles toast + refresh
        }
    }

    // =========================================================================
    // SETTINGS
    // =========================================================================
    function loadSettings() {
        if (!pluginService) return
        trigger = pluginService.loadPluginData(pluginId, "trigger", "bt")
        _countdownDuration = pluginService.loadPluginData(pluginId, "countdownDuration", 5)
    }

    // =========================================================================
    // DEVICE LOADING
    // =========================================================================
    function refreshDevices() {
        devices = []
        pairedMacs = []
        _infoQueue = []
        _currentInfoDevice = null
        _discoveredMacs = []
        _pairedCallback = () => {
            // If a connect was pending (e.g. user selected device while BT was off),
            // trigger it now that devices are populated
            if (_pendingConnectMac !== "") {
                var pendingMac = _pendingConnectMac
                _pendingConnectMac = ""
                connectDevice(pendingMac)
            }
            // Kick off serial info fetch for all paired devices.
            // Connected devices are prioritised (unshifted to front) so battery
            // appears as quickly as possible for already-connected devices.
            if (devices.length === 0) { refreshItems(); return }
            var connected = devices.filter(d => d.connected)
            var rest = devices.filter(d => !d.connected)
            _infoQueue = connected.concat(rest)
            _currentInfoDevice = _infoQueue.shift()
            infoProc.running = true
        }
        pairedDevicesProc.running = true
    }

    // =========================================================================
    // ACTIONS
    // =========================================================================
    function connectDevice(mac) {
        var device = findDevice(mac)
        if (!device) return
        if (!btPowered) {
            // BT is off — power on first, then connect once adapter is ready
            _pendingConnectMac = mac
            powerProc.running = true
            ToastService.showInfo("Enabling Bluetooth, then connecting to " + device.name + "...")
            return
        }
        device.connecting = true
        device.error = null
        refreshItems()
        if (!_silentConnect)
            ToastService.showInfo("Connecting to " + device.name + "...")
        _silentConnect = false
        _connectMac = mac
        connectProc.running = true
    }

    function disconnectDevice(mac) {
        var device = findDevice(mac)
        if (!device) return
        device.connecting = true
        device.error = null
        refreshItems()
        _disconnectMac = mac
        disconnectProc.running = true
    }

    function unpairDevice(mac) {
        _unpairMac = mac
        unpairProc.running = true
    }

    function pairDevice(mac) {
        var device = findDevice(mac)
        if (!device) return
        device.connecting = true
        device.error = null
        refreshItems()
        ToastService.showInfo("Pairing with " + device.name + "...")
        _pairMac = mac
        pairProc.running = true
    }

    function startPairingMode() {
        if (scanning) return
        scanning = true
        powerProc.running = true
        ToastService.showInfo("Scanning for " + _countdownDuration + "s...")

        // First load all currently known devices (not just paired) so anything
        // bluetoothctl already knows about shows up immediately without waiting
        // for a [NEW] event
        allDevicesProc.running = true

        // Show placeholder while scanning
        var placeholder = makeDevice("__scanning__", "Scanning for " + _countdownDuration + "s...", false)
        placeholder.icon = "material:bluetooth_searching"
        devices.push(placeholder)
        refreshItems()

        scanProc.running = true
        scanTimer.restart()
    }

    // =========================================================================
    // ITEM BUILDING
    // =========================================================================
    function getItems(query) {
        var items = []
        filterDevices(devices, query).forEach(d => items.push(createDeviceItem(d)))

        if (items.length === 0) {
            items.push({
                name: "No devices found",
                icon: "material:bluetooth_disabled",
                comment: "Pair a device first or use 'Scan for devices'",
                action: "",
                categories: ["Bluetooth"]
            })
        }

        // Bluetooth power toggle — always visible at the bottom
        items.push({
            name: btPowered ? "Turn Bluetooth off" : "Turn Bluetooth on",
            icon: btPowered ? "material:bluetooth_disabled" : "material:bluetooth",
            comment: btPowered ? "Power off the Bluetooth adapter" : "Power on the Bluetooth adapter",
            action: btPowered ? "action:poweroff" : "action:poweron",
            categories: ["Bluetooth"],
            keywords: ["power", "enable", "disable", "on", "off"]
        })

        if (!scanning) {
            items.push({
                name: "Scan for new devices",
                icon: "material:add",
                comment: "Scan " + _countdownDuration + "s for nearby Bluetooth devices",
                action: "action:scan",
                categories: ["Bluetooth"],
                keywords: ["pair", "new", "add", "scan", "discover"]
            })
        }

        return items
    }

    function filterDevices(deviceList, query) {
        var pool = deviceList.filter(d =>
            d.paired ||
            d.mac === "__scanning__" ||
            scanning ||
            root._discoveredMacs.includes(d.mac)
        )

        if (!query || query.trim().length === 0) return pool
        var q = query.toLowerCase().trim()
        if (q === trigger || q === trigger + " ") return pool

        return pool.filter(d =>
            d.mac === "__scanning__" ||
            d.name.toLowerCase().includes(q) ||
            d.mac.toLowerCase().includes(q) ||
            (d.category && d.category.toLowerCase().includes(q))
        )
    }

    function createDeviceItem(device) {
        if (device.mac === "__scanning__") {
            return {
                name: device.name,
                icon: "material:bluetooth_searching",
                comment: "Discovered devices appear below automatically",
                action: "",
                categories: ["Bluetooth"],
                keywords: []
            }
        }

        var batteryText = device.battery !== null ? "🔋 " + device.battery + "%  " : ""
        var name = device.paired
            ? batteryText + device.name
            : "[ " + device.name + " ]"   // brackets signal unpaired/discoverable
        var comment = device.paired
            ? getStatusText(device)
            : "Not paired · tap to pair"

        if (device.error) comment = device.error

        // Unpaired discovered devices use pair action instead of connect
        var action = device.paired ? "device:" + device.mac : "pair:" + device.mac

        return {
            name: name,
            icon: getDeviceIcon(device),
            comment: comment,
            action: action,
            categories: ["Bluetooth"],
            keywords: [device.category || "other", device.paired ? "paired" : "discovered"]
        }
    }

    function getDeviceIcon(device) {
        var iconMap = {
            "audio-headset": "material:headphones",
            "audio-card": "material:media_output",
            "input-mouse": "material:mouse",
            "input-keyboard": "material:keyboard",
            "input-gaming": "material:sports_esports",
            "phone": "material:mobile_3",
            "audio-speaker": "material:speaker"
        }
        return iconMap[device.icon || ""] || "material:bluetooth"
    }

    function getStatusText(device) {
        if (device.error) return device.error
        if (device.connecting && device.connected) return "Disconnecting..."
        if (device.connecting) return "Connecting..."
        if (device.connected) return "✓ Connected"
        if (device.available) return "In Range"
        return "Out of Range"
    }

    function executeItem(item) {
        if (!item || !item.action) return
        var action = item.action
        if (action === "action:scan")     { startPairingMode(); return }
        if (action === "action:poweron")  { powerProc.running = true; return }
        if (action === "action:poweroff") { powerOffProc.running = true; return }
        if (action.startsWith("device:")) { toggleDevice(action.substring(7)); return }
        if (action.startsWith("pair:"))   { pairDevice(action.substring(5)); return }
        if (action.startsWith("unpair:")) { unpairDevice(action.substring(7)); return }
    }

    function toggleDevice(mac) {
        var device = findDevice(mac)
        if (!device || device.connecting) return
        if (device.connected) disconnectDevice(mac)
        else connectDevice(mac)
    }

    function getContextMenuActions(item) {
        if (!item || !item.action) return []
        var action = item.action

        // Unpaired discovered device
        if (action.startsWith("pair:")) {
            var mac = action.substring(5)
            return [{ icon: "bluetooth", text: "Pair", action: () => pairDevice(mac) }]
        }

        if (!action.startsWith("device:")) return []
        var mac = action.substring(7)
        var device = findDevice(mac)
        if (!device) return []

        var actions = []
        if (device.connected) {
            actions.push({ icon: "bluetooth_disabled", text: "Disconnect",
                action: () => disconnectDevice(mac) })
        } else {
            actions.push({ icon: "bluetooth", text: "Connect",
                action: () => connectDevice(mac) })
        }
        if (device.paired) {
            actions.push({ icon: "delete", text: "Forget", closeLauncher: true,
                action: () => unpairDevice(mac) })
        }
        return actions
    }

    // =========================================================================
    // HELPERS
    // =========================================================================
    function findDevice(mac) {
        for (var i = 0; i < devices.length; i++) {
            if (devices[i].mac === mac) return devices[i]
        }
        return null
    }

    function makeDevice(mac, name, paired) {
        return {
            mac: mac, name: name,
            paired: paired, connected: false, available: paired ? false : true,
            icon: "", battery: null, category: "other",
            connecting: false, error: null
        }
    }

    function refreshItems() {
        if (pluginService) pluginService.requestLauncherUpdate(pluginId)
        itemsChanged()
    }

    function sortDevices() {
        devices.sort((a, b) => {
            if (a.mac === "__scanning__") return 1
            if (b.mac === "__scanning__") return -1
            if (a.connected !== b.connected) return b.connected ? 1 : -1
            if (a.paired !== b.paired) return a.paired ? -1 : 1
            if (a.available !== b.available) return a.available ? -1 : 1
            return a.name.localeCompare(b.name)
        })
    }

    function getCategoryFromIcon(icon) {
        if (icon.startsWith("audio-") || icon === "audio-card" || icon === "audio-speaker") return "audio"
        if (icon.startsWith("input-")) return "input"
        if (icon === "phone" || icon === "phone-android") return "phone"
        return "other"
    }

    function getPasteText(item) { return null }
    function getPasteArgs(item) { return null }
}
