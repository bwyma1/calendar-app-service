import RAW
import nostr_kit_swift

@RAW_staticbuff(bytes:8)
public struct MemberID:Sendable, Equatable, Hashable, RAW_convertible { }

public struct MemberContent:NOSTR_event_content, Sendable, Hashable, RAW_convertible {
	public let id:MemberID
	public var name:EncodedString
	public var club:EncodedString
	
	public init(name:String, club:String) {
		self.name = EncodedString(stringLiteral: name)
		self.club = EncodedString(stringLiteral: club)
		self.id = try! generateSecureRandomBytes(as: MemberID.self)
	}

	public init?(RAW_decode inputPtr:consuming UnsafeRawPointer, count: RAW.size_t) {
		guard count >= MemoryLayout<MemberID>.size else { return nil }
		self.id = MemberID(RAW_staticbuff_seeking: &inputPtr)
		var dataCount = count - MemoryLayout<MemberID>.size
		
		guard dataCount >= MemoryLayout<Bytes2>.size else { return nil }
		let nameLength = Int(Bytes2(RAW_staticbuff_seeking: &inputPtr).RAW_native())
		dataCount -= MemoryLayout<Bytes2>.size
		guard dataCount >= nameLength else { return nil }
		let name = EncodedString(RAW_decode: inputPtr, count: nameLength)
		inputPtr = inputPtr.advanced(by: nameLength)
		dataCount -= nameLength
		self.name = name
		
		guard dataCount >= MemoryLayout<Bytes2>.size else { return nil }
		let clubLength = Int(Bytes2(RAW_staticbuff_seeking: &inputPtr).RAW_native())
		dataCount -= MemoryLayout<Bytes2>.size
		guard dataCount == clubLength else { return nil }
		let club = EncodedString(RAW_decode: inputPtr, count: clubLength)
		self.club = club
	}

	public func RAW_encode(count: inout RAW.size_t) {
		count += MemoryLayout<MemberID>.size + MemoryLayout<Bytes2>.size * 2
		name.RAW_encode(count: &count)
		club.RAW_encode(count: &count)
	}

	public func RAW_encode(dest: UnsafeMutablePointer<UInt8>) -> UnsafeMutablePointer<UInt8> {
		var dest = id.RAW_encode(dest: dest)
		
		var nameLength = 0; name.RAW_encode(count: &nameLength)
		let nameLengthBytes = Bytes2(RAW_native: UInt16(nameLength))
		dest = nameLengthBytes.RAW_encode(dest: dest)
		dest = name.RAW_encode(dest: dest)
		
		var clubLength = 0; club.RAW_encode(count: &clubLength)
		let clubLengthBytes = Bytes2(RAW_native: UInt16(clubLength))
		dest = clubLengthBytes.RAW_encode(dest: dest)
		return club.RAW_encode(dest: dest)
	}
}
