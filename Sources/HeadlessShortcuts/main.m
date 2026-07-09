#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/message.h>

typedef NS_ENUM(NSUInteger, HSCommand) {
    HSCommandNone,
    HSCommandCreate,
    HSCommandEdit,
    HSCommandDelete,
};

typedef struct {
    HSCommand command;
    NSString *workflowPath;
    NSString *name;
    NSString *workflowID;
} HSOptions;

typedef struct {
    Class fileClass;
    Class workflowClass;
    Class databaseClass;
    Class proxyClass;
} HSRuntime;

static NSString *const HSErrorDomain = @"HeadlessShortcuts";

typedef NS_ENUM(NSInteger, HSErrorCode) {
    HSErrorOperationFailed = 1,
    HSErrorNotFound = 2,
};

static void setError(NSError **error, HSErrorCode code, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:HSErrorDomain
                                     code:code
                                 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}

static void setErrorMessage(NSError **error, NSString *message) {
    setError(error, HSErrorOperationFailed, message);
}

static NSString *standardPath(NSString *path) {
    return [[path stringByExpandingTildeInPath] stringByStandardizingPath];
}

static NSString *databasePath(void) {
    NSString *override = [NSProcessInfo processInfo].environment[@"HEADLESS_SHORTCUTS_DATABASE"];
    if ([override length]) {
        return standardPath(override);
    }
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Shortcuts/Shortcuts.sqlite"];
}

static BOOL parseOptions(NSArray<NSString *> *arguments, HSOptions *options, NSError **error) {
    if ([arguments count] < 2) {
        setErrorMessage(error, @"missing command");
        return NO;
    }

    NSString *command = arguments[1];
    if ([command isEqualToString:@"create"]) {
        options->command = HSCommandCreate;
    } else if ([command isEqualToString:@"edit"]) {
        options->command = HSCommandEdit;
    } else if ([command isEqualToString:@"delete"]) {
        options->command = HSCommandDelete;
    } else {
        setErrorMessage(error, [NSString stringWithFormat:@"unknown command %@", command]);
        return NO;
    }

    for (NSUInteger index = 2; index < [arguments count]; index++) {
        NSString *argument = arguments[index];
        if ([argument isEqualToString:@"--plist"]) {
            if (++index >= [arguments count]) {
                setErrorMessage(error, @"--plist requires a value");
                return NO;
            }
            options->workflowPath = arguments[index];
        } else if ([argument isEqualToString:@"--name"]) {
            if (++index >= [arguments count]) {
                setErrorMessage(error, @"--name requires a value");
                return NO;
            }
            options->name = arguments[index];
        } else if ([argument isEqualToString:@"--id"]) {
            if (++index >= [arguments count]) {
                setErrorMessage(error, @"--id requires a value");
                return NO;
            }
            options->workflowID = arguments[index];
        } else {
            setErrorMessage(error, [NSString stringWithFormat:@"unknown argument %@", argument]);
            return NO;
        }
    }

    if (options->command == HSCommandCreate) {
        if (![options->workflowPath length] || ![options->name length] || [options->workflowID length]) {
            setErrorMessage(error, @"create requires --plist PATH and --name NAME");
            return NO;
        }
    } else if (options->command == HSCommandEdit) {
        if (![options->workflowID length] || ![options->workflowPath length] || [options->name length]) {
            setErrorMessage(error, @"edit requires --id UUID and --plist PATH");
            return NO;
        }
    } else if (options->command == HSCommandDelete) {
        if (![options->workflowID length] || [options->workflowPath length] || [options->name length]) {
            setErrorMessage(error, @"delete requires --id UUID");
            return NO;
        }
    }

    if ([options->workflowID length]) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:options->workflowID];
        if (!uuid) {
            setErrorMessage(error, @"--id must be a UUID");
            return NO;
        }
        options->workflowID = [uuid UUIDString];
    }
    if ([options->workflowPath length]) {
        options->workflowPath = standardPath(options->workflowPath);
    }
    return YES;
}

static NSString *operationName(HSCommand command) {
    switch (command) {
        case HSCommandCreate:
            return @"create";
        case HSCommandEdit:
            return @"edit";
        case HSCommandDelete:
            return @"delete";
        case HSCommandNone:
            return @"unknown";
    }
}

