#if os(Windows)
import Foundation
import KlimacontrolCore
import MideaKit
import WinSDK

/// Foundation unter Windows liefert für `TimeZone.current` GMT (es reicht den lokalisierten Zonennamen an ICU weiter).
/// Darum die Windows-Zone über ICU in eine IANA-Kennung umsetzen und als Standardzone setzen; `Calendar.current` und
/// `DateFormatter` folgen ihr. Ohne Ergebnis bleibt alles wie es ist.
@discardableResult
func applyWindowsTimeZone() -> String? {
    guard let windowsID = windowsTimeZoneKey(), let iana = ianaTimeZone(forWindowsID: windowsID),
          let zone = TimeZone(identifier: iana) else {
        AppLog.write(L.Log.Bridge.timeZone, L.Log.Level.warning)
        return nil
    }
    NSTimeZone.default = zone
    return iana
}

private func windowsTimeZoneKey() -> String? {
    var info = DYNAMIC_TIME_ZONE_INFORMATION()
    guard GetDynamicTimeZoneInformation(&info) != TIME_ZONE_ID_INVALID else { return nil }
    let key = withUnsafeBytes(of: info.TimeZoneKeyName) { raw in
        String(decoding: raw.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self)
    }
    return key.isEmpty ? nil : key
}

/// ICUs Zeitzonentabelle steckt in der mitgelieferten `_FoundationICU.dll`; ihre Symbole tragen das Präfix `swift_`
/// und sind zur Bauzeit nicht ohne Eingriff in `Package.swift` linkbar, darum zur Laufzeit gesucht.
private typealias WindowsIDToZone = @convention(c) (
    UnsafePointer<UInt16>?, Int32, UnsafePointer<CChar>?, UnsafeMutablePointer<UInt16>?, Int32, UnsafeMutablePointer<Int32>?
) -> Int32

func ianaTimeZone(forWindowsID windowsID: String) -> String? {
    guard let module = "_FoundationICU.dll".withCString(encodedAs: UTF16.self, { GetModuleHandleW($0) }),
          let symbol = GetProcAddress(module, "swift_ucal_getTimeZoneIDForWindowsID") else { return nil }
    let convert = unsafeBitCast(symbol, to: WindowsIDToZone.self)
    let win = Array(windowsID.utf16)
    var out = [UInt16](repeating: 0, count: 128)
    var status: Int32 = 0
    let length = convert(win, Int32(win.count), nil, &out, Int32(out.count), &status)
    guard status <= 0, length > 0, Int(length) <= out.count else { return nil }
    return String(decoding: out.prefix(Int(length)), as: UTF16.self)
}
#endif
