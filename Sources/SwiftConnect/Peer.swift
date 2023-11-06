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

		func yield(_ data: Data, forToken token: Int) {
			let continuation = continuations.removeValue(forKey: token)!
			continuation.resume(returning: data)
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
						let message = ID(rawValue: data.first!)!
						var data = data.dropFirst()
						let token = try Int(uleb128: &data)
						if let data = try await localInterface.handle(message: message, data: data) {
							try await send(message: message, data: data, token: token)
						} else {
							await replies.yield(data, forToken: token)
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
				Task {
					let token = await replies.enqueue(continuation)
					do {
						try await send(message: message, data: data, token: token)
					} catch {
						continuation.resume(throwing: error)
					}
				}
			}
		}
	}

	func send(message: ID, data: Data, token: Int) async throws {
		try await connection.send(data: Data([message.rawValue]) + token.uleb128 + data)
	}
}

public protocol LocalInterface<ID> {
	associatedtype ID: MessageID

	func handle(message: ID, data: Data) async throws -> Data?
}
