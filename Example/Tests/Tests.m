//
//  FDBTests.m
//  FDBTests
//
//  Created by Aleksejs Sinicins on 10/09/2014.
//  Copyright (c) 2014 Aleksejs Sinicins. All rights reserved.
//

#import <FDB/FDB.h>

@interface A : FDBObject

@property (copy, nonatomic) NSString *a;
@property (strong, nonatomic) NSNumber *b;
@property (strong, nonatomic) NSDate *c;
@property (strong, nonatomic) NSData *d;
@property (strong, nonatomic) NSArray *e;
@property (strong, nonatomic) NSDictionary *f;

@end
@implementation A
@dynamic a, b, c, d, e,f;

+ (BOOL (^)(FDB *, unsigned int *))migrate
{
    return ^BOOL(FDB *db, unsigned int *schemaVersion){
        __block BOOL success = YES;
        [db inTransaction:^(FDB *database, BOOL *rollback) {
            void(^failed)() = ^{
                *rollback = YES;
                success = NO;
            };
            if (*schemaVersion < 1) {
                if (![db executeUpdate:
                      @"CREATE TABLE A ("
                      @"    id        TEXT PRIMARY KEY,"
                      @"    a         TEXT,"
                      @"    b         TEXT,"
                      @"    c         TEXT,"
                      @"    d         TEXT,"
                      @"    e         TEXT,"
                      @"    f         TEXT"
                      @");",
                      nil]) return failed();
                *schemaVersion = 1;
            }
        }];
        NSAssert(success, @"Migration failed");
        return success;
    };
}

@end

SpecBegin(InitialSpecs)

describe(@"absctract object", ^{
    __block A *a;
    [FDB configureWithDatabaseFile:@"/tmp/testA"];
    it(@"cannot be found", ^{
        expect([A existsWithId:@"testObject"]).to.beFalsy();
    });
    
    it(@"can init", ^{
        a = [A new];
        a.id = @"testObject";
        expect(a).notTo.beNil();
    });

    it(@"can assign string", ^{
        a.a = @"test string";
        expect(a.a).to.equal(@"test string");
    });
    
    it(@"can be saved", ^{
        expect([a save]).to.beTruthy();
    });
    
    it(@"can be found by id", ^{
        A *b = [A withId:@"testObject"];
        expect(b).to.beAnInstanceOf(A.class);
    });
    
    it(@"can be found by property", ^{
        A *b = [A firstWhere:@"a = ?", @"test string", nil];
        expect(b).to.beAnInstanceOf(A.class);
    });
    
    it(@"can be destroyed", ^{
        expect([a delete]).to.beTruthy();
    });
    
    it(@"cannot be found again", ^{
        expect([A existsWithId:@"testObject"]).to.beFalsy();
    });
});

SpecEnd
