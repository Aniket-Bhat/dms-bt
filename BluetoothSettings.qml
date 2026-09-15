import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "bluetoothLauncher"

    property bool _initialized: false

    onPluginServiceChanged: {
        if (pluginService) {
            Qt.callLater(() => { _initialized = true })
        }
    }

    StyledText {
        width: parent.width
        text: "Bluetooth"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Quickly connect, disconnect, and manage Bluetooth devices from the launcher"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: triggerColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: triggerColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Trigger"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StringSetting {
                settingKey: "trigger"
                label: "Launcher Trigger"
                description: "Prefix to activate the Bluetooth launcher (e.g., \"bt\" or \"bluetooth\")"
                placeholder: "bt"
                defaultValue: "bt"
                onValueChanged: {
                    if (!root._initialized) return
                    root.saveValue("trigger", value)
                }
            }
        }
    }

    StyledRect {
        width: parent.width
        height: scanColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: scanColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Scanning"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StringSetting {
                settingKey: "countdownDuration"
                label: "Scan Duration (seconds)"
                description: "How long to scan for nearby devices (3–30)"
                placeholder: "5"
                defaultValue: "5"
                onValueChanged: {
                    if (!root._initialized) return
                    var n = parseInt(value)
                    if (isNaN(n)) return
                    root.saveValue("countdownDuration", Math.min(30, Math.max(3, n)))
                }
            }
        }
    }

    StyledRect {
        width: parent.width
        height: tipsColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surface

        Column {
            id: tipsColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                spacing: Theme.spacingM

                DankIcon {
                    name: "info"
                    size: Theme.iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: "Usage Tips"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                width: parent.width
                text: "Type the trigger keyword in the launcher (e.g., \"bt\") to browse your Bluetooth devices.\n\nPress Tab on a device for more actions: Connect, Disconnect, or Unpair.\n\nAlternatively, you can also setup a keybind to open `dms ipc call launcher openQuery <trigger>`"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }
        }
    }
}
