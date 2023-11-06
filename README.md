# SwiftConnect

SwiftConnect is a small Swift wrapper around a Network TCP stream on the local network (using Bonjour for discovery) and a simple higher layer protocol for communications. While the transport is bidirectional, the API is designed around a "service" provided by a single server and connected to by potentially many clients.

## Usage

### Pre-shared key

Setup for servers differs a little bit from clients. Once a connection is established, the channel is identical from both ends. All connections are encrypted using TLS-PSK derived from a shared key of your choosing.

> [!IMPORTANT]  
> For security, you should generate the shared key using cryptographically appropriate random data. Sharing this key should be done out-of-band and is out of scope for SwiftConnect. For user-facing applications, one way you might do this is by generating a code on one device and asking the user to confirm it on the second one.

#### Setting up the server

A typical server should advertise its availability using `Connection.advertise(forServiceType:name:key:)`. Attempts by clients to connect will show up as `NWConnection` objects, which you can pass to `Connection.init(connection:)` to complete the connection process.

#### Setting up the client

A client should browse for servers it wants to connect to. `Connection.endpoints(forServiceType:)` will asynchronously stream a list of available `NWEndpoint`s, and once you've found an endpoint that you'd like to connect to, call `Connection.init(endpoint:key:)` to establish the connection using the shared encryption key.

#### Transferring data

Both clients and servers can send data to each other using `Connection.send(data:)`, and receive data by watching `Connection.data`.

### Certificates

You can also use TLSv1.2 with client and server certificates. The caller can specify custom certificate chain validation logic on each end as well. Create your client/server identity as `SecIdentity` and pass it to `Connection.advertise(forServiceType:name:identity:validation:)` or `Connection.init(endpoint:identity:validation:)`. The `validation` callback will return the peer's certificate (chain) which your application can use to determine the validity with custom logic. The default validation will return true on any certificate and should only be used for testing purposes.

### Messages

It is recommended that you use the higher layer communication interface designed around Swift types.

#### Defining message

Implement the `MessageID` protocol to uniquely assign messages to identifiers. Then implement the `Message` protocol for each message you want to handle along with `Serializable` types that will be sent/received for that message. Primitive types and `Codable` types are automatically `Serializable`. Additional types require conformance to the `Serializable` protocol.

```swift
enum LocalMessage: UInt8, MessageID {
	case handshake
	case windows
	case startCasting

	struct Handshake: Message {
		static let id = LocalMessage.handshake

		struct Request: Serializable, Codable {
			let version: Int
		}

		struct Reply: Serializable, Codable {
			let version: Int
		}
	}

	struct Windows: Message {
		static let id = LocalMessage.windows

		typealias Request = SerializableVoid

		struct Reply: Serializable, Codable {
			let windows: [Window]
		}
	}

	struct StartCasting: Message {
		static let id = LocalMessage.startCasting

		struct Request: Serializable, Codable {
			let windowID: Window.ID
		}

		typealias Reply = SerializableVoid
	}
}

enum RemoteMessage: UInt8, MessageID {
	case handshake
	case windowFrame
	case childWindows

	struct Handshake: Message {
		static let id = RemoteMessage.handshake

		struct Request: Serializable, Codable {
			let version: Int
		}

		struct Reply: Serializable, Codable {
			let version: Int
		}
	}

	struct WindowFrame: Message {
		static let id = RemoteMessage.windowFrame

		struct Request: Serializable {
			let windowID: Window.ID
			let frame: Frame

			func encode() async throws -> Data {
				return try await windowID.uleb128 + frame.encode()
			}

			static func decode(_ data: Data) async throws -> Self {
				var data = data
				return try await self.init(windowID: .init(uleb128: &data), frame: .decode(data))
			}
		}

		typealias Reply = SerializableVoid
	}

	struct ChildWindows: Message {
		static let id = RemoteMessage.childWindows

		struct Request: Serializable, Codable {
			let parent: Window.ID
			let children: [Window.ID]
		}

		typealias Reply = SerializableVoid
	}
}
```

You can define the same messages for the host and client or different messages. The `MessageID` can use the same values.

#### Handling messages

Implement the `LocalInterface` protocol to handle incoming messages. You are responsible for deserializing/serializing the data in an agreed-upon format between the peers. However, the `Serializable` interface makes this simple to do and involves writing some boilerplate (TODO: Swift macros could be used here.).

```swift
class Local: LocalInterface {
	typealias M = LocalMessage

	var remote: Remote!

	let screenRecorder = ScreenRecorder()

	func handle(message: M, data: Data) async throws -> Data {
		switch message {
			case .handshake:
				return try await _handshake(parameters: .decode(data)).encode()
			case .windows:
				return try await _windows(parameters: .decode(data)).encode()
			case .startCasting:
				return try await _startCasting(parameters: .decode(data)).encode()
		}
	}

	func handle(error: Error) {
		// do something here
	}

	private func _handshake(parameters: M.Handshake.Request) async throws -> M.Handshake.Reply {
		return .init(version: 1)
	}

	private func _windows(parameters: M.Windows.Request) async throws -> M.Windows.Reply {
		return try await .init(
			windows: screenRecorder.windows.compactMap {
				guard let application = $0.owningApplication?.applicationName,
					$0.isOnScreen
				else {
					return nil
				}
				return Window(windowID: $0.windowID, title: $0.title, app: application, frame: $0.frame, windowLayer: $0.windowLayer)
			})
	}

	private func _startCasting(parameters: M.StartCasting.Request) async throws -> M.StartCasting.Reply {
		let window = try await screenRecorder.lookup(windowID: parameters.windowID)!
		let stream = try await screenRecorder.stream(window: window)

		Task {
			for await frame in stream where frame.imageBuffer != nil {
				Task {
					try await remote.windowFrame(forWindowID: parameters.windowID, frame: Frame(frame: frame))
				}
			}
		}
		return .init()
	}
}
```

#### Sending messages

Once you have a `Connection` and `Message`s defined, you can start sending messages by calling `send(_:to:)` on the message.

```swift
struct Remote {
	typealias M = RemoteMessage
	let peer: Peer

	init(connection: Connection) {
		let local = Local()
		self.connection = Peer(connection: connection, localInterface: local)
		local.remote = self
	}

	func handshake() async throws -> Bool {
		try await _handshake(parameters: .init(version: 1)).version == 1
	}

	private func _handshake(parameters: M.Handshake.Request) async throws -> M.Handshake.Reply {
		try await M.Handshake.send(parameters, to: peer)
	}

	func windowFrame(forWindowID windowID: CGWindowID, frame: Frame) async throws {
		_ = try await _windowFrame(parameters: .init(windowID: windowID, frame: frame))
	}

	private func _windowFrame(parameters: M.WindowFrame.Request) async throws -> M.WindowFrame.Reply {
		try await M.WindowFrame.send(parameters, to: peer)
	}

	func childWindows(parent: CGWindowID, children: [CGWindowID]) async throws {
		_ = try await _childWindows(parameters: .init(parent: parent, children: children))
	}

	private func _childWindows(parameters: M.ChildWindows.Request) async throws -> M.ChildWindows.Reply {
		try await M.ChildWindows.send(parameters, to: peer)
	}
}
```
