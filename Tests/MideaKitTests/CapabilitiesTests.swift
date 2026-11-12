import XCTest
@testable import MideaKit

/// Fähigkeiten-Antwort 0xB5 mit erfundenen Bytes, Auswertung wie msmart-ng `CapabilitiesResponse`.
final class CapabilitiesTests: XCTestCase {
    func testParsePageFromFrame() throws {
        let payload: [UInt8] = [0xB5, 2, 0xE3, 0x00, 0x01, 0x08, 0x2C, 0x02, 0x01, 0x01, 0x00]
        guard case .capabilities(let caps, let more) = try Response.parse(Frame.build(.query, payload, id: 7)) else {
            return XCTFail("keine Fähigkeiten")
        }
        XCTAssertFalse(more)
        XCTAssertEqual(caps.raw, [0x00E3: [0x08], 0x022C: [0x01]])
        XCTAssertEqual(caps.ieco, 8)
        XCTAssertNil(caps.iecoEnd)
        XCTAssertTrue(caps.iecoCool && caps.iecoHeat, "8 = ECOMaster: Kühlen und Heizen")
        XCTAssertEqual(caps.iecoNumber, 1, "Nummer hängt nur an ieco_end")
    }

    func testUnsolicitedCapabilitiesAreIgnored() throws {
        // Rahmentyp 0x05 statt 0x03: zählt nicht als Antwort auf die Abfrage (wie msmart-ng).
        var f = [UInt8](Frame.build(.query, [0xB5, 1, 0xE3, 0x00, 0x01, 0x01, 0x00], id: 7))
        f[9] = 0x05
        f[f.count - 1] = Frame.checksum(f[1..<(f.count - 1)])
        guard case .other(0xB5) = try Response.parse(Data(f)) else { return XCTFail("ungefragte Fähigkeiten ausgewertet") }
    }

    func testParsePageEdgeCases() {
        // Länge 0 wird übersprungen, ein abgeschnittener Eintrag beendet die Seite.
        let page = ACCapabilities.parsePage([0xB5, 3, 0x14, 0x02, 0x00, 0xE3, 0x00, 0x02, 0x03, 0x03, 0x48, 0x00, 0x05, 0x01])
        XCTAssertEqual(page.capabilities.raw, [0x00E3: [0x03, 0x03]])
        XCTAssertEqual(page.capabilities.iecoNumber, 3)
        XCTAssertTrue(page.capabilities.iecoCool)
        XCTAssertEqual(ACCapabilities.parsePage([0xB5]).capabilities, ACCapabilities())
        XCTAssertEqual(ACCapabilities.parsePage([0xC0, 1, 2, 3]).capabilities, ACCapabilities())
    }

    func testIECOFlagsLikeMsmart() {
        func flags(_ v: [UInt8]) -> (Bool, Bool, UInt8) {
            let c = ACCapabilities(raw: [0x00E3: v])
            return (c.iecoCool, c.iecoHeat, c.iecoNumber)
        }
        XCTAssertTrue(flags([1]) == (true, false, 1))
        XCTAssertTrue(flags([4]) == (false, true, 1))
        XCTAssertTrue(flags([0, 1]) == (true, false, 3))
        XCTAssertTrue(flags([0, 3]) == (false, true, 3))
        XCTAssertTrue(flags([0, 8]) == (true, true, 8))
        XCTAssertTrue(flags([0]) == (false, false, 1))
        XCTAssertFalse(ACCapabilities().reportsIECO)
    }

    func testCapabilityFrames() {
        XCTAssertEqual([UInt8](Frame.getCapabilities(additional: true, id: 0x10))[10..<14].map { $0 }, [0xB5, 0x01, 0x01, 0x01])
        XCTAssertEqual(Array(Frame.setProperty(.ieco, true, iecoNumber: 3, id: 1)[10..<18]), [0xB0, 1, 0xE3, 0x00, 13, 0, 3, 1])
    }

    func testComfortFlagsLikeMsmart() {
        func caps(_ id: UInt16, _ v: UInt8) -> ACCapabilities { ACCapabilities(raw: [id: [v]]) }
        let none = ACCapabilities()
        for flag in [none.selfClean, none.rateSelect, none.parentControl, none.outSilent, none.eco, none.freezeProtection,
                     none.swingVertical, none.swingHorizontal, none.turboCool, none.turboHeat, none.anion,
                     none.displayControl, none.sound, none.iecoSupported] {
            XCTAssertNil(flag, "nicht gemeldet = unbekannt")
        }
        XCTAssertEqual(caps(0x0039, 1).selfClean, true)
        XCTAssertEqual(caps(0x0039, 0).selfClean, false)
        XCTAssertEqual([0, 1, 2, 3, 4].map { caps(0x0048, $0).rateSelectLevels }, [0, 2, 5, 5, 0])
        XCTAssertEqual(caps(0x0048, 0).rateSelect, false)
        XCTAssertEqual(caps(0x0051, 1).parentControl, true)
        XCTAssertEqual([0, 1, 2, 3].map { caps(0x00CD, $0).outSilent }, [false, true, false, true])
        XCTAssertEqual([0, 1, 2, 3].map { caps(0x0212, $0).eco }, [false, true, true, false])
        XCTAssertEqual([0, 1, 2].map { caps(0x0213, $0).freezeProtection }, [false, true, false])
        XCTAssertEqual([0, 1, 2, 3].map { caps(0x0215, $0).swingVertical }, [true, true, false, false])
        XCTAssertEqual([0, 1, 2, 3].map { caps(0x0215, $0).swingHorizontal }, [false, true, false, true])
        XCTAssertEqual([0, 1, 2, 3].map { caps(0x021A, $0).turboCool }, [true, true, false, false])
        XCTAssertEqual([0, 1, 2, 3].map { caps(0x021A, $0).turboHeat }, [false, true, false, true])
        XCTAssertEqual([0, 1].map { caps(0x021E, $0).anion }, [false, true])
        XCTAssertEqual([0, 1, 2, 3, 100].map { caps(0x0224, $0).displayControl }, [false, true, true, false, true])
        XCTAssertEqual([0, 1].map { caps(0x022C, $0).sound }, [false, true])
        XCTAssertEqual([0, 1, 4].map { caps(0x00E3, $0).iecoSupported }, [false, true, true])
    }
}
