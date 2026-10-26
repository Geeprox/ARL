import Foundation
import Darwin
import Security

// No Codable conformance and no caller-provided approved/authenticated Boolean.
final class AuthenticatedCaller {
    let subject:String
    private let check:()->Bool
    private init(subject:String,check:@escaping()->Bool){self.subject=subject;self.check=check}
    func isCurrent()->Bool{check()}
    static func fromRegisteredSocket(_ fd:Int32,subject:String,expectedPID:Int32,requirement:String,registrationEpoch:UInt64,currentRegistrationEpoch:@escaping()->UInt64?)throws->AuthenticatedCaller {
        guard identifier(subject),expectedPID>0,registrationEpoch>0,!requirement.isEmpty,requirement.utf8.count<=4096 else{throw ReviewFault("caller_unverified")}
        func token()->Data? {
            var raw=[UInt8](repeating:0,count:32);var size:socklen_t=32
            guard getsockopt(fd,0,6,&raw,&size)==0,size==32 else{return nil};return Data(raw)
        }
        guard let original=token() else{throw ReviewFault("caller_unverified")}
        let words=original.withUnsafeBytes{raw in (0..<8).map{raw.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self)}}
        guard words[1]==getuid(),words[5]==UInt32(expectedPID) else{throw ReviewFault("caller_unverified")}
        func valid()->Bool {
            guard currentRegistrationEpoch()==registrationEpoch,token()==original else{return false}
            var rule:SecRequirement?;var guest:SecCode?
            guard SecRequirementCreateWithString(requirement as CFString,[],&rule)==errSecSuccess,let rule,
                  SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributeAudit as String:original] as CFDictionary,[],&guest)==errSecSuccess,let guest else{return false}
            return SecCodeCheckValidity(guest,SecCSFlags(rawValue:kSecCSStrictValidate),rule)==errSecSuccess && currentRegistrationEpoch()==registrationEpoch && token()==original
        }
        guard valid() else{throw ReviewFault("caller_unverified")}
        return AuthenticatedCaller(subject:subject,check:valid)
    }
    #if APPLE_REVIEW_FIXTURE
    static func fixture(_ subject:String,check:@escaping()->Bool={true})->AuthenticatedCaller{AuthenticatedCaller(subject:subject,check:check)}
    #endif
}
