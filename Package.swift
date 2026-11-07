// swift-tools-version:6.4
import PackageDescription

// Kit, Kern und Tests bauen überall; die SwiftUI-App nur auf macOS. Kryptografie: CryptoKit/CommonCrypto auf
// Apple-Plattformen, sonst swift-crypto. Bewusst ohne `unsafeFlags` (sonst nicht als Abhängigkeit nutzbar) und ohne
// InternalImportsByDefault (bräuchte `public import` im ganzen Kern).
// swift-crypto ist überall deklariert, damit Package.resolved auf allen Plattformen gleich bleibt; eingebunden nur
// unter Windows/Linux. Version nur zusammen mit einem Testlauf unter Windows erhöhen.
let cryptoPackages: [Package.Dependency] = [.package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")]
let nonApple: [Platform] = [.windows, .linux]
let cryptoProducts: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: nonApple)),
    .product(name: "_CryptoExtras", package: "swift-crypto", condition: .when(platforms: nonApple)),
]

// Warnungen sind Fehler (SE-0480; gilt nur für die eigenen Swift-Ziele, nicht für CSQLite und Abhängigkeiten).
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"), .enableUpcomingFeature("MemberImportVisibility"),
    .treatAllWarnings(as: .error),
]

var products: [Product] = [
    .library(name: "MideaKit", targets: ["MideaKit"]),
    .library(name: "KlimacontrolCore", targets: ["KlimacontrolCore"]),
]
var targets: [Target] = [
    .target(name: "MideaKit", dependencies: cryptoProducts, swiftSettings: swiftSettings),
    // SQLite: Apple-Plattformen nehmen die des Systems, sonst die mitgelieferte Amalgamation (exclude: README.md ist
    // keine Quelle, sonst warnt SwiftPM). Deren Warnungen unter Windows/Linux werden hingenommen (kein `-w`).
    .target(name: "CSQLite", exclude: ["README.md"], cSettings: [
        .define("SQLITE_OMIT_LOAD_EXTENSION"), .define("SQLITE_DQS", to: "0"), .define("SQLITE_THREADSAFE", to: "1"),
    ]),
    .target(name: "KlimacontrolCore", dependencies: [
        "MideaKit", .target(name: "CSQLite", condition: .when(platforms: [.windows, .linux])),
    ], swiftSettings: swiftSettings),
    // vectors.json wird über #filePath gelesen, nicht als Ressource – ohne exclude warnt SwiftPM ebenfalls.
    .testTarget(name: "MideaKitTests", dependencies: ["MideaKit"] + cryptoProducts, exclude: ["vectors.json"],
                swiftSettings: swiftSettings),
    .testTarget(name: "KlimacontrolCoreTests", dependencies: ["KlimacontrolCore", "MideaKit"],
                swiftSettings: swiftSettings),
]
#if os(macOS)
products.append(.executable(name: "KlimacontrolApp", targets: ["KlimacontrolApp"]))
// Sparkle (Updates der Mac-App) als Binärziel statt als Paket: steht so nicht in Package.resolved und bleibt
// Windows/Linux ganz verborgen. URL und Prüfsumme wie in Sparkles eigener Package.swift zur selben Version.
targets.append(.binaryTarget(
    name: "Sparkle",
    url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip",
    checksum: "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"))
targets.append(.executableTarget(name: "KlimacontrolApp", dependencies: ["MideaKit", "KlimacontrolCore", "Sparkle"],
                                 swiftSettings: swiftSettings))
#endif
// C-Schnittstelle für die Windows-Oberfläche (DLL nur unter Windows); überall übersetzt, damit Umbenennungen im Kern
// schon am Mac auffallen.
targets.append(.target(name: "KlimacontrolBridge", dependencies: ["MideaKit", "KlimacontrolCore"],
                       swiftSettings: swiftSettings))
// Vertrag Bridge → Windows-Oberfläche: jedes Feld des echten Schnappschusses steht im Muster der C#-Tests.
targets.append(.testTarget(name: "KlimacontrolBridgeTests", dependencies: ["KlimacontrolBridge", "KlimacontrolCore", "MideaKit"],
                           swiftSettings: swiftSettings))
#if os(Windows)
products.append(.library(name: "KlimacontrolBridge", type: .dynamic, targets: ["KlimacontrolBridge"]))
#endif

let package = Package(
    name: "Klimacontrol",
    // iOS 18 wegen `Mutex` (Synchronization), wie macOS 15.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: products,
    dependencies: cryptoPackages,
    targets: targets,
    swiftLanguageModes: [.v6]
)
