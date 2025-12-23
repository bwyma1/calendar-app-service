import Logging
import Foundation
import RAW
import bedrock
import RAW_base64
import QuickLMDB
import nostr_kit_swift

extension NOSTR_id:@retroactive MDB_comparable {
	public static var MDB_compare_f: MDB_compare_ftype {
		return { lhs, rhs in
		   guard let lhs = lhs, let rhs = rhs else {
			   return 0
		   }
		   let lsize = lhs.pointee.mv_size
		   let rsize = rhs.pointee.mv_size

		   let lptr = lhs.pointee.mv_data!
		   let rptr = rhs.pointee.mv_data!

		   let minSize = min(lsize, rsize)

		   let cmp = memcmp(lptr, rptr, minSize)
		   if cmp != 0 {
			   return Int32(cmp)
		   }
		   if lsize < rsize { return -1 }
		   if lsize > rsize { return 1 }
		   return 0
	   }
	}
}
extension NOSTR_id {
	public var debugDescription:String {
		return "\(String(RAW_base64.encode(self)))"
	}
}

@inline(__always)
public func eventMatchesFilters(_ event: NOSTR_event_signed<UnsignedEvent<CalendarEventContent>>, filters: [Filter], logLevel: Logger.Level) -> Bool {
	var logger = Logger(label: "filter")
	logger.logLevel = logLevel
	guard !filters.isEmpty else {
		return true
	}
	guard event.unsignedEvent.kind.RAW_native() != 5 else {
		return true
	}
	for filter in filters {
		// make sure each filter tag is in the event tags
		var hasTags: Bool = true
		for tag in filter.tags {
			guard event.unsignedEvent.tags.contains(where: { eventTag in
				tag.isEqual(to: eventTag)
			}) else {
				hasTags = false
				continue
			}
		}
		if((filter.ids == [] || filter.ids.contains(event.unsignedEvent.id)) &&
		   (filter.authors == [] || filter.authors.contains(event.unsignedEvent.publicKey)) &&
		   (filter.kinds == [] || filter.kinds.contains(event.unsignedEvent.kind)) &&
		   (filter.since == nil || filter.since! <= event.unsignedEvent.date) &&
		   (filter.until == nil || filter.until! >= event.unsignedEvent.date) &&
		   hasTags) {
			logger.trace("Found event that matches at least one filter", metadata: ["event_id": "\(String(describing: event.unsignedEvent.id))"])
			return true
		}
		logger.trace("Event doesn't match filter, moving to next filter...")
	}
	logger.trace("Event doesn't match any filter", metadata: ["event_id": "\(String(describing: event.unsignedEvent.id))"])
	return false
}

/// A database for storing `NOSTR_signed_events`.
public struct EventDB:Sendable {
	fileprivate let env:Environment
	fileprivate let events:Database.Strict<NOSTR_id, NOSTR_event_signed<UnsignedEvent<CalendarEventContent>>>
	fileprivate let log:Logger
	
	public static func deleteDatabase(base:Path, logLevel:Logger.Level) throws {
		let finalMdbPath = base.appendingPathComponent("events.mdb")
		let finalLockPath = base.appendingPathComponent("events.mdb-lock")
		var makeLogger = Logger(label:"\(String(describing:Self.self))")
		makeLogger.logLevel = logLevel
		do {
			makeLogger.debug("deleting nostr events database", metadata:["path":"\(finalMdbPath.path())"])
			try FileManager.default.removeItem(atPath:finalMdbPath.path())
			makeLogger.info("successfully deleted nostr events database")
		} catch {
			makeLogger.error("Error: \(finalMdbPath.path()) couldn’t be removed or doesn't exist.")
		}
		do {
			makeLogger.debug("deleting nostr events database lock", metadata:["path":"\(finalLockPath.path())"])
			try FileManager.default.removeItem(atPath:finalLockPath.path())
			makeLogger.info("successfully deleted nostr events database lock")
		} catch {
			makeLogger.error("Error: \(finalLockPath.path()) couldn’t be removed or doesn't exist.")
		}
		
	}

