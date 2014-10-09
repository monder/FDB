//
//  FDBObject.m
//  FDB
//
//  Created by Aleksejs Sinicins on 25/07/13.
//  Copyright (c) 2014 Aleksejs Sinicins. All rights reserved.
//

#import "FDB.h"
#import <objc/runtime.h>

static NSMutableDictionary *_databaseObjects;
static NSMutableDictionary *_insertionObservers;
static NSMutableDictionary *_deletionObservers;
static NSMutableDictionary *_modificationObservers;
static NSMutableDictionary *_contextBlockMap;

id fdb_accessorGetter(FDBObject *self, SEL _cmd);
void fdb_accessorSetter(FDBObject *self, SEL _cmd, id newValue);

@interface FDBObject ()

@property (strong, nonatomic) NSMutableDictionary *__content;

+ (BOOL)executeUpdate:(NSString *)sql, ... NS_REQUIRES_NIL_TERMINATION;
+ (NSArray *)executeQuery:(NSString *)sql, ... NS_REQUIRES_NIL_TERMINATION;

+ (NSString *)tableName;

+ (NSArray *)objectsWithDBResult:(NSArray *)result;

@end

@implementation FDBObject

@dynamic id;

#pragma mark - Init

+ (NSString *)tableName
{
    return NSStringFromClass([self class]);
}

+ (void)initialize
{
    [super initialize];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _databaseObjects = [[NSMutableDictionary alloc] init];
        _insertionObservers = [@{} mutableCopy];
        _deletionObservers = [@{} mutableCopy];
        _modificationObservers = [@{} mutableCopy];
        _contextBlockMap = [@{} mutableCopy];
    });
    if (self.class != FDBObject.class && self.superclass == FDBObject.class) {
        FDB *db = [FDB sharedInstance];
        // Prepare
        NSArray *meta = [db executeQuery:
                         @"SELECT version FROM _FDBMetadata WHERE tableName = ?",
                         self.tableName, nil];
        if (!meta.count) {
            [db executeUpdate:
             @"CREATE TABLE IF NOT EXISTS _FDBMetadata (tableName TEXT NOT NULL, version TEXT NOT NULL, PRIMARY KEY(tableName))",
             nil];
            [db executeUpdate:
             @"INSERT INTO _FDBMetadata (tableName, version) VALUES (?, ?)",
             self.tableName, @"0", nil];
        }
        // Migrate
        unsigned int schemaVersion = [[meta lastObject][@"version"] unsignedIntValue];
        self.migrate(db, &schemaVersion);
        [db executeUpdate:
         @"UPDATE _FDBMetadata SET version = ? WHERE tableName = ?",
         [@(schemaVersion) stringValue], self.tableName, nil];
    }
}

- (id)init
{
    self = [super init];
    if (self) {
        self.__content = [@{} mutableCopy];
        if (!_databaseObjects[NSStringFromClass(self.class)])
            _databaseObjects[NSStringFromClass(self.class)] = [NSMapTable strongToWeakObjectsMapTable];
    }
    return self;
}

- (void)dealloc
{
    [_databaseObjects[NSStringFromClass(self.class)] removeObjectForKey:self.id];
}

#pragma mark - Helpers

+ (BOOL(^)(FDB *db, unsigned int *schemaVersion))migrate
{
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass",
                                           NSStringFromSelector(_cmd)]
                                 userInfo:nil];
    return nil;
}

+ (BOOL)executeUpdate:(NSString *)sql, ...
{
    va_list args;
    va_start(args, sql);
    sql = [sql stringByReplacingOccurrencesOfString:@"$T" withString:self.tableName];
    BOOL result = !![[FDB sharedInstance] executeQuery:sql varArgs:args shouldReturnResult:NO];
    va_end(args);
    return result;
}

