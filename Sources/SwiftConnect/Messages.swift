//
//  Messages.swift
//  MacCast
//
//  Created by Saagar Jha on 10/9/23.
//

/// Unique identifier for each different message.
public protocol MessageID: RawRepresentable<UInt8>, Equatable {}

/// Implement this protocol for every message you wish to handle.
public protocol Message<ID> {
	associatedtype ID: MessageID

	static var id: ID { get }
	associatedtype Request: Serializable
	associatedtype Reply: Serializable
}

public extension Message {
	/// Send a message to a peer.
	/// - Parameters:
	///   - parameters: Parameters to send to the peer.
	///   - peer: Peer who will receive the message.
	/// - Returns: Response from the peer.
	static func send(_ parameters: Request, to peer: Peer<some MessageID>) async throws -> Reply {
		try await .decode(peer.sendWithReply(message: Self.id, data: parameters.encode()))
	}
}
