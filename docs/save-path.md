# Save Path

Headless Shortcuts intentionally avoids constructing `ZSHORTCUT` rows by hand.
The importer uses WorkflowKit's own record and Core Data creation path:

```text
WFWorkflowFile initWithFileData:name:error:
  -> WFWorkflowFile recordRepresentationWithError:
  -> WFWorkflow initWithRecord:reference:storageProvider:error:
  -> WFWorkflow.databaseAccessQueue dispatch_barrier_sync
  -> WFWorkflow.saveToRecord
  -> WFWorkflow.record
  -> set WFWorkflowRecord.actionCount from record.actions.count
  -> WFDatabase initWithPersistenceMode:fileURL:error:
  -> WFDatabaseProxy initWithDatabase:
  -> WFDatabaseProxy createWorkflowWithWorkflowRecord:nameCollisionBehavior:error:
  -> WFDatabaseProxy referenceForWorkflowID:
  -> WFDatabaseProxy sortedVisibleWorkflowsByNameWithError:
  -> read-only ZACTIONCOUNT verification
```

The `saveToRecord` step is required for the current action/name import boundary.
A copied-database probe that skipped it still created Core Data rows, but left
fields such as `ZACTIONCOUNT` and `ZWORKFLOWSUBTITLE` at their default values.
Calling `saveToRecord` on `databaseAccessQueue` materializes the action list and
subtitle before `WFDatabaseProxy` saves the record.

Runtime tracing also showed that `saveToRecord` can occasionally leave
`actionCount` stale for a one-action record, even while `record.actions` contains
the action and `workflowSubtitle` says `1 action`. The CLI therefore finalizes
`WFWorkflowRecord.actionCount` from `record.actions.count` before calling
`createWorkflowWithWorkflowRecord:nameCollisionBehavior:error:` and verifies the
persisted SQLite row before returning the workflowID.

The post-create refresh and read-only verification are also intentional. In
copied-database testing, a trigger workflow could briefly persist with
`ZACTIONCOUNT=0` even though the saved record had `1 action`; a subsequent
WorkflowKit database open settled the row to `ZACTIONCOUNT=1`. The CLI performs
that native refresh itself and only returns after read-only SQLite verification
observes the expected action count.

## Scope Notes

The traced create path proved that `WFDatabaseProxy` delegates to
`WFDatabase createWorkflowWithOptions:nameCollisionBehavior:error:` with a
`WFWorkflowCreationOptions` object wrapping the record. That is the storage
abstraction this tool uses.

The current acceptance target is not full byte-for-byte or field-for-field
native metadata preservation. Tracing native-exported workflows showed that
`saveToRecord` can recompute output classes, for example collapsing a richer
output class set to `WFContentItem`. Input classes, no-input/fallback behavior,
output classes, triggers, and related metadata should be treated as known
limitations unless they block the basic guarantee: unsigned workflow plist plus
name imports into SQLite as a valid shortcut and returns a workflowID.