+ (NSArray *)executeQuery:(NSString *)sql, ...
{
    va_list args;
    va_start(args, sql);
    sql = [sql stringByReplacingOccurrencesOfString:@"$T" withString:self.tableName];
    NSArray *result = [[FDB sharedInstance] executeQuery:sql varArgs:args shouldReturnResult:YES];
    va_end(args);
    return result;
}

+ (NSArray *)objectsWithDBResult:(NSArray *)result
{
    NSMutableArray *objects = [[NSMutableArray alloc] init];
    for (NSDictionary *resultDictionary in result) {
        NSString *identifier = resultDictionary[@"id"];
        FDBObject *o = [_databaseObjects[NSStringFromClass(self.class)] objectForKey:identifier];
        if (!o || o == (FDBObject *)[NSNull null]) {
            o = [[[self class] alloc] init];
            o.id = identifier;
            [_databaseObjects[NSStringFromClass(self.class)] setObject:o forKey:identifier];
            o->___content = [self mapDictionary:resultDictionary withBlock:^id(NSString *key, NSString *obj) {
                return [o deserializeProperty:key value:obj];
            }];
        }
        [objects addObject:o];
    }
    return objects;
}

#pragma mark - Queries

+ (BOOL)existsWithId:(NSString *)objectId
{
    if (!objectId)
        return NO;
    id obj = [_databaseObjects[NSStringFromClass(self.class)] objectForKey:objectId];
    if (obj)
        return obj != [NSNull null];

    NSArray *result = [self executeQuery:
                       @"SELECT id FROM $T WHERE id = ? LIMIT 1", objectId, nil];
    if (!result.count)
        [_databaseObjects[NSStringFromClass(self.class)] setObject:[NSNull null] forKey:objectId];
    return !![result count];
}

+ (instancetype)withId:(NSString *)objectId
{
    if (!objectId)
        return nil;
    id obj = [_databaseObjects[NSStringFromClass(self.class)] objectForKey:objectId];
    if (obj) {
        if (obj == [NSNull null]) {
            return nil;
        } else {
            return [_databaseObjects[NSStringFromClass(self.class)] objectForKey:objectId];
        }
    }

    NSArray *result = [self executeQuery:
                       @"SELECT * FROM $T WHERE id = ?", objectId, nil];
    if (!result.count)
        [_databaseObjects[NSStringFromClass(self.class)] setObject:[NSNull null] forKey:objectId];
    return [[self objectsWithDBResult:result] lastObject];
}

+ (NSArray *)all
{
    NSArray *result = [self executeQuery:
                       @"SELECT * FROM $T", nil];
    return [self objectsWithDBResult:result];
}

+ (NSArray *)allWhere:(NSString *)sql, ...
{
    va_list args;
    va_start(args, sql);
    sql = [NSString stringWithFormat:@"SELECT * FROM %@ WHERE %@", self.tableName, sql];
    NSArray *result = [[FDB sharedInstance] executeQuery:sql varArgs:args shouldReturnResult:YES];
    va_end(args);
    return [self objectsWithDBResult:result];
}

+ (NSArray *)allWhereInnerJoin:(NSString *)sql, ...
{
    va_list args;
    va_start(args, sql);
    sql = [[NSString stringWithFormat:@"SELECT $T.* FROM %@ INNER JOIN %@", self.tableName, sql] stringByReplacingOccurrencesOfString:@"$T"
                                                                                                                        withString:self.tableName];
    NSArray *result = [[FDB sharedInstance] executeQuery:sql varArgs:args shouldReturnResult:YES];
    va_end(args);
    return [self objectsWithDBResult:result];
}

+ (NSArray *)allWhereLeftJoin:(NSString *)sql, ...
{
    va_list args;
    va_start(args, sql);
    sql = [[NSString stringWithFormat:@"SELECT $T.* FROM %@ LEFT JOIN %@", self.tableName, sql] stringByReplacingOccurrencesOfString:@"$T"
                                                                                                                           withString:self.tableName];
    NSArray *result = [[FDB sharedInstance] executeQuery:sql varArgs:args shouldReturnResult:YES];
    va_end(args);
    return [self objectsWithDBResult:result];
}

