import CryptoKit
import Foundation
import Network

public struct Connection {
	public typealias ValidationCallback = ([SecCertificate]) -> Bool

	public let connection: NWConnection
	public let listening: Bool
	public let data: AsyncThrowingStream<Data, Error>
	private let dataContinuation: AsyncThrowingStream<Data, Error>.Continuation

	public var peerCertificateChain: [SecCertificate] {
		guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
			return []
		}
		return metadata.securityProtocolMetadata.peerCertificateChain
	}

	public static func endpoints(forServiceType serviceType: String) -> AsyncThrowingStream<[NWEndpoint], Error> {
		AsyncThrowingStream { continuation in
			let parameters = NWParameters()
			parameters.includePeerToPeer = true

			let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
			browser.stateUpdateHandler = { state in
				switch state {
					case .ready:
						continuation.yield(browser.browseResults.map(\.endpoint))
					case .failed(let error):
						continuation.finish(throwing: error)
					case .cancelled:
						continuation.finish()
					default:
						break
				}
			}
			browser.browseResultsChangedHandler = { results, changes in
				continuation.yield(results.map(\.endpoint))
			}
			continuation.onTermination = { @Sendable _ in
				browser.cancel()
			}
			browser.start(queue: .main)
		}
	}

	public static func advertise(forServiceType serviceType: String, name: String? = nil, key: Data) -> AsyncThrowingStream<NWConnection, Error> {
		advertise(forServiceType: serviceType, name: name) {
			NWParameters(authenticatingWithKey: key)
		}
	}

	public static func advertise(forServiceType serviceType: String, name: String? = nil, identity: SecIdentity, validation: @escaping ValidationCallback = { _ in true }) -> AsyncThrowingStream<NWConnection, Error> {
		advertise(forServiceType: serviceType, name: name) {
			NWParameters(authenticatingWithIdentity: identity, isServer: true, validation: validation)
		}
	}

	private static func advertise(forServiceType serviceType: String, name: String?, parameters: () -> NWParameters) -> AsyncThrowingStream<NWConnection, Error> {
		AsyncThrowingStream { continuation in
			let listener: NWListener
			do {
				listener = try NWListener(using: parameters())
			} catch {
				continuation.finish(throwing: error)
				return
			}
			listener.service = .init(name: name, type: serviceType)
			listener.stateUpdateHandler = { state in
				switch state {
					case .failed(let error):
						continuation.finish(throwing: error)
					case .cancelled:
						continuation.finish()
					default:
						break
				}
			}
			listener.newConnectionHandler = { connection in
				continuation.yield(connection)
			}
			continuation.onTermination = { @Sendable _ in
				listener.cancel()
			}
			listener.start(queue: .main)
		}
	}

	public init(endpoint: NWEndpoint, key: Data) async throws {
		try await self.init(endpoint: endpoint) {
			NWParameters(authenticatingWithKey: key)
		}
	}

	public init(endpoint: NWEndpoint, identity: SecIdentity, validation: @escaping ValidationCallback = { _ in true }) async throws {
		try await self.init(endpoint: endpoint) {
			NWParameters(authenticatingWithIdentity: identity, isServer: false, validation: validation)
		}
	}

	private init(endpoint: NWEndpoint, parameters: () -> NWParameters) async throws {
		self.connection = NWConnection(to: endpoint, using: parameters())
		listening = false
		(data, dataContinuation) = AsyncThrowingStream.makeStream()
		try await connect()
	}

	public init(connection: NWConnection) async throws {
		self.connection = connection
		listening = true
		(data, dataContinuation) = AsyncThrowingStream.makeStream()
		try await connect()
	}

	public func connect() async throws {
		try await withCheckedThrowingContinuation { continuation in
			connection.stateUpdateHandler = { [weak connection] state in
				switch state {
					case .ready:
						connection?.stateUpdateHandler = { state in
							switch state {
								case .failed(let error):
									dataContinuation.finish(throwing: error)
								case .cancelled:
									dataContinuation.finish()
								default:
									break
							}
						}
						continuation.resume()

					case .failed(let error):
						continuation.resume(throwing: error)
					default:
						break
				}
			}
			connection.start(queue: .main)
		}
		Self.recieveNextMessage(connection: connection, continuation: dataContinuation)
	}

	public func send(data: Data) async throws {
		return try await withCheckedThrowingContinuation { continuation in
			connection.send(
				content: data,
				completion: .contentProcessed({
					if let error = $0 {
						continuation.resume(throwing: error)
					} else {
						continuation.resume()
					}
				}))
		}
	}

	public func close() {
		connection.cancel()
	}

	private static func recieveNextMessage(connection: NWConnection, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
		connection.receiveMessage { data, _, _, error in
			guard let data = data else {
				if let error = error {
					continuation.finish(throwing: error)
				}
				return
			}
			continuation.yield(data)
			Self.recieveNextMessage(connection: connection, continuation: continuation)
		}
	}
}

extension NWParameters {
	convenience init(authenticatingWithKey key: Data) {
		let tlsOptions = NWProtocolTLS.Options()
		let symmetricKey = SymmetricKey(data: key)
		let code = HMAC<SHA256>.authenticationCode(for: Data("SwiftConnect".utf8), using: symmetricKey).withUnsafeBytes(DispatchData.init)
		sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions, code as dispatch_data_t, Data("WindowProjectionTest".utf8).withUnsafeBytes(DispatchData.init) as dispatch_data_t)
		sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions, tls_ciphersuite_t(rawValue: numericCast(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

		// TLS PSK requires TLSv1.2 on Apple platforms.
		// See https://developer.apple.com/forums/thread/688508.
		sec_protocol_options_set_max_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
		sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)

		self.init(tls: tlsOptions)
		defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: .init(implementation: SwiftConnectProtocol.self)), at: 0)
		includePeerToPeer = true
	}

	convenience init(authenticatingWithIdentity identity: SecIdentity, isServer: Bool, validation: @escaping Connection.ValidationCallback) {
		let tlsOptions = NWProtocolTLS.Options()
		sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
		if isServer {
			sec_protocol_options_set_peer_authentication_required(tlsOptions.securityProtocolOptions, true)
			sec_protocol_options_set_challenge_block(tlsOptions.securityProtocolOptions, { _, completion in
				completion(sec_identity_create(identity)!)
			}, .main)
		} else {
			sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, sec_identity_create(identity)!)
		}
		sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { metadata, _, completion in
			completion(validation(metadata.peerCertificateChain))
		}, .main)

		self.init(tls: tlsOptions)
		defaultProtocolStack.applicationProtocols.insert(NWProtocolFramer.Options(definition: .init(implementation: SwiftConnectProtocol.self)), at: 0)
		includePeerToPeer = true
	}
}

extension sec_protocol_metadata_t {
	var peerCertificateChain: [SecCertificate] {
		var certificates = [SecCertificate]()
		sec_protocol_metadata_access_peer_certificate_chain(self) { certificate in
			certificates.append(sec_certificate_copy_ref(certificate).takeRetainedValue())
		}
		return certificates
	}
}
