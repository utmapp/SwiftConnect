// swift-tools-version: 5.9

import PackageDescription

let package = Package(
	name: "SwiftConnect",
	platforms: [.macOS(.v10_15), .iOS(.v13), .watchOS(.v7), .tvOS(.v13)],
	products: [
		.library(
			name: "SwiftConnect",
			targets: ["SwiftConnect"])
	],
	targets: [
		.target(
			name: "SwiftConnect"),
		.testTarget(
			name: "SwiftConnectTests",
			dependencies: ["SwiftConnect"]),
	]
)