+ (instancetype)firstWhere:(NSString *)sql, ...
{
    va_list args;
    va_start(args, sql);
    sql = [NSString stringWithFormat:@"SELECT * FROM %@ WHERE %@ LIMIT 1", self.tableName, sql];
    NSArray *result = [[FDB sharedInstance] executeQuery:sql varArgs:args shouldReturnResult:YES];
    va_end(args);
    return [[self objectsWithDBResult:result] lastObject];
}

+ (instancetype)firstWhereInnerJoin:(NSString *)sql, ...
{
    va_list args;
    va_start(args, sql);
    sql = [[NSString stringWithFormat:@"SELECT $T.* FROM %@ INNER JOIN %@ LIMIT 1", self.tableName, sql] stringByReplacingOccurrencesOfString:@"$T"
                                                                                                                           withString:self.tableName];
    NSArray *result = [[FDB sharedInstance] executeQuery:sql varArgs:args shouldReturnResult:YES];
    va_end(args);
    return [[self objectsWithDBResult:result] lastObject];
}

- (BOOL)delete
{
    [_databaseObjects[NSStringFromClass(self.class)] removeObjectForKey:self.id];
    BOOL success = [[FDB sharedInstance] executeUpdate:
            [NSString stringWithFormat:
             @"DELETE FROM %@ WHERE id = ?",
             self.class.tableName], self.id, nil];
    if (success) {
        [[NSFileManager defaultManager] removeItemAtPath:[[self.class contentPath] stringByAppendingPathComponent:[self.class normalizeName:self.id]]
                                                   error:nil];
        NSString *className = NSStringFromClass([self class]);
        for (id context in _deletionObservers[className]) {
            void(^block)(FDBObject *object, FDBEvent event) = [_contextBlockMap[className] objectForKey:context];
            dispatch_async(dispatch_get_main_queue(), ^{
                block(self, FDBEventDeletion);
            });
        }
    }
    return success;
}

+ (BOOL)deleteAllWhere:(NSString *)sql, ...
{
    va_list args;
    va_start(args, sql);
    NSString *selectSql = [NSString stringWithFormat:@"SELECT id FROM %@ WHERE %@", self.tableName, sql];
    NSArray *result = [[FDB sharedInstance] executeQuery:selectSql varArgs:args shouldReturnResult:YES];
    for (NSDictionary *res in result) {
        [[NSFileManager defaultManager] removeItemAtPath:[[self.class contentPath] stringByAppendingPathComponent:[self normalizeName:res[@"id"]]]
                                                   error:nil];
        [_databaseObjects[NSStringFromClass(self.class)] removeObjectForKey:res[@"id"]];
    }
    va_end(args);
    va_start(args, sql);
    sql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@", self.tableName, sql];
    BOOL success = !![[FDB sharedInstance] executeQuery:sql varArgs:args shouldReturnResult:NO];
    va_end(args);
    if (success) {
        NSString *className = NSStringFromClass([self class]);
        for (id context in _deletionObservers[NSStringFromClass(self.class)]) {
            void(^block)(FDBObject *object, FDBEvent event) = [_contextBlockMap[className] objectForKey:context];
            dispatch_async(dispatch_get_main_queue(), ^{
                block(nil, FDBEventDeletion);
            });
        }
    }
    return success;
}

