//
//  Multiplexer.swift
//  MacCast
//
//  Created by Saagar Jha on 10/9/23.
//

import Foundation

public struct Peer<ID: MessageID> {
	let connection: Connection
	let localInterface: any LocalInterface<ID>

	actor Replies {
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
	let replies = Replies()

	init(connection: Connection, localInterface: any LocalInterface<ID>) {
		self.connection = connection
		self.localInterface = localInterface
		serviceReplies()
	}

	func serviceReplies() {
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

	func send(message: ID, data: Data) async throws {
		try await send(message: message, data: data, token: 0)
	}

	func sendWithReply(message: ID, data: Data) async throws -> Data {
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

	func send(message: ID, data: Data, token: Int, flags: PeerFlag = .none) async throws {
		try await connection.send(data: Data([message.rawValue, flags.rawValue]) + token.uleb128 + data)
	}

	func send(message: ID, error: Error, token: Int) async throws {
		try await send(message: message, data: error.localizedDescription.data(using: .utf8)!, token: token, flags: [.response, .error])
	}
}

struct PeerFlag: OptionSet {
	let rawValue: UInt8

	static let none = PeerFlag([])
	static let response = PeerFlag(rawValue: 1 << 0)
	static let error = PeerFlag(rawValue: 1 << 1)
}

enum PeerError: Error {
	case invalidMessage
	case invalidToken
	case unsupportedMessage(UInt8)
	case errorMessage(String)
}

extension PeerError: LocalizedError {
	var errorDescription: String? {
		switch self {
		case .invalidMessage: return NSLocalizedString("An invalid message was recieved from the peer.", comment: "Peer")
		case .invalidToken: return NSLocalizedString("An invalid token was recieved from the peer.", comment: "Peer")
		case .unsupportedMessage(let id): return String.localizedStringWithFormat(NSLocalizedString("Message ID '%u' is unsupported.", comment: "Peer"), id)
		case .errorMessage(let message): return message
		}
	}
}

public protocol LocalInterface<ID> {
	associatedtype ID: MessageID

	func handle(message: ID, data: Data) async throws -> Data
	func handle(error: Error)
}

public extension LocalInterface {
	func handle(error: Error) {
		// ignore errors by default
	}
}
