#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import <unistd.h>

typedef struct {
    NSString *workflowPath;
    NSString *name;
    NSString *databasePath;
    BOOL databaseWasExplicit;
    BOOL json;
    BOOL noBackup;
    BOOL backupAlways;
    BOOL noQuit;
    BOOL quitAlways;
    NSUInteger collisionBehavior;
    NSUInteger persistenceMode;
} HSOptions;

static NSString *defaultDatabasePath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Shortcuts/Shortcuts.sqlite"];
}

static NSString *standardPath(NSString *path) {
    return [[path stringByExpandingTildeInPath] stringByStandardizingPath];
}

static void setErrorMessage(NSError **error, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:@"HeadlessShortcuts"
                                     code:1
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}

static void printUsage(void) {
    fprintf(stderr,
            "usage: headless-shortcuts import WORKFLOW_PLIST --name NAME [options]\n"
            "\n"
            "options:\n"
            "  --database PATH          Shortcuts.sqlite path (default: ~/Library/Shortcuts/Shortcuts.sqlite)\n"
            "  --name NAME              shortcut name to save\n"
            "  --json                   print JSON instead of only workflowID\n"
            "  --backup                 create a SQLite backup even for explicit --database paths\n"
            "  --no-backup              skip automatic backup\n"
            "  --quit-shortcuts         ask Shortcuts.app to quit before import\n"
            "  --no-quit                do not ask Shortcuts.app to quit\n"
            "  --collision-behavior N   WorkflowKit name collision behavior (default: 0)\n"
            "  --persistence-mode N     WFDatabase persistence mode (default: 0)\n");
}

static BOOL parseUnsigned(NSString *text, NSUInteger *value) {
    char *end = NULL;
    unsigned long long parsed = strtoull([text UTF8String], &end, 0);
    if (!end || *end != '\0') {
        return NO;
    }
    *value = (NSUInteger)parsed;
    return YES;
}

static BOOL parseOptions(NSArray<NSString *> *arguments, HSOptions *options, NSError **error) {
    options->databasePath = defaultDatabasePath();
    options->collisionBehavior = 0;
    options->persistenceMode = 0;

    if ([arguments count] < 2 || ![arguments[1] isEqualToString:@"import"]) {
        setErrorMessage(error, @"expected 'import' command");
        return NO;
    }

    for (NSUInteger i = 2; i < [arguments count]; i++) {
        NSString *arg = arguments[i];
        if ([arg isEqualToString:@"--name"]) {
            if (++i >= [arguments count]) {
                setErrorMessage(error, @"--name requires a value");
                return NO;
            }
            options->name = arguments[i];
        } else if ([arg isEqualToString:@"--database"]) {
            if (++i >= [arguments count]) {
                setErrorMessage(error, @"--database requires a value");
                return NO;
            }
            options->databasePath = arguments[i];
            options->databaseWasExplicit = YES;
        } else if ([arg isEqualToString:@"--json"]) {
            options->json = YES;
        } else if ([arg isEqualToString:@"--backup"]) {
            options->backupAlways = YES;
        } else if ([arg isEqualToString:@"--no-backup"]) {
            options->noBackup = YES;
        } else if ([arg isEqualToString:@"--quit-shortcuts"]) {
            options->quitAlways = YES;
        } else if ([arg isEqualToString:@"--no-quit"]) {
            options->noQuit = YES;
        } else if ([arg isEqualToString:@"--collision-behavior"]) {
            if (++i >= [arguments count] || !parseUnsigned(arguments[i], &options->collisionBehavior)) {
                setErrorMessage(error, @"--collision-behavior requires an unsigned integer");
                return NO;
            }
        } else if ([arg isEqualToString:@"--persistence-mode"]) {
            if (++i >= [arguments count] || !parseUnsigned(arguments[i], &options->persistenceMode)) {
                setErrorMessage(error, @"--persistence-mode requires an unsigned integer");
                return NO;
            }
        } else if ([arg hasPrefix:@"--"]) {
            setErrorMessage(error, [NSString stringWithFormat:@"unknown option %@", arg]);
            return NO;
        } else if (!options->workflowPath) {
            options->workflowPath = arg;
        } else {
            setErrorMessage(error, [NSString stringWithFormat:@"unexpected argument %@", arg]);
            return NO;
        }
    }

    if (!options->workflowPath) {
        setErrorMessage(error, @"missing workflow plist path");
        return NO;
    }
    if (![options->name length]) {
        setErrorMessage(error, @"--name is required");
        return NO;
    }

    options->workflowPath = standardPath(options->workflowPath);
    options->databasePath = standardPath(options->databasePath);
    return YES;
}