- (BOOL)save
{
    NSMutableArray *databaseKeys = [[NSMutableArray alloc] init];
    NSDictionary *content = [FDBObject mapDictionary:self.__content withBlock:^NSString *(NSString *key, id value) {
        if (class_getProperty([self class], [key UTF8String])) {
            [databaseKeys addObject:key];
            return [self serializeProperty:key value:value];
        } else {
            return nil;
        }
    }];
    NSAssert(databaseKeys.count, @"Nothing to save");
    NSString *keyString = [databaseKeys componentsJoinedByString:@","];
    NSString *valueString = [@":" stringByAppendingString:[databaseKeys componentsJoinedByString:@",:"]];

    BOOL success = [self.class executeUpdate:
                    [NSString stringWithFormat:
                     @"INSERT OR REPLACE INTO $T (%@) VALUES (%@)", keyString, valueString],
                    content, nil];
    if (success) {
        NSString *className = NSStringFromClass(self.class);
        FDBObject *o = [_databaseObjects[className] objectForKey:self.id];
        if (o && o != (FDBObject *)[NSNull null]) {
            // Modification
            for (id context in _modificationObservers[className]) {
                void(^block)(FDBObject *object, FDBEvent event) = [_contextBlockMap[className] objectForKey:context];
                dispatch_async(dispatch_get_main_queue(), ^{
                    block(self, FDBEventModification);
                });
            }
        } else {
            // New object
            [_databaseObjects[className] setObject:self forKey:self.id];
            for (id context in _insertionObservers[className]) {
                void(^block)(FDBObject *object, FDBEvent event) = [_contextBlockMap[className] objectForKey:context];
                dispatch_async(dispatch_get_main_queue(), ^{
                    block(self, FDBEventInsertion);
                });
            }
        }
    }
    return success;
}

#pragma mark - Dynamic properties

#define PrimitiveCFunctionsForType(TYPENAME, TYPEGETTER, TYPESETTER) \
TYPENAME fdb_accessorGetterPrimitive##TYPENAME(FDBObject *self, SEL _cmd);\
TYPENAME fdb_accessorGetterPrimitive##TYPENAME(FDBObject *self, SEL _cmd)\
{\
NSString *method = NSStringFromSelector(_cmd);\
return [[self.__content valueForKey:method] TYPEGETTER];\
}\
void fdb_accessorSetterPrimitive##TYPENAME(FDBObject *self, SEL _cmd, TYPENAME newValue);\
void fdb_accessorSetterPrimitive##TYPENAME(FDBObject *self, SEL _cmd, TYPENAME newValue)\
{\
NSNumber *newValueObject = [NSNumber TYPESETTER:newValue];\
if (!newValueObject)\
return;\
NSString *method = NSStringFromSelector(_cmd);\
NSString *anID = [[[[[method substringFromIndex:3] substringToIndex:1] lowercaseString] stringByAppendingString:[method substringFromIndex:4]] substringToIndex:method.length - 4];\
[self.__content setValue:newValueObject forKey:anID];\
}

PrimitiveCFunctionsForType(NSUInteger, unsignedIntegerValue, numberWithUnsignedInteger)
PrimitiveCFunctionsForType(uint32_t, unsignedIntValue, numberWithUnsignedInt)

