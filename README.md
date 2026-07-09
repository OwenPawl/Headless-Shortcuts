# Headless Shortcuts

Headless Shortcuts imports an unsigned Shortcuts workflow plist into
`~/Library/Shortcuts/Shortcuts.sqlite` without using the Shortcuts UI.

It takes two inputs:

- a workflow plist
- a shortcut name

On success it prints the created workflow ID.

## Build

```sh
make
```

The binary is written to `build/headless-shortcuts`.

## Usage

Import into the live Shortcuts database:

```sh
build/headless-shortcuts import ~/Downloads/MyWorkflow.plist --name "My Workflow"
```

On success, the CLI prints the created workflowID. Use `--json` for structured
output.

You can also point it at a copied database:

```sh
build/headless-shortcuts import ~/Downloads/MyWorkflow.plist \
  --name "Copied DB Test" \
  --database /tmp/Shortcuts.sqlite
```

## Safety

For the default live database, the CLI creates a timestamped SQLite backup and
asks Shortcuts.app to quit before importing. Explicit `--database` paths are
treated as caller-managed test databases, so backup and quit are not automatic.

Signed `AEA1` `.shortcut` envelopes are not accepted; pass an unsigned workflow
plist.

## Notes

This uses Apple's private WorkflowKit/Core Data classes and is research tooling.
The current boundary is deliberately small: plist plus name in, workflow ID out.