static BOOL sqliteBackup(NSString *sourcePath, NSString *backupPath, NSError **error) {
    sqlite3 *source = NULL;
    sqlite3 *dest = NULL;
    sqlite3_backup *backup = NULL;
    int rc = sqlite3_open_v2([sourcePath fileSystemRepresentation], &source, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        setErrorMessage(error, [NSString stringWithFormat:@"open source database failed: %s", source ? sqlite3_errmsg(source) : "unknown"]);
        if (source) {
            sqlite3_close(source);
        }
        return NO;
    }
    sqlite3_busy_timeout(source, 5000);

    rc = sqlite3_open_v2([backupPath fileSystemRepresentation], &dest, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (rc != SQLITE_OK) {
        setErrorMessage(error, [NSString stringWithFormat:@"open backup database failed: %s", dest ? sqlite3_errmsg(dest) : "unknown"]);
        sqlite3_close(source);
        if (dest) {
            sqlite3_close(dest);
        }
        return NO;
    }
    sqlite3_busy_timeout(dest, 5000);

    backup = sqlite3_backup_init(dest, "main", source, "main");
    if (!backup) {
        setErrorMessage(error, [NSString stringWithFormat:@"sqlite backup init failed: %s", sqlite3_errmsg(dest)]);
        sqlite3_close(dest);
        sqlite3_close(source);
        return NO;
    }

    do {
        rc = sqlite3_backup_step(backup, 128);
        if (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) {
            usleep(100000);
        }
    } while (rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED);

    int finishRC = sqlite3_backup_finish(backup);
    if (finishRC != SQLITE_OK) {
        rc = finishRC;
    }
    if (rc != SQLITE_DONE) {
        setErrorMessage(error, [NSString stringWithFormat:@"sqlite backup failed: %s", sqlite3_errmsg(dest)]);
        sqlite3_close(dest);
        sqlite3_close(source);
        return NO;
    }

    sqlite3_close(dest);
    sqlite3_close(source);
    return YES;
}

static BOOL readShortcutActionCount(NSString *databasePath, NSString *workflowID, NSInteger *actionCount, NSError **error) {
    sqlite3 *db = NULL;
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_open_v2([databasePath fileSystemRepresentation], &db, SQLITE_OPEN_READONLY, NULL);
    if (rc != SQLITE_OK) {
        setErrorMessage(error, [NSString stringWithFormat:@"open database for verification failed: %s", db ? sqlite3_errmsg(db) : "unknown"]);
        if (db) {
            sqlite3_close(db);
        }
        return NO;
    }
    sqlite3_busy_timeout(db, 5000);

    rc = sqlite3_prepare_v2(db, "select ZACTIONCOUNT from ZSHORTCUT where ZWORKFLOWID=?", -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        setErrorMessage(error, [NSString stringWithFormat:@"prepare verification query failed: %s", sqlite3_errmsg(db)]);
        sqlite3_close(db);
        return NO;
    }
    sqlite3_bind_text(stmt, 1, [workflowID UTF8String], -1, SQLITE_TRANSIENT);
    rc = sqlite3_step(stmt);
    if (rc == SQLITE_ROW) {
        *actionCount = (NSInteger)sqlite3_column_int64(stmt, 0);
        sqlite3_finalize(stmt);
        sqlite3_close(db);
        return YES;
    }
    if (rc == SQLITE_DONE) {
        setErrorMessage(error, @"created workflow row was not found during verification");
    } else {
        setErrorMessage(error, [NSString stringWithFormat:@"verification query failed: %s", sqlite3_errmsg(db)]);
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return NO;
}

static NSString *timestampedBackupPath(NSString *databasePath) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [formatter stringFromDate:[NSDate date]];
    return [databasePath stringByAppendingFormat:@".%@.backup", stamp];
}

static void quitShortcuts(void) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
    task.arguments = @[@"-e", @"tell application \"Shortcuts\" to quit"];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    [task launchAndReturnError:nil];
    [task waitUntilExit];
}

static id callObject0(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) {
        return nil;
    }
    id (*msg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return msg(obj, sel);
}

static NSString *objectDescription(id obj) {
    if (!obj) {
        return nil;
    }
    return [[obj description] copy];
}

static BOOL loadWorkflowKit(Class *fileClass, Class *workflowClass, Class *databaseClass, Class *proxyClass, NSError **error) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_NOW);
    if (!handle) {
        setErrorMessage(error, [NSString stringWithFormat:@"could not load WorkflowKit: %s", dlerror()]);
        return NO;
    }

    *fileClass = NSClassFromString(@"WFWorkflowFile");
    *workflowClass = NSClassFromString(@"WFWorkflow");
    *databaseClass = NSClassFromString(@"WFDatabase");
    *proxyClass = NSClassFromString(@"WFDatabaseProxy");
    if (!*fileClass || !*workflowClass || !*databaseClass || !*proxyClass) {
        setErrorMessage(error, @"WorkflowKit did not expose the required classes");
        return NO;
    }
    return YES;
}

