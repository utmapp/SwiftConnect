//
//  Messages.swift
//  MacCast
//
//  Created by Saagar Jha on 10/9/23.
//

public protocol MessageID: RawRepresentable<UInt8>, Equatable {}

public protocol Message<ID> {
	associatedtype ID: MessageID

	static var id: ID { get }
	associatedtype Request: Serializable
	associatedtype Reply: Serializable
}

public extension Message {
	static func send(_ parameters: Request, to peer: Peer<ID>) async throws -> Reply {
		try await .decode(peer.sendWithReply(message: Self.id, data: parameters.encode()))
	}
}
