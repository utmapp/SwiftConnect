import XCTest

@testable import SwiftConnect

enum TestMessage: UInt8, MessageID {
	case handshake
	case fail

	struct Handshake: Message {
		static let id = TestMessage.handshake

		typealias Request = SerializableVoid

		typealias Reply = SerializableVoid
	}

	struct Fail: Message {
		static let id = TestMessage.fail

		typealias Request = SerializableVoid

		typealias Reply = SerializableVoid
	}
}

enum TestError: Error {
	case testError
}

struct TestLocalInterface: LocalInterface {
	func handle(message: TestMessage, data: Data) async throws -> Data {
		switch message {
		case .handshake:
			return try await _handshake(parameters: .decode(data)).encode()
		case .fail: throw TestError.testError
		}
	}

	func _handshake(parameters: TestMessage.Handshake.Request) async throws -> TestMessage.Handshake.Reply {
		return .init()
	}
}

final class PeerTests: XCTestCase {
	static let serviceType = "_swiftservertest._tcp"

	// Generated randomly.
	static let key = Data([0xbb, 0x62, 0x04, 0x37, 0x86, 0x6e, 0x03, 0x45])

	func testHandshake() async throws {
		let server = Task {
			let serverConnection = try await Connection(connection: Connection.advertise(forServiceType: Self.serviceType, key: Self.key).first { _ in true }!)
			let server = Peer(connection: serverConnection, localInterface: TestLocalInterface())
			_ = try await TestMessage.Handshake.send(.init(), to: server)
			serverConnection.close()
		}
		let client = Task {
			let clientConnection = try await Connection(endpoint: Connection.browse(forServiceType: Self.serviceType).first { !$0.isEmpty }!.first!.endpoint, key: Self.key)
			let client = Peer(connection: clientConnection, localInterface: TestLocalInterface())
			_ = try await TestMessage.Handshake.send(.init(), to: client)
			clientConnection.close()
		}
		try await server.value
		try await client.value
	}

	func testError() async throws {
		let server = Task {
			let serverConnection = try await Connection(connection: Connection.advertise(forServiceType: Self.serviceType, key: Self.key).first { _ in true }!)
			let server = Peer(connection: serverConnection, localInterface: TestLocalInterface())
			do {
				_ = try await TestMessage.Fail.send(.init(), to: server)
				XCTFail("No error was thrown.")
			} catch {
				print(error)
			}
			serverConnection.close()
		}
		let client = Task {
			let clientConnection = try await Connection(endpoint: Connection.browse(forServiceType: Self.serviceType).first { !$0.isEmpty }!.first!.endpoint, key: Self.key)
			let client = Peer(connection: clientConnection, localInterface: TestLocalInterface())
			do {
				_ = try await TestMessage.Fail.send(.init(), to: client)
				XCTFail("No error was thrown.")
			} catch {
				print(error)
			}
			clientConnection.close()
		}
		try await server.value
		try await client.value
	}
}