static NSString *importWorkflow(HSOptions options, NSString **backupPathOut, NSError **error) {
    NSString *defaultPath = standardPath(defaultDatabasePath());
    BOOL isDefaultDatabase = [options.databasePath isEqualToString:defaultPath];
    BOOL shouldQuit = options.quitAlways || (!options.noQuit && isDefaultDatabase && !options.databaseWasExplicit);
    BOOL shouldBackup = options.backupAlways || (!options.noBackup && isDefaultDatabase && !options.databaseWasExplicit);

    if (shouldQuit) {
        quitShortcuts();
    }
    if (shouldBackup) {
        NSString *backupPath = timestampedBackupPath(options.databasePath);
        if (!sqliteBackup(options.databasePath, backupPath, error)) {
            return nil;
        }
        if (backupPathOut) {
            *backupPathOut = backupPath;
        }
    }

    NSData *workflowData = [NSData dataWithContentsOfFile:options.workflowPath options:0 error:error];
    if (!workflowData) {
        return nil;
    }
    if ([workflowData length] >= 4 && memcmp([workflowData bytes], "AEA1", 4) == 0) {
        setErrorMessage(error, @"signed AEA1 .shortcut envelopes are not supported; pass an unsigned workflow plist");
        return nil;
    }

    Class fileClass = Nil;
    Class workflowClass = Nil;
    Class databaseClass = Nil;
    Class proxyClass = Nil;
    if (!loadWorkflowKit(&fileClass, &workflowClass, &databaseClass, &proxyClass, error)) {
        return nil;
    }

    id (*allocMsg)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id (*initFile)(id, SEL, id, id, NSError **) = (id (*)(id, SEL, id, id, NSError **))objc_msgSend;
    id (*recordRep)(id, SEL, NSError **) = (id (*)(id, SEL, NSError **))objc_msgSend;
    id (*initWorkflow)(id, SEL, id, id, id, NSError **) = (id (*)(id, SEL, id, id, id, NSError **))objc_msgSend;
    void (*setObject1)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    void (*msgVoid0)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    id (*initDatabase)(id, SEL, NSUInteger, id, NSError **) = (id (*)(id, SEL, NSUInteger, id, NSError **))objc_msgSend;
    id (*initProxy)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    id (*createWorkflow)(id, SEL, id, NSUInteger, NSError **) = (id (*)(id, SEL, id, NSUInteger, NSError **))objc_msgSend;
    id (*proxyReferenceForWorkflowID)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    id (*proxySortedVisible)(id, SEL, NSError **) = (id (*)(id, SEL, NSError **))objc_msgSend;
    NSInteger (*msgInt0)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
    void (*setInteger1)(id, SEL, NSInteger) = (void (*)(id, SEL, NSInteger))objc_msgSend;

    id file = initFile(allocMsg((id)fileClass, @selector(alloc)),
                       @selector(initWithFileData:name:error:),
                       workflowData,
                       options.name,
                       error);
    if (!file) {
        return nil;
    }

    id record = recordRep(file, @selector(recordRepresentationWithError:), error);
    if (!record) {
        return nil;
    }
    if ([record respondsToSelector:@selector(setName:)]) {
        setObject1(record, @selector(setName:), options.name);
    }

    id workflow = initWorkflow(allocMsg((id)workflowClass, @selector(alloc)),
                               @selector(initWithRecord:reference:storageProvider:error:),
                               record,
                               nil,
                               nil,
                               error);
    if (!workflow) {
        return nil;
    }

    id queueObject = callObject0(workflow, @selector(databaseAccessQueue));
    if (!queueObject) {
        setErrorMessage(error, @"WFWorkflow did not provide databaseAccessQueue");
        return nil;
    }
    dispatch_queue_t queue = (dispatch_queue_t)queueObject;
    dispatch_barrier_sync(queue, ^{
        msgVoid0(workflow, @selector(saveToRecord));
    });

    id savedRecord = callObject0(workflow, @selector(record));
    if (!savedRecord) {
        setErrorMessage(error, @"WFWorkflow did not provide a record after saveToRecord");
        return nil;
    }
    record = savedRecord;
    if ([record respondsToSelector:@selector(setName:)]) {
        setObject1(record, @selector(setName:), options.name);
    }
    NSInteger expectedActionCount = -1;
    if ([record respondsToSelector:@selector(actionCount)]) {
        expectedActionCount = msgInt0(record, @selector(actionCount));
    }
    (void)callObject0(record, @selector(name));
    (void)callObject0(record, @selector(workflowSubtitle));
    id savedActions = callObject0(record, @selector(actions));
    if ([savedActions respondsToSelector:@selector(count)]) {
        expectedActionCount = (NSInteger)[savedActions count];
        if ([record respondsToSelector:@selector(setActionCount:)]) {
            setInteger1(record, @selector(setActionCount:), expectedActionCount);
        }
    }
    (void)callObject0(record, @selector(workflowTypes));
    (void)callObject0(record, @selector(unifiedAutomationTriggers));
    (void)[NSString stringWithFormat:@"%@", record];

    NSURL *databaseURL = [NSURL fileURLWithPath:options.databasePath];
    id database = initDatabase(allocMsg((id)databaseClass, @selector(alloc)),
                               @selector(initWithPersistenceMode:fileURL:error:),
                               options.persistenceMode,
                               databaseURL,
                               error);
    if (!database) {
        return nil;
    }

    id proxy = initProxy(allocMsg((id)proxyClass, @selector(alloc)), @selector(initWithDatabase:), database);
    if (!proxy) {
        setErrorMessage(error, @"WFDatabaseProxy initWithDatabase: returned nil");
        return nil;
    }

    id reference = createWorkflow(proxy,
                                  @selector(createWorkflowWithWorkflowRecord:nameCollisionBehavior:error:),
                                  record,
                                  options.collisionBehavior,
                                  error);
    if (!reference) {
        return nil;
    }

    NSString *workflowID = objectDescription(callObject0(reference, @selector(identifier)));
    if (![workflowID length]) {
        setErrorMessage(error, @"created workflow reference did not expose an identifier");
        return nil;
    }
    (void)proxyReferenceForWorkflowID(proxy, @selector(referenceForWorkflowID:), workflowID);
    NSError *refreshError = nil;
    (void)proxySortedVisible(proxy, @selector(sortedVisibleWorkflowsByNameWithError:), &refreshError);
    reference = nil;
    proxy = nil;
    database = nil;
    record = nil;
    workflow = nil;
    file = nil;

    if (expectedActionCount >= 0) {
        BOOL settled = NO;
        NSInteger actualActionCount = -1;
        for (NSUInteger attempt = 0; attempt < 4 && !settled; attempt++) {
            @autoreleasepool {
                NSError *ignoredRefreshError = nil;
                id refreshDatabase = initDatabase(allocMsg((id)databaseClass, @selector(alloc)),
                                                  @selector(initWithPersistenceMode:fileURL:error:),
                                                  options.persistenceMode,
                                                  databaseURL,
                                                  &ignoredRefreshError);
                id refreshProxy = refreshDatabase ? initProxy(allocMsg((id)proxyClass, @selector(alloc)), @selector(initWithDatabase:), refreshDatabase) : nil;
                if (refreshProxy) {
                    (void)proxyReferenceForWorkflowID(refreshProxy, @selector(referenceForWorkflowID:), workflowID);
                    (void)proxySortedVisible(refreshProxy, @selector(sortedVisibleWorkflowsByNameWithError:), &ignoredRefreshError);
                }
            }

            NSError *verifyError = nil;
            if (readShortcutActionCount(options.databasePath, workflowID, &actualActionCount, &verifyError) && actualActionCount == expectedActionCount) {
                settled = YES;
                break;
            }
            usleep(150000);
        }
        if (!settled) {
            setErrorMessage(error, [NSString stringWithFormat:@"imported workflow did not settle expected action count %ld; last observed %ld", (long)expectedActionCount, (long)actualActionCount]);
            return nil;
        }
    }
    return workflowID;
}

