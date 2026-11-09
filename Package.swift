// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OrionDiagnostics",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OrionDiagnostics", targets: ["OrionDiagnostics"])],
    targets: [
        .target(name: "CSerial", publicHeadersPath: "include"),
        .target(name: "BMSCore", dependencies: ["CSerial"], linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(name: "OrionDiagnostics", dependencies: ["BMSCore"]),
        .testTarget(name: "BMSCoreTests", dependencies: ["BMSCore", "CSerial", "OrionDiagnostics"], resources:[.process("Fixtures")])
    ]
)
