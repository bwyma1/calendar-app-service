import Testing
@testable import calendar_core

@Test func memberEncodeDecode() throws {
	let member = MemberContent(name: "alice", club: "club")
	var memberLen = 0; member.RAW_encode(count: &memberLen)
	let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: memberLen)
	defer { buffer.deallocate() }
	_ = member.RAW_encode(dest:buffer.baseAddress!)
	let decodedMember = MemberContent(RAW_decode: buffer.baseAddress!, count: memberLen)!
	#expect(member.name == decodedMember.name)
	#expect(member.club == decodedMember.club)
	#expect(member.id == decodedMember.id)
}