static void printJSON(NSDictionary *response) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:response
                                                   options:NSJSONWritingSortedKeys
                                                     error:nil];
    if (data) {
        fwrite([data bytes], 1, [data length], stdout);
        fputc('\n', stdout);
    }
}

static void printSuccess(HSCommand command, NSString *workflowID, NSString *name) {
    NSMutableDictionary *response = [@{
        @"ok": @YES,
        @"operation": operationName(command),
        @"workflowID": workflowID,
    } mutableCopy];
    if ([name length]) {
        response[@"name"] = name;
    }
    printJSON(response);
}

static void printFailure(HSCommand command, NSString *workflowID, NSError *error, NSString *code) {
    NSString *message = [error localizedDescription] ?: @"operation failed";
    NSMutableDictionary *response = [@{
        @"ok": @NO,
        @"operation": operationName(command),
        @"error": @{
            @"code": code,
            @"message": message,
        },
    } mutableCopy];
    if ([workflowID length]) {
        response[@"workflowID"] = workflowID;
    }
    printJSON(response);
}

static NSString *operationErrorCode(NSError *error) {
    if ([[error domain] isEqualToString:HSErrorDomain] && [error code] == HSErrorNotFound) {
        return @"not_found";
    }
    return @"operation_failed";
}

static id callObject0(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) {
        return nil;
    }
    id (*message)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return message(object, selector);
}

static void setObject(id object, SEL selector, id value) {
    void (*message)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    message(object, selector, value);
}

static void setBoolean(id object, SEL selector, BOOL value) {
    void (*message)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    message(object, selector, value);
}

static void setInteger(id object, SEL selector, NSInteger value) {
    void (*message)(id, SEL, NSInteger) = (void (*)(id, SEL, NSInteger))objc_msgSend;
    message(object, selector, value);
}

static BOOL loadRuntime(HSRuntime *runtime, NSError **error) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/WorkflowKit.framework/WorkflowKit", RTLD_NOW);
    if (!handle) {
        setErrorMessage(error, [NSString stringWithFormat:@"could not load WorkflowKit: %s", dlerror()]);
        return NO;
    }

    runtime->fileClass = NSClassFromString(@"WFWorkflowFile");
    runtime->workflowClass = NSClassFromString(@"WFWorkflow");
    runtime->databaseClass = NSClassFromString(@"WFDatabase");
    runtime->proxyClass = NSClassFromString(@"WFDatabaseProxy");
    if (!runtime->fileClass || !runtime->workflowClass || !runtime->databaseClass || !runtime->proxyClass) {
        setErrorMessage(error, @"WorkflowKit did not expose the required classes");
        return NO;
    }
    return YES;
}

static BOOL openDatabase(HSRuntime runtime, id *databaseOut, id *proxyOut, NSError **error) {
    NSString *path = databasePath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        setErrorMessage(error, [NSString stringWithFormat:@"Shortcuts database not found at %@", path]);
        return NO;
    }

    id (*allocate)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id (*initializeDatabase)(id, SEL, NSUInteger, id, NSError **) =
        (id (*)(id, SEL, NSUInteger, id, NSError **))objc_msgSend;
    id (*initializeProxy)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;

    id database = initializeDatabase(allocate((id)runtime.databaseClass, @selector(alloc)),
                                     @selector(initWithPersistenceMode:fileURL:error:),
                                     (NSUInteger)0,
                                     [NSURL fileURLWithPath:path],
                                     error);
    if (!database) {
        return NO;
    }
    id proxy = initializeProxy(allocate((id)runtime.proxyClass, @selector(alloc)),
                               @selector(initWithDatabase:),
                               database);
    if (!proxy) {
        setErrorMessage(error, @"WFDatabaseProxy initWithDatabase: returned nil");
        return NO;
    }

    *databaseOut = database;
    *proxyOut = proxy;
    return YES;
}

