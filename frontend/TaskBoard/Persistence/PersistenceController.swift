import CoreData

/// Core Data stack with a fully programmatic model — no .xcdatamodeld GUI
/// artifact, so the schema is reviewable in code and identical in tests.
enum PersistenceController {
    static let modelName = "TaskBoard"

    static func makeModel() -> NSManagedObjectModel {
        func attr(_ name: String, _ type: NSAttributeType, optional: Bool = false, defaultValue: Any? = nil) -> NSAttributeDescription {
            let a = NSAttributeDescription()
            a.name = name
            a.attributeType = type
            a.isOptional = optional
            a.defaultValue = defaultValue
            return a
        }

        // The local task cache. Mirrors the server row plus client-side sync
        // bookkeeping. `syncedSnapshot` is the last server-acknowledged state —
        // the base used to detect which fields changed remotely on a 409.
        let task = NSEntityDescription()
        task.name = "CDTask"
        task.managedObjectClassName = "CDTask"
        task.properties = [
            attr("id", .stringAttributeType),
            attr("title", .stringAttributeType, defaultValue: ""),
            attr("details", .stringAttributeType, defaultValue: ""),
            attr("status", .stringAttributeType, defaultValue: "todo"),
            attr("orderKey", .stringAttributeType, defaultValue: "V"),
            attr("version", .integer64AttributeType, defaultValue: 0),
            attr("createdAt", .stringAttributeType, defaultValue: ""),
            attr("updatedAt", .stringAttributeType, defaultValue: ""),
            attr("locallyBorn", .booleanAttributeType, defaultValue: true),
            attr("locallyDeleted", .booleanAttributeType, defaultValue: false),
            attr("syncFlag", .stringAttributeType, optional: true),
            attr("syncedSnapshot", .stringAttributeType, optional: true),
            attr("conflictJSON", .stringAttributeType, optional: true),
        ]
        task.uniquenessConstraints = [["id"]]

        // The offline mutation queue. opId is a monotonic local counter (never
        // wall clock — design §8), assigned from CDSyncMeta.nextOpId.
        let op = NSEntityDescription()
        op.name = "CDPendingOp"
        op.managedObjectClassName = "CDPendingOp"
        op.properties = [
            attr("opId", .integer64AttributeType, defaultValue: 0),
            attr("taskId", .stringAttributeType),
            attr("kind", .stringAttributeType),
            attr("payloadJSON", .stringAttributeType, defaultValue: "{}"),
            attr("mutationId", .stringAttributeType),
            attr("transmitted", .booleanAttributeType, defaultValue: false),
            attr("rebaseCount", .integer16AttributeType, defaultValue: 0),
        ]
        op.uniquenessConstraints = [["opId"]]

        // Singleton: sync cursor + board epoch + the op-id counter.
        let meta = NSEntityDescription()
        meta.name = "CDSyncMeta"
        meta.managedObjectClassName = "CDSyncMeta"
        meta.properties = [
            attr("cursor", .integer64AttributeType, defaultValue: 0),
            attr("boardEpoch", .stringAttributeType, optional: true),
            attr("nextOpId", .integer64AttributeType, defaultValue: 1),
        ]

        let model = NSManagedObjectModel()
        model.entities = [task, op, meta]
        return model
    }

    /// `inMemory` uses SQLite at /dev/null: real SQLite semantics (constraints,
    /// transactions) with nothing persisted — deterministic tests.
    static func makeContainer(inMemory: Bool) -> NSPersistentContainer {
        let container = NSPersistentContainer(name: modelName, managedObjectModel: makeModel())
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TaskBoard", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            container.persistentStoreDescriptions.first!.url = dir.appendingPathComponent("board.sqlite")
        }
        container.loadPersistentStores { _, error in
            if let error {
                fatalError("Failed to load persistent store: \(error)")
            }
        }
        return container
    }
}

@objc(CDTask)
final class CDTask: NSManagedObject {
    @NSManaged var id: String
    @NSManaged var title: String
    @NSManaged var details: String
    @NSManaged var status: String
    @NSManaged var orderKey: String
    @NSManaged var version: Int64
    @NSManaged var createdAt: String
    @NSManaged var updatedAt: String
    @NSManaged var locallyBorn: Bool
    @NSManaged var locallyDeleted: Bool
    @NSManaged var syncFlag: String?
    @NSManaged var syncedSnapshot: String?
    @NSManaged var conflictJSON: String?
}

@objc(CDPendingOp)
final class CDPendingOp: NSManagedObject {
    @NSManaged var opId: Int64
    @NSManaged var taskId: String
    @NSManaged var kind: String
    @NSManaged var payloadJSON: String
    @NSManaged var mutationId: String
    @NSManaged var transmitted: Bool
    @NSManaged var rebaseCount: Int16
}

@objc(CDSyncMeta)
final class CDSyncMeta: NSManagedObject {
    @NSManaged var cursor: Int64
    @NSManaged var boardEpoch: String?
    @NSManaged var nextOpId: Int64
}
