//
//  FDB.h
//  FDB
//
//  Created by Aleksejs Sinicins on 25/07/13.
//  Copyright (c) 2014 Aleksejs Sinicins. All rights reserved.
//

@import Foundation;
#import "FDBObject.h"

typedef struct sqlite3 sqlite3;

@interface FDB : NSObject

+ (FDB *)sharedInstance;
+ (BOOL)configureWithDatabaseFile:(NSString *)databaseFile;
- (BOOL)executeUpdate:(NSString *)sql, ... NS_REQUIRES_NIL_TERMINATION;
- (NSArray *)executeQuery:(NSString *)sql, ... NS_REQUIRES_NIL_TERMINATION;
- (void)inTransaction:(void (^)(FDB *database, BOOL *rollback))block;
- (NSArray *)executeQuery:(NSString *)sql varArgs:(va_list)args shouldReturnResult:(BOOL)returnsResult;

@end
