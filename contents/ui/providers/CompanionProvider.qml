import QtQuick 2.15
import org.kde.plasma.plasma5support 2.0 as P5Support
import "../DeviceUtils.js" as DeviceUtils

// BatteryWatch Companion service provider
Item {
    id: root
    visible: false
    
    property var devices: []
    property bool available: false
    
    function refresh() {
        pollSource.connectSource("gdbus call --session --dest org.batterywatch.Companion --object-path /org/batterywatch/Companion --method org.batterywatch.Companion.GetDevices 2>/dev/null")
    }

    function clampPercent(value) {
        var n = parseInt(value)
        if (isNaN(n)) return null
        return Math.max(0, Math.min(100, n))
    }

    function toTitleBatteryLabel(labelLower) {
        if (labelLower === "left") return "Left"
        if (labelLower === "right") return "Right"
        if (labelLower === "case") return "Case"
        return labelLower.length > 0 ? (labelLower.charAt(0).toUpperCase() + labelLower.slice(1)) : null
    }

    function normalizeBatteryLabel(label) {
        var normalized = (label || "").toString().trim().toLowerCase()
        if (!normalized) return null

        if (normalized === "l" || normalized === "left" || normalized.indexOf("left") !== -1)
            return "Left"
        if (normalized === "r" || normalized === "right" || normalized.indexOf("right") !== -1)
            return "Right"
        if (normalized === "c" || normalized === "case" || normalized.indexOf("case") !== -1 || normalized.indexOf("cradle") !== -1)
            return "Case"

        return toTitleBatteryLabel(normalized)
    }

    function parseBatteryCharging(value) {
        if (value === true) return true
        if (value === false || value === undefined || value === null) return false
        var v = value.toString().trim().toLowerCase()
        return v === "charging" || v === "true" || v === "1"
    }

    function getObjectValueByAliases(obj, aliases) {
        if (!obj || typeof obj !== "object") return undefined
        for (var i = 0; i < aliases.length; i++) {
            var key = aliases[i]
            if (Object.prototype.hasOwnProperty.call(obj, key))
                return obj[key]
        }
        return undefined
    }

    function pushBatteryFromAliases(target, source, aliases, label) {
        var raw = getObjectValueByAliases(source, aliases)
        var pct = clampPercent(raw)
        if (pct === null) return

        target.push({
            label: label,
            percentage: pct,
            charging: false
        })
    }

    function dedupeAndSortBatteries(batteries) {
        var byLabel = {}
        batteries.forEach(function(bat) {
            var key = (bat.label || "").toLowerCase()
            byLabel[key] = bat
        })

        var unique = []
        for (var key in byLabel)
            unique.push(byLabel[key])

        var order = { "left": 0, "right": 1, "case": 2 }
        unique.sort(function(a, b) {
            var ka = (a.label || "").toLowerCase()
            var kb = (b.label || "").toLowerCase()
            var oa = (order[ka] !== undefined) ? order[ka] : 99
            var ob = (order[kb] !== undefined) ? order[kb] : 99
            if (oa !== ob) return oa - ob
            return ka.localeCompare(kb)
        })

        return unique
    }

    function extractBatteries(data) {
        var result = []

        if (Array.isArray(data.batteries) && data.batteries.length > 0) {
            data.batteries.forEach(function(bat) {
                if (!bat || typeof bat !== "object") return

                var pct = clampPercent(
                    (bat.percentage !== undefined) ? bat.percentage :
                    ((bat.level !== undefined) ? bat.level : bat.battery)
                )
                if (pct === null) return

                var label = normalizeBatteryLabel(bat.label || bat.name || bat.side || bat.part || "")
                var charging = parseBatteryCharging(
                    (bat.charging !== undefined) ? bat.charging : bat.status
                )

                result.push({
                    label: label,
                    percentage: pct,
                    charging: charging
                })
            })
        }

        // Fallback for companion payloads that provide component batteries as flat/nested keys.
        if (result.length === 0) {
            var objectsToProbe = [data]
            if (data.battery && typeof data.battery === "object") objectsToProbe.push(data.battery)
            if (data.budBattery && typeof data.budBattery === "object") objectsToProbe.push(data.budBattery)
            if (data.earbuds && typeof data.earbuds === "object") objectsToProbe.push(data.earbuds)

            for (var i = 0; i < objectsToProbe.length; i++) {
                var src = objectsToProbe[i]

                pushBatteryFromAliases(result, src,
                    ["left", "left_battery", "leftBattery", "battery_left", "batteryLeft", "left_level", "leftLevel", "l"],
                    "Left")
                pushBatteryFromAliases(result, src,
                    ["right", "right_battery", "rightBattery", "battery_right", "batteryRight", "right_level", "rightLevel", "r"],
                    "Right")
                pushBatteryFromAliases(result, src,
                    ["case", "case_battery", "caseBattery", "battery_case", "batteryCase", "cradle", "charging_case", "chargingCase", "c"],
                    "Case")
            }
        }

        return dedupeAndSortBatteries(result)
    }

    function normalizeModel(modelOrName) {
        var raw = (modelOrName || "").toString().trim()
        var lower = raw.toLowerCase()
        if (!lower) return ""

        if (lower.indexOf("airpodspro3") !== -1 ||
            lower.match(/airpods\s*pro(?:\s*|\s*\(|[-_])(?:3|iii|3rd|gen\s*3|third)/))
            return "AirPods Pro 3"

        if (lower.match(/galaxy\s*(ear\s*buds|earbuds|buds)\s*2/) ||
            lower.match(/galaxy\s*buds\s*2/) ||
            lower.indexOf("buds2") !== -1)
            return "Galaxy Earbuds 2"

        return raw
    }

    function inferDeviceType(rawType, name, model) {
        if (rawType && rawType !== "unknown")
            return rawType

        var haystack = ((name || "") + " " + (model || "")).toLowerCase()
        if (haystack.match(/airpods|earbuds|ear\s*buds|buds|headset|headphones/))
            return "headphones"

        return rawType || "unknown"
    }

    function extractDeviceId(data, fallbackName) {
        var directId = data.id || data.address || data.mac || data.macAddress ||
            data.bluetoothAddress || data.btAddress || data.serial || data.device_id || data.uuid || ""

        if (directId)
            return directId.toString().trim()

        // As a last resort, keep the device visible using a deterministic local ID.
        var fallback = (fallbackName || data.model || data.name || "").toString().trim()
        if (!fallback)
            return ""
        return "companion:" + fallback.toLowerCase().replace(/\s+/g, "-")
    }
    
    // Parse Companion JSON data into device object
    function parseCompanionDevice(data) {
        if (!data || typeof data !== 'object') return null

        var normalizedName = normalizeModel(data.name || "")
        var normalizedModel = normalizeModel(data.model || normalizedName || "")
        var id = extractDeviceId(data, normalizedName || normalizedModel)
        if (!id) return null

        var deviceType = inferDeviceType(data.device_type || "unknown", data.name || "", normalizedModel)
        var icon = data.icon_name || DeviceUtils.getIconForType(deviceType)
        
        // Handle batteries array
        var batteries = extractBatteries(data)
        var percentage = 0
        
        if (batteries.length > 0) {
            var total = 0
            batteries.forEach(function(bat) {
                total += bat.percentage
            })
            percentage = Math.round(total / batteries.length)
            batteries = batteries.map(function(bat) {
                var labelLower = (bat.label || "").toLowerCase()
                var isCharging = bat.charging === true
                return {
                    label: bat.label,
                    percentage: bat.percentage,
                    charging: isCharging,
                    // Only show in tray if: not Case AND not charging
                    showInTray: labelLower !== "case" && !isCharging
                }
            })
        } else if (data.percentage !== undefined) {
            percentage = clampPercent(data.percentage)
            if (percentage === null)
                percentage = 0
        }
        
        return {
            name: normalizedName || data.name || normalizedModel || data.model || i18n("Unknown Device"),
            serial: id,
            percentage: percentage,
            icon: icon,
            type: deviceType,
            batteries: batteries,
            model: normalizedModel || data.model || "",
            source: "companion",
            nativePath: "",
            objectPath: "",
            connectionType: 2,
            bluetoothAddress: id,
            disconnect: () => companionDisconnectSource.connectSource("bluetoothctl disconnect " + id),
            disconnectTooltip: i18n("Disconnect device")
        }
    }
    
    P5Support.DataSource {
        id: companionDisconnectSource
        engine: "executable"
        interval: 0
        // Companion polls on its own timer, refresh will pick up the change
        onNewData: (src, data) => disconnectSource(src)
    }

    P5Support.DataSource {
        id: pollSource
        engine: "executable"
        connectedSources: []
        interval: 0
        
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            
            var output = data["stdout"] || ""
            if (data["exit code"] !== 0 || !output.trim()) {
                if (root.available) {
                    root.available = false
                    root.devices = []
                    console.log(i18n("BatteryWatch: Companion service disconnected"))
                }
                return
            }
            
            // Parse gdbus output: ('json_string',)
            var match = output.match(/\('(.*)'\,?\)/)
            if (!match) return
            
            try {
                var jsonStr = match[1].replace(/\\'/g, "'").replace(/\\"/g, '"').replace(/\\\\/g, '\\')
                var rawDevices = JSON.parse(jsonStr)
                
                if (!Array.isArray(rawDevices)) return
                
                root.devices = rawDevices.map(d => parseCompanionDevice(d)).filter(d => d !== null)
                
                if (!root.available) {
                    root.available = true
                    console.log(i18n("BatteryWatch: Companion service connected"))
                }
            } catch (e) {
                console.warn(i18n("BatteryWatch: Failed to parse companion data:"), e)
            }
        }
    }
    
    // Poll frequently when service is available, probe slowly when not
    Timer {
        interval: root.available ? 10000 : 60000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
    
    Component.onCompleted: root.refresh()
}
