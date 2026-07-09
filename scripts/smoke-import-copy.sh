#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN="$ROOT/build/headless-shortcuts"
SOURCE_DB="${1:-$HOME/Library/Shortcuts/Shortcuts.sqlite}"
ACTION_WORKFLOW="${2:-$ROOT/fixtures/notification.workflow.plist}"
TRIGGER_WORKFLOW="${3:-$ROOT/fixtures/app-trigger.workflow.plist}"

if [ ! -x "$BIN" ]; then
  make -C "$ROOT" >/dev/null
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/headless-shortcuts-smoke.XXXXXX")
DB="$TMP_DIR/Shortcuts.sqlite"
sqlite3 "$SOURCE_DB" ".backup '$DB'"

BEFORE=$(sqlite3 "$DB" "select count(*) from ZSHORTCUT;")
STAMP=$(date +%s)
ACTION_NAME="Headless Smoke Action $STAMP"
ACTION_ID=$("$BIN" import "$ACTION_WORKFLOW" --name "$ACTION_NAME" --database "$DB" --no-backup --no-quit)
TRIGGER_NAME="Headless Smoke Trigger $STAMP"
TRIGGER_ID=$("$BIN" import "$TRIGGER_WORKFLOW" --name "$TRIGGER_NAME" --database "$DB" --no-backup --no-quit)
AFTER=$(sqlite3 "$DB" "select count(*) from ZSHORTCUT;")
INTEGRITY=$(sqlite3 "$DB" "pragma integrity_check;")
ACTION_ROW=$(sqlite3 "$DB" "select ZACTIONCOUNT || '|' || ZWORKFLOWSUBTITLE from ZSHORTCUT where ZWORKFLOWID='$ACTION_ID';")
TRIGGER_ROW=$(sqlite3 "$DB" "select ZACTIONCOUNT || '|' || ZWORKFLOWSUBTITLE from ZSHORTCUT where ZWORKFLOWID='$TRIGGER_ID';")
ACTION_SAVED_NAME=$(sqlite3 "$DB" "select ZNAME from ZSHORTCUT where ZWORKFLOWID='$ACTION_ID';")
TRIGGER_SAVED_NAME=$(sqlite3 "$DB" "select ZNAME from ZSHORTCUT where ZWORKFLOWID='$TRIGGER_ID';")
ACTION_DATA_LEN=$(sqlite3 "$DB" "select length(ZDATA) from ZSHORTCUTACTIONS where ZSHORTCUT=(select Z_PK from ZSHORTCUT where ZWORKFLOWID='$ACTION_ID');")
TRIGGER_DATA_LEN=$(sqlite3 "$DB" "select length(ZDATA) from ZSHORTCUTACTIONS where ZSHORTCUT=(select Z_PK from ZSHORTCUT where ZWORKFLOWID='$TRIGGER_ID');")
TRIGGER_COUNT=$(sqlite3 "$DB" "select count(*) from ZUNIFIEDTRIGGER where ZSHORTCUT=(select Z_PK from ZSHORTCUT where ZWORKFLOWID='$TRIGGER_ID');")

case "$ACTION_ID" in
  ????????-????-????-????-????????????) ;;
  *)
    echo "action workflowID is not UUID-shaped: $ACTION_ID" >&2
    exit 1
    ;;
esac
case "$TRIGGER_ID" in
  ????????-????-????-????-????????????) ;;
  *)
    echo "trigger workflowID is not UUID-shaped: $TRIGGER_ID" >&2
    exit 1
    ;;
esac
if [ "$AFTER" -ne $((BEFORE + 2)) ]; then
  echo "expected shortcut count $((BEFORE + 2)), got $AFTER" >&2
  exit 1
fi
if [ "$INTEGRITY" != "ok" ]; then
  echo "integrity_check failed: $INTEGRITY" >&2
  exit 1
fi
if [ "$ACTION_ROW" != "1|1 action" ]; then
  echo "unexpected action row state: $ACTION_ROW" >&2
  exit 1
fi
if [ "$TRIGGER_ROW" != "1|1 action" ]; then
  echo "unexpected trigger row state: $TRIGGER_ROW" >&2
  exit 1
fi
if [ "$ACTION_SAVED_NAME" != "$ACTION_NAME" ]; then
  echo "unexpected action name: $ACTION_SAVED_NAME" >&2
  exit 1
fi
if [ "$TRIGGER_SAVED_NAME" != "$TRIGGER_NAME" ]; then
  echo "unexpected trigger name: $TRIGGER_SAVED_NAME" >&2
  exit 1
fi
if [ "$ACTION_DATA_LEN" -le 42 ]; then
  echo "action data blob is unexpectedly small: $ACTION_DATA_LEN" >&2
  exit 1
fi
if [ "$TRIGGER_DATA_LEN" -le 42 ]; then
  echo "trigger data blob is unexpectedly small: $TRIGGER_DATA_LEN" >&2
  exit 1
fi
if [ "$TRIGGER_COUNT" -ne 1 ]; then
  echo "expected one unified trigger row, got $TRIGGER_COUNT" >&2
  exit 1
fi

echo "ok actionWorkflowID=$ACTION_ID triggerWorkflowID=$TRIGGER_ID database=$DB"
