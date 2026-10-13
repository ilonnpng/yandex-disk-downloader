// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YandexDiskDownloader",
    platforms: [.macOS(.v13)],
    products: [.library(name: "YandexDiskCore", targets: ["YandexDiskCore"]),
               .executable(name: "YandexDiskDownloader", targets: ["YandexDiskDownloader"])],
    targets: [.target(name: "YandexDiskCore"),
              .executableTarget(name: "YandexDiskDownloader", dependencies: ["YandexDiskCore"]),
              .testTarget(name: "YandexDiskCoreTests", dependencies: ["YandexDiskCore"])])
