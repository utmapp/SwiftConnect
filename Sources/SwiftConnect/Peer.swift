//
//  Multiplexer.swift
//  MacCast
//
//  Created by Saagar Jha on 10/9/23.
//

import Foundation

/// Represents a remote peer who can send and receive messages.
public struct Peer<ID: MessageID> {
	private let connection: Connection
	private let localInterface: any LocalInterface<ID>

	private actor Replies {
		var token: Int = 1
		var continuations = [Int: CheckedContinuation<Data, Error>]()

		func enqueue(_ continuation: CheckedContinuation<Data, Error>) -> Int {
			defer {
				token += 1
			}
			continuations[token] = continuation
			return token
		}

		func failAll(with error: Error) {
			for continuation in continuations.values {
				continuation.resume(throwing: error)
			}
			continuations.removeAll()
		}

		func yield(_ data: Data, forToken token: Int) throws {
			guard let continuation = continuations.removeValue(forKey: token) else {
				throw PeerError.invalidToken
			}
			continuation.resume(returning: data)
		}

		func fail(_ error: Error, forToken token: Int) throws {
			guard let continuation = continuations.removeValue(forKey: token) else {
				throw PeerError.invalidToken
			}
			continuation.resume(throwing: error)
		}
	}
	private let replies = Replies()

	/// Create a peer from a connection.
	/// - Parameters:
	///   - connection: An established connection.
	///   - localInterface: A local interface used for handling remote messages.
	public init(connection: Connection, localInterface: any LocalInterface<ID>) {
		self.connection = connection
		self.localInterface = localInterface
		serviceReplies()
	}

	private func serviceReplies() {
		Task {
			do {
				for try await data in connection.data {
					Task {
						do {
							var data = data
							guard let id = data.popFirst(), let _flags = data.popFirst() else {
								throw PeerError.invalidMessage
							}
							guard let message = ID(rawValue: id) else {
								throw PeerError.unsupportedMessage(id)
							}

							let flags = PeerFlag(rawValue: _flags)
							let token = try Int(uleb128: &data)
							
							// handle responses
							if flags.contains(.response) {
								if flags.contains(.error) {
									let message = String(data: data, encoding: .utf8)!
									try await replies.fail(PeerError.errorMessage(message), forToken: token)
								} else {
									try await replies.yield(data, forToken: token)
								}
							} else {
								// handle requests
								var response: Data?
								do {
									response = try await localInterface.handle(message: message, data: data)
								} catch {
									try await send(message: message, error: error, token: token)
								}
								if let response = response {
									try await send(message: message, data: response, token: token, flags: .response)
								}
							}
						} catch {
							localInterface.handle(error: error)
						}
					}
				}
			} catch {
				await replies.failAll(with: error)
			}
		}
	}

	internal func sendWithReply(message: ID, data: Data) async throws -> Data {
		try await withCheckedThrowingContinuation { continuation in
			Task {
				let token = await replies.enqueue(continuation)
				do {
					try await send(message: message, data: data, token: token)
				} catch {
					try! await replies.fail(error, forToken: token)
				}
			}
		}
	}

	private func send(message: ID, data: Data, token: Int, flags: PeerFlag = .none) async throws {
		try await connection.send(data: Data([message.rawValue, flags.rawValue]) + token.uleb128 + data)
	}

	private func send(message: ID, error: Error, token: Int) async throws {
		try await send(message: message, data: error.localizedDescription.data(using: .utf8)!, token: token, flags: [.response, .error])
	}
}

private struct PeerFlag: OptionSet {
	let rawValue: UInt8

	static let none = PeerFlag([])
	static let response = PeerFlag(rawValue: 1 << 0)
	static let error = PeerFlag(rawValue: 1 << 1)
}

/// Error responses from the communications.
public enum PeerError: Error {
	/// An invalid message was recieved from the peer.
	case invalidMessage
	/// An invalid token was recieved from the peer.
	case invalidToken
	/// An unsupported `MessageID` was recieved from the peer. (Usually indicating an interface version mismatch).
	case unsupportedMessage(UInt8)
	/// An error message was sent by the peer.
	case errorMessage(String)
}

extension PeerError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .invalidMessage: return NSLocalizedString("An invalid message was recieved from the peer.", comment: "Peer")
		case .invalidToken: return NSLocalizedString("An invalid token was recieved from the peer.", comment: "Peer")
		case .unsupportedMessage(let id): return String.localizedStringWithFormat(NSLocalizedString("Message ID '%u' is unsupported.", comment: "Peer"), id)
		case .errorMessage(let message): return message
		}
	}
}

/// Implement this protocol to handle messages from the remote peer.
public protocol LocalInterface<ID> {
	associatedtype ID: MessageID

	/// Handle a message from a peer.
	/// - Parameters:
	///   - message: Unique identifier for this message.
	///   - data: Incoming parameters which must be unserialized in an agreed-upon procedure.
	/// - Returns: Outgoing response which must be serialized in an agreed-upon procedure.
	func handle(message: ID, data: Data) async throws -> Data

	/// (Optional) Handle an error from a peer.
	///
	/// If the error is in response to a message, it will be thrown in the `send(_:to:)` call.
	/// Any other communication error will be handled by this function.
	/// - Parameter error: Error received.
	func handle(error: Error)
}

public extension LocalInterface {
	func handle(error: Error) {
		// ignore errors by default
	}
}
