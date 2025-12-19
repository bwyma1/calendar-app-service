import RAW
import Foundation
import nostr_kit_swift
import bedrock

@RAW_staticbuff(concat:bedrock.Date.Seconds.self)
public struct DateUTC:Sendable, Equatable, Comparable, CustomDebugStringConvertible, Hashable {
	/// represents the time in seconds since the Unix epoch (January 1, 1970)
	private let seconds:bedrock.Date.Seconds
	public init() {
		seconds = bedrock.Date.Seconds(localTime:false)
	}
	private init(seconds unixTime:bedrock.Date.Seconds) {
		seconds = unixTime
	}
	public init(date: Foundation.Date) {
		self.seconds = bedrock.Date.Seconds(
			RAW_native: UInt64(date.timeIntervalSince1970)
		)
	}
	public func toDate() -> Foundation.Date {
		Date(timeIntervalSince1970: TimeInterval(seconds.timeIntervalSinceUnixDate()))
	}
	public var debugDescription:String {
		return "\(seconds.timeIntervalSinceUnixDate())"
	}
	public static func + (_ lhs:DateUTC, _ rhs:UInt64) -> DateUTC {
		return Self(seconds:lhs.seconds + rhs)
	}
	public static func - (_ lhs:DateUTC, _ rhs:UInt64) -> DateUTC {
		return Self(seconds:lhs.seconds - rhs)
	}
}

@RAW_convertible_string_type<UTF8>(backing:RAW_byte.self)
public struct EncodedString:Sendable, Equatable, Hashable, Comparable, ExpressibleByStringLiteral, CustomDebugStringConvertible {
	public var debugDescription:String {
		return String(self)
	}
}

public struct CalendarEventContent:NOSTR_event_content, Sendable, Hashable, RAW_convertible {
	public var title: EncodedString
	public var start: DateUTC
	public var end: DateUTC
	
	public init(title:String, start:Foundation.Date, end:Foundation.Date) {
		self.title = EncodedString(stringLiteral: title)
		self.start = DateUTC(date: start)
		self.end = DateUTC(date: end)
	}

	public init?(RAW_decode inputPtr:consuming UnsafeRawPointer, count: RAW.size_t) {
		start = DateUTC(RAW_staticbuff_seeking: &inputPtr)
		end = DateUTC(RAW_staticbuff_seeking: &inputPtr)
		let titleCount = Int(count - MemoryLayout<DateUTC>.size * 2)
		let title = EncodedString(RAW_decode: inputPtr, count: titleCount)
		self.title = title
	}

	public func RAW_encode(count: inout RAW.size_t) {
		title.RAW_encode(count: &count)
		count += MemoryLayout<DateUTC>.size * 2
	}

	public func RAW_encode(dest: UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8> {
		var dest = start.RAW_encode(dest: dest)
		dest = end.RAW_encode(dest: dest)
		dest = title.RAW_encode(dest: dest)
		return dest
	}
}
