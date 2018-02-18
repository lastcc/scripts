import Foundation
import CoreData
import CloudKit
import Bluebird

public protocol KirinoCloudTokenKey: class {
    var kirinoTokenKey: String { get }
    var previousServerChangeToken: CKServerChangeToken? { get set }
}

extension KirinoCloudTokenKey {
    private var finalKey: String {
        let finalKey = "\(KirinoConfiguration.KirinoKeys.kirinoCloudKitStoredServerChangeTokenKey.rawValue).\(kirinoTokenKey)"
        return finalKey
    }
    public var previousServerChangeToken: CKServerChangeToken? {
        get {
            if let data = KirinoConfiguration.shared.sharedUserDefaults.data(forKey: finalKey) {
                return NSKeyedUnarchiver.unarchiveObject(with: data) as? CKServerChangeToken
            }
            return nil
        }
        set {
            if let token = newValue {
                let data = NSKeyedArchiver.archivedData(withRootObject: token)
                KirinoConfiguration.shared.sharedUserDefaults.set(data, forKey: finalKey)
            }
        }
    }
}

extension CKDatabase: KirinoCloudTokenKey {
    public var kirinoTokenKey: String {
        switch databaseScope {
        case .private:
            return "private"
        case .public:
            return "public"
        case .shared:
            return "shared"
        }
    }
}

extension CKRecordZoneID: KirinoCloudTokenKey {
    public var kirinoTokenKey: String {
        return zoneName
    }
}

extension CKRecordZone: KirinoCloudTokenKey {
    public var kirinoTokenKey: String {
        return zoneID.kirinoTokenKey
    }
}

enum KirinoCloudError: Error {
    // [subscriptionID:DetailedErrorInfo]
    case databaseSubscriptionError([String:CKError])
    case someZoneTokenExpired([CKRecordZoneID])
    case accountNotAvailable
}

public class KirinoConfiguration {
    
    public static let shared: KirinoConfiguration = KirinoConfiguration()
    
    // CloudKit Support
    public let container = CKContainer(identifier: "iCloud.com.kirino.asuna.Kirino")
    public var privateCloudDatabase: CKDatabase {
        return container.privateCloudDatabase
    }
    
    public func addDatabaseSubscriptionPromise(for db: CKDatabase, subscriptionID: String) -> Promise<Void> {
        return Promise<Void> { fulfill, reject in
            addDatabaseSubscription(for: db, subscriptionID: subscriptionID, completion: { (possibleError) in
                if let error = possibleError {
                    reject(error)
                } else {
                    fulfill(())
                }
            })
        }
    }
    
    public func addDatabaseSubscription(for db: CKDatabase, subscriptionID: String, completion: @escaping (Error?) -> Void) {
        // check if subsciption is locally cached, for current user record.
        // now none action taken.
        // if ... { return }
        let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
        subscription.notificationInfo = {
            let info = CKNotificationInfo()
            info.shouldSendContentAvailable = true
            return info
        }()
        
        let op = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: nil)
        