static void printJSON(NSDictionary *dictionary) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    if (data) {
        fwrite([data bytes], 1, [data length], stdout);
        fputc('\n', stdout);
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithCapacity:(NSUInteger)argc];
        for (int i = 0; i < argc; i++) {
            [arguments addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        NSError *error = nil;
        HSOptions options = {0};
        if (!parseOptions(arguments, &options, &error)) {
            if (options.json) {
                printJSON(@{@"ok": @NO, @"error": [error localizedDescription] ?: @"invalid arguments"});
            } else {
                fprintf(stderr, "error: %s\n\n", [[[error localizedDescription] ?: @"invalid arguments" description] UTF8String]);
                printUsage();
            }
            return 64;
        }

        NSString *backupPath = nil;
        NSString *workflowID = importWorkflow(options, &backupPath, &error);
        if (!workflowID) {
            if (options.json) {
                printJSON(@{@"ok": @NO, @"error": [error localizedDescription] ?: @"import failed"});
            } else {
                fprintf(stderr, "error: %s\n", [[[error localizedDescription] ?: @"import failed" description] UTF8String]);
            }
            return 1;
        }

        if (options.json) {
            NSMutableDictionary *result = [@{
                @"ok": @YES,
                @"workflowID": workflowID,
                @"database": options.databasePath,
                @"name": options.name
            } mutableCopy];
            if (backupPath) {
                result[@"backup"] = backupPath;
            }
            printJSON(result);
        } else {
            printf("%s\n", [workflowID UTF8String]);
        }
    }
    return 0;
}