static id materializedWorkflow(HSRuntime runtime, NSString *plistPath, NSString *name, NSError **error) {
    NSData *data = [NSData dataWithContentsOfFile:plistPath options:0 error:error];
    if (!data) {
        return nil;
    }
    if ([data length] >= 4 && memcmp([data bytes], "AEA1", 4) == 0) {
        setErrorMessage(error, @"signed AEA1 .shortcut envelopes are not supported; pass an unsigned workflow plist");
        return nil;
    }

    id (*allocate)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id (*initializeFile)(id, SEL, id, id, NSError **) =
        (id (*)(id, SEL, id, id, NSError **))objc_msgSend;
    id (*recordRepresentation)(id, SEL, NSError **) =
        (id (*)(id, SEL, NSError **))objc_msgSend;
    id (*initializeWorkflow)(id, SEL, id, id, id, NSError **) =
        (id (*)(id, SEL, id, id, id, NSError **))objc_msgSend;
    void (*voidMessage)(id, SEL) = (void (*)(id, SEL))objc_msgSend;

    id file = initializeFile(allocate((id)runtime.fileClass, @selector(alloc)),
                             @selector(initWithFileData:name:error:),
                             data,
                             name,
                             error);
    if (!file) {
        return nil;
    }
    id record = recordRepresentation(file, @selector(recordRepresentationWithError:), error);
    if (!record) {
        return nil;
    }
    if ([record respondsToSelector:@selector(setName:)]) {
        setObject(record, @selector(setName:), name);
    }

    id workflow = initializeWorkflow(allocate((id)runtime.workflowClass, @selector(alloc)),
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
    dispatch_barrier_sync((dispatch_queue_t)queueObject, ^{
        voidMessage(workflow, @selector(saveToRecord));
    });

    record = callObject0(workflow, @selector(record));
    if (!record) {
        setErrorMessage(error, @"WFWorkflow did not provide a record after saveToRecord");
        return nil;
    }
    if ([record respondsToSelector:@selector(setName:)]) {
        setObject(record, @selector(setName:), name);
    }
    id actions = callObject0(record, @selector(actions));
    if ([actions respondsToSelector:@selector(count)] && [record respondsToSelector:@selector(setActionCount:)]) {
        setInteger(record, @selector(setActionCount:), (NSInteger)[actions count]);
    }
    return workflow;
}

static NSString *identifierForReference(id reference, NSError **error) {
    id identifier = callObject0(reference, @selector(identifier));
    NSString *workflowID = [identifier isKindOfClass:[NSString class]] ? identifier : [identifier description];
    if (![workflowID length]) {
        setErrorMessage(error, @"workflow reference did not expose an identifier");
        return nil;
    }
    return workflowID;
}

static NSString *createShortcut(HSOptions options,
                                HSRuntime runtime,
                                id proxy,
                                NSString **nameOut,
                                NSError **error) {
    id workflow = materializedWorkflow(runtime, options.workflowPath, options.name, error);
    if (!workflow) {
        return nil;
    }
    id record = callObject0(workflow, @selector(record));
    id (*createWorkflow)(id, SEL, id, NSUInteger, NSError **) =
        (id (*)(id, SEL, id, NSUInteger, NSError **))objc_msgSend;
    id reference = createWorkflow(proxy,
                                  @selector(createWorkflowWithWorkflowRecord:nameCollisionBehavior:error:),
                                  record,
                                  (NSUInteger)0,
                                  error);
    if (!reference) {
        return nil;
    }
    id createdName = callObject0(reference, @selector(name));
    if (nameOut && [createdName isKindOfClass:[NSString class]] && [createdName length]) {
        *nameOut = createdName;
    }
    return identifierForReference(reference, error);
}

static id referenceForWorkflowID(id proxy, NSString *workflowID) {
    id (*reference)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    return reference(proxy, @selector(referenceForWorkflowID:), workflowID);
}

static NSString *editShortcut(HSOptions options,
                              HSRuntime runtime,
                              id database,
                              id proxy,
                              NSString **nameOut,
                              NSError **error) {
    id reference = referenceForWorkflowID(proxy, options.workflowID);
    if (!reference) {
        setError(error,
                 HSErrorNotFound,
                 [NSString stringWithFormat:@"shortcut %@ was not found", options.workflowID]);
        return nil;
    }

    id (*workflowForReference)(id, SEL, id, id, NSError **) =
        (id (*)(id, SEL, id, id, NSError **))objc_msgSend;
    id existingWorkflow = workflowForReference((id)runtime.workflowClass,
                                                @selector(workflowWithReference:database:error:),
                                                reference,
                                                database,
                                                error);
    if (!existingWorkflow) {
        return nil;
    }
    NSString *existingName = callObject0(existingWorkflow, @selector(name));
    if (![existingName length]) {
        setErrorMessage(error, @"existing shortcut did not provide a name");
        return nil;
    }

    id replacementWorkflow = materializedWorkflow(runtime, options.workflowPath, existingName, error);
    if (!replacementWorkflow) {
        return nil;
    }
    id replacementActions = callObject0(replacementWorkflow, @selector(actions));
    if (!replacementActions) {
        setErrorMessage(error, @"replacement workflow did not provide actions");
        return nil;
    }

    NSMutableArray *copiedActions = [NSMutableArray arrayWithCapacity:[replacementActions count]];
    for (id action in replacementActions) {
        id copiedAction = [action copy];
        if (!copiedAction) {
            setErrorMessage(error, @"replacement workflow action could not be copied");
            return nil;
        }
        [copiedActions addObject:copiedAction];
    }

    @try {
        setBoolean(existingWorkflow, @selector(setSaveDisabled:), YES);
        setObject(existingWorkflow, @selector(setActions:), copiedActions);
        setBoolean(existingWorkflow, @selector(setSaveDisabled:), NO);
    } @catch (NSException *exception) {
        setErrorMessage(error, [NSString stringWithFormat:@"could not replace workflow actions: %@", [exception reason]]);
        return nil;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *saveError = nil;
    void (^completion)(NSError *) = ^(NSError *result) {
        saveError = result;
        dispatch_semaphore_signal(semaphore);
    };
    void (*saveWithCompletion)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
    saveWithCompletion(existingWorkflow, @selector(saveWithCompletionBlock:), completion);
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    if (saveError) {
        if (error) {
            *error = saveError;
        }
        return nil;
    }
    if (nameOut) {
        *nameOut = existingName;
    }
    return options.workflowID;
}

static NSString *deleteShortcut(HSOptions options, id database, id proxy, NSError **error) {
    id reference = referenceForWorkflowID(proxy, options.workflowID);
    if (!reference) {
        setError(error,
                 HSErrorNotFound,
                 [NSString stringWithFormat:@"shortcut %@ was not found", options.workflowID]);
        return nil;
    }

    BOOL (*deleteReference)(id, SEL, id, NSError **) =
        (BOOL (*)(id, SEL, id, NSError **))objc_msgSend;
    if (!deleteReference(database, @selector(deleteReference:error:), reference, error)) {
        return nil;
    }
    return options.workflowID;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithCapacity:(NSUInteger)argc];
        for (int index = 0; index < argc; index++) {
            [arguments addObject:[NSString stringWithUTF8String:argv[index]]];
        }

        NSError *error = nil;
        HSOptions options = {0};
        if (!parseOptions(arguments, &options, &error)) {
            printFailure(options.command, nil, error, @"invalid_arguments");
            return 64;
        }

        HSRuntime runtime = {0};
        if (!loadRuntime(&runtime, &error)) {
            printFailure(options.command, options.workflowID, error, operationErrorCode(error));
            return 1;
        }
        id database = nil;
        id proxy = nil;
        if (!openDatabase(runtime, &database, &proxy, &error)) {
            printFailure(options.command, options.workflowID, error, operationErrorCode(error));
            return 1;
        }

        NSString *workflowID = nil;
        NSString *name = options.command == HSCommandCreate ? options.name : nil;
        switch (options.command) {
            case HSCommandCreate:
                workflowID = createShortcut(options, runtime, proxy, &name, &error);
                break;
            case HSCommandEdit:
                workflowID = editShortcut(options, runtime, database, proxy, &name, &error);
                break;
            case HSCommandDelete:
                workflowID = deleteShortcut(options, database, proxy, &error);
                break;
            case HSCommandNone:
                break;
        }
        if (!workflowID) {
            printFailure(options.command, options.workflowID, error, operationErrorCode(error));
            return 1;
        }

        printSuccess(options.command, workflowID, name);
    }
    return 0;
}
