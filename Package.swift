// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "calendar-app-service",
	platforms:[
		.macOS(.v15)
	],
	products: [
		.executable(
			 name:"calendar-services",
			 targets:[
				 "calendar-services"
			 ]
		 ),
		.library(
			name: "calendar-core",
			targets: ["calendar-core"]
		),
	],
	dependencies:[
//		.package(url:"https://github.com/tannerdsilva/rawdog.git", "20.0.0"..<"21.0.0"),
		.package(url:"https://github.com/tannerdsilva/rawdog.git", revision: "1c4966c72102fc01b169cbc18ee5f0be10d802de"),
		.package(url:"https://github.com/tannerdsilva/QuickLMDB.git", "14.0.0"..<"15.0.0"),
//		.package(path:"../nostr-kit-swift"),
		.package(url:"https://github.com/bwyma1/nostr-kit-swift", revision:"a8072a1bee5bc7541a8b5375b1aa0e4b370665c4"),
		.package(url:"https://github.com/tannerdsilva/wireguard-swift", revision:"f015dfe134763a1daa460c623b3c0b8bcb6fcd97"),
//		.package(path:"../wireguard-swift"),

		.package(url:"https://github.com/apple/swift-nio.git", "2.81.0"..<"3.0.0"),
		.package(url:"https://github.com/tannerdsilva/bedrock.git", "7.1.0"..<"8.0.0"),

		.package(url:"https://github.com/swift-server/swift-service-lifecycle.git", "2.6.3"..<"3.0.0"),
		.package(url:"https://github.com/apple/swift-argument-parser.git", "1.5.0"..<"2.0.0"),
	],
    targets: [
		.executableTarget(
			name: "calendar-services",
			dependencies:[
				.product(name:"bedrock", package:"bedrock"),
				.product(name:"RAW", package:"rawdog"),
				.product(name:"RAW_blake2", package:"rawdog"),
				.product(name:"RAW_sha256", package:"rawdog"),
				.product(name:"QuickLMDB", package:"QuickLMDB"),
				
				.product(name:"NIO", package:"swift-nio"),
				.product(name:"ServiceLifecycle", package:"swift-service-lifecycle"),
				.product(name:"ArgumentParser", package:"swift-argument-parser"),
				.product(name:"wireguard-userspace-nio", package:"wireguard-swift"),
				"calendar-core"
			]
		),
        .target(
            name: "calendar-core",
			dependencies:[
				.product(name:"bedrock", package:"bedrock"),
				.product(name:"RAW", package:"rawdog"),
				.product(name:"RAW_blake2", package:"rawdog"),
				.product(name:"QuickLMDB", package:"QuickLMDB"),
				.product(name:"nostr-kit-swift", package:"nostr-kit-swift")
			]
        ),
        .testTarget(
            name: "calendar-app-serviceTests",
            dependencies: ["calendar-core"]
        ),
    ]
)