	public init(base:Path, logLevel:Logger.Level) throws {
		let finalPath = base.appendingPathComponent("events.mdb")
		let memoryMapSize = size_t(finalPath.getFileSize() + 512 * 1024 * 1024 * 1024)
		var log = Logger(label:"\(String(describing:Self.self))")
		log.logLevel = logLevel
		self.log = log
		log.debug("initializing events database", metadata:["path":"\(finalPath.path())", "memoryMapSize":"\(memoryMapSize)b"])
		env = try Environment(path:finalPath.path(), flags:[.noSubDir], mapSize:memoryMapSize, maxReaders:8, maxDBs:1, mode:[.ownerReadWriteExecute, .groupReadExecute, .otherReadExecute])
		log.trace("created environment. now creating initial transaction", metadata:["path":"\(finalPath.path())", "memoryMapSize":"\(memoryMapSize)b"])
		let newTrans = try Transaction(env:env, readOnly:false)
		log.trace("created initial transaction. now creating main database", metadata:["path":"\(finalPath.path())", "memoryMapSize":"\(memoryMapSize)b"])
		events = try Database.Strict<NOSTR_id, NOSTR_event_signed<UnsignedEvent<CalendarEventContent>>>(env:env, name:nil, flags:[.create], tx:newTrans)
		log.trace("created main database. now committing transaction", metadata:["path":"\(finalPath.path())", "memoryMapSize":"\(memoryMapSize)b"])
		try newTrans.commit()
	}
	
	public func clearDatabase() throws {
		let newTrans = try Transaction(env: env, readOnly: false)
		try events.deleteAllEntries(tx: newTrans)
		try newTrans.commit()
		log.info("successfully deleted events database")
	}

	/// Scribes a new (already Signature Confirmed!!!) event into the events database.
	public func scribeNewEvent(signedEvent:NOSTR_event_signed<UnsignedEvent<CalendarEventContent>>, logLevel:Logger.Level) throws {
		var logger = log
		logger.logLevel = logLevel
		logger[metadataKey:"event_id"] = "\(String(describing: signedEvent.unsignedEvent.id))"

		logger.trace("opening transaction to write data to events database")
		let newTrans = try Transaction(env:env, readOnly:false)
		try events.cursor(tx:newTrans) { cursor in
			do {
				guard try cursor.containsEntry(key:signedEvent.unsignedEvent.id) == false else {
					logger.info("Attempted to write an event that already exists")
					throw LMDBError.keyExists
				}
			} catch LMDBError.notFound {}
			logger.trace("event id validated as new. writing to db.")
			try cursor.setEntry(key:signedEvent.unsignedEvent.id, value:signedEvent, flags:[])
		}
		try newTrans.commit()
		logger.debug("successfully wrote event to database")
	}

	/// Filters out all events from the database that match the given filters.
	/// Follows the NOSTR protocol where the filters use an OR function and each filter's fields use an AND function.
	/// Thus, a signed event only needs to match all of the constraints of a single filter to be returned.
	public func filterEvents(filter:[Filter]) throws -> [NOSTR_event_signed<UnsignedEvent<CalendarEventContent>>] {
		var filteredEvents:[NOSTR_event_signed<UnsignedEvent<CalendarEventContent>>] = []
		// Filters are OR'd and filter fields are AND'ed
		let newTrans = try Transaction(env:env, readOnly:true)
		do {
			try events.cursor(tx:newTrans) { cursor in
				let (_, val) = try cursor.opFirst()
				if eventMatchesFilters(val, filters: filter, logLevel: log.logLevel) {
					filteredEvents.append(val)
				}
				while let (_, val) = try? cursor.opNext() {
					if eventMatchesFilters(val, filters: filter, logLevel: log.logLevel) {
						filteredEvents.append(val)
					}
				}
			}
		} catch { }
		log.debug("Found \(filteredEvents.count) events that match the given filters")
		return filteredEvents
	}
}
