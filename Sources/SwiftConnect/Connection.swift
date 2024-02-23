import CryptoKit
import Foundation
import Network

/// Establishing and managing end-to-end connections.
public struct Connection {
	/// Callback function for custom certificate chain validation.
	public typealias ValidationCallback = ([SecCertificate]) -> Bool

	/// Callback function for connection errors.
	public typealias ErrorCallback = ((Self, any Error) -> Void)

	/// Underlying Network.framework connection.
	public let connection: NWConnection

	/// If true, this connection is in server mode.
	public let isListening: Bool

	/// Iterate over this property to read data from the connection.
	public private(set) var data: AsyncThrowingStream<Data, Error>

	/// Optional error handler that is invoked when there is a connection error.
	private let errorHandler: ErrorCallback?

	/// Internal continuation context for `data`.
	private let dataContinuation: AsyncThrowingStream<Data, Error>.Continuation

	/// Certificate chain of the connected peer.
	public var peerCertificateChain: [SecCertificate] {
		guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
			return []
		}
		return metadata.securityProtocolMetadata.peerCertificateChain
	}

	/// Dispatch queue for connection callbacks.
	private let connectionQueue: DispatchQueue

	/// Finds local peers advertising a service over Bonjour with optional metadata.
	/// - Parameter serviceType: Name of the service to look for.
	/// - Returns: Set of browse results (asynchronously).
	public static func browse(forServiceType serviceType: String, connectionQueue: DispatchQueue = .main) -> AsyncThrowingStream<Set<NWBrowser.Result>, Error> {
		AsyncThrowingStream { continuation in
			let parameters = NWParameters()
			parameters.includePeerToPeer = true

			let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: parameters)
			browser.stateUpdateHandler = { state in
				switch state {
					case .ready:
						continuation.yield(browser.browseResults)
					case .failed(let error):
						continuation.finish(throwing: error)
					case .cancelled:
						continuation.finish()
					default:
						break
				}
			}
			browser.browseResultsChangedHandler = { results, changes in
				continuation.yield(results)
			}
			continuation.onTermination = { @Sendable _ in
				browser.cancel()
			}
			browser.start(queue: connectionQueue)
		}
	}
	
	/// Start a new service over Bonjour using TLS with a shared key.
	/// - Parameters:
	///   - port: Optional port to listen on.
	///   - serviceType: Name of the service to advertise.
	///   - name: Optional name of the device.
	///   - txtRecord: Optional TXT records to advertise.
	///   - key: Pre-shared key to establish TLS-PSK.
	/// - Returns: List of connected peers (asynchronously).
	public static func advertise(on port: NWEndpoint.Port = .any, forServiceType serviceType: String, name: String? = nil, txtRecord: NWTXTRecord? = nil, connectionQueue: DispatchQueue = .main, key: Data) -> AsyncThrowingStream<NWConnection, Error> {
		advertise(on: port, forServiceType: serviceType, name: name, txtRecord: txtRecord, connectionQueue: connectionQueue) {
			NWParameters(authenticatingWithKey: key)
		}
	}

	/// Start a new service over Bonjour using TLS with a server identity.
	/// - Parameters:
	///   - port: Optional port to listen on.
	///   - serviceType: Name of the service to advertise.
	///   - name: Optional name of the device.
	///   - txtRecord: Optional TXT records to advertise.
	///   - connectionQueue: Dispatch queue for connection callbacks.
	///   - identity: Contains the certificate and private key of the server.
	///   - validation: Optional validation callback on connecting clients.
	/// - Returns: List of connected peers (asynchronously).
	public static func advertise(on port: NWEndpoint.Port = .any, forServiceType serviceType: String, name: String? = nil, txtRecord: NWTXTRecord? = nil, connectionQueue: DispatchQueue = .main, identity: SecIdentity, validation: @escaping ValidationCallback = { _ in true }) -> AsyncThrowingStream<NWConnection, Error> {
		advertise(on: port, forServiceType: serviceType, name: name, txtRecord: txtRecord, connectionQueue: connectionQueue) {
			NWParameters(authenticatingWithIdentity: identity, isServer: true, validationQueue: connectionQueue, validation: validation)
		}
	}

	private static func advertise(on port: NWEndpoint.Port, forServiceType serviceType: String, name: String?, txtRecord: NWTXTRecord?, connectionQueue: DispatchQueue, parameters: () -> NWParameters) -> AsyncThrowingStream<NWConnection, Error> {
		AsyncThrowingStream { continuation in
			let listener: NWListener
			do {
				listener = try NWListener(using: parameters(), on: port)
			} catch {
				continuation.finish(throwing: error)
				return
			}
			listener.service = .init(name: name, type: serviceType, txtRecord: txtRecord ?? NWTXTRecord())
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
			listener.start(queue: connectionQueue)
		}
	}

	/// Open a new connection to an existing service using TLS with a shared key.
	/// - Parameters:
	///   - endpoint: Service to connect to.
	///   - connectionQueue: Dispatch queue for connection callbacks.
	///   - key: Pre-shared key to establish TLS-PSK.
	///   - errorHandler: Optional error handler that is invoked when there is a connection error.
	public init(endpoint: NWEndpoint, connectionQueue: DispatchQueue = .main, key: Data, errorHandler: ErrorCallback? = nil) async throws {
		try await self.init(endpoint: endpoint, connectionQueue: connectionQueue, errorHandler: errorHandler) {
			NWParameters(authenticatingWithKey: key)
		}
	}

	/// Open a new connection to an existing service using TLS with a client identity.
	/// - Parameters:
	///   - endpoint: Service to connect to.
	///   - connectionQueue: Dispatch queue for connection callbacks.
	///   - identity: Contains the certificate and private key of the client.
	///   - errorHandler: Optional error handler that is invoked when there is a connection error.
	///   - validation: Optional validation callback on the server identity.
	public init(endpoint: NWEndpoint, connectionQueue: DispatchQueue = .main, identity: SecIdentity, errorHandler: ErrorCallback? = nil, validation: @escaping ValidationCallback = { _ in true }) async throws {
		try await self.init(endpoint: endpoint, connectionQueue: connectionQueue, errorHandler: errorHandler) {
			NWParameters(authenticatingWithIdentity: identity, isServer: false, validationQueue: connectionQueue, validation: validation)
		}
	}

	private init(endpoint: NWEndpoint, connectionQueue: DispatchQueue, errorHandler: ErrorCallback?, parameters: () -> NWParameters) async throws {
		self.connectionQueue = connectionQueue
		self.connection = NWConnection(to: endpoint, using: parameters())
		self.errorHandler = errorHandler
		isListening = false
		(data, dataContinuation) = AsyncThrowingStream.makeStream()
		try await connect()
	}

	/// Accept a new connecting client.
	/// - Parameter connection: Connection from a client.
	/// - Parameter connectionQueue: Dispatch queue for connection callbacks.
	/// - Parameter errorHandler: Optional error handler that is invoked when there is a connection error.
	public init(connection: NWConnection, connectionQueue: DispatchQueue = .main, errorHandler: ErrorCallback? = nil) async throws {
		self.connectionQueue = connectionQueue
		self.connection = connection
		self.errorHandler = errorHandler
		isListening = true
		(data, dataContinuation) = AsyncThrowingStream.makeStream()
		try await connect()
	}

	private func connect() async throws {
		try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				connection.stateUpdateHandler = { [weak connection] state in
					switch state {
						case .ready:
							connection?.stateUpdateHandler = { state in
								switch state {
									case .failed(let error):
										dataContinuation.finish(throwing: error)
										errorHandler?(self, error)
									case .cancelled:
										dataContinuation.finish()
									default:
										break
								}
							}
							continuation.resume()

						case .failed(let error):
							connection?.stateUpdateHandler = nil
							continuation.resume(throwing: error)
						case .cancelled:
							connection?.stateUpdateHandler = nil
							continuation.resume(throwing: CancellationError())
						default:
							break
					}
				}
				connection.start(queue: connectionQueue)
			}
		} onCancel: {
			connection.cancel()
		}
		Self.recieveNextMessage(connection: connection, continuation: dataContinuation)
	}

	/// Send data to connected peer.
	/// - Parameter data: Data to send.
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

	/// Close and invalidate this connection.
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

	convenience init(authenticatingWithIdentity identity: SecIdentity, isServer: Bool, validationQueue: DispatchQueue, validation: @escaping Connection.ValidationCallback) {
		let tlsOptions = NWProtocolTLS.Options()
		sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
		if isServer {
			sec_protocol_options_set_peer_authentication_required(tlsOptions.securityProtocolOptions, true)
			sec_protocol_options_set_challenge_block(tlsOptions.securityProtocolOptions, { _, completion in
				completion(sec_identity_create(identity)!)
			}, validationQueue)
		} else {
			sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, sec_identity_create(identity)!)
		}
		sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { metadata, _, completion in
			completion(validation(metadata.peerCertificateChain))
		}, validationQueue)

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
