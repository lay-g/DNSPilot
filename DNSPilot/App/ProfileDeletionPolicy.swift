import Foundation

enum ProfileDeletionPolicy {
    static func isPendingTarget(
        profileID: DNSProfile.ID,
        targetProfileID: DNSProfile.ID?,
        activeProfileID: DNSProfile.ID?
    ) -> Bool {
        targetProfileID == profileID && activeProfileID != profileID
    }
}
