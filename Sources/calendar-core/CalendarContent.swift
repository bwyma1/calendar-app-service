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
	public var members: [EncodedString]
	public var start: DateUTC
	public var end: DateUTC
	
	public init(title:String, members:[String], start:Foundation.Date, end:Foundation.Date) {
		self.title = EncodedString(stringLiteral: title)
		self.members = members.map { EncodedString(stringLiteral: $0) }
		self.start = DateUTC(date: start)
		self.end = DateUTC(date: end)
	}

	public init?(RAW_decode inputPtr:consuming UnsafeRawPointer, count: RAW.size_t) {
		guard count >= MemoryLayout<DateUTC>.size * 2 else { return nil }
		start = DateUTC(RAW_staticbuff_seeking: &inputPtr)
		end = DateUTC(RAW_staticbuff_seeking: &inputPtr)
		var dataCount = count - MemoryLayout<DateUTC>.size * 2
		
		guard dataCount >= MemoryLayout<Bytes1>.size else { return nil }
		let memberCount = Bytes1(RAW_staticbuff_seeking: &inputPtr).RAW_native()
		dataCount -= MemoryLayout<Bytes1>.size
		
		var members: [EncodedString] = []
		for _ in 0..<Int(memberCount) {
			// Read length of next tag value
			guard dataCount >= MemoryLayout<Bytes2>.size else { return nil }
			dataCount -= MemoryLayout<Bytes2>.size
			let length = Int(Bytes2(RAW_staticbuff_seeking: &inputPtr).RAW_native())
			// Read the tag value
			guard dataCount >= length else { return nil }
			dataCount -= length
			let member = EncodedString(RAW_decode: inputPtr, count: length)
			inputPtr = inputPtr.advanced(by: length)
			members.append(member)
		}
		self.members = members
		
		guard dataCount >= MemoryLayout<Bytes2>.size else { return nil }
		let titleLength = Int(Bytes2(RAW_staticbuff_seeking: &inputPtr).RAW_native())
		dataCount -= MemoryLayout<Bytes2>.size
		guard dataCount == titleLength else { return nil }
		let title = EncodedString(RAW_decode: inputPtr, count: titleLength)
		self.title = title
	}

	public func RAW_encode(count: inout RAW.size_t) {
		count += MemoryLayout<Bytes1>.size + MemoryLayout<Bytes2>.size * (members.count + 1)
		for member in members {
			member.RAW_encode(count: &count)
		}
		title.RAW_encode(count: &count)
		count += MemoryLayout<DateUTC>.size * 2
	}

	public func RAW_encode(dest: UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8> {
		var dest = start.RAW_encode(dest: dest)
		dest = end.RAW_encode(dest: dest)
		
		let memberCount = Bytes1(RAW_native: UInt8(members.count))
		dest = memberCount.RAW_encode(dest: dest)
		for member in members {
			// Encode the length of the tag value
			var memberLength = 0; member.RAW_encode(count: &memberLength)
			let memberLengthBytes = Bytes2(RAW_native: UInt16(memberLength))
			dest = memberLengthBytes.RAW_encode(dest: dest)
			
			// Encode the tag value itself
			dest = member.RAW_encode(dest: dest)
		}
		
		var titleLength = 0; title.RAW_encode(count: &titleLength)
		let titleLengthBytes = Bytes2(RAW_native: UInt16(titleLength))
		dest = titleLengthBytes.RAW_encode(dest: dest)
		
		dest = title.RAW_encode(dest: dest)
		return dest
	}
}
