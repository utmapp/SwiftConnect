// swift-tools-version: 5.9

import PackageDescription

let package = Package(
	name: "SwiftConnect",
	platforms: [.macOS(.v10_15), .iOS(.v13), .watchOS(.v7), .tvOS(.v13), .visionOS(.v1)],
	products: [
		.library(
			name: "SwiftConnect",
			targets: ["SwiftConnect"])
	],
	dependencies: [
		.package(url: "https://github.com/osy/Cod.git", branch: "main")
	],
	targets: [
		.target(
			name: "SwiftConnect",
			dependencies: ["Cod"]),
		.testTarget(
			name: "SwiftConnectTests",
			dependencies: ["SwiftConnect"]),
	]
)
