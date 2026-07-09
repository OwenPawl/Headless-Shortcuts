# Headless Shortcuts

Headless Shortcuts imports unsigned Shortcuts workflow plists into
`~/Library/Shortcuts/Shortcuts.sqlite` without driving the Shortcuts UI.

It does not hand-write `ZSHORTCUT` rows. The CLI loads Apple's private
WorkflowKit framework, turns the workflow file into a `WFWorkflowRecord`, and
asks WorkflowKit/Core Data to create the saved shortcut row.

## Status

This is local macOS research tooling. It uses private WorkflowKit Objective-C
classes and is expected to track Apple's Shortcuts storage model.

Current supported boundary: unsigned workflow plist + supplied name -> inserted
Shortcut row -> generated workflowID. The importer is focused on preserving
workflow actions and the caller-supplied name well enough for Shortcuts to load
and run the created shortcut.

Current save path:

```text
WFWorkflowFile initWithFileData:name:error:
  -> WFWorkflowFile recordRepresentationWithError:
  -> WFWorkflow initWithRecord:reference:storageProvider:error:
  -> WFWorkflow.databaseAccessQueue dispatch_barrier_sync
  -> WFWorkflow.saveToRecord
  -> WFWorkflow.record
  -> finalize actionCount from record.actions
  -> WFDatabaseProxy createWorkflowWithWorkflowRecord:nameCollisionBehavior:error:
```

See `docs/save-path.md` for the storage rationale and copied-database proof.

## Known Limitations

This is not yet a full native-import clone for every record metadata field.
Runtime traces showed that `saveToRecord` can recompute fields such as output
classes, and richer parity for input fallback, output classes, triggers, and
related record metadata remains research territory. Those fields are not part
of the current acceptance target unless they prevent a basic action/name import
from producing a valid, usable shortcut.

## Build

```sh
make
```

The binary is written to `build/headless-shortcuts`.

## Import

Import into the live Shortcuts database:

```sh
build/headless-shortcuts import ~/Downloads/MyWorkflow.plist --name "My Workflow"
```

On success, the CLI prints the created workflowID. Use `--json` for structured
output.

Validate against a copied database first:

```sh
scripts/smoke-import-copy.sh
```

Or provide a database copy manually:

```sh
build/headless-shortcuts import fixtures/notification.workflow.plist \
  --name "Copied DB Test" \
  --database /tmp/Shortcuts.sqlite
```

## Safety

For the default live database, the CLI creates a timestamped SQLite backup and
asks Shortcuts.app to quit before importing. Explicit `--database` paths are
treated as caller-managed test databases, so backup and quit are not automatic.

Signed `AEA1` `.shortcut` envelopes are not accepted; pass an unsigned workflow
plist.