        op.modifySubscriptionsCompletionBlock = { saved, deleted, possibleError in
            /*  This block reports an error of type partialFailure when it saves or delete only some of the subscriptions successfully. The userInfo dictionary of the error contains a CKPartialErrorsByItemIDKey key whose value is an NSDictionary object. The keys of that dictionary are the IDs of the subscriptions that were not saved or deleted, and the corresponding values are error objects containing information about what happened.
                Referrer: https://developer.apple.com/documentation/cloudkit/ckmodifysubscriptionsoperation/1515288-modifysubscriptionscompletionblo
             */
            
            if let ckError = possibleError as? CKError {
                // get error info dict: [subscriptionID:DetailedErrorInfo]
                // the dict contains not saved or deleted subscriptions.
                if ckError.code == CKError.partialFailure, let infoDict = ckError.userInfo[CKPartialErrorsByItemIDKey] as? [String:CKError] {
                    completion(KirinoCloudError.databaseSubscriptionError(infoDict))
                }
            } else {
                completion(possibleError)
            }
        }
        op.qualityOfService = .utility
        db.add(op)
    }
    
    public func fetchDatabaseChangesPromise(_ db: CKDatabase) -> Promise<[CKRecordZoneID]> {
        return Promise<[CKRecordZoneID]> { fulfill, reject in
            fetchDatabaseChanges(db, completion: { (possibleError, changedRecordZoneIDs) in
                if let error = possibleError {
                    reject(error)
                } else {
                    fulfill(changedRecordZoneIDs)
                }
            })
        }
    }
    
    public func fetchDatabaseChanges(_ db: CKDatabase, completion: @escaping (Error?, [CKRecordZoneID]) -> Void) {
        
        let op = CKFetchDatabaseChangesOperation(previousServerChangeToken: db.previousServerChangeToken)
        
        var changed: [CKRecordZoneID] = []
        op.changeTokenUpdatedBlock = { [weak db] token in
            db?.previousServerChangeToken = token
        }
        op.recordZoneWithIDChangedBlock = { idOfRecordZone in
            changed.append(idOfRecordZone)
        }
        op.recordZoneWithIDWasDeletedBlock = { idOfRecordZone in
            // this does not make sense for current use case
            // nop.
        }
        op.recordZoneWithIDWasPurgedBlock = { idOfRecordZone in
            // this does not make sense for current use case
            // nop.
        }
        op.fetchDatabaseChangesCompletionBlock = {  [weak db] finalToken, moreComing, error in
            if let ckError = error as? CKError, ckError.code == .changeTokenExpired {
                db?.previousServerChangeToken = nil
            } else {
                // I assume that...
                // if there are other kinds of failures, the received token should be the same as we send it out.
                if error != nil && finalToken != db?.previousServerChangeToken {
                    print("a token mismatch") // FIXME: unhandled error
                }
                db?.previousServerChangeToken = finalToken
            }
            completion(error, changed)
        }
    }
    
    public func fetchZoneChangesPromise(changed: [CKRecordZoneID], from db: CKDatabase) -> Promise<([CKRecord], [CKRecordID])> {
        return Promise<([CKRecord], [CKRecordID])> { fulfill, reject in
            fetchZoneChanges(changed: changed, from: db, completion: { (changedRecords, deletedRecordIDs, tokenExpiredRecordZoneIDs, error) in
                
                if tokenExpiredRecordZoneIDs.count > 0 && error != nil {
                    print("multiple error!")
                }
                
                if let error = error {
                    reject(error)
                } else if tokenExpiredRecordZoneIDs.count > 0 {
                    reject(KirinoCloudError.someZoneTokenExpired(tokenExpiredRecordZoneIDs))
                } else {
                    fulfill((changedRecords, deletedRecordIDs))
                }
            })
        }
    }
    
    public func fetchZoneChanges(changed: [CKRecordZoneID], from db: CKDatabase, completion: @escaping (_ changedRecords: [CKRecord], _ deletedRecordIDs: [CKRecordID], _ tokenExpiredRecordZoneIDs: [CKRecordZoneID], _ error: Error?) -> Void) {

        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecordID] = []
        var tokenExpiredRecordZoneIDs: [CKRecordZoneID] = []
        var options: [CKRecordZoneID : CKFetchRecordZoneChangesOptions] = [:]
        
        for idOfRecordZone in changed {
            let option = CKFetchRecordZoneChangesOptions()
            option.previousServerChangeToken = idOfRecordZone.previousServerChangeToken
            options[idOfRecordZone] = option
        }
        
        let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: changed, optionsByRecordZoneID: options)
        
        op.recordZoneChangeTokensUpdatedBlock = { (recordZoneID: CKRecordZoneID, serverChangeToken: CKServerChangeToken?, clientChangeTokenData: Data?) in
            recordZoneID.previousServerChangeToken = serverChangeToken
        }
        
        op.recordChangedBlock = { record in
            changedRecords.append(record)
        }
        
        op.recordWithIDWasDeletedBlock = { recordID, recordType in
            deletedRecordIDs.append(recordID)
        }
        
        op.recordZoneFetchCompletionBlock = { recordZoneID, serverChangeToken, clientChangeTokenData, moreComing, error in
            
            guard let ckError = error as? CKError else {
                recordZoneID.previousServerChangeToken = serverChangeToken
                return
            }
            
            if ckError.code == .changeTokenExpired {
                recordZoneID.previousServerChangeToken = nil
                tokenExpiredRecordZoneIDs.append(recordZoneID)
            } else {
                // FIXME: unhandled error
                print("unhandled error: \(ckError)")
            }
        }
        
        op.fetchRecordZoneChangesCompletionBlock = { error in
            completion(changedRecords, deletedRecordIDs, tokenExpiredRecordZoneIDs, error)
        }
        
        db.add(op)
    }
    
    public func accountStatusPromise() -> Promise<Bool> {
        return Promise<Bool> { fulfill, reject in
            container.accountStatus { (accountStatus, possibleError) in
                if accountStatus == .available {
                    fulfill(true)
                } else {
                    reject(KirinoCloudError.accountNotAvailable)
                }
            }
        }
    }
    
    public func resolveCloudError(error: Error) {
        
    }
    
    public func cloudKitSetup() {
        
        Bluebird.try {
            self.accountStatusPromise()
        }.then { _ in
            self.addDatabaseSubscriptionPromise(for: self.privateCloudDatabase, subscriptionID: "private-changes")
        }.then { _ in
            self.fetchDatabaseChangesPromise(self.privateCloudDatabase).recover({ (error) -> Promise<[CKRecordZoneID]> in
                if let ckError = error as? CKError, ckError.code == CKError.changeTokenExpired {
                    return self.fetchDatabaseChangesPromise(self.privateCloudDatabase)
                } else {
                    throw error
                }
            })
        }.then { changedRecordZoneIDs in
            self.fetchZoneChangesPromise(changed: changedRecordZoneIDs, from: self.privateCloudDatabase)
        }.then { changedRocords, deletedRecordIDs in
            // update UI
        }.catch { error in
            // FIXME: unhandled error
            if let kirinoError = error as? KirinoCloudError {
                switch kirinoError {
                case .accountNotAvailable:
                    print("accountNotAvailable")
                case .databaseSubscriptionError(let infoDict): break
                case .someZoneTokenExpired(let expiredRecordZoneIDs): break
                }
            } else {
                print(error)
            }
        }
    }
    
 }
