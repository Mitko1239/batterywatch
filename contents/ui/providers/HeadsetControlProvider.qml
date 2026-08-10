import QtQuick 2.15
import org.kde.plasma.plasma5support 2.0 as P5Support
import org.kde.plasma.plasmoid 2.0
import "../DeviceUtils.js" as DeviceUtils

// HeadsetControl provider
// Reads headset battery data via: headsetcontrol -b -o json
Item {
    id: root
    visible: false

    property var devices: []
    property bool available: false
    property bool headsetControlEnabled: Plasmoid.configuration.enableHeadsetControlIntegration

    readonly property var emptyList: []
    readonly property int wirelessType: 1
    readonly property string pollCmd: "headsetcontrol -b -o json 2>/dev/null"
    property bool showUnavailableAsNA: Plasmoid.configuration.headsetControlShowUnavailableAsNA

    onHeadsetControlEnabledChanged: {
        if (!headsetControlEnabled) {
            devices = []
            available = false
            pollSource.disconnectSource(pollCmd)
        } else {
            refresh()
        }
    }

    onShowUnavailableAsNAChanged: {
        if (headsetControlEnabled)
            refresh()
    }

    function refresh() {
        if (!headsetControlEnabled)
            return

        pollSource.disconnectSource(pollCmd)
        pollSource.connectSource(pollCmd)
    }

    function parseCharging(status) {
        if (status === true || status === false)
            return status

        if (typeof status !== "string")
            return false

        var normalized = status.trim().toLowerCase()
        return normalized.indexOf("charging") !== -1 || normalized === "true" || normalized === "yes" || normalized === "on" || normalized === "1"
    }

    function hasBatteryError(device) {
        if (!device || typeof device !== "object")
            return false
        if (!device.errors || typeof device.errors !== "object")
            return false

        var errorValue = device.errors.battery
        if (errorValue === undefined || errorValue === null)
            return false

        return String(errorValue).trim().length > 0
    }

    function isBatteryUnavailable(device, battery, level) {
        if (hasBatteryError(device))
            return true

        if (!battery || typeof battery !== "object")
            return true

        var status = battery.status
        if (typeof status === "string") {
            var normalized = status.trim().toUpperCase()
            if (normalized.indexOf("UNAVAILABLE") !== -1 ||
                normalized.indexOf("NOT_AVAILABLE") !== -1 ||
                normalized.indexOf("DISCONNECTED") !== -1 ||
                normalized.indexOf("UNKNOWN") !== -1 ||
                normalized === "N/A") {
                return true
            }
        }

        // Valid level is required for display.
        return !isFinite(level) || level < 0
    }

    function toHexId(value) {
        if (value === undefined || value === null)
            return ""

        var n
        if (typeof value === "number") {
            n = value
        } else if (typeof value === "string") {
            var trimmed = value.trim().toLowerCase()
            if (!trimmed)
                return ""

            if (trimmed.startsWith("0x"))
                n = parseInt(trimmed, 16)
            else if (/^[0-9a-f]+$/.test(trimmed) && /[a-f]/.test(trimmed))
                n = parseInt(trimmed, 16)
            else
                n = parseInt(trimmed, 10)
        }

        if (!isFinite(n) || n < 0)
            return ""

        return "0x" + Math.round(n).toString(16).padStart(4, "0")
    }

    function firstDefined(device, keys) {
        for (var i = 0; i < keys.length; i++) {
            var k = keys[i]
            if (device[k] !== undefined && device[k] !== null)
                return device[k]
        }
        return undefined
    }

    function parseCombinedUsbId(value) {
        if (value === undefined || value === null)
            return ""

        var text = String(value).trim()
        if (!text)
            return ""

        // Supports: 1038:22a1, 0x1038:0x22a1, 1038-22a1, 1038_22a1
        var match = text.match(/(?:0x)?([0-9a-fA-F]{4})\s*[:\-_]\s*(?:0x)?([0-9a-fA-F]{4})/)
        if (!match)
            return ""

        return "0x" + match[1].toLowerCase() + ":0x" + match[2].toLowerCase()
    }

    function vendorProductId(device) {
        var vendorRaw = firstDefined(device, [
            "id_vendor", "vendor_id", "vendorId", "idVendor", "vendor_hex", "vendorHex", "vid"
        ])
        var productRaw = firstDefined(device, [
            "id_product", "id_project", "product_id", "productId", "idProduct", "product_hex", "productHex", "pid"
        ])

        var vendor = toHexId(vendorRaw)
        var product = toHexId(productRaw)

        if (!(vendor && product)) {
            var combined = firstDefined(device, [
                "usb_id", "usbId", "device_id", "deviceId", "vendor_product", "vendorProduct"
            ])
            var combinedId = parseCombinedUsbId(combined)
            if (combinedId)
                return combinedId
        }

        if (vendor && product)
            return vendor + ":" + product
        return ""
    }

    function parseDevices(jsonText) {
        var parsed = JSON.parse(jsonText)
        var sourceDevices = []

        if (Array.isArray(parsed)) {
            sourceDevices = parsed
        } else if (parsed && Array.isArray(parsed.devices)) {
            sourceDevices = parsed.devices
        }

        var result = []
        var seen = ({})

        for (var i = 0; i < sourceDevices.length; i++) {
            var d = sourceDevices[i]
            if (!d || typeof d !== "object")
                continue

            var battery = (d.battery && typeof d.battery === "object") ? d.battery : ({})
            var rawLevel = battery.level
            var level = Number(rawLevel)
            var unavailable = isBatteryUnavailable(d, battery, level)

            // Hide devices when headsetcontrol reports unavailable battery state.
            if (unavailable && !showUnavailableAsNA)
                continue

            var clamped = Math.max(0, Math.min(100, Math.round(level)))
            var name = d.device || d.name || i18n("Unknown Headset")
            var idText = vendorProductId(d)
            var serial = d.id || d.serial || idText || ("headsetcontrol-" + i)

            // Avoid showing the device name again in the subtitle fallback path.
            if (serial === name)
                serial = idText || ("headsetcontrol-" + i)

            if (seen[serial])
                continue
            seen[serial] = true

            result.push({
                name: name,
                serial: idText,
                percentage: unavailable ? -1 : clamped,
                charging: unavailable ? false : parseCharging(battery.status),
                batteryUnavailable: unavailable,
                type: "headset",
                icon: DeviceUtils.getIconForType("headset"),
                connectionType: wirelessType,
                source: "headsetcontrol",
                batteries: emptyList
            })
        }

        result.sort((a, b) => (a.name || "").localeCompare(b.name || ""))
        return result
    }

    function sameDevices(a, b) {
        if (a.length !== b.length)
            return false

        for (var i = 0; i < a.length; i++) {
            var x = a[i]
            var y = b[i]

            if (x.serial !== y.serial ||
                x.name !== y.name ||
                x.percentage !== y.percentage ||
                x.charging !== y.charging ||
                x.batteryUnavailable !== y.batteryUnavailable)
                return false
        }

        return true
    }

    P5Support.DataSource {
        id: pollSource
        engine: "executable"
        connectedSources: []
        interval: 0

        onNewData: (src, data) => {
            disconnectSource(src)

            if (!root.headsetControlEnabled) {
                root.devices = []
                root.available = false
                return
            }

            var output = data.stdout || ""
            if (data["exit code"] !== 0 || !output.trim()) {
                if (root.devices.length > 0)
                    root.devices = []
                root.available = false
                return
            }

            try {
                var parsedDevices = root.parseDevices(output.trim())
                if (!root.sameDevices(parsedDevices, root.devices))
                    root.devices = parsedDevices
                root.available = true
            } catch (e) {
                console.warn("BatteryWatch HeadsetControl: Failed to parse output:", e)
                if (root.devices.length > 0)
                    root.devices = []
                root.available = false
            }
        }
    }

    Timer {
        interval: Math.max(1, Plasmoid.configuration.headsetControlPollingTime) * 1000
        running: root.headsetControlEnabled
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: {
        if (root.headsetControlEnabled)
            root.refresh()
    }
}