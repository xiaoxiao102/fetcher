/* Copyright 2014 Google Inc. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

#import <XCTest/XCTest.h>

#import "GTMSessionFetcherTestServer.h"
#import "GTMSessionFetcherService.h"

@interface GTMSessionFetcherServiceTest : XCTestCase {
  GTMSessionFetcherTestServer *_testServer;
  BOOL _isServerRunning;
}

@end

// File available in Tests folder.
static NSString *const kValidFileName = @"gettysburgaddress.txt";

@implementation GTMSessionFetcherServiceTest

- (NSString *)docRootPath {
  // Find a test file.
  NSBundle *testBundle = [NSBundle bundleForClass:[self class]];
  XCTAssertNotNil(testBundle);

  // Use the directory of the test file as the root directory for our server.
  NSString *docFolder = [testBundle resourcePath];
  return docFolder;
}

- (void)setUp {
  NSString *docRoot = [self docRootPath];

  _testServer = [[GTMSessionFetcherTestServer alloc] initWithDocRoot:docRoot];
  _isServerRunning = _testServer != nil;

  XCTAssertTrue(_isServerRunning,
                @">>> http test server failed to launch; skipping service tests\n");
}

- (void)tearDown {
  _testServer = nil;
  _isServerRunning = NO;
}

- (void)testFetcherService {
  if (!_isServerRunning) return;

  // Utility blocks for counting array entries for a specific host.
  NSUInteger (^URLsPerHost)(NSArray *, NSString *) = ^(NSArray *URLs, NSString *host) {
      NSUInteger counter = 0;
      for (NSURL *url in URLs) {
        if ([host isEqual:[url host]]) {
          counter++;
        }
      }
      return counter;
  };

  NSUInteger (^FetchersPerHost) (NSArray *, NSString *) = ^(NSArray *fetchers, NSString *host) {
      NSArray *fetcherURLs = [fetchers valueForKeyPath:@"mutableRequest.URL"];
      return URLsPerHost(fetcherURLs, host);
  };

  // Utility block for finding the minimum priority fetcher for a specific host.
  NSInteger (^PriorityPerHost) (NSArray *, NSString *) = ^(NSArray *fetchers, NSString *host) {
      NSInteger val = NSIntegerMax;
      for (GTMSessionFetcher *fetcher in fetchers) {
        if ([host isEqual:[[fetcher.mutableRequest URL] host]]) {
          val = MIN(val, fetcher.servicePriority);
        }
      }
      return val;
  };

  // We'll verify we fetched from the server the same data that is on disk.
  NSString *gettysburgPath = [_testServer localPathForFile:kValidFileName];
  NSData *gettysburgAddress = [NSData dataWithContentsOfFile:gettysburgPath];

  // We'll create 10 fetchers.  Only 2 should run simultaneously.
  // 1 should fail; the rest should succeeed.
  const NSUInteger kMaxRunningFetchersPerHost = 2;

  NSString *const kUserAgent = @"ServiceTest-UA";

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.maxRunningFetchersPerHost = kMaxRunningFetchersPerHost;
  service.userAgent = kUserAgent;
  service.allowLocalhostRequest = YES;

  // Make URLs for a valid fetch, a fetch that returns a status error,
  // and a valid fetch with a different host.
  NSURL *validFileURL = [_testServer localURLForFile:kValidFileName];

  NSString *invalidFile = [kValidFileName stringByAppendingString:@"?status=400"];
  NSURL *invalidFileURL = [_testServer localURLForFile:invalidFile];

  NSURL *altValidURL = [_testServer localv6URLForFile:invalidFile];

  XCTAssertEqualObjects([validFileURL host], @"localhost", @"unexpected host");
  XCTAssertEqualObjects([invalidFileURL host], @"localhost", @"unexpected host");
  XCTAssertEqualObjects([altValidURL host], @"::1", @"unexpected host");

  // Make an array with the urls from the different hosts, including one
  // that will fail with a status 400 error.
  NSMutableArray *urlArray = [NSMutableArray array];
  for (int idx = 1; idx <= 4; idx++) [urlArray addObject:validFileURL];
  [urlArray addObject:invalidFileURL];
  for (int idx = 1; idx <= 5; idx++) [urlArray addObject:validFileURL];
  for (int idx = 1; idx <= 5; idx++) [urlArray addObject:altValidURL];
  for (int idx = 1; idx <= 5; idx++) [urlArray addObject:validFileURL];
  NSUInteger totalNumberOfFetchers = [urlArray count];

  __block NSMutableArray *pending = [NSMutableArray array];
  __block NSMutableArray *running = [NSMutableArray array];
  __block NSMutableArray *completed = [NSMutableArray array];

  NSUInteger priorityVal = 0;

  // Create all the fetchers.
  NSMutableArray *fetchersInFlight = [NSMutableArray array];
  NSMutableArray *observers = [NSMutableArray array];
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  for (NSURL *fileURL in urlArray) {
    GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];

    // Fetcher start notification.
    id startObserver = [nc addObserverForName:kGTMSessionFetcherStartedNotification
                                       object:fetcher
                                        queue:nil
                                   usingBlock:^(NSNotification *note) {
        // Verify that we have at most two fetchers running for this fetcher's host.
        [running addObject:fetcher];
        [pending removeObject:fetcher];

        NSMutableURLRequest *fetcherReq = [fetcher mutableRequest];
        NSURL *fetcherReqURL = [fetcherReq URL];
        NSString *host = [fetcherReqURL host];
        NSUInteger numberRunning = FetchersPerHost(running, host);
        XCTAssertTrue(numberRunning > 0, @"count error");
        XCTAssertTrue(numberRunning <= kMaxRunningFetchersPerHost, @"too many running");

        NSInteger pendingPriority = PriorityPerHost(pending, host);
        XCTAssertTrue(fetcher.servicePriority <= pendingPriority,
                      @"a pending fetcher has greater priority");

        XCTAssertEqual([service numberOfFetchers],
                       [running count] + [pending count],
                       @"fetcher count off");
        XCTAssertEqual([service numberOfRunningFetchers], [running count], @"running off");
        XCTAssertEqual([service numberOfDelayedFetchers], [pending count], @"delayed off");

        NSArray *knownToService = [running arrayByAddingObjectsFromArray:pending];
        XCTAssertEqualObjects([NSCountedSet setWithArray:[service issuedFetchers]],
                              [NSCountedSet setWithArray:knownToService]);

        NSArray *matches = [service issuedFetchersWithRequestURL:fetcherReqURL];
        NSUInteger idx = NSNotFound;
        if (matches) {
          idx = [matches indexOfObjectIdenticalTo:fetcher];
        }
        XCTAssertTrue(idx != NSNotFound, @"Missing %@ in %@", fetcherReqURL, matches);
        NSURL *fakeURL = [NSURL URLWithString:@"http://example.com/bad"];
        matches = [service issuedFetchersWithRequestURL:fakeURL];
        XCTAssertEqual([matches count], (NSUInteger)0);

        NSString *agent = [fetcherReq valueForHTTPHeaderField:@"User-Agent"];
        XCTAssertEqualObjects(agent, kUserAgent);
    }];
    [observers addObject:startObserver];

    // Fetcher stopped notification.
    id stopObserver = [nc addObserverForName:kGTMSessionFetcherStoppedNotification
                                      object:fetcher
                                       queue:nil
                                  usingBlock:^(NSNotification *note) {
        // Verify that we only have two fetchers running.
        [completed addObject:fetcher];
        [running removeObject:fetcher];

        NSString *host = [[[fetcher mutableRequest] URL] host];

        NSUInteger numberRunning = FetchersPerHost(running, host);
        NSUInteger numberPending = FetchersPerHost(pending, host);
        NSUInteger numberCompleted = FetchersPerHost(completed, host);

        XCTAssertTrue(numberRunning <= kMaxRunningFetchersPerHost, @"too many running");
        XCTAssertTrue(numberPending + numberRunning + numberCompleted <= URLsPerHost(urlArray, host),
                      @"%d issued running (pending:%u running:%u completed:%u)",
                      (unsigned int)totalNumberOfFetchers, (unsigned int)numberPending,
                      (unsigned int)numberRunning, (unsigned int)numberCompleted);

        NSArray *knownToService =
            [[running arrayByAddingObjectsFromArray:pending] arrayByAddingObject:fetcher];
        XCTAssertEqualObjects([NSCountedSet setWithArray:[service issuedFetchers]],
                              [NSCountedSet setWithArray:knownToService]);

        XCTAssertEqual([service numberOfFetchers], [running count] + [pending count] + 1,
                       @"fetcher count off");
        XCTAssertEqual([service numberOfRunningFetchers], [running count] + 1, @"running off");
        XCTAssertEqual([service numberOfDelayedFetchers], [pending count], @"delayed off");
    }];
    [observers addObject:stopObserver];

    [pending addObject:fetcher];

    // Set the fetch priority to a value that cycles 0, 1, -1, 0, ...
    priorityVal++;
    if (priorityVal > 1) priorityVal = -1;
    fetcher.servicePriority = priorityVal;

    // Start this fetcher.
    [fetchersInFlight addObject:fetcher];
    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
        // Callback.
        XCTAssert([fetchersInFlight containsObject:fetcher]);
        [fetchersInFlight removeObjectIdenticalTo:fetcher];

        // The query should be empty except for the URL with a status code.
        NSString *query = [[[fetcher mutableRequest] URL] query];
        BOOL isValidRequest = ([query length] == 0);
        if (isValidRequest) {
          XCTAssertEqualObjects(fetchData, gettysburgAddress, @"Bad fetch data");
          XCTAssertNil(fetchError, @"unexpected %@ %@", fetchError, [fetchError userInfo]);
        } else {
          // This is the query with ?status=400.
          XCTAssertEqual([fetchError code], (NSInteger)400, @"expected error");
        }
    }];
  }

  [service waitForCompletionOfAllFetchersWithTimeout:15];

  XCTAssertEqual([pending count], (NSUInteger)0, @"still pending: %@", pending);
  XCTAssertEqual([running count], (NSUInteger)0, @"still running: %@", running);
  XCTAssertEqual([completed count], (NSUInteger)totalNumberOfFetchers, @"incomplete");
  XCTAssertEqual([fetchersInFlight count], (NSUInteger)0, @"Uncompleted: %@", fetchersInFlight);

  XCTAssertEqual([service numberOfFetchers], (NSUInteger)0, @"service non-empty");

  for (id observer in observers) {
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
  }
}

- (void)testStopAllFetchers {
  if (!_isServerRunning) return;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.maxRunningFetchersPerHost = 2;
  service.allowLocalhostRequest = YES;

  // Create three fetchers for each of two URLs, so there should be
  // two running and one delayed for each.
  NSURL *validFileURL = [_testServer localURLForFile:kValidFileName];
  NSURL *altValidURL = [_testServer localv6URLForFile:kValidFileName];

  // Add three fetches for each URL.
  NSArray *urlArray = @[
      validFileURL, altValidURL, validFileURL, altValidURL, validFileURL, altValidURL
  ];

  // Create and start all the fetchers.
  for (NSURL *fileURL in urlArray) {
    GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];
    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
        // We shouldn't reach any of the callbacks.
        XCTFail(@"Fetcher completed but should have been stopped");
    }];
  }

  // Two hosts.
  XCTAssertEqual([service.runningFetchersByHost count], (NSUInteger)2, @"hosts running");
  XCTAssertEqual([service.delayedFetchersByHost count], (NSUInteger)2, @"hosts delayed");

  // We should see two fetchers running and one delayed for each host.
  NSArray *localhosts = [service.runningFetchersByHost objectForKey:@"localhost"];
  XCTAssertEqual([localhosts count], (NSUInteger)2, @"hosts running");

  localhosts = [service.delayedFetchersByHost objectForKey:@"localhost"];
  XCTAssertEqual([localhosts count], (NSUInteger)1, @"hosts delayed");

  [service stopAllFetchers];

  XCTAssertEqual([service.runningFetchersByHost count], (NSUInteger)0, @"hosts running");
  XCTAssertEqual([service.delayedFetchersByHost count], (NSUInteger)0, @"hosts delayed");
}

- (void)testSessionReuse {
  if (!_isServerRunning) return;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.allowLocalhostRequest = YES;

  const NSTimeInterval kUnusedSessionTimeout = 3.0;
  service.unusedSessionTimeout = kUnusedSessionTimeout;

  NSURL *validFileURL = [_testServer localURLForFile:kValidFileName];

  NSArray *urlArray = @[ validFileURL, validFileURL, validFileURL, validFileURL ];
  NSMutableSet *uniqueSessions = [NSMutableSet set];
  NSMutableSet *uniqueTasks = [NSMutableSet set];
  __block NSUInteger completedFetchCounter = 0;

  //
  // Create and start all the fetchers without reusing the session.
  //
  service.reuseSession = NO;
  for (NSURL *fileURL in urlArray) {
    GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];
    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
      ++completedFetchCounter;
      XCTAssertNotNil(fetchData);
      XCTAssertNil(fetchError);
    }];
    [uniqueSessions addObject:[NSValue valueWithNonretainedObject:fetcher.session]];
    [uniqueTasks addObject:[NSValue valueWithNonretainedObject:fetcher.sessionTask]];

    XCTAssertEqual(fetcher.session.delegate, fetcher);
  }
  XCTAssertTrue([service waitForCompletionOfAllFetchersWithTimeout:10]);

  // We should have one unique session per fetcher.
  XCTAssertEqual(completedFetchCounter, [urlArray count]);
  XCTAssertEqual([uniqueTasks count], [urlArray count]);
  XCTAssertEqual([uniqueSessions count], [urlArray count], @"%@", uniqueSessions);
  XCTAssertNil([service session]);
  XCTAssertNil([service sessionDelegate]);

  // Inside the delegate dispatcher, there should now be a nil map of tasks to fetchers.
  NSDictionary *taskMap = [(id)service.sessionDelegate valueForKey:@"taskToFetcherMap"];
  XCTAssertNil(taskMap);

  //
  // Now reuse the session for multiple fetches.
  //
  [uniqueSessions removeAllObjects];
  [uniqueTasks removeAllObjects];
  [service resetSession];
  completedFetchCounter = 0;

  service.reuseSession = YES;
  for (NSURL *fileURL in urlArray) {
    GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];
    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
      ++completedFetchCounter;
      XCTAssertNotNil(fetchData);
      XCTAssertNil(fetchError);
    }];
    [uniqueSessions addObject:[NSValue valueWithNonretainedObject:fetcher.session]];
    [uniqueTasks addObject:[NSValue valueWithNonretainedObject:fetcher.sessionTask]];

    XCTAssertEqual(fetcher.session.delegate, service.sessionDelegate);
  }
  XCTAssertTrue([service waitForCompletionOfAllFetchersWithTimeout:10]);

  // We should have used two sessions total.
  XCTAssertEqual(completedFetchCounter, [urlArray count]);
  XCTAssertEqual([uniqueTasks count], [urlArray count]);
  XCTAssertEqual([uniqueSessions count], (NSUInteger)1, @"%@", uniqueSessions);

  // Inside the delegate dispatcher, there should be an empty map of tasks to fetchers.
  taskMap = [(id)service.sessionDelegate valueForKey:@"taskToFetcherMap"];
  XCTAssertEqualObjects(taskMap, @{ });

  // Because we set kUnusedSessionDiscardInterval to 3 seconds earlier, there
  // should still be a remembered session immediately after the fetches finish.
  NSURLSession *session = [service session];
  XCTAssertNotNil(session);

  // Wait up to 5 seconds for the sessions to become invalid.
  XCTestExpectation *exp = [self expectationWithDescription:@"sessioninvalid"];

  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  id observer = [nc addObserverForName:kGTMSessionFetcherServiceSessionBecameInvalidNotification
                                object:service
                                 queue:nil
                            usingBlock:^(NSNotification *note) {
    NSURLSession *invalidSession = [note.userInfo objectForKey:kGTMSessionFetcherServiceSessionKey];
    XCTAssertEqualObjects(invalidSession, session);
    [exp fulfill];
  }];
  [self waitForExpectationsWithTimeout:5.0 handler:nil];

  // Unlike right after the fetches finish, now the session should be nil.
  XCTAssertNil(service.session);

  [nc removeObserver:observer];
}

- (void)testSessionAbandonment {
  if (!_isServerRunning) return;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.allowLocalhostRequest = YES;
  service.reuseSession = YES;
  service.maxRunningFetchersPerHost = 2;

  const NSTimeInterval kUnusedSessionTimeout = 3.0;
  service.unusedSessionTimeout = kUnusedSessionTimeout;

  NSURL *validFileURL = [_testServer localURLForFile:kValidFileName];
  NSArray *urlArray = @[ validFileURL, validFileURL, validFileURL, validFileURL ];

  __block int numberOfCallsBack = 0;
  __block int numberOfErrors = 0;

  for (NSURL *fileURL in urlArray) {
    GTMSessionFetcher *fetcher = [service fetcherWithURL:fileURL];
    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
      if (fetchError != nil) {
        ++numberOfErrors;
      }

      // If NSURLSession had a suspended task, it won't have called its delegate,
      // so the fetcher will have manufactured a callback with a cancellation error.
      XCTAssert((fetchData != nil && fetchError == nil)
          || (fetchData == nil && fetchError.code == NSURLErrorCancelled),
                @"error=%@, data=%@", fetchError, fetchData);

      // On the first completion, we'll reset the session.
      ++numberOfCallsBack;
      if (numberOfCallsBack == 1) {
        [service resetSession];

        // Inside the delegate dispatcher, there should be a nil map of tasks to fetchers.
        NSDictionary *taskMap = [(id)service.sessionDelegate valueForKey:@"taskToFetcherMap"];
        XCTAssertNil(taskMap);
      }
    }];
  }
  XCTAssertTrue([service waitForCompletionOfAllFetchersWithTimeout:10]);

  // Here we verify that all fetchers were called back.
  XCTAssertEqual(numberOfCallsBack, (int)[urlArray count]);

  // On some builds (Mac/iOS and certain machines), all are succeeding; on some,
  // one finishes with an error, apparently a task ending up suspended when we
  // reset the session.  This may resolve as all builds migrate to a common version of
  // NSURLSession; if not, we should try to figure out why this is inconsistent.
  // On the simulator, all are succeeding.
  XCTAssertLessThanOrEqual(numberOfErrors, 1);
}

- (void)testFetcherServiceTestBlock {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  GTMSessionFetcherService *service = [[GTMSessionFetcherService alloc] init];
  service.allowedInsecureSchemes = @[ @"http" ];

  // Create four fetchers, with alternating success and failure test blocks.

  NSString *host = @"bad.example.com";
  NSData *resultData = [@"Freebles" dataUsingEncoding:NSUTF8StringEncoding];

  service.testBlock = ^(GTMSessionFetcher *fetcherToTest,
                        GTMSessionFetcherTestResponse testResponse) {
      NSData *fakedResultData;
      NSHTTPURLResponse *fakedResultResponse;
      NSError *fakedResultError;

      NSURL *requestURL = fetcherToTest.mutableRequest.URL;
      NSString *pathStr = requestURL.path.lastPathComponent;
      BOOL isOdd = (([pathStr intValue] % 2) != 0);
      if (isOdd) {
        // Succeed.
        fakedResultData = resultData;
        fakedResultResponse = [[NSHTTPURLResponse alloc] initWithURL:requestURL
                                                          statusCode:200
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:@{ @"Bearded" : @"Collie" }];
        fakedResultError = nil;
      } else {
        // Fail.
        fakedResultData = nil;
        fakedResultResponse = [[NSHTTPURLResponse alloc] initWithURL:requestURL
                                                          statusCode:500
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:@{ @"Afghan" : @"Hound" }];
        fakedResultError = [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                                               code:500
                                           userInfo:@{ kGTMSessionFetcherStatusDataKey : @"Oops" }];
      }

      testResponse(fakedResultResponse, fakedResultData, fakedResultError);
  };

  for (int idx = 1; idx < 5; idx++) {
    NSString *urlStr = [NSString stringWithFormat:@"http://%@/%d", host, idx];
    GTMSessionFetcher *fetcher = [service fetcherWithURLString:urlStr];

    [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
        BOOL isOdd = ((idx % 2) != 0);
        if (isOdd) {
          // Should have succeeded.
          XCTAssertEqualObjects(fetchData, resultData);
          XCTAssertNil(fetchError);
          XCTAssertEqual(fetcher.statusCode, (NSInteger)200);
          XCTAssertEqualObjects(fetcher.responseHeaders[@"Bearded"], @"Collie");
        } else {
          // Should have failed.
          XCTAssertNil(fetchData);
          XCTAssertEqual(fetchError.code, (NSInteger)500);
          XCTAssertEqual(fetcher.statusCode, 500);
          XCTAssertEqualObjects(fetcher.responseHeaders[@"Afghan"], @"Hound");
        }
    }];
  }

  XCTAssertEqual([[service.runningFetchersByHost objectForKey:host] count],
                 (NSUInteger)4);

  [service waitForCompletionOfAllFetchersWithTimeout:10];

  XCTAssertEqual([[service.runningFetchersByHost objectForKey:host] count],
                 (NSUInteger)0);
}

- (void)testMockCreationMethod {
  // No test server needed.
  _testServer = nil;
  _isServerRunning = NO;

  // Test with data.
  NSData *data = [@"abcdefg" dataUsingEncoding:NSUTF8StringEncoding];

  GTMSessionFetcherService *service =
      [GTMSessionFetcherService mockFetcherServiceWithFakedData:data
                                                     fakedError:nil];
  GTMSessionFetcher *fetcher = [service fetcherWithURLString:@"http://example.invalid"];

  XCTestExpectation *expectFinishedWithData = [self expectationWithDescription:@"Called back"];

  [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
    XCTAssertEqualObjects(fetchData, data);
    XCTAssertNil(fetchError);
    [expectFinishedWithData fulfill];
  }];
  [self waitForExpectationsWithTimeout:10 handler:nil];

  // Test with error.
  NSError *error = [NSError errorWithDomain:@"example.com" code:-321 userInfo:nil];
  service = [GTMSessionFetcherService mockFetcherServiceWithFakedData:nil
                                                           fakedError:error];
  fetcher = [service fetcherWithURLString:@"http://example.invalid"];

  XCTestExpectation *expectFinishedWithError = [self expectationWithDescription:@"Called back"];

  [fetcher beginFetchWithCompletionHandler:^(NSData *fetchData, NSError *fetchError) {
    XCTAssertNil(fetchData);
    XCTAssertEqualObjects(fetchError, error);
    [expectFinishedWithError fulfill];
  }];
  [self waitForExpectationsWithTimeout:10 handler:nil];
}

@end
