// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "kvm-switcher",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "kvmctl", targets: ["kvmctl"]),
        .executable(name: "KVMMenuBar", targets: ["KVMMenuBar"]),
    ],
    targets: [
        // Platform-free: DDC framing, MCCS capabilities, config, switch/verify logic, KVM state.
        .target(name: "KVMCore"),

        // Declarations for Apple Silicon's private IOAVService I2C API (exported by IOKit).
        .target(
            name: "CIOAVService",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),

        // macOS MonitorBackend: display discovery + DDC/CI over IOAVService.
        .target(name: "MacDDC", dependencies: ["KVMCore", "CIOAVService"]),

        .executableTarget(name: "kvmctl", dependencies: ["KVMCore", "MacDDC"]),
        .executableTarget(
            name: "KVMMenuBar",
            dependencies: ["KVMCore", "MacDDC"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]
        ),

        .testTarget(name: "KVMCoreTests", dependencies: ["KVMCore"]),
    ]
)
