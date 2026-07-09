# Headless Shortcuts

Headless Shortcuts creates, edits, and deletes shortcuts in
`~/Library/Shortcuts/Shortcuts.sqlite` without using the Shortcuts UI.

## Build

```sh
make
```

The binary is written to `build/headless-shortcuts`.

## Usage

Create a shortcut from an unsigned workflow plist:

```sh
build/headless-shortcuts create --plist ~/Downloads/MyWorkflow.plist --name "My Workflow"
```

Replace the actions of an existing shortcut while preserving its name:

```sh
build/headless-shortcuts edit --id UUID --plist ~/Downloads/MyWorkflow.plist
```

Delete an existing shortcut using WorkflowKit's sync-aware deletion path:

```sh
build/headless-shortcuts delete --id UUID
```

Each command prints the affected workflow ID on success.

Signed `AEA1` `.shortcut` envelopes are not accepted; pass an unsigned workflow
plist.

## Notes

This uses Apple's private WorkflowKit/Core Data classes and is research tooling.
Create and edit currently focus on workflow actions and the supplied or existing
name; richer workflow metadata is not guaranteed to round-trip unchanged.
