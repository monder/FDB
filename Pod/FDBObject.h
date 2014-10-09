//
//  FDBObject.h
//  FDB
//
//  Created by Aleksejs Sinicins on 25/07/13.
//  Copyright (c) 2014 Aleksejs Sinicins. All rights reserved.
//

@import Foundation;
@class FDB;

typedef NS_OPTIONS(NSUInteger, FDBEvent) {
    FDBEventNone = 0,
    FDBEventInsertion = 1 << 0,
    FDBEventDeletion = 1 << 1,
    FDBEventModification = 1 << 2,
};

@interface FDBObject : NSObject

@property (copy, nonatomic) NSString *id;

+ (BOOL(^)(FDB *db, unsigned int *schemaVersion))migrate;

+ (BOOL)existsWithId:(NSString *)id;
+ (instancetype)withId:(NSString *)id;
+ (NSArray *)all;
+ (NSArray *)allWhere:(NSString *)sql, ... NS_REQUIRES_NIL_TERMINATION;
+ (NSArray *)allWhereInnerJoin:(NSString *)sql, ... NS_REQUIRES_NIL_TERMINATION;
+ (NSArray *)allWhereLeftJoin:(NSString *)sql, ... NS_REQUIRES_NIL_TERMINATION;
+ (instancetype)firstWhere:(NSString *)sql, ... NS_REQUIRES_NIL_TERMINATION;
+ (instancetype)firstWhereInnerJoin:(NSString *)sql, ... NS_REQUIRES_NIL_TERMINATION;

+ (BOOL)deleteAllWhere:(NSString *)sql, ... NS_REQUIRES_NIL_TERMINATION;
- (BOOL)delete;

- (BOOL)save;

+ (NSString *)contentPath;
+ (NSString *)normalizeName:(NSString *)name;

+ (void)addObserverForEvents:(FDBEvent)events context:(id)context block:(void(^)(id object, FDBEvent event))block;
+ (void)removeObserverForContext:(id)context;

- (NSString *)serializeProperty:(NSString *)propertyName value:(id)value;
- (id)deserializeProperty:(NSString *)propertyName value:(NSString *)value;

- (id)objectForKeyedSubscript:(NSString *)key;
- (void)setObject:(id)obj forKeyedSubscript:(NSString *)key;
@end
