import Foundation
import Logging
import NIO
import ServiceLifecycle
import wireguard_userspace_nio
import nostr_kit_swift
import calendar_core
import bedrock_fifo
import bedrock
import RAW
import RAW_dh25519

final actor NostrRequestsStore {
	private var nostrRequests: [PublicKey: NOSTR_message_REQ] = [:]

	func get(_ key: PublicKey) -> NOSTR_message_REQ? {
		nostrRequests[key]
	}

	func set(_ value: NOSTR_message_REQ, for key: PublicKey) {
		nostrRequests[key] = value
	}

	func remove(_ key: PublicKey) {
		nostrRequests.removeValue(forKey: key)
	}

	func removeAll() {
		nostrRequests.removeAll()
	}

	func all() -> [PublicKey: NOSTR_message_REQ] {
		nostrRequests
	}

	func contains(_ key: PublicKey) -> Bool {
		nostrRequests[key] != nil
	}
}


final class CalendarServerService: Service {
	let databasePath:bedrock.Path
	let configurationPath:Path
	let myPort:Int
	let myPrivateKey:MemoryGuarded<RAW_dh25519.PrivateKey>
	
	init(databasePath:Path, configurationPath:Path, myPort:Int, myPrivateKey:MemoryGuarded<RAW_dh25519.PrivateKey>) {
		self.databasePath = databasePath
		self.configurationPath = configurationPath
		self.myPort = myPort
		self.myPrivateKey = myPrivateKey
	}
	