+ (BOOL)resolveInstanceMethod:(SEL)aSEL
{
    NSString *method = NSStringFromSelector(aSEL);
    NSString *propertyName = method;
    if ([method hasPrefix:@"set"]) {
        propertyName = [[[[[method substringFromIndex:3] substringToIndex:1] lowercaseString] stringByAppendingString:[method substringFromIndex:4]] substringToIndex:method.length - 4];
    }
    objc_property_t property = class_getProperty(self, [propertyName UTF8String]);
    if (property) {
        const char *type = property_getAttributes(property);
        NSString *typeString = [NSString stringWithUTF8String:type];
        NSArray *attributes = [typeString componentsSeparatedByString:@","];
        NSString *typeAttribute = [attributes objectAtIndex:0];
        NSString *propertyType = [typeAttribute substringFromIndex:1];
        const char *rawPropertyType = [propertyType UTF8String];
        if ([method hasPrefix:@"set"]) {
            if ([typeAttribute hasPrefix:@"T@\""]) {
                class_addMethod([self class], aSEL, (IMP)fdb_accessorSetter, "v@:@");
            } else if (strcmp(rawPropertyType, @encode(NSUInteger)) == 0) {
                class_addMethod([self class], aSEL, (IMP)fdb_accessorSetterPrimitiveNSUInteger, "v@:@");
            } else if (strcmp(rawPropertyType, @encode(uint32_t)) == 0) {
                class_addMethod([self class], aSEL, (IMP)fdb_accessorSetterPrimitiveuint32_t, "v@:@");
            } else {
                NSAssert(FALSE, @"Unknown type %s", rawPropertyType);
            }
            return YES;
        } else {
            if ([typeAttribute hasPrefix:@"T@\""]) {
                class_addMethod([self class], aSEL, (IMP)fdb_accessorGetter, "@@:");
            } else if (strcmp(rawPropertyType, @encode(NSUInteger)) == 0) {
                class_addMethod([self class], aSEL, (IMP)fdb_accessorGetterPrimitiveNSUInteger, "v@:@");
            } else if (strcmp(rawPropertyType, @encode(uint32_t)) == 0) {
                class_addMethod([self class], aSEL, (IMP)fdb_accessorGetterPrimitiveuint32_t, "v@:@");
            } else {
                NSAssert(FALSE, @"Unknown type %s", rawPropertyType);
            }
            return YES;
        }
    }
    return [super resolveInstanceMethod:aSEL];
}

id fdb_accessorGetter(FDBObject *self, SEL _cmd)
{
    NSString *method = NSStringFromSelector(_cmd);
    return [self.__content valueForKey:method];
}

void fdb_accessorSetter(FDBObject *self, SEL _cmd, id newValue)
{
    if (!newValue)
        return;

    NSString *method = NSStringFromSelector(_cmd);

    NSString *anID = [[[[[method substringFromIndex:3] substringToIndex:1] lowercaseString] stringByAppendingString:[method substringFromIndex:4]] substringToIndex:method.length - 4];
    [self.__content setValue:newValue forKey:anID];
}

#pragma mark -

+ (NSString *)contentPath
{
    static NSMutableDictionary *contentPaths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        contentPaths = [@{} mutableCopy];
    });
    NSString *className = NSStringFromClass([self class]);
    if (contentPaths[className])
        return contentPaths[className];

    NSString *contentPath = [[[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject]stringByAppendingPathComponent:@"FDB"] stringByAppendingPathComponent:[self normalizeName:className]];
    [[NSFileManager defaultManager] createDirectoryAtPath:contentPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    contentPaths[className] = contentPath;
    return contentPath;
}

+ (NSString *)normalizeName:(NSString *)name
{
    return name;
}

+ (NSMutableDictionary *)mapDictionary:(NSDictionary *)dictionary withBlock:(id(^)(id key, id value))block
{
    NSMutableDictionary *res = [[NSMutableDictionary alloc] initWithCapacity:dictionary.count];
    [dictionary enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        id value = block(key, obj);
        if (value) res[key] = value;
    }];
    return res;
}

#pragma mark - Events

+ (void)addObserverForEvents:(FDBEvent)events context:(id)context block:(void(^)(id object, FDBEvent event))block
{
    NSString *className = NSStringFromClass([self class]);
    if (!_insertionObservers[className]) {
        _insertionObservers[className] = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
        _deletionObservers[className] = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
        _modificationObservers[className] = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
        _contextBlockMap[className] = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                                            valueOptions:NSPointerFunctionsCopyIn];
    }
    if ((events & FDBEventInsertion) == FDBEventInsertion)
        [_insertionObservers[className] addObject:context];
    if ((events & FDBEventDeletion) == FDBEventDeletion)
        [_deletionObservers[className] addObject:context];
    if ((events & FDBEventModification) == FDBEventModification)
        [_modificationObservers[className] addObject:context];

    [_contextBlockMap[className] setObject:block forKey:context];
}

