//
//  FDB.m
//  FDB
//
//  Created by Aleksejs Sinicins on 25/07/13.
//  Copyright (c) 2014 Aleksejs Sinicins. All rights reserved.
//

#import "FDB.h"
#import <sqlite3.h>

@interface FDB ()

@property (assign, nonatomic) sqlite3 *database;

- (NSArray *)executeQuery:(NSString *)sql varArgs:(va_list)args shouldReturnResult:(BOOL)returnsResult;

@end

@implementation FDB

+ (FDB *)sharedInstance
{
    static FDB *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

+ (BOOL)configureWithDatabaseFile:(NSString *)databaseFile
{
    FDB *fdb = [self sharedInstance];
    sqlite3_open([databaseFile UTF8String], &fdb->_database);
    return SQLITE_OK;
}

- (BOOL)executeUpdate:(NSString *)sql, ...
{
    va_list args;
    va_start(args, sql);
    BOOL result = !![self executeQuery:sql varArgs:args shouldReturnResult:NO];
    va_end(args);
    return result;
}

- (NSArray *)executeQuery:(NSString *)sql, ...
{
    va_list args;
    va_start(args, sql);
    NSArray *result = [self executeQuery:sql varArgs:args shouldReturnResult:YES];
    va_end(args);
    return result;
}

- (NSArray *)executeQuery:(NSString *)sql varArgs:(va_list)args shouldReturnResult:(BOOL)returnsResult
{
    int status = SQLITE_OK;
    sqlite3_stmt *stmt = NULL;

    status = sqlite3_prepare_v2(_database, [sql UTF8String], -1, &stmt, NULL);
    if (status != SQLITE_OK) {
        NSLog(@"FDB error %d: %s", sqlite3_errcode(_database), sqlite3_errmsg(_database));
        sqlite3_finalize(stmt);
        return nil;
    }

    int queryCount = sqlite3_bind_parameter_count(stmt);
    int index = 0;
    id obj = (__bridge id)(va_arg(args, void *));
    if ([obj isKindOfClass:[NSDictionary class]]) { // Named variables
        for (NSString *key in [obj allKeys]) {
            NSString *name = [@":" stringByAppendingString:key];
            int namedIndex = sqlite3_bind_parameter_index(stmt, [name UTF8String]);
            if (namedIndex) {
                NSString *value = obj[key];
                if (![value isKindOfClass:[NSString class]]) {
                    NSLog(@"FDB error: Only string arguments are supported (%@ is an %@)", key, NSStringFromClass([value class]));
                    sqlite3_finalize(stmt);
                    return nil;
                }
                sqlite3_bind_text(stmt, namedIndex, [value UTF8String], -1, SQLITE_STATIC);
                index++;
            } else {
                NSLog(@"FDB warning: Could not find index for %@", key);
            }
        }
    } else {
        while (index < queryCount && obj) {
            if (![obj isKindOfClass:[NSString class]]) {
                NSLog(@"FDB error: Only string arguments are supported (%d is an %@)", index, NSStringFromClass([obj class]));
                sqlite3_finalize(stmt);
                return nil;
            }
            index++; // Index starts with 1
            sqlite3_bind_text(stmt, index, [obj UTF8String], -1, SQLITE_STATIC);
            obj = va_arg(args, id);
        }
    }

    if (index != queryCount) {
        NSLog(@"FDB error: The bind count (%d) is not correct for the # of variables in the query (%d) (%@)", index, queryCount, sql);
        sqlite3_finalize(stmt);
        return nil;
    }

    NSMutableArray *result = [@[] mutableCopy];
    do {
        status = sqlite3_step(stmt);
        if (status != SQLITE_DONE && status != SQLITE_ROW) {
            NSLog(@"FDB error %d: %s", sqlite3_errcode(_database), sqlite3_errmsg(_database));
            sqlite3_finalize(stmt);
            return nil;
        }
        if (!returnsResult || status != SQLITE_ROW) {
            sqlite3_finalize(stmt);
            return result;
        }
        int columnCount = sqlite3_data_count(stmt);
        if (columnCount) {
            NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithCapacity:columnCount];
            columnCount = sqlite3_column_count(stmt);
            for (int columnIndex = 0; columnIndex < columnCount; columnIndex++) {
                NSString *columnName = [NSString stringWithUTF8String:sqlite3_column_name(stmt, columnIndex)];
                const char *val = (const char *)sqlite3_column_text(stmt, columnIndex);
                if (val) {
                    NSString *columnValue = [NSString stringWithUTF8String:val];
                    [dictionary setObject:columnValue forKey:columnName];
                }
            }
            [result addObject:dictionary];
        } else {
            NSLog(@"FDB warning: There seem to be no columns in this set.");
        }
    } while (status == SQLITE_ROW);
    sqlite3_finalize(stmt);
    return result;
}

- (void)inTransaction:(void (^)(FDB *database, BOOL *rollback))block
{
    BOOL rollback = NO;
    [self executeUpdate:@"BEGIN TRANSACTION", nil];
    block(self, &rollback);
    if (rollback) {
        [self executeUpdate:@"ROLLBACK TRANSACTION", nil];
    } else {
        [self executeUpdate:@"COMMIT TRANSACTION", nil];
    }
}
@end