	func run() async throws {
		let nostrRequests = NostrRequestsStore()
		var tempLogger = Logger(label: "calendar-server-service")
		tempLogger.logLevel = .debug
		let cliLogger = tempLogger
		
		let jsonURL = URL(fileURLWithPath: configurationPath.appendingPathComponent("peer-config.json").path())
		let cfg = try loadConfig(from: jsonURL)
		
		let eventDB = try EventDB(base: databasePath, logLevel: .debug)
		
		try await cancelWhenGracefulShutdown {
			_ = try await withThrowingTaskGroup(body: { foo in
				var peerInfos:[PeerInfo] = []
				for peer in cfg.peers {
					peerInfos.append(PeerInfo(publicKey:peer.publicKey, endpoint: peer.endpoint, internalKeepAlive: peer.internalKeepAlive, inboundData: FIFO<ByteBuffer, Swift.Error>()))
				}
				let myInterface = try WGInterface<KCPChannels>(staticPrivateKey: self.myPrivateKey, mtu:1400, initialConfiguration:peerInfos, logLevel:.info, listeningPort: self.myPort)
				
				foo.addTask {
					try await myInterface.run()
				}
				
				cliLogger.info("WireGuard interface started. Waiting for channel initialization...")
				try await myInterface.waitForChannelInit()
				
				let channel = try await myInterface.getChannel()
				
				// Read in data and do all of the nostr services...
				for peerInfo in peerInfos {
					foo.addTask {
						var buffer = ByteBufferAllocator().buffer(capacity: 1024)
						let iterator = peerInfo.inboundData?.makeAsyncConsumer()
						while !Task.isCancelled {
							if let incomingSignal = try await iterator?.next(whenTaskCancelled: .finish) {
								cliLogger.debug("Received incoming data. Checking for NOSTR messages.")
								var message:NOSTR_message<UnsignedEvent<CalendarEventContent>>?
								var memberMessage:NOSTR_message<UnsignedEvent<MemberContent>>?
								incomingSignal.withUnsafeReadableBytes { ptr in
									// Try calendar EVENT Message
									do {
										guard let event = NOSTR_message_EVENT<UnsignedEvent<CalendarEventContent>>(RAW_decode: ptr.baseAddress!, count: ptr.count) else {
											throw NOSTR_message_error.badDecode
										}
										message = .EVENT(event)
									} catch { }
									// Try member EVENT Message
									do {
										guard let event = NOSTR_message_EVENT<UnsignedEvent<MemberContent>>(RAW_decode: ptr.baseAddress!, count: ptr.count) else {
											throw NOSTR_message_error.badDecode
										}
										memberMessage = .EVENT(event)
									} catch { }
									// Try REQ Message
									do {
										guard let request = NOSTR_message_REQ(RAW_decode: ptr.baseAddress!, count: ptr.count) else {
											throw NOSTR_message_error.badDecode
										}
										message = .REQ(request)
									} catch { }
									// Try CLOSE Message
									do {
										guard let close = NOSTR_message_CLOSE(RAW_decode: ptr.baseAddress!, count: ptr.count) else {
											throw NOSTR_message_error.badDecode
										}
										message = .CLOSE(close)
									} catch { }
									
								}
								switch message {
									case .REQ(let request):
										cliLogger.debug("Processing REQ Message")
										await nostrRequests.set(request, for: peerInfo.publicKey)
										
										var memberEvents:[NOSTR_event_signed<UnsignedEvent<MemberContent>>] = try eventDB.filterMemberEvents(filter: request.filters)
										memberEvents.sort { $0.unsignedEvent.kind.RAW_native() < $1.unsignedEvent.kind.RAW_native() }
										for event in memberEvents {
											var eventLength = 0; event.RAW_encode(count: &eventLength)
											buffer.withUnsafeMutableWritableBytes { ptr in
												guard let base = ptr.baseAddress else { return }
												let ptr = base.assumingMemoryBound(to: UInt8.self)
												_ = event.RAW_encode(dest: ptr)
											}
											buffer.moveWriterIndex(forwardBy: eventLength)
											try WGInterface<KCPChannels>.write(channel: channel, publicKey: peerInfo.publicKey, data: buffer)
											buffer.clear(minimumCapacity: 1024)
										}
										
										var calendarEvents:[NOSTR_event_signed<UnsignedEvent<CalendarEventContent>>] = try eventDB.filterCalendarEvents(filter: request.filters)
										calendarEvents.sort { $0.unsignedEvent.kind.RAW_native() < $1.unsignedEvent.kind.RAW_native() }
										for event in calendarEvents {
											var eventLength = 0; event.RAW_encode(count: &eventLength)
											buffer.withUnsafeMutableWritableBytes { ptr in
												guard let base = ptr.baseAddress else { return }
												let ptr = base.assumingMemoryBound(to: UInt8.self)
												_ = event.RAW_encode(dest: ptr)
											}
											buffer.moveWriterIndex(forwardBy: eventLength)
											try WGInterface<KCPChannels>.write(channel: channel, publicKey: peerInfo.publicKey, data: buffer)
											buffer.clear(minimumCapacity: 1024)
										}
									case .EVENT(let eventMsg):
										cliLogger.debug("Processing EVENT Message")
										let event = eventMsg.event
										guard event.isValidSignature() else {
											break
										}
										try eventDB.scribeNewCalendarEvent(signedEvent: event, logLevel: cliLogger.logLevel)
										// Send event to all active requests that need it
										let requests = await nostrRequests.all()
										for (key, request) in requests {
											if(eventMatchesFilters(event, filters: request.filters, logLevel: cliLogger.logLevel)) {
												var eventLength = 0; event.RAW_encode(count: &eventLength)
												buffer.withUnsafeMutableWritableBytes { ptr in
													guard let base = ptr.baseAddress else { return }
													let ptr = base.assumingMemoryBound(to: UInt8.self)
													_ = event.RAW_encode(dest: ptr)
												}
												buffer.moveWriterIndex(forwardBy: eventLength)
												try WGInterface<KCPChannels>.write(channel: channel, publicKey: key, data: buffer)
												buffer.clear(minimumCapacity: 1024)
											}
										}
									case .CLOSE(_):
										cliLogger.debug("Processing CLOSE Message")
										await nostrRequests.remove(peerInfo.publicKey)
									case nil:
										cliLogger.debug("Incoming data didn't match any NOSTR Message type. Ignoring.")
										break
								}
								switch memberMessage {
									case .EVENT(let eventMsg):
										cliLogger.debug("Processing EVENT Message")
										let event = eventMsg.event
										guard event.isValidSignature() else {
											break
										}
										try eventDB.scribeNewMemberEvent(signedEvent: event, logLevel: cliLogger.logLevel)
										// Send event to all active requests that need it
										let requests = await nostrRequests.all()
										for (key, request) in requests {
											if(eventMatchesFilters(event, filters: request.filters, logLevel: cliLogger.logLevel)) {
												var eventLength = 0; event.RAW_encode(count: &eventLength)
												buffer.withUnsafeMutableWritableBytes { ptr in
													guard let base = ptr.baseAddress else { return }
													let ptr = base.assumingMemoryBound(to: UInt8.self)
													_ = event.RAW_encode(dest: ptr)
												}
												buffer.moveWriterIndex(forwardBy: eventLength)
												try WGInterface<KCPChannels>.write(channel: channel, publicKey: key, data: buffer)
												buffer.clear(minimumCapacity: 1024)
											}
										}
									default:
										break
								}
							}
						}
					}
				}
				
				try await foo.waitForAll()
			})
		}
	}
}
