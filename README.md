# Headless Shortcuts

A macOS CLI for creating, editing, and deleting shortcuts directly in
`~/Library/Shortcuts/Shortcuts.sqlite`.

## Build

```sh
make
```

The binary is written to `build/headless-shortcuts`.

## Commands

```sh
# Create
build/headless-shortcuts create --plist workflow.plist --name "My Shortcut"

# Replace actions and preserve the existing name
build/headless-shortcuts edit --id UUID --plist workflow.plist

# Delete
build/headless-shortcuts delete --id UUID
```

Every command writes one compact JSON object to stdout:

```json
{"name":"My Shortcut","ok":true,"operation":"create","workflowID":"UUID"}
```

Exit codes are `0` for success, `1` for an operation failure, and `64` for
invalid arguments.

This tool uses Apple's private WorkflowKit APIs. It accepts unsigned workflow
plists, not signed `AEA1` `.shortcut` files. Create and edit currently focus on
workflow actions and names.