+ (void)removeObserverForContext:(id)context
{
    NSString *className = NSStringFromClass([self class]);
    [_insertionObservers[className] removeObject:context];
    [_deletionObservers[className] removeObject:context];
    [_modificationObservers[className] removeObject:context];
    [_contextBlockMap[className] removeObjectForKey:context];
}

- (NSString *)serializeProperty:(NSString *)propertyName value:(id)value
{
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    } else if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    } else if ([value isKindOfClass:[NSDate class]]) {
        return [@([value timeIntervalSince1970]) stringValue];
    } else if ([value isKindOfClass:[NSData class]]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:[[self.class contentPath] stringByAppendingPathComponent:[self.class normalizeName:self.id]]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [(NSData *)value writeToFile:[[[self.class contentPath] stringByAppendingPathComponent:[self.class normalizeName:self.id]] stringByAppendingPathComponent:[self.class normalizeName:propertyName]]
                          atomically:YES];
        return propertyName;
    } else if ([value isKindOfClass:[NSArray class]] ||
               [value isKindOfClass:[NSDictionary class]]) {
        return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value
                                                                              options:0
                                                                                error:nil]
                                     encoding:NSUTF8StringEncoding];
    } else {
        NSLog(@"Unknown type %@ for %@ (%@)", NSStringFromClass([value class]), propertyName, value);
    }
    return nil;
}

- (id)deserializeProperty:(NSString *)propertyName value:(NSString *)value
{
    objc_property_t property = class_getProperty(self.class, [propertyName UTF8String]);
    NSAssert1(property, @"Property %@ does not exist.", propertyName);
    const char *attrs = property_getAttributes(property);
    if (attrs[0] == 'T' && attrs[1] == '@' && attrs[2] == '"') {
        attrs = &(attrs[3]);
    } else {
        // Primitives
        return [[[NSNumberFormatter alloc] init] numberFromString:value];
    }
    if (strncmp(attrs, "NSString", strlen("NSString")) == 0) {
        return value;
    } else if (strncmp(attrs, "NSNumber", strlen("NSNumber")) == 0) {
        return [[[NSNumberFormatter alloc] init] numberFromString:value];
    } else if (strncmp(attrs, "NSDate", strlen("NSDate")) == 0) {
        return [NSDate dateWithTimeIntervalSince1970:[[[[NSNumberFormatter alloc] init] numberFromString:value] doubleValue]];
    } else if (strncmp(attrs, "NSData", strlen("NSData")) == 0) {
        return [NSData dataWithContentsOfFile:[[[self.class contentPath] stringByAppendingPathComponent:[self.class normalizeName:self.id]] stringByAppendingPathComponent:[self.class normalizeName:propertyName]]];
    } else {
        if (strncmp(attrs, "NSArray", strlen("NSArray")) != 0 &&
            strncmp(attrs, "NSDictionary", strlen("NSDictionary")) != 0 &&
            strncmp(attrs, "NSMutableArray", strlen("NSMutableArray")) != 0 &&
            strncmp(attrs, "NSMutableDictionary", strlen("NSMutableDictionary")) != 0) {
            NSLog(@"Unknown type %s for %@ (%@)", attrs, propertyName, value);
        }
        if (strncmp(attrs, "NSMutableArray", strlen("NSMutableArray")) == 0 ||
            strncmp(attrs, "NSMutableDictionary", strlen("NSMutableDictionary")) == 0) {
            return [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding]
                                                   options:NSJSONReadingAllowFragments | NSJSONReadingMutableContainers
                                                     error:nil];
        } else {
            return [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding]
                                                   options:NSJSONReadingAllowFragments
                                                     error:nil];
        }
    }
    return nil;
}

- (id)objectForKeyedSubscript:(NSString *)key
{
    return [self->___content objectForKeyedSubscript:key];
}

- (void)setObject:(id)obj forKeyedSubscript:(NSString *)key
{
    if (obj)
        [self->___content setObject:obj forKey:key];
    else
        [self->___content removeObjectForKey:key];
}
@end
