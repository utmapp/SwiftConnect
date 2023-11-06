//
//  SerializableConformances.swift
//  MacCast
//
//  Created by Saagar Jha on 10/10/23.
//

import Foundation

/// Represents a `Void` type.
public struct SerializableVoid: Serializable {
	public func encode() -> Data {
		Data()
	}

	public static func decode(_ data: Data) -> Self {
		assert(data.isEmpty)
		return .init()
	}
}

public extension Serializable where Self: Codable {
	func encode() throws -> Data {
		try Encoder().encode(self)
	}

	static func decode(_ data: Data) throws -> Self {
		try Decoder().decode(Self.self, from: data)
	}
}

extension Optional: Serializable where Wrapped: Serializable {
	public func encode() async throws -> Data {
		if let self {
			return try await Data([1]) + self.encode()
		} else {
			return Data([0])
		}
	}

	public static func decode(_ data: Data) async throws -> Self {
		let discriminator = data.first!
		let rest = data.dropFirst()
		switch discriminator {
			case 0:
				return nil
			case 1:
				return try await Wrapped.decode(rest)
			default:
				fatalError()
		}
	}
}

extension Data: Serializable {
	public func encode() -> Data {
		self
	}

	public static func decode(_ data: Data) -> Self {
		data
	}
}
