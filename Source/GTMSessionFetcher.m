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

#import "GTMSessionFetcher.h"

#import <sys/utsname.h>

// For iOS, the fetcher can declare itself a background task to allow fetches to finish
// up when the app leaves the foreground.  This is distinct from providing a background
// configuration, which allows out-of-process uploads and downloads.
#if TARGET_OS_IPHONE && !defined(GTM_BACKGROUND_TASK_FETCHING)
#define GTM_BACKGROUND_TASK_FETCHING 1
#endif

NSString *const kGTMSessionFetcherStartedNotification           = @"kGTMSessionFetcherStartedNotification";
NSString *const kGTMSessionFetcherStoppedNotification           = @"kGTMSessionFetcherStoppedNotification";
NSString *const kGTMSessionFetcherRetryDelayStartedNotification = @"kGTMSessionFetcherRetryDelayStartedNotification";
NSString *const kGTMSessionFetcherRetryDelayStoppedNotification = @"kGTMSessionFetcherRetryDelayStoppedNotification";

NSString *const kGTMSessionFetcherErrorDomain       = @"com.google.GTMSessionFetcher";
NSString *const kGTMSessionFetcherStatusDomain      = @"com.google.HTTPStatus";
NSString *const kGTMSessionFetcherStatusDataKey     = @"data";  // data returned with a kGTMSessionFetcherStatusDomain error

static NSString *const kGTMSessionIdentifierPrefix = @"com.google.GTMSessionFetcher";
static NSString *const kGTMSessionIdentifierDestinationFileURLMetadataKey = @"_destURL";
static NSString *const kGTMSessionIdentifierBodyFileURLMetadataKey        = @"_bodyURL";

// The default max retry interview is 10 minutes for uploads (POST/PUT/PATCH),
// 1 minute for downloads.
static const NSTimeInterval kUnsetMaxRetryInterval = -1.0;
static const NSTimeInterval kDefaultMaxDownloadRetryInterval = 60.0;
static const NSTimeInterval kDefaultMaxUploadRetryInterval = 60.0 * 10.;

static NSString * const kGTMSessionFetcherPersistedDestinationKey =
    @"com.google.GTMSessionFetcher.downloads";
//
// GTMSessionFetcher
//

#if 0
#define GTM_LOG_SESSION_DELEGATE(...) GTMSESSION_LOG_DEBUG(__VA_ARGS__)
#else
#define GTM_LOG_SESSION_DELEGATE(...)
#endif

#if 0
#define GTM_LOG_BACKGROUND_SESSION(...) GTMSESSION_LOG_DEBUG(__VA_ARGS__)
#else
#define GTM_LOG_BACKGROUND_SESSION(...)
#endif

@interface GTMSessionFetcher ()

@property(strong, readwrite) NSData *downloadedData;
@property(strong, readwrite) NSMutableURLRequest *mutableRequest;

@end

@interface GTMSessionFetcher (GTMSessionFetcherLoggingInternal)
- (void)logFetchWithError:(NSError *)error;
- (void)logNowWithError:(NSError *)error;
- (NSInputStream *)loggedInputStreamForInputStream:(NSInputStream *)inputStream;
- (GTMSessionFetcherBodyStreamProvider)loggedStreamProviderForStreamProvider:
    (GTMSessionFetcherBodyStreamProvider)streamProvider;
@end

static NSTimeInterval InitialMinRetryInterval(void) {
  return 1.0 + ((double)(arc4random_uniform(0x0FFFF)) / (double) 0x0FFFF);
}

static BOOL IsLocalhost(NSString *host) {
  return ([host caseInsensitiveCompare:@"localhost"] == NSOrderedSame
          || [host isEqual:@"::1"]
          || [host isEqual:@"127.0.0.1"]);
}

static GTMSessionFetcherTestBlock gGlobalTestBlock;

@implementation GTMSessionFetcher {
  NSMutableURLRequest *_request;
  NSURLSession *_session;
  NSURLSessionConfiguration *_configuration;
  NSURLSessionTask *_sessionTask;
  NSString *_taskDescription;
  NSURLResponse *_response;
  NSString *_sessionIdentifier;
  BOOL _didCreateSessionIdentifier;
  NSString *_sessionIdentifierUUID;
  BOOL _useBackgroundSession;
  NSMutableData *_downloadedData;
  NSError *_downloadMoveError;
  NSData *_downloadResumeData;
  NSURL *_destinationFileURL;
  int64_t _downloadedLength;
  NSURLCredential *_credential;     // username & password
  NSURLCredential *_proxyCredential; // credential supplied to proxy servers
  BOOL _isStopNotificationNeeded;   // set when start notification has been sent
  BOOL _isUsingTestBlock;  // set when a test block was provided (remains set when the block is released)
#if GTM_BACKGROUND_TASK_FETCHING
  UIBackgroundTaskIdentifier _backgroundTaskIdentifer;
#endif
  id _userData;                     // retained, if set by caller
  NSMutableDictionary *_properties; // more data retained for caller
  dispatch_queue_t _callbackQueue;
  dispatch_group_t _callbackGroup;

  id<GTMFetcherAuthorizationProtocol> _authorizer;

  // The service object that created and monitors this fetcher, if any
  id<GTMSessionFetcherServiceProtocol> _service;
  NSString *_serviceHost;
  NSInteger _servicePriority;
  BOOL _userStoppedFetching;

  BOOL _isRetryEnabled;             // user wants auto-retry
  NSTimer *_retryTimer;
  NSUInteger _retryCount;
  NSTimeInterval _maxRetryInterval; // default 60 (download) or 600 (upload) seconds
  NSTimeInterval _minRetryInterval; // random between 1 and 2 seconds
  NSTimeInterval _retryFactor;      // default interval multiplier is 2
  NSTimeInterval _lastRetryInterval;
  NSDate *_initialRequestDate;
  BOOL _hasAttemptedAuthRefresh;

  NSString *_comment;               // comment for log
  NSString *_log;
#if !STRIP_GTM_FETCH_LOGGING
  NSMutableData *_loggedStreamData;
  NSURL *_redirectedFromURL;
  NSString *_logRequestBody;
  NSString *_logResponseBody;
  BOOL _hasLoggedError;
  BOOL _deferResponseBodyLogging;
#endif
}

+ (void)load {
  [self restoreFetchersForBackgroundSessions];
}

+ (instancetype)fetcherWithRequest:(NSURLRequest *)request {
  return [[self alloc] initWithRequest:request configuration:nil];
}

+ (instancetype)fetcherWithURL:(NSURL *)requestURL {
  return [self fetcherWithRequest:[NSURLRequest requestWithURL:requestURL]];
}

+ (instancetype)fetcherWithURLString:(NSString *)requestURLString {
  return [self fetcherWithURL:[NSURL URLWithString:requestURLString]];
}

+ (instancetype)fetcherWithDownloadResumeData:(NSData *)resumeData {
  GTMSessionFetcher *fetcher = [self fetcherWithRequest:nil];
  fetcher.comment = @"Resuming download";
  fetcher.downloadResumeData = resumeData;
  return fetcher;
}

+ (instancetype)fetcherWithSessionIdentifier:(NSString *)sessionIdentifier {
  GTMSESSION_ASSERT_DEBUG(sessionIdentifier != nil, @"Invalid session identifier");
  NSMapTable *sessionIdentifierToFetcherMap = [self sessionIdentifierToFetcherMap];
  GTMSessionFetcher *fetcher = [sessionIdentifierToFetcherMap objectForKey:sessionIdentifier];
  if (!fetcher && [sessionIdentifier hasPrefix:kGTMSessionIdentifierPrefix]) {
    fetcher = [self fetcherWithRequest:nil];
    [fetcher setSessionIdentifier:sessionIdentifier];
    [sessionIdentifierToFetcherMap setObject:fetcher forKey:sessionIdentifier];
    [fetcher setCommentWithFormat:@"Resuming %@",
     fetcher && fetcher->_sessionIdentifierUUID ? fetcher->_sessionIdentifierUUID : @"?"];
  }
  return fetcher;
}

+ (NSMapTable *)sessionIdentifierToFetcherMap {
  // TODO: What if a service is involved in creating the fetcher? Currently, when re-creating
  // fetchers, if a service was involved, it is not re-created. Should the service maintain a map?
  static NSMapTable *gSessionIdentifierToFetcherMap = nil;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    gSessionIdentifierToFetcherMap = [NSMapTable strongToWeakObjectsMapTable];
  });
  return gSessionIdentifierToFetcherMap;
}

- (instancetype)init {
  return [self initWithRequest:nil configuration:nil];
}

- (instancetype)initWithRequest:(NSURLRequest *)request  {
  return [self initWithRequest:request configuration:nil];
}

- (instancetype)initWithRequest:(NSURLRequest *)request
                  configuration:(NSURLSessionConfiguration *)configuration {
  self = [super init];
  if (self) {
    if (![NSURLSession class]) {
      Class oldFetcherClass = NSClassFromString(@"GTMHTTPFetcher");
      if (oldFetcherClass) {
        self = [[oldFetcherClass alloc] initWithRequest:request];
      } else {
        self = nil;
      }
      return self;
    }
#if GTM_BACKGROUND_TASK_FETCHING
    _backgroundTaskIdentifer = UIBackgroundTaskInvalid;
#endif
    _request = [request mutableCopy];
    _configuration = configuration;

    NSData *bodyData = [request HTTPBody];
    if (bodyData) {
      _bodyLength = (int64_t)[bodyData length];
    } else {
      _bodyLength = NSURLSessionTransferSizeUnknown;
    }

    _callbackQueue = dispatch_get_main_queue();
    _callbackGroup = dispatch_group_create();

    _minRetryInterval = InitialMinRetryInterval();
    _maxRetryInterval = kUnsetMaxRetryInterval;

#if !STRIP_GTM_FETCH_LOGGING
    // Encourage developers to set the comment property or use
    // setCommentWithFormat: by providing a default string.
    _comment = @"(No fetcher comment set)";
#endif
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  // disallow use of fetchers in a copy property
  [self doesNotRecognizeSelector:_cmd];
  return nil;
}

- (NSString *)description {
  return [NSString stringWithFormat:@"%@ %p (%@)",
          [self class], self, [self.mutableRequest URL]];
}

- (void)dealloc {
  GTMSESSION_ASSERT_DEBUG(!_isStopNotificationNeeded,
                          @"unbalanced fetcher notification for %@", [_request URL]);
  [self forgetSessionIdentifierForFetcher];

  // Note: if a session task or a retry timer was pending, then this instance
  // would be retained by those so it wouldn't be getting dealloc'd,
  // hence we don't need to stopFetch here
}

#pragma mark -

// Begin fetching the URL (or begin a retry fetch).  The delegate is retained
// for the duration of the fetch connection.

- (void)beginFetchWithCompletionHandler:(GTMSessionFetcherCompletionHandler)handler {
  _completionHandler = handler;

  // The user may have called setDelegate: earlier if they want to use other
  // delegate-style callbacks during the fetch; otherwise, the delegate is nil,
  // which is fine.
  [self beginFetchMayDelay:YES mayAuthorize:YES];
}

- (GTMSessionFetcherCompletionHandler)completionHandlerWithTarget:(id)target
                                                didFinishSelector:(SEL)finishedSelector {
  GTMSessionFetcherAssertValidSelector(target, finishedSelector, @encode(GTMSessionFetcher *),
                                       @encode(NSData *), @encode(NSError *), 0);
  GTMSessionFetcherCompletionHandler completionHandler = ^(NSData *data, NSError *error) {
      if (target && finishedSelector) {
        id selfArg = self;  // Placate ARC.
        NSMethodSignature *sig = [target methodSignatureForSelector:finishedSelector];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        [invocation setSelector:finishedSelector];
        [invocation setTarget:target];
        [invocation setArgument:&selfArg atIndex:2];
        [invocation setArgument:&data atIndex:3];
        [invocation setArgument:&error atIndex:4];
        [invocation invoke];
      }
  };
  return completionHandler;
}

- (void)beginFetchWithDelegate:(id)target
             didFinishSelector:(SEL)finishedSelector {
  GTMSessionFetcherCompletionHandler handler =  [self completionHandlerWithTarget:target
                                                                didFinishSelector:finishedSelector];
  [self beginFetchWithCompletionHandler:handler];
}

- (void)beginFetchMayDelay:(BOOL)mayDelay
              mayAuthorize:(BOOL)mayAuthorize {
  // This is the internal entry point for re-starting fetches.

  // A utility block for creating error objects when we fail to start the fetch.
  NSError *(^beginFailureError)(NSInteger) = ^(NSInteger code){
    NSString *urlString = [[_request URL] absoluteString];
    NSDictionary *userInfo = @{
      NSURLErrorFailingURLStringErrorKey : (urlString ? urlString : @"(missing URL)")
    };
    return [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                               code:code
                           userInfo:userInfo];
  };

  if (_sessionTask != nil) {
    // If cached fetcher returned through fetcherWithSessionIdentifier:, then it's
    // already begun, but don't consider this a failure, since the user need not know this.
    if (_sessionIdentifier != nil) {
      return;
    }
    GTMSESSION_ASSERT_DEBUG(NO, @"Fetch object %@ being reused; this should never happen", self);
    [self failToBeginFetchWithError:beginFailureError(kGTMSessionFetcherErrorDownloadFailed)];
    return;
  }

  NSURL *requestURL = [_request URL];
  if (requestURL == nil && !_downloadResumeData && !_sessionIdentifier) {
    GTMSESSION_ASSERT_DEBUG(NO, @"Beginning a fetch requires a request with a URL");
    [self failToBeginFetchWithError:beginFailureError(kGTMSessionFetcherErrorDownloadFailed)];
    return;
  }

#if !GTM_ALLOW_INSECURE_REQUESTS
  if (requestURL != nil) {
    // Allow https only for requests, unless overridden by the client.
    //
    // Non-https requests may too easily be snooped, so we disallow them by default.
    //
    // file: and data: schemes are usually safe if they are hardcoded in the client or provided
    // by a trusted source, but since it's fairly rare to need them, it's safest to make clients
    // explicitly whitelist them.
    NSString *requestScheme = [requestURL scheme];
    BOOL isSecure = ([requestScheme caseInsensitiveCompare:@"https"] == NSOrderedSame);
    if (!isSecure) {
      BOOL allowRequest = NO;
      NSString *host = [requestURL host];
      if (IsLocalhost(host)) {
        if (_allowLocalhostRequest) {
          allowRequest = YES;
        } else {
          // To fetch from localhost, the fetcher must specifically have the allowLocalhostRequest
          // property set.
#if DEBUG
          GTMSESSION_ASSERT_DEBUG(NO, @"Fetch request for localhost but fetcher"
                                  @" allowLocalhostRequest is not set: %@", requestURL);
#else
          NSLog(@"Localhost fetch disallowed for %@", requestURL);
#endif
        }
      } else {
        // Not localhost; check schemes.
        for (NSString *allowedScheme in _allowedInsecureSchemes) {
          if ([requestScheme caseInsensitiveCompare:allowedScheme] == NSOrderedSame) {
            allowRequest = YES;
            break;
          }
        }
        if (!allowRequest) {
          // To make a request other than https:, the client must specify an array for the
          // allowedInsecureSchemes property.
#if DEBUG
          GTMSESSION_ASSERT_DEBUG(NO, @"Insecure fetch request has a scheme (%@)"
                                  @" not found in fetcher allowedInsecureSchemes (%@): %@",
                                  requestScheme, _allowedInsecureSchemes, requestURL);
#else
          NSLog(@"Fetch disallowed for %@", requestURL);
#endif
        }
      }
      if (!allowRequest) {
        [self failToBeginFetchWithError:beginFailureError(kGTMSessionFetcherErrorInsecureRequest)];
        return;
      }
    }  // !isSecure
  }  // requestURL != nil
#endif  // GTM_ALLOW_INSECURE_REQUESTS

  if (_cookieStorage == nil) {
    _cookieStorage = [[self class] staticCookieStorage];
  }

  BOOL isRecreatingSession = (_sessionIdentifier != nil) && (_request == nil);

  if (!_session) {
    // Create a session.
    if (!_configuration) {
      if (_sessionIdentifier || _useBackgroundSession) {
        if (!_sessionIdentifier) {
          [self createSessionIdentifierWithMetadata:nil];
        }
        NSMapTable *sessionIdentifierToFetcherMap = [[self class] sessionIdentifierToFetcherMap];
        [sessionIdentifierToFetcherMap setObject:self forKey:_sessionIdentifier];

#if (!TARGET_OS_IPHONE && defined(MAC_OS_X_VERSION_10_10) && MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_10) \
    || (TARGET_OS_IPHONE && defined(__IPHONE_8_0) && __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_8_0)
        // iOS 8/10.10 builds require the new backgroundSessionConfiguration method name.
        _configuration =
            [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:_sessionIdentifier];
#else
        _configuration =
            [NSURLSessionConfiguration backgroundSessionConfiguration:_sessionIdentifier];
#endif
        _useBackgroundSession = YES;
      } else {
        _configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
      }
      _configuration.TLSMinimumSupportedProtocol = kTLSProtocol12;
    }
    _configuration.HTTPCookieStorage = _cookieStorage;

    if (_configurationBlock) {
      _configurationBlock(self, _configuration);
    }

    _session = [NSURLSession sessionWithConfiguration:_configuration
                                             delegate:self
                                        delegateQueue:[NSOperationQueue mainQueue]];
    GTMSESSION_ASSERT_DEBUG(_session, @"Couldn't create session");

    // If this assertion fires, the client probably tried to use a session identifier that was
    // already used. The solution is to make the client use a unique identifier (or better yet let
    // the session fetcher assign the identifier).
    GTMSESSION_ASSERT_DEBUG(_session.delegate == self, @"Couldn't assign delegate.");
  }

  if (isRecreatingSession) {
    // Let's make sure there are tasks still running or if not that we get a callback from a
    // completed one; otherwise, we assume the tasks failed.
    // This is the observed behavior perhaps 25% of the time within the Simulator running 7.0.3 on
    // exiting the app after starting an upload and relaunching the app if we manage to relaunch
    // after the task has completed, but before the system relaunches us in the background.
    [_session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks,
                                              NSArray *downloadTasks) {
      if ([dataTasks count] == 0 && [uploadTasks count] == 0 && [downloadTasks count] == 0) {
        double const kDelayInSeconds = 1.0;  // We should get progress indication or completion soon
        dispatch_time_t checkForFeedbackDelay =
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelayInSeconds * NSEC_PER_SEC));
        dispatch_after(checkForFeedbackDelay, dispatch_get_main_queue(), ^{
          if (!_sessionTask && !_request) {
            // If our task and/or request haven't been restored, then we assume task feedback lost.
            [self removePersistedBackgroundSessionFromDefaults];
            NSError *sessionError =
                [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                                    code:kGTMSessionFetcherErrorBackgroundFetchFailed
                                userInfo:nil];
            [self failToBeginFetchWithError:sessionError];
          }
        });
      }
    }];
    return;
  }

  self.downloadedData = nil;
  _downloadedLength = 0;

  if (mayDelay && _service) {
    BOOL shouldFetchNow = [_service fetcherShouldBeginFetching:self];
    if (!shouldFetchNow) {
      // The fetch is deferred, but will happen later
      return;
    }
  }

  NSString *effectiveHTTPMethod = [_request valueForHTTPHeaderField:@"X-HTTP-Method-Override"];
  if (effectiveHTTPMethod == nil) {
    effectiveHTTPMethod = [_request HTTPMethod];
  }
  BOOL isEffectiveHTTPGet = (effectiveHTTPMethod == nil
                             || [effectiveHTTPMethod isEqual:@"GET"]);

  BOOL needsUploadTask = (_useUploadTask || _bodyFileURL || _bodyStreamProvider);
  if (_bodyData || _bodyStreamProvider || _request.HTTPBodyStream) {
    if (isEffectiveHTTPGet) {
      [_request setHTTPMethod:@"POST"];
      isEffectiveHTTPGet = NO;
    }

    if (_bodyData) {
      if (!needsUploadTask) {
        [_request setHTTPBody:_bodyData];
      }
#if !STRIP_GTM_FETCH_LOGGING
    } else if (_request.HTTPBodyStream) {
      if ([self respondsToSelector:@selector(loggedInputStreamForInputStream:)]) {
        _request.HTTPBodyStream = [self performSelector:@selector(loggedInputStreamForInputStream:)
                                             withObject:_request.HTTPBodyStream];
      }
#endif
    }
  }

  // We authorize after setting up the http method and body in the request
  // because OAuth 1 may need to sign the request body
  if (mayAuthorize && _authorizer) {
    BOOL isAuthorized = [_authorizer isAuthorizedRequest:_request];
    if (!isAuthorized) {
      // Authorization needed.  This will recursively call this beginFetch:mayDelay:
      // or failToBeginFetchWithError:.
      [self authorizeRequest];
      return;
    }
  }

  // set the default upload or download retry interval, if necessary
  if (_isRetryEnabled && _maxRetryInterval <= 0) {
    if (isEffectiveHTTPGet || [effectiveHTTPMethod isEqual:@"HEAD"]) {
      [self setMaxRetryInterval:kDefaultMaxDownloadRetryInterval];
    } else {
      [self setMaxRetryInterval:kDefaultMaxUploadRetryInterval];
    }
  }

  // finally, start the connection
  BOOL needsDataAccumulator = NO;
  if (_downloadResumeData) {
    _sessionTask = [_session downloadTaskWithResumeData:_downloadResumeData];
  } else if (_destinationFileURL) {
    _sessionTask = [_session downloadTaskWithRequest:_request];
  } else if (needsUploadTask) {
    if (_bodyFileURL) {
      _sessionTask = [_session uploadTaskWithRequest:_request fromFile:_bodyFileURL];
    } else if (_bodyStreamProvider) {
      _sessionTask = [_session uploadTaskWithStreamedRequest:_request];
    } else {
      GTMSESSION_ASSERT_DEBUG(_bodyData != nil, @"upload task needs body data");
      _sessionTask = [_session uploadTaskWithRequest:_request fromData:_bodyData];
    }
    needsDataAccumulator = YES;
  } else {
    _sessionTask = [_session dataTaskWithRequest:_request];
    needsDataAccumulator = YES;
  }
  if (needsDataAccumulator && _accumulateDataBlock == nil) {
    self.downloadedData = [NSMutableData data];
  }
  [self addPersistedBackgroundSessionToDefaults];

  if (_taskDescription) {
    _sessionTask.taskDescription = _taskDescription;
  }
  if (!_testBlock) {
    if (gGlobalTestBlock) {
      // Note that the test block may pass nil for all of its response parameters,
      // indicating that the fetch should actually proceed. This is useful when the
      // global test block has been set, and the app is only testing a specific
      // fetcher.  The block simulation code will then resume the task.
      _testBlock = gGlobalTestBlock;
    } else {
      [_sessionTask resume];
    }
  }
  _isUsingTestBlock = (_testBlock != nil);

#if GTM_BACKGROUND_TASK_FETCHING
  // Background tasks seem to interfere with out-of-process uploads and downloads.
  if (!_useBackgroundSession) {
    // Tell UIApplication that we want to continue even when the app is in the
    // background.
    UIApplication *app = [UIApplication sharedApplication];
    _backgroundTaskIdentifer = [app beginBackgroundTaskWithExpirationHandler:^{
      // Background task expiration callback - this block is always invoked by
      // UIApplication on the main thread.
      [self backgroundFetchExpired];
    }];
  }
#endif

  if (!_initialRequestDate) {
    _initialRequestDate = [[NSDate alloc] init];
  }

  // Once _connection is non-nil we can send the start notification
  //
  // We don't expect to reach here even on retry or auth until a stop notification has been sent
  // for the previous task, but we should ensure that we don't unbalance that.
  GTMSESSION_ASSERT_DEBUG(!_isStopNotificationNeeded, @"Start notification without a prior stop");
  [self sendStopNotificationIfNeeded];

  _isStopNotificationNeeded = YES;
  NSNotificationCenter *defaultNC = [NSNotificationCenter defaultCenter];
  [defaultNC postNotificationName:kGTMSessionFetcherStartedNotification
                           object:self];

  if (_testBlock) {
    [self simulateFetchForTestBlock];
  }
}

- (void)simulateFetchForTestBlock {
  _testBlock(self, ^(NSURLResponse *response, NSData *responseData, NSError *error) {
      // Callback from test block.
      if (response == nil && responseData == nil && error == nil) {
        // Assume the fetcher should execute rather than be tested.
        _testBlock = nil;
        _isUsingTestBlock = NO;
        [_sessionTask resume];
        return;
      }

      if (_bodyStreamProvider) {
        // Read from the input stream into an NSData buffer.
        [self invokeOnCallbackQueueUnlessStopped:^{
          _bodyStreamProvider(^(NSInputStream *bodyStream){
            NSMutableData *streamedData = [NSMutableData data];
            [bodyStream open];
            while ([bodyStream hasBytesAvailable]) {
              uint8_t buffer[512];
              NSInteger numberOfBytesRead = [bodyStream read:buffer maxLength:sizeof(buffer)];
              if (numberOfBytesRead > 0) {
                [streamedData appendBytes:buffer length:(NSUInteger)numberOfBytesRead];
              }
            }
            [bodyStream close];
            NSError *streamError = [bodyStream streamError];
            [self simulateDataCallbacksForTestBlockWithBodyData:streamedData
                                                       response:response
                                                   responseData:responseData
                                                          error:streamError];
          });
        }];
      } else {
        // No input stream; use the supplied data or file URL.
        if (_bodyFileURL) {
          NSError *readError;
          _bodyData = [NSData dataWithContentsOfURL:_bodyFileURL
                                            options:NSDataReadingMappedIfSafe
                                              error:&readError];
          error = readError;
        }

        // No body URL or stream provider.
        [self simulateDataCallbacksForTestBlockWithBodyData:_bodyData
                                                   response:response
                                               responseData:responseData
                                                      error:error];
      }
    });
}

- (void)simulateByteTransferReportWithDataLength:(int64_t)totalDataLength
                                           block:(GTMSessionFetcherSendProgressBlock)block {
  // This utility method simulates transfer progress with up to three callbacks.
  // It is used to call back to any of the progress blocks.
  int64_t sendReportSize = totalDataLength / 3 + 1;
  int64_t totalSent = 0;
  while (totalSent < totalDataLength) {
    int64_t bytesRemaining = totalDataLength - totalSent;
    sendReportSize = MIN(sendReportSize, bytesRemaining);
    totalSent += sendReportSize;
    [self invokeOnCallbackQueueUnlessStopped:^{
        block(sendReportSize, totalSent, totalDataLength);
    }];
  }
}

- (void)simulateDataCallbacksForTestBlockWithBodyData:(NSData *)bodyData
                                             response:(NSURLResponse *)response
                                         responseData:(NSData *)responseData
                                                error:(NSError *)error {
  // This method does the test simulation of callbacks once the upload
  // and download data are known.

  // Simulate reporting send progress.
  if (_sendProgressBlock) {
    [self simulateByteTransferReportWithDataLength:(int64_t)[bodyData length]
                                             block:^(int64_t bytesSent,
                                                     int64_t totalBytesSent,
                                                     int64_t totalBytesExpectedToSend) {
        _sendProgressBlock(bytesSent, totalBytesSent, totalBytesExpectedToSend);
    }];
  }

  if (_destinationFileURL) {
    // Simulate download to file progress.
    if (_downloadProgressBlock) {
      [self simulateByteTransferReportWithDataLength:(int64_t)[responseData length]
                                               block:^(int64_t bytesDownloaded,
                                                       int64_t totalBytesDownloaded,
                                                       int64_t totalBytesExpectedToDownload) {
        _downloadProgressBlock(bytesDownloaded, totalBytesDownloaded, totalBytesExpectedToDownload);
      }];
    }

    NSError *writeError;
    [responseData writeToURL:_destinationFileURL
                     options:NSDataWritingAtomic
                       error:&writeError];
    if (writeError) {
      // Tell the test code that writing failed.
      error = writeError;
    }
  } else {
    // Simulate download to NSData progress.
    if (_accumulateDataBlock) {
      [self invokeOnCallbackQueueUnlessStopped:^{
        _accumulateDataBlock(responseData);
      }];
    } else {
      _downloadedData = [responseData mutableCopy];
    }

    if (_receivedProgressBlock) {
      [self simulateByteTransferReportWithDataLength:(int64_t)[responseData length]
                                               block:^(int64_t bytesReceived,
                                                       int64_t totalBytesReceived,
                                                       int64_t totalBytesExpectedToReceive) {
         _receivedProgressBlock(bytesReceived, totalBytesReceived);
       }];
    }

    if (_willCacheURLResponseBlock) {
      // Simulate letting the client inspect and alter the cached response.
      NSCachedURLResponse *cachedResponse =
          [[NSCachedURLResponse alloc] initWithResponse:response
                                                   data:responseData];
      [self invokeOnCallbackQueueAfterUserStopped:YES
                                            block:^{
          _willCacheURLResponseBlock(cachedResponse, ^(NSCachedURLResponse *responseToCache){
              // The app may provide an alternative response, or nil to defeat caching.
          });
      }];
    }
  }
  _response = response;
  dispatch_async(dispatch_get_main_queue(), ^{
    // Rather than invoke failToBeginFetchWithError: we want to simulate completion of
    // a connection that started and ended, so we'll call down to finishWithError:
    NSInteger status = error ? [error code] : 200;
    [self shouldRetryNowForStatus:status error:error response:^(BOOL shouldRetry) {
        [self finishWithError:error shouldRetry:shouldRetry];
    }];
  });
}

- (void)setSessionTask:(NSURLSessionTask *)sessionTask {
  @synchronized(self) {
    if (_sessionTask == sessionTask) {
      return;
    }
    _sessionTask = sessionTask;
    if (_sessionTask) {
      // Request could be nil on restoring this fetcher from a background session.
      if (!_request) {
        _request = [_sessionTask.originalRequest mutableCopy];
      }
    }
  }
}

- (void)addPersistedBackgroundSessionToDefaults {
  if (!_sessionIdentifier) {
    return;
  }
  NSArray *oldBackgroundSessions = [[self class] activePersistedBackgroundSessions];
  if ([oldBackgroundSessions containsObject:_sessionIdentifier]) {
    return;
  }
  NSMutableArray *newBackgroundSessions =
      [NSMutableArray arrayWithArray:oldBackgroundSessions];
  [newBackgroundSessions addObject:_sessionIdentifier];
  GTM_LOG_BACKGROUND_SESSION(@"Add to background sessions: %@", newBackgroundSessions);

  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  [userDefaults setObject:newBackgroundSessions
                   forKey:kGTMSessionFetcherPersistedDestinationKey];
  [userDefaults synchronize];
}

- (void)removePersistedBackgroundSessionFromDefaults {
  NSString *sessionIdentifier;
  @synchronized(self) {
    sessionIdentifier = _sessionIdentifier;
    if (!sessionIdentifier) return;
  }

  NSArray *oldBackgroundSessions = [[self class] activePersistedBackgroundSessions];
  if (!oldBackgroundSessions) {
    return;
  }
  NSMutableArray *newBackgroundSessions =
      [NSMutableArray arrayWithArray:oldBackgroundSessions];
  NSUInteger sessionIndex = [newBackgroundSessions indexOfObject:sessionIdentifier];
  if (sessionIndex == NSNotFound) {
    return;
  }
  [newBackgroundSessions removeObjectAtIndex:sessionIndex];
  GTM_LOG_BACKGROUND_SESSION(@"Remove from background sessions: %@", newBackgroundSessions);

  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  if ([newBackgroundSessions count] == 0) {
    [userDefaults removeObjectForKey:kGTMSessionFetcherPersistedDestinationKey];
  } else {
    [userDefaults setObject:newBackgroundSessions
                     forKey:kGTMSessionFetcherPersistedDestinationKey];
  }
  [userDefaults synchronize];
}

+ (NSArray *)activePersistedBackgroundSessions {
  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  NSArray *oldBackgroundSessions =
      [userDefaults arrayForKey:kGTMSessionFetcherPersistedDestinationKey];
  if ([oldBackgroundSessions count] == 0) {
    return nil;
  }
  NSMutableArray *activeBackgroundSessions = nil;
  NSMapTable *sessionIdentifierToFetcherMap = [self sessionIdentifierToFetcherMap];
  for (NSString *sessionIdentifier in oldBackgroundSessions) {
    GTMSessionFetcher *fetcher = [sessionIdentifierToFetcherMap objectForKey:sessionIdentifier];
    if (fetcher) {
      if (!activeBackgroundSessions) {
        activeBackgroundSessions = [[NSMutableArray alloc] init];
      }
      [activeBackgroundSessions addObject:sessionIdentifier];
    }
  }
  return activeBackgroundSessions;
}

+ (void)restoreFetchersForBackgroundSessions {
  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  NSArray *backgroundSessions =
      [userDefaults arrayForKey:kGTMSessionFetcherPersistedDestinationKey];
  NSMapTable *sessionIdentifierToFetcherMap = [self sessionIdentifierToFetcherMap];
  for (NSString *sessionIdentifier in backgroundSessions) {
    GTMSessionFetcher *fetcher = [sessionIdentifierToFetcherMap objectForKey:sessionIdentifier];
    if (!fetcher) {
      fetcher = [self fetcherWithSessionIdentifier:sessionIdentifier];
      GTMSESSION_ASSERT_DEBUG(fetcher != nil,
                              @"Unexpected invalid session identifier: %@", sessionIdentifier);
      [fetcher beginFetchWithCompletionHandler:nil];
    }
    GTM_LOG_BACKGROUND_SESSION(@"%@ restoring session %@ by creating fetcher %@ %p",
                               [self class], sessionIdentifier, fetcher, fetcher);
  }
}

+ (NSArray *)fetchersForBackgroundSessions {
  NSMutableArray *fetchers = [NSMutableArray array];
  NSMapTable *sessionIdentifierToFetcherMap = [self sessionIdentifierToFetcherMap];
  for (NSString *sessionIdentifier in sessionIdentifierToFetcherMap) {
    GTMSessionFetcher *fetcher = [sessionIdentifierToFetcherMap objectForKey:sessionIdentifier];
    if (fetcher) {
      [fetchers addObject:fetcher];
    }
  }
  return fetchers;
}

#if TARGET_OS_IPHONE
+ (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
                      completionHandler:(GTMSessionFetcherSystemCompletionHandler)completionHandler {
  GTMSessionFetcher *fetcher = [self fetcherWithSessionIdentifier:identifier];
  if (fetcher != nil) {
    fetcher.systemCompletionHandler = completionHandler;
  } else {
    GTM_LOG_BACKGROUND_SESSION(@"%@ did not create background session identifier: %@",
                               [self class], identifier);
  }
}
#endif

- (NSString *)sessionIdentifier {
  @synchronized(self) {
    return _sessionIdentifier;
  }
}

- (void)setSessionIdentifier:(NSString *)sessionIdentifier {
  GTMSESSION_ASSERT_DEBUG(sessionIdentifier != nil, @"Invalid session identifier");
  @synchronized(self) {
    GTMSESSION_ASSERT_DEBUG(!_session, @"Unable to set session identifier after session created");
    _sessionIdentifier = [sessionIdentifier copy];
    _useBackgroundSession = YES;
    [self restoreDefaultStateForSessionIdentifierMetadata];
  }
}

- (NSDictionary *)sessionUserInfo {
  @synchronized(self) {
    if (_sessionUserInfo == nil) {
      // We'll return the metadata dictionary with internal keys removed. This avoids the user
      // re-using the userInfo dictionary later and accidentally including the internal keys.
      NSMutableDictionary *metadata = [[self sessionIdentifierMetadata] mutableCopy];
      NSSet *keysToRemove = [metadata keysOfEntriesPassingTest:^BOOL(id key, id obj, BOOL *stop) {
          return [key hasPrefix:@"_"];
      }];
      [metadata removeObjectsForKeys:[keysToRemove allObjects]];
      if ([metadata count] > 0) {
        _sessionUserInfo = metadata;
      }
    }
    return _sessionUserInfo;
  }
}

- (void)setSessionUserInfo:(NSDictionary *)dictionary {
  @synchronized(self) {
    GTMSESSION_ASSERT_DEBUG(_sessionIdentifier == nil, @"Too late to assign userInfo");
    _sessionUserInfo = dictionary;
  }
}

- (NSDictionary *)sessionIdentifierDefaultMetadata {
  NSMutableDictionary *defaultUserInfo = [[NSMutableDictionary alloc] init];
  if (_destinationFileURL) {
    defaultUserInfo[kGTMSessionIdentifierDestinationFileURLMetadataKey] =
        [_destinationFileURL absoluteString];
  }
  if (_bodyFileURL) {
    defaultUserInfo[kGTMSessionIdentifierBodyFileURLMetadataKey] = [_bodyFileURL absoluteString];
  }
  return ([defaultUserInfo count] > 0) ? defaultUserInfo : nil;
}

- (void)restoreDefaultStateForSessionIdentifierMetadata {
  NSDictionary *metadata = [self sessionIdentifierMetadata];
  NSString *destinationFileURLString = metadata[kGTMSessionIdentifierDestinationFileURLMetadataKey];
  if (destinationFileURLString) {
    _destinationFileURL = [NSURL URLWithString:destinationFileURLString];
    GTM_LOG_BACKGROUND_SESSION(@"Restoring destination file URL: %@", _destinationFileURL);
  }
  NSString *bodyFileURLString = metadata[kGTMSessionIdentifierBodyFileURLMetadataKey];
  if (bodyFileURLString) {
    _bodyFileURL = [NSURL URLWithString:bodyFileURLString];
    GTM_LOG_BACKGROUND_SESSION(@"Restoring body file URL: %@", _bodyFileURL);
  }
}

- (NSDictionary *)sessionIdentifierMetadata {
  // Session Identifier format: "com.google.<ClassName>_<UUID>_<Metadata in JSON format>
  if (!_sessionIdentifier) {
    return nil;
  }
  NSScanner *metadataScanner = [NSScanner scannerWithString:_sessionIdentifier];
  [metadataScanner setCharactersToBeSkipped:nil];
  NSString *metadataString;
  NSString *uuid;
  if ([metadataScanner scanUpToString:@"_" intoString:NULL] &&
      [metadataScanner scanString:@"_" intoString:NULL] &&
      [metadataScanner scanUpToString:@"_" intoString:&uuid] &&
      [metadataScanner scanString:@"_" intoString:NULL] &&
      [metadataScanner scanUpToString:@"\n" intoString:&metadataString]) {
    _sessionIdentifierUUID = uuid;
    NSData *metadataData = [metadataString dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error;
    NSDictionary *metadataDict =
        [NSJSONSerialization JSONObjectWithData:metadataData
                                        options:0
                                          error:&error];
    GTM_LOG_BACKGROUND_SESSION(@"User Info from session identifier: %@ %@",
                               metadataDict, error ? error : @"");
    return metadataDict;
  }
  return nil;
}

- (void)createSessionIdentifierWithMetadata:(NSDictionary *)metadataToInclude {
  // Session Identifier format: "com.google.<ClassName>_<UUID>_<Metadata in JSON format>
  GTMSESSION_ASSERT_DEBUG(!_sessionIdentifier, @"Session identifier already created");
  _sessionIdentifierUUID = [[NSUUID UUID] UUIDString];
  _sessionIdentifier =
      [NSString stringWithFormat:@"%@_%@", kGTMSessionIdentifierPrefix, _sessionIdentifierUUID];
  // Start with user-supplied keys so they cannot accidentally override the fetcher's keys.
  NSMutableDictionary *metadataDict =
      [NSMutableDictionary dictionaryWithDictionary:_sessionUserInfo];

  if (metadataToInclude) {
    [metadataDict addEntriesFromDictionary:metadataToInclude];
  }
  NSDictionary *defaultMetadataDict = [self sessionIdentifierDefaultMetadata];
  if (defaultMetadataDict) {
    [metadataDict addEntriesFromDictionary:defaultMetadataDict];
  }
  if ([metadataDict count] > 0) {
    NSData *metadataData = [NSJSONSerialization dataWithJSONObject:metadataDict
                                                           options:0
                                                             error:NULL];
    GTMSESSION_ASSERT_DEBUG(metadataData != nil,
                            @"Session identifier user info failed to convert to JSON");
    if ([metadataData length] > 0) {
      NSString *metadataString = [[NSString alloc] initWithData:metadataData
                                                       encoding:NSUTF8StringEncoding];
      _sessionIdentifier =
          [_sessionIdentifier stringByAppendingFormat:@"_%@", metadataString];
    }
  }
  _didCreateSessionIdentifier = YES;
}

- (void)failToBeginFetchWithError:(NSError *)error {
  if (error == nil) {
    error = [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                                code:kGTMSessionFetcherErrorDownloadFailed
                            userInfo:nil];
  }

  [self invokeFetchCallbacksOnCallbackQueueWithData:nil
                                              error:error];
  [self releaseCallbacks];

  [_service fetcherDidStop:self];

  self.authorizer = nil;
}

+ (GTMSessionCookieStorage *)staticCookieStorage {
  static GTMSessionCookieStorage *gCookieStorage = nil;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    gCookieStorage = [[GTMSessionCookieStorage alloc] init];
  });
  return gCookieStorage;
}

#if GTM_BACKGROUND_TASK_FETCHING

- (void)backgroundFetchExpired {
  // On background expiration, we stop the fetch and invoke the callbacks
  NSError *error = [NSError errorWithDomain:kGTMSessionFetcherErrorDomain
                                       code:kGTMSessionFetcherErrorBackgroundExpiration
                                   userInfo:nil];
  [self invokeFetchCallbacksOnCallbackQueueWithData:nil
                                              error:error];
  @synchronized(self) {
    // Stopping the fetch here will indirectly call endBackgroundTask
    [self stopFetchReleasingCallbacks:NO];

    [self releaseCallbacks];
    self.authorizer = nil;
  }
}

- (void)endBackgroundTask {
  @synchronized(self) {
    // Whenever the connection stops or background execution expires,
    // we need to tell UIApplication we're done
    if (_backgroundTaskIdentifer != UIBackgroundTaskInvalid) {
      [[UIApplication sharedApplication] endBackgroundTask:_backgroundTaskIdentifer];

      _backgroundTaskIdentifer = UIBackgroundTaskInvalid;
    }
  }
}

#endif // GTM_BACKGROUND_TASK_FETCHING

- (void)authorizeRequest {
  id authorizer = self.authorizer;
  SEL asyncAuthSel = @selector(authorizeRequest:delegate:didFinishSelector:);
  if ([authorizer respondsToSelector:asyncAuthSel]) {
    SEL callbackSel = @selector(authorizer:request:finishedWithError:);
    [authorizer authorizeRequest:_request
                        delegate:self
               didFinishSelector:callbackSel];
  } else {
    GTMSESSION_ASSERT_DEBUG(authorizer == nil, @"invalid authorizer for fetch");

    // No authorizing possible, and authorizing happens only after any delay;
    // just begin fetching
    [self beginFetchMayDelay:NO
                mayAuthorize:NO];
  }
}

- (void)authorizer:(id<GTMFetcherAuthorizationProtocol>)auth
           request:(NSMutableURLRequest *)request
 finishedWithError:(NSError *)error {
  if (error != nil) {
    // We can't fetch without authorization
    [self failToBeginFetchWithError:error];
  } else {
    [self beginFetchMayDelay:NO
                mayAuthorize:NO];
  }
}


// Returns YES if this is in the process of fetching a URL, or waiting to
// retry, or waiting for authorization, or waiting to be issued by the
// service object
- (BOOL)isFetching {
  if (_sessionTask != nil || _retryTimer != nil) return YES;

  BOOL isAuthorizing = [_authorizer isAuthorizingRequest:_request];
  if (isAuthorizing) return YES;

  BOOL isDelayed = [_service isDelayingFetcher:self];
  return isDelayed;
}

- (NSURLResponse *)response {
  @synchronized(self) {
    NSURLResponse *response = _sessionTask.response;
    if (response) return response;
    return _response;
  }
}

- (NSInteger)statusCode {
  NSURLResponse *response = self.response;
  NSInteger statusCode;

  if ([response respondsToSelector:@selector(statusCode)]) {
    statusCode = [(NSHTTPURLResponse *)response statusCode];
  } else {
    //  Default to zero, in hopes of hinting "Unknown" (we can't be
    //  sure that things are OK enough to use 200).
    statusCode = 0;
  }
  return statusCode;
}


- (NSDictionary *)responseHeaders {
  NSURLResponse *response = self.response;
  if ([response respondsToSelector:@selector(allHeaderFields)]) {
    NSDictionary *headers = [(NSHTTPURLResponse *)response allHeaderFields];
    return headers;
  }
  return nil;
}

- (void)releaseCallbacks {
  self.callbackQueue = nil;

  _completionHandler = nil;  // Setter overridden in upload. Setter assumed to be used externally.
  self.configurationBlock = nil;
  self.sendProgressBlock = nil;
  self.receivedProgressBlock = nil;
  self.downloadProgressBlock = nil;
  self.accumulateDataBlock = nil;
  self.willCacheURLResponseBlock = nil;
  self.retryBlock = nil;
  self.testBlock = nil;
  self.resumeDataBlock = nil;
}

- (void)forgetSessionIdentifierForFetcher {
  // This should be called inside a @synchronized block (except during dealloc.)
  if (_sessionIdentifier) {
    NSMapTable *sessionIdentifierToFetcherMap = [[self class] sessionIdentifierToFetcherMap];
    [sessionIdentifierToFetcherMap removeObjectForKey:_sessionIdentifier];
    _sessionIdentifier = nil;
    _didCreateSessionIdentifier = NO;
  }
}

// External stop method
- (void)stopFetching {
  @synchronized(self) {
    // Prevent enqueued callbacks from executing.
    _userStoppedFetching = YES;
  }
  [self stopFetchReleasingCallbacks:YES];
}

// Cancel the fetch of the URL that's currently in progress.
//
// If shouldReleaseCallbacks is NO then the fetch will be retried so the callbacks
// need to still be retained.
- (void)stopFetchReleasingCallbacks:(BOOL)shouldReleaseCallbacks {
  id<GTMSessionFetcherServiceProtocol> service;

  // If the task or the retry timer is all that's retaining the fetcher,
  // we want to be sure this instance survives stopping at least long enough for
  // the stack to unwind.
  __autoreleasing GTMSessionFetcher *holdSelf = self;

  [holdSelf destroyRetryTimer];

  @synchronized(self) {
    service = _service;

    if (_sessionTask) {
      // In case cancelling the task or session calls this recursively, we want
      // to ensure that we'll only release the task and delegate once,
      // so first set _sessionTask to nil
      //
      // This may be called in a callback from the task, so use autorelease to avoid
      // releasing the task in its own callback.
      __autoreleasing NSURLSessionTask *oldTask = _sessionTask;
      if (!_isUsingTestBlock) {
        _response = _sessionTask.response;
      }
      _sessionTask = nil;

      if ([oldTask state] != NSURLSessionTaskStateCompleted) {
        // For download tasks, when the fetch is stopped, we may provide resume data that can
        // be used to create a new session.
        BOOL mayResume = (_resumeDataBlock
                          && [oldTask respondsToSelector:@selector(cancelByProducingResumeData:)]);
        if (!mayResume) {
          [oldTask cancel];
        } else {
          void (^resumeBlock)(NSData *) = _resumeDataBlock;
          _resumeDataBlock = nil;

          // Save callbackQueue since releaseCallbacks clears it.
          dispatch_queue_t callbackQueue = _callbackQueue;
          dispatch_group_enter(_callbackGroup);
          [(NSURLSessionDownloadTask *)oldTask cancelByProducingResumeData:^(NSData *resumeData) {
              [self invokeOnCallbackQueue:callbackQueue
                         afterUserStopped:YES
                                    block:^{
                  resumeBlock(resumeData);
                  dispatch_group_leave(_callbackGroup);
              }];
          }];
        }
      }
    }

    if (_session) {
#if TARGET_OS_IPHONE
      // Don't invalidate if we've got a systemCompletionHandler, since
      // URLSessionDidFinishEventsForBackgroundURLSession: won't be called if invalidated.
      BOOL shouldInvalidate = !self.systemCompletionHandler;
#else
      BOOL shouldInvalidate = YES;
#endif
      if (shouldInvalidate) {
        __autoreleasing NSURLSession *oldSession = _session;
        _session = nil;
        [oldSession finishTasksAndInvalidate];
      }
    }
  }  // @synchronized(self)

  // send the stopped notification
  [self sendStopNotificationIfNeeded];

  @synchronized(self) {
    [_authorizer stopAuthorizationForRequest:_request];

    if (shouldReleaseCallbacks) {
      [self releaseCallbacks];

      self.authorizer = nil;
    }
  }  // @synchronized(self)

  [service fetcherDidStop:self];

#if GTM_BACKGROUND_TASK_FETCHING
  [self endBackgroundTask];
#endif

  [self removePersistedBackgroundSessionFromDefaults];
}

- (void)sendStopNotificationIfNeeded {
  BOOL sendNow = NO;
  @synchronized(self) {
    if (_isStopNotificationNeeded) {
      _isStopNotificationNeeded = NO;
      sendNow = YES;
    }
  }

  if (sendNow) {
    [[NSNotificationCenter defaultCenter] postNotificationName:kGTMSessionFetcherStoppedNotification
                                                        object:self];
  }
}

- (void)retryFetch {
  [self stopFetchReleasingCallbacks:NO];

  // A retry will need a configuration with a fresh session identifier.
  @synchronized(self) {
    if (_sessionIdentifier && _didCreateSessionIdentifier) {
      [self forgetSessionIdentifierForFetcher];
      _configuration = nil;
    }
  }

  [self beginFetchWithCompletionHandler:_completionHandler];
}

- (BOOL)waitForCompletionWithTimeout:(NSTimeInterval)timeoutInSeconds {
  // Uncovered in upload fetcher testing, because the chunk fetcher is being waited on, and gets
  // released by the upload code. The uploader just holds onto it with an ivar, and that gets
  // nilled in the chunk fetcher callback.
  // Used once in while loop just to avoid unused variable compiler warning.
  __autoreleasing GTMSessionFetcher *holdSelf = self;

  NSDate *giveUpDate = [NSDate dateWithTimeIntervalSinceNow:timeoutInSeconds];

  BOOL shouldSpinRunLoop = ([NSThread isMainThread] &&
                            _callbackQueue == dispatch_get_main_queue());
  BOOL expired = NO;

  // Loop until the callbacks have been called and released, and until
  // the connection is no longer pending, until there are no callback dispatches
  // in flight, or until the timeout has expired.

  int64_t delta = (int64_t)(100 * NSEC_PER_MSEC);  // 100 ms
  while ((holdSelf->_sessionTask && [_sessionTask state] != NSURLSessionTaskStateCompleted)
         || _completionHandler != nil
         || (_callbackGroup
             && dispatch_group_wait(_callbackGroup, dispatch_time(DISPATCH_TIME_NOW, delta)))) {
    expired = ([giveUpDate timeIntervalSinceNow] < 0);
    if (expired) break;

    // Run the current run loop 1/1000 of a second to give the networking
    // code a chance to work
    const NSTimeInterval kSpinInterval = 0.001;
    if (shouldSpinRunLoop) {
      NSDate *stopDate = [NSDate dateWithTimeIntervalSinceNow:kSpinInterval];
      [[NSRunLoop currentRunLoop] runUntilDate:stopDate];
    } else {
      [NSThread sleepForTimeInterval:kSpinInterval];
    }
  }
  return !expired;
}

+ (void)setGlobalTestBlock:(GTMSessionFetcherTestBlock)block {
  gGlobalTestBlock = [block copy];
}

#pragma mark NSURLSession Delegate Methods

// NSURLSession documentation indicates that redirectRequest can be passed to the handler
// but empirically redirectRequest lacks the HTTP body, so passing it will break POSTs.
// Instead, we construct a new request, a copy of the original, with overrides from the
// redirect.

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)redirectResponse
        newRequest:(NSURLRequest *)redirectRequest
 completionHandler:(void (^)(NSURLRequest *))handler {
  [self setSessionTask:task];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ task:%@ willPerformHTTPRedirection:%@ newRequest:%@",
                           [self class], self, session, task, redirectResponse, redirectRequest);
  @synchronized(self) {
    if (redirectRequest && redirectResponse) {
      // Copy the original request, including the body.
      NSMutableURLRequest *newRequest = [_request mutableCopy];

      // Disallow scheme changes (say, from https to http).
      NSURL *originalRequestURL = [_request URL];
      NSURL *redirectRequestURL = [redirectRequest URL];

      NSString *originalScheme = [originalRequestURL scheme];
      NSString *redirectScheme = [redirectRequestURL scheme];

      if ([originalScheme caseInsensitiveCompare:@"http"] == NSOrderedSame
          && redirectScheme != nil
          && [redirectScheme caseInsensitiveCompare:@"https"] == NSOrderedSame) {
        // Allow the change from http to https.
      } else {
        // Disallow any other scheme changes.
        redirectScheme = originalScheme;
      }
      // The new requests's URL overrides the original's URL.
      NSURLComponents *components = [NSURLComponents componentsWithURL:redirectRequestURL
                                               resolvingAgainstBaseURL:NO];
      components.scheme = redirectScheme;
      NSURL *newURL = [components URL];
      [newRequest setURL:newURL];

      // Any headers in the redirect override headers in the original.
      NSDictionary *redirectHeaders = [redirectRequest allHTTPHeaderFields];
      for (NSString *key in redirectHeaders) {
        NSString *value = [redirectHeaders objectForKey:key];
        [newRequest setValue:value forHTTPHeaderField:key];
      }

      redirectRequest = newRequest;

      // Log the response we just received
      _response = redirectResponse;
      [self logNowWithError:nil];

      // Update the request for future logging
      NSMutableURLRequest *mutable = [redirectRequest mutableCopy];
      self.mutableRequest = mutable;
    }
    handler(redirectRequest);
  }  // @synchronized(self)

}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))handler {
  [self setSessionTask:dataTask];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ dataTask:%@ didReceiveResponse:%@",
                           [self class], self, session, dataTask, response);

  @synchronized(self) {
    BOOL hadPreviousData = _downloadedLength > 0;

    // This method is called when the server has determined that it
    // has enough information to create the NSURLResponse
    // it can be called multiple times, for example in the case of a
    // redirect, so each time we reset the data.
    [_downloadedData setLength:0];
    _downloadedLength = 0;

    if (hadPreviousData) {
      // Tell the accumulate block to discard prior data.
      GTMSessionFetcherAccumulateDataBlock accumulateBlock = _accumulateDataBlock;
      if (accumulateBlock) {
        [self invokeOnCallbackQueueUnlessStopped:^{
            accumulateBlock(nil);
        }];
      }
    }

    handler(NSURLSessionResponseAllow);
  }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ dataTask:%@ didBecomeDownloadTask:%@",
                           [self class], self, session, dataTask, downloadTask);
  [self setSessionTask:downloadTask];
}


- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition,
                             NSURLCredential *credential))handler {
  [self setSessionTask:task];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ task:%@ didReceiveChallenge:%@",
                           [self class], self, session, task, challenge);

  @synchronized(self) {
    NSInteger previousFailureCount = [challenge previousFailureCount];
    if (previousFailureCount <= 2) {
      NSURLProtectionSpace *protectionSpace = [challenge protectionSpace];
      NSString *authenticationMethod = [protectionSpace authenticationMethod];
      if ([authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust]) {
        // SSL.
        //
        // Background sessions seem to require an explicit check of the server trust object
        // rather than default handling.
        SecTrustRef serverTrust = challenge.protectionSpace.serverTrust;
        if (serverTrust == NULL) {
          // No server trust information is available.
          handler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        } else {
          BOOL shouldAllow = _allowInvalidServerCertificates;
          if (!shouldAllow) {
            // Evaluate the certificate chain.
            SecTrustResultType trustEval = 0;
            OSStatus trustError = SecTrustEvaluate(serverTrust, &trustEval);
            if (trustError == errSecSuccess) {
              // Having a trust level "unspecified" by the user is the usual result, described at
              //   https://developer.apple.com/library/mac/qa/qa1360
              if (trustEval == kSecTrustResultUnspecified || trustEval == kSecTrustResultProceed) {
                shouldAllow = YES;
              } else {
                GTMSESSION_LOG_DEBUG(@"Challenge SecTrustResultType %u for %@, properties: %@",
                    trustEval, [[_request URL] host],
                    CFBridgingRelease(SecTrustCopyProperties(serverTrust)));
              }
            } else {
              GTMSESSION_LOG_DEBUG(@"Error %d evaluating trust for %@", (int)trustError, _request);
            }
          }
          if (shouldAllow) {
            NSURLCredential *trustCredential = [NSURLCredential credentialForTrust:serverTrust];
            handler(NSURLSessionAuthChallengeUseCredential, trustCredential);
          } else {
            GTMSESSION_LOG_DEBUG(@"Cancelling authentication challenge for %@", [_request URL]);
            handler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
          }
        }
        return;
      }

      NSURLCredential *credential = _credential;

      if ([[challenge protectionSpace] isProxy] && _proxyCredential != nil) {
        credential = _proxyCredential;
      }

      // Here, if credential is still nil, then we *could* try to get it from
      // NSURLCredentialStorage's defaultCredentialForProtectionSpace:.
      // We don't, because we're assuming:
      //
      // - For server credentials, we only want ones supplied by the program calling http fetcher
      // - For proxy credentials, if one were necessary and available in the keychain, it would've
      //   been found automatically by NSURLSession and this challenge delegate method never
      //   would've been called anyway

      if (credential) {
        // try the credential
        handler(NSURLSessionAuthChallengeUseCredential, credential);
        return;
      }
    }  // @synchronized(self)

    // We don't have credentials, or we've failed auth 3 times.  The completion
    // handler will be called with code NSURLErrorCancelled.
    handler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
  }
}

- (void)invokeOnCallbackQueueUnlessStopped:(void (^)(void))block {
  [self invokeOnCallbackQueueAfterUserStopped:NO
                                        block:block];
}

- (void)invokeOnCallbackQueueAfterUserStopped:(BOOL)afterStopped
                                        block:(void (^)(void))block {
  [self invokeOnCallbackQueue:self.callbackQueue
             afterUserStopped:afterStopped
                        block:block];
}

- (void)invokeOnCallbackQueue:(dispatch_queue_t)callbackQueue
             afterUserStopped:(BOOL)afterStopped
                        block:(void (^)(void))block {
  if (callbackQueue) {
    dispatch_group_async(_callbackGroup, callbackQueue, ^{
        if (!afterStopped) {
          @synchronized(self) {
            // Avoid a race between stopFetching and the callback.
            if (_userStoppedFetching) return;
          }
        }
        block();
    });
  }
}

- (void)invokeFetchCallbacksOnCallbackQueueWithData:(NSData *)data
                                              error:(NSError *)error {
  // Callbacks will be released in the method stopFetchReleasingCallbacks:
  void (^handler)(NSData *, NSError *);
  @synchronized(self) {
    handler = _completionHandler;
  }
  if (handler) {
    [self invokeOnCallbackQueueUnlessStopped:^{
        handler(data, error);
    }];
  }
}


- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)uploadTask
 needNewBodyStream:(void (^)(NSInputStream *bodyStream))completionHandler {
  [self setSessionTask:uploadTask];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ task:%@ needNewBodyStream:",
                           [self class], self, session, uploadTask);
  @synchronized(self) {
    GTMSessionFetcherBodyStreamProvider provider = _bodyStreamProvider;
#if !STRIP_GTM_FETCH_LOGGING
    if ([self respondsToSelector:@selector(loggedStreamProviderForStreamProvider:)]) {
      provider = [self performSelector:@selector(loggedStreamProviderForStreamProvider:)
                            withObject:provider];
    }
#endif
    if (provider) {
      [self invokeOnCallbackQueueUnlessStopped:^{
          provider(completionHandler);
      }];
    } else {
      GTMSESSION_ASSERT_DEBUG(NO, @"NSURLSession expects a stream provider");

      completionHandler(nil);
    }
  }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
  [self setSessionTask:task];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ task:%@ didSendBodyData:%lld"
                           @" totalBytesSent:%lld totalBytesExpectedToSend:%lld",
                           [self class], self, session, task, bytesSent, totalBytesSent,
                           totalBytesExpectedToSend);
  @synchronized(self) {
    if (!_sendProgressBlock) return;
  }

  // We won't hold on to send progress block; it's ok to not send it if the upload finishes.
  [self invokeOnCallbackQueueUnlessStopped:^{
      GTMSessionFetcherSendProgressBlock progressBlock;
      @synchronized(self) {
        progressBlock = _sendProgressBlock;
      }
      if (progressBlock) {
        progressBlock(bytesSent, totalBytesSent, totalBytesExpectedToSend);
      }
  }];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  [self setSessionTask:dataTask];
  NSUInteger bufferLength = [data length];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ dataTask:%@ didReceiveData:%p (%llu bytes)",
                           [self class], self, session, dataTask, data,
                           (unsigned long long)bufferLength);
  if (bufferLength == 0) {
    // Observed on completing an out-of-process upload.
    return;
  }
  @synchronized(self) {
    GTMSessionFetcherAccumulateDataBlock accumulateBlock = _accumulateDataBlock;
    if (accumulateBlock) {
      // Let the client accumulate the data.
      _downloadedLength += bufferLength;
      [self invokeOnCallbackQueueUnlessStopped:^{
          accumulateBlock(data);
      }];
    } else {
      // Append to the mutable data buffer.

      // Resumed upload tasks may not yet have a data buffer.
      if (_downloadedData == nil) {
        // Using NSClassFromString for iOS 6 compatibility.
        GTMSESSION_ASSERT_DEBUG(
            ![dataTask isKindOfClass:NSClassFromString(@"NSURLSessionDownloadTask")],
            @"Resumed download tasks should not receive data bytes");
        _downloadedData = [[NSMutableData alloc] init];
      }

      [_downloadedData appendData:data];
      _downloadedLength = (int64_t)[_downloadedData length];

      // We won't hold on to receivedProgressBlock here; it's ok to not send
      // it if the transfer finishes.
      if (_receivedProgressBlock) {
        [self invokeOnCallbackQueueUnlessStopped:^{
            GTMSessionFetcherReceivedProgressBlock progressBlock;
            @synchronized(self) {
              progressBlock = _receivedProgressBlock;
            }
            if (progressBlock) {
              progressBlock((int64_t)bufferLength, _downloadedLength);
            }
        }];
      }
    }
  }  // @synchronized(self)
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ dataTask:%@ willCacheResponse:%@ %@",
                           [self class], self, session, dataTask,
                           proposedResponse, proposedResponse.response);
  GTMSessionFetcherWillCacheURLResponseBlock callback;
  @synchronized(self) {
    callback = _willCacheURLResponseBlock;
  }

  if (callback) {
    [self invokeOnCallbackQueueAfterUserStopped:YES
                                          block:^{
        callback(proposedResponse, completionHandler);
    }];
  } else {
    completionHandler(proposedResponse);
  }
}


- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ downloadTask:%@ didWriteData:%lld"
                           @" bytesWritten:%lld totalBytesExpectedToWrite:%lld",
                           [self class], self, session, downloadTask, bytesWritten,
                           totalBytesWritten, totalBytesExpectedToWrite);
  [self setSessionTask:downloadTask];

  // We won't hold on to download progress block during the enqueue;
  // it's ok to not send it if the upload finishes.
  [self invokeOnCallbackQueueUnlessStopped:^{
      GTMSessionFetcherDownloadProgressBlock progressBlock;
      @synchronized(self) {
        progressBlock = _downloadProgressBlock;
      }
      if (progressBlock) {
        progressBlock(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
      }
  }];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ downloadTask:%@ didResumeAtOffset:%lld"
                           @" expectedTotalBytes:%lld",
                           [self class], self, session, downloadTask, fileOffset,
                           expectedTotalBytes);
  [self setSessionTask:downloadTask];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)downloadLocationURL {
  // Download may have relaunched app, so update ivar, and update before getting statusCode,
  // since statusCode relies on accessing task.
  [self setSessionTask:downloadTask];
  NSInteger code = [self statusCode];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ downloadTask:%@ didFinishDownloadingToURL:%@, status = %ld",
                           [self class], self, session, downloadTask,
                           downloadLocationURL, (long)code);
  if (code >= 200 && code < 400) {
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    NSDictionary *attributes = [fileMgr attributesOfItemAtPath:[downloadLocationURL path]
                                                         error:NULL];
    @synchronized(self) {
      NSURL *destinationURL = self.destinationFileURL;

      _downloadedLength = (int64_t)[attributes fileSize];

      // Overwrite any previous file at the destination URL.
      [fileMgr removeItemAtURL:destinationURL error:NULL];

      NSError *error;
      if (![fileMgr moveItemAtURL:downloadLocationURL
                            toURL:destinationURL
                            error:&error]) {
        _downloadMoveError = error;
      }
      GTM_LOG_BACKGROUND_SESSION(@"%@ %p Moved download from \"%@\" to \"%@\"  %@",
                                 [self class], self,
                                 [downloadLocationURL path], [destinationURL path],
                                 error ? error : @"");
    }
  }
}

/* Sent as the last message related to a specific task.  Error may be
 * nil, which implies that no error occurred and this task is complete.
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
  [self setSessionTask:task];
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ task:%@ didCompleteWithError:%@",
                           [self class], self, session, task, error);

  NSInteger status = self.statusCode;
  BOOL succeeded = NO;
  @synchronized(self) {
    if (error == nil) {
      error = _downloadMoveError;
    }
    succeeded = (error == nil && status >= 0 && status < 300);
    if (succeeded) {
      // Succeeded.
      _bodyLength = task.countOfBytesSent;
    }
  }

  if (succeeded) {
    [self finishWithError:nil shouldRetry:NO];
    return;
  }
  // For background redirects, no delegate method is called, so we cannot restore a stripped
  // Authorization header, so if a 403 was generated due to a missing OAuth header, set the current
  // request's URL to the redirected URL, so we in effect restore the Authorization header.
  if ((status == 403) && _useBackgroundSession) {
    NSURL *redirectURL = [self.response URL];
    if (![[_request URL] isEqual:redirectURL]) {
      NSString *authorizationHeader =
          [[_request allHTTPHeaderFields] objectForKey:@"Authorization"];
      if (authorizationHeader != nil) {
        [_request setURL:redirectURL];
        [self retryFetch];
        return;
      }
    }
  }
  // Failed.
  [self shouldRetryNowForStatus:status error:error response:^(BOOL shouldRetry) {
    [self finishWithError:error shouldRetry:shouldRetry];
  }];
}

#if TARGET_OS_IPHONE
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSessionDidFinishEventsForBackgroundURLSession:%@",
                           [self class], self, session);
  GTMSessionFetcherSystemCompletionHandler handler;
  @synchronized(self) {
    handler = self.systemCompletionHandler;
    self.systemCompletionHandler = nil;
  }
  if (handler) {
    GTM_LOG_BACKGROUND_SESSION(@"%@ %p Calling system completionHandler", [self class], self);
    handler();

    @synchronized(self) {
      NSURLSession *oldSession = _session;
      _session = nil;
      [oldSession finishTasksAndInvalidate];
    }
  }
  [self removePersistedBackgroundSessionFromDefaults];
}
#endif

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error {
  // This may happen repeatedly for retries.  On authentication callbacks, the retry
  // may begin before the prior session sends the didBecomeInvalid delegate message.
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ didBecomeInvalidWithError:%@",
                           [self class], self, session, error);
}

- (void)finishWithError:(NSError *)error shouldRetry:(BOOL)shouldRetry {
  BOOL shouldStopFetching = YES;
  NSData *downloadedData = nil;
#if !STRIP_GTM_FETCH_LOGGING
  BOOL shouldDeferLogging = NO;
#endif
  BOOL shouldBeginRetryTimer = NO;

  [self removePersistedBackgroundSessionFromDefaults];

  @synchronized(self) {

    NSInteger status = [self statusCode];

    if (error == nil && status >= 0 && status < 300) {
      // Success
      downloadedData = _downloadedData;
    } else {
      // Unsuccessful
#if !STRIP_GTM_FETCH_LOGGING
      if (!_hasLoggedError) {
        [self logNowWithError:error];
        _hasLoggedError = YES;
      }
#endif
      // Status over 300; retry or notify the delegate of failure
      if (shouldRetry) {
        // retrying
        shouldBeginRetryTimer = YES;
        shouldStopFetching = NO;
      } else {
        if (error == nil) {
          // Create an error.
          NSDictionary *userInfo = nil;
          if ([_downloadedData length] > 0) {
            userInfo = @{ kGTMSessionFetcherStatusDataKey : _downloadedData };
          }
          error = [NSError errorWithDomain:kGTMSessionFetcherStatusDomain
                                      code:status
                                  userInfo:userInfo];
        } else {
          // If the error had resume data, and the client supplied a resume block, pass the
          // data to the client.
          void (^resumeBlock)(NSData *) = _resumeDataBlock;
          _resumeDataBlock = nil;
          if (resumeBlock) {
            NSData *resumeData = [[error userInfo] objectForKey:NSURLSessionDownloadTaskResumeData];
            if (resumeData) {
              [self invokeOnCallbackQueueAfterUserStopped:YES block:^{
                  resumeBlock(resumeData);
              }];
            }
          }
        }
        if ([_downloadedData length] > 0) {
          downloadedData = _downloadedData;
        }
      }
    }
#if !STRIP_GTM_FETCH_LOGGING
    shouldDeferLogging = _deferResponseBodyLogging;
#endif
  }  // @synchronized(self)

  if (shouldBeginRetryTimer) {
    [self beginRetryTimer];
  }

  // We want to send the stop notification before calling the delegate's
  // callback selector, since the callback selector may release all of
  // the fetcher properties that the client is using to track the fetches.
  //
  // We'll also stop now so that, to any observers watching the notifications,
  // it doesn't look like our wait for a retry (which may be long,
  // 30 seconds or more) is part of the network activity.
  [self sendStopNotificationIfNeeded];

  if (shouldStopFetching) {
    [self invokeFetchCallbacksOnCallbackQueueWithData:downloadedData
                                                error:error];
    // The upload subclass doesn't want to release callbacks until upload chunks have completed.
    BOOL shouldRelease = [self shouldReleaseCallbacksUponCompletion];
    [self stopFetchReleasingCallbacks:shouldRelease];
  }

#if !STRIP_GTM_FETCH_LOGGING
  @synchronized(self) {
    if (!shouldDeferLogging && !_hasLoggedError) {
      [self logNowWithError:error];
    }
  }
#endif
}

- (BOOL)shouldReleaseCallbacksUponCompletion {
  // A subclass can override this to keep callbacks around after the
  // connection has finished successfully
  return YES;
}

- (void)logNowWithError:(NSError *)error {
  // If the logging category is available, then log the current request,
  // response, data, and error
  if ([self respondsToSelector:@selector(logFetchWithError:)]) {
    [self performSelector:@selector(logFetchWithError:) withObject:error];
  }
}

#pragma mark Retries

- (BOOL)isRetryError:(NSError *)error {
  struct RetryRecord {
    __unsafe_unretained NSString *const domain;
    int code;
  };

  struct RetryRecord retries[] = {
    { kGTMSessionFetcherStatusDomain, 408 }, // request timeout
    { kGTMSessionFetcherStatusDomain, 502 }, // failure gatewaying to another server
    { kGTMSessionFetcherStatusDomain, 503 }, // service unavailable
    { kGTMSessionFetcherStatusDomain, 504 }, // request timeout
    { NSURLErrorDomain, NSURLErrorTimedOut },
    { NSURLErrorDomain, NSURLErrorNetworkConnectionLost },
    { nil, 0 }
  };

  // NSError's isEqual always returns false for equal but distinct instances
  // of NSError, so we have to compare the domain and code values explicitly

  for (int idx = 0; retries[idx].domain != nil; idx++) {

    if ([[error domain] isEqual:retries[idx].domain]
        && [error code] == retries[idx].code) {

      return YES;
    }
  }
  return NO;
}


// shouldRetryNowForStatus:error: responds with YES if the user has enabled retries
// and the status or error is one that is suitable for retrying.  "Suitable"
// means either the isRetryError:'s list contains the status or error, or the
// user's retry block is present and returns YES when called, or the
// authorizer may be able to fix.
- (void)shouldRetryNowForStatus:(NSInteger)status
                          error:(NSError *)error
                       response:(GTMSessionFetcherRetryResponse)response {
  // Determine if a refreshed authorizer may avoid an authorization error
  @synchronized(self) {
    BOOL shouldRetryForAuthRefresh = NO;
    BOOL isFirstAuthError = (_authorizer != nil
                             && !_hasAttemptedAuthRefresh
                             && status == kGTMSessionFetcherStatusUnauthorized); // 401

    if (isFirstAuthError) {
      if ([_authorizer respondsToSelector:@selector(primeForRefresh)]) {
        BOOL hasPrimed = [_authorizer primeForRefresh];
        if (hasPrimed) {
          shouldRetryForAuthRefresh = YES;
          _hasAttemptedAuthRefresh = YES;
          [_request setValue:nil forHTTPHeaderField:@"Authorization"];
        }
      }
    }

    // Determine if we're doing exponential backoff retries
    BOOL shouldDoIntervalRetry = ([self isRetryEnabled]
                                  && [self nextRetryInterval] < [self maxRetryInterval]);

    if (shouldDoIntervalRetry) {
      // If an explicit max retry interval was set, we expect repeated backoffs to take
      // up to roughly twice that for repeated fast failures.  If the initial attempt is
      // already more than 3 times the max retry interval, then failures have taken a long time
      // (such as from network timeouts) so don't retry again to avoid the app becoming
      // unexpectedly unresponsive.
      if (_maxRetryInterval > 0) {
        NSTimeInterval maxAllowedIntervalBeforeRetry = _maxRetryInterval * 3;
        NSTimeInterval timeSinceInitialRequest = -[_initialRequestDate timeIntervalSinceNow];
        if (timeSinceInitialRequest > maxAllowedIntervalBeforeRetry) {
          shouldDoIntervalRetry = NO;
        }
      }
    }

    BOOL willRetry = NO;
    BOOL canRetry = shouldRetryForAuthRefresh || shouldDoIntervalRetry;
    if (canRetry) {
      // Check if this is a retryable error
      if (error == nil) {
        // Make an error for the status
        NSDictionary *userInfo = nil;
        if ([_downloadedData length] > 0) {
          userInfo = @{ kGTMSessionFetcherStatusDataKey : _downloadedData };
        }
        error = [NSError errorWithDomain:kGTMSessionFetcherStatusDomain
                                    code:status
                                userInfo:userInfo];
      }

      willRetry = shouldRetryForAuthRefresh || [self isRetryError:error];

      // If the user has installed a retry callback, consult that.
      GTMSessionFetcherRetryBlock retryBlock = _retryBlock;
      if (retryBlock) {
        [self invokeOnCallbackQueueUnlessStopped:^{
            retryBlock(willRetry, error, response);
        }];
        return;
      }
    }
    response(willRetry);
  }
}

- (void)beginRetryTimer {
  if (![NSThread isMainThread]) {
    // Defer creating and starting the timer until we're on the main thread to ensure it has
    // a run loop.
    dispatch_group_t group;
    @synchronized(self) {
      group = _callbackGroup;
    }
    dispatch_group_async(group, dispatch_get_main_queue(), ^{
        [self beginRetryTimer];
    });
    return;
  }

  NSTimeInterval nextInterval = [self nextRetryInterval];
  NSTimeInterval maxInterval = [self maxRetryInterval];
  NSTimeInterval newInterval = MIN(nextInterval, (maxInterval > 0 ? maxInterval : DBL_MAX));

  [self destroyRetryTimer];

  @synchronized(self) {
    _lastRetryInterval = newInterval;

    _retryTimer = [NSTimer timerWithTimeInterval:newInterval
                                          target:self
                                        selector:@selector(retryTimerFired:)
                                        userInfo:nil
                                         repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:_retryTimer
                              forMode:NSDefaultRunLoopMode];
  }

  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:kGTMSessionFetcherRetryDelayStartedNotification
                    object:self];
}

- (void)retryTimerFired:(NSTimer *)timer {
  [self destroyRetryTimer];

  @synchronized(self) {
    _retryCount++;

    [self retryFetch];
  }
}

- (void)destroyRetryTimer {
  BOOL shouldNotify = NO;
  @synchronized(self) {
    if (_retryTimer) {
      [_retryTimer invalidate];
      _retryTimer = nil;
      shouldNotify = YES;
    }
  }  // @synchronized(self)

  if (shouldNotify) {
    NSNotificationCenter *defaultNC = [NSNotificationCenter defaultCenter];
    [defaultNC postNotificationName:kGTMSessionFetcherRetryDelayStoppedNotification
                             object:self];
  }
}

- (NSUInteger)retryCount {
  return _retryCount;
}

- (NSTimeInterval)nextRetryInterval {
  // The next wait interval is the factor (2.0) times the last interval,
  // but never less than the minimum interval.
  NSTimeInterval secs = _lastRetryInterval * _retryFactor;
  if (_maxRetryInterval > 0) {
    secs = MIN(secs, _maxRetryInterval);
  }
  secs = MAX(secs, _minRetryInterval);

  return secs;
}

- (NSTimer *)retryTimer {
  return _retryTimer;
}

- (BOOL)isRetryEnabled {
  return _isRetryEnabled;
}

- (void)setRetryEnabled:(BOOL)flag {

  if (flag && !_isRetryEnabled) {
    // We defer initializing these until the user calls setRetryEnabled
    // to avoid using the random number generator if it's not needed.
    // However, this means min and max intervals for this fetcher are reset
    // as a side effect of calling setRetryEnabled.
    //
    // Make an initial retry interval random between 1.0 and 2.0 seconds
    [self setMinRetryInterval:0.0];
    [self setMaxRetryInterval:kUnsetMaxRetryInterval];
    [self setRetryFactor:2.0];
    _lastRetryInterval = 0.0;
  }
  _isRetryEnabled = flag;
};

- (NSTimeInterval)maxRetryInterval {
  return _maxRetryInterval;
}

- (void)setMaxRetryInterval:(NSTimeInterval)secs {
  if (secs > 0) {
    _maxRetryInterval = secs;
  } else {
    _maxRetryInterval = kUnsetMaxRetryInterval;
  }
}

- (double)minRetryInterval {
  return _minRetryInterval;
}

- (void)setMinRetryInterval:(NSTimeInterval)secs {
  if (secs > 0) {
    _minRetryInterval = secs;
  } else {
    // Set min interval to a random value between 1.0 and 2.0 seconds
    // so that if multiple clients start retrying at the same time, they'll
    // repeat at different times and avoid overloading the server
    _minRetryInterval = InitialMinRetryInterval();
  }
}

#pragma mark iOS System Completion Handlers

#if TARGET_OS_IPHONE
static NSMutableDictionary *gSystemCompletionHandlers = nil;

- (GTMSessionFetcherSystemCompletionHandler)systemCompletionHandler {
  return [[self class] systemCompletionHandlerForSessionIdentifier:_sessionIdentifier];
}

- (void)setSystemCompletionHandler:(GTMSessionFetcherSystemCompletionHandler)systemCompletionHandler {
  [[self class] setSystemCompletionHandler:systemCompletionHandler
                      forSessionIdentifier:_sessionIdentifier];
}

+ (void)setSystemCompletionHandler:(GTMSessionFetcherSystemCompletionHandler)systemCompletionHandler
              forSessionIdentifier:(NSString *)sessionIdentifier {
  @synchronized([GTMSessionFetcher class]) {
    if (gSystemCompletionHandlers == nil && systemCompletionHandler != nil) {
      gSystemCompletionHandlers = [[NSMutableDictionary alloc] init];
    }
    // Use setValue: to remove the object if completionHandler is nil.
    [gSystemCompletionHandlers setValue:systemCompletionHandler
                                 forKey:sessionIdentifier];
  }
}

+ (GTMSessionFetcherSystemCompletionHandler)systemCompletionHandlerForSessionIdentifier:(NSString *)sessionIdentifier {
  if (!sessionIdentifier) {
    return nil;
  }
  @synchronized([GTMSessionFetcher class]) {
    return [gSystemCompletionHandlers objectForKey:sessionIdentifier];
  }
}
#endif  // TARGET_OS_IPHONE

#pragma mark Getters and Setters

@synthesize mutableRequest = _request,
            downloadResumeData = _downloadResumeData,
            configuration = _configuration,
            configurationBlock = _configurationBlock,
            session = _session,
            sessionTask = _sessionTask,
            sessionUserInfo = _sessionUserInfo,
            taskDescription = _taskDescription,
            useBackgroundSession = _useBackgroundSession,
            completionHandler = _completionHandler,
            credential = _credential,
            proxyCredential = _proxyCredential,
            bodyData = _bodyData,
            bodyFileURL = _bodyFileURL,
            bodyLength = _bodyLength,
            bodyStreamProvider = _bodyStreamProvider,
            authorizer = _authorizer,
            service = _service,
            serviceHost = _serviceHost,
            servicePriority = _servicePriority,
            accumulateDataBlock = _accumulateDataBlock,
            receivedProgressBlock = _receivedProgressBlock,
            downloadProgressBlock = _downloadProgressBlock,
            resumeDataBlock = _resumeDataBlock,
            sendProgressBlock = _sendProgressBlock,
            willCacheURLResponseBlock = _willCacheURLResponseBlock,
            retryBlock = _retryBlock,
            retryFactor = _retryFactor,
            downloadedLength = _downloadedLength,
            downloadedData = _downloadedData,
            useUploadTask = _useUploadTask,
            allowedInsecureSchemes = _allowedInsecureSchemes,
            allowLocalhostRequest = _allowLocalhostRequest,
            allowInvalidServerCertificates = _allowInvalidServerCertificates,
            cookieStorage = _cookieStorage,
            callbackQueue = _callbackQueue,
            testBlock = _testBlock,
            comment = _comment,
            log = _log;

#if !STRIP_GTM_FETCH_LOGGING
@synthesize redirectedFromURL = _redirectedFromURL,
            logRequestBody = _logRequestBody,
            logResponseBody = _logResponseBody,
            hasLoggedError = _hasLoggedError,
            deferResponseBodyLogging = _deferResponseBodyLogging;
#endif

- (int64_t)bodyLength {
  @synchronized(self) {
    if (_bodyLength == NSURLSessionTransferSizeUnknown) {
      if (_bodyData) {
        _bodyLength = (int64_t)[_bodyData length];
      } else if (_bodyFileURL) {
        NSNumber *fileSizeNum = nil;
        NSError *fileSizeError = nil;
        if ([_bodyFileURL getResourceValue:&fileSizeNum
                                    forKey:NSURLFileSizeKey
                                     error:&fileSizeError]) {
          _bodyLength = [fileSizeNum longLongValue];
        }
      }
    }
    return _bodyLength;
  }
}

- (id)userData {
  @synchronized(self) {
    return _userData;
  }
}

- (void)setUserData:(id)theObj {
  @synchronized(self) {
    _userData = theObj;
  }
}

- (NSURL *)destinationFileURL {
  @synchronized(self) {
    return _destinationFileURL;
  }
}

- (void)setDestinationFileURL:(NSURL *)destinationFileURL {
  @synchronized(self) {
    GTMSESSION_ASSERT_DEBUG(!_sessionIdentifier,
        @"Destination File URL cannot be changed after session identifier has been created");
    _destinationFileURL = destinationFileURL;
  }
}

- (void)setProperties:(NSDictionary *)dict {
  @synchronized(self) {
    _properties = [dict mutableCopy];
  }
}

- (NSDictionary *)properties {
  @synchronized(self) {
    return _properties;
  }
}

- (void)setProperty:(id)obj forKey:(NSString *)key {
  @synchronized(self) {
    if (_properties == nil && obj != nil) {
      [self setProperties:[NSMutableDictionary dictionary]];
    }
    [_properties setValue:obj forKey:key];
  }
}

- (id)propertyForKey:(NSString *)key {
  @synchronized(self) {
    return [_properties objectForKey:key];
  }
}

- (void)addPropertiesFromDictionary:(NSDictionary *)dict {
  @synchronized(self) {
    if (_properties == nil && dict != nil) {
      [self setProperties:[dict mutableCopy]];
    } else {
      [_properties addEntriesFromDictionary:dict];
    }
  }
}

- (void)setCommentWithFormat:(id)format, ... {
#if !STRIP_GTM_FETCH_LOGGING
  NSString *result = format;
  if (format) {
    va_list argList;
    va_start(argList, format);

    result = [[NSString alloc] initWithFormat:format
                                    arguments:argList];
    va_end(argList);
  }
  [self setComment:result];
#endif
}

#if !STRIP_GTM_FETCH_LOGGING
- (NSData *)loggedStreamData {
  return _loggedStreamData;
}

- (void)appendLoggedStreamData:dataToAdd {
  if (!_loggedStreamData) {
    _loggedStreamData = [NSMutableData data];
  }
  [_loggedStreamData appendData:dataToAdd];
}

- (void)clearLoggedStreamData {
  _loggedStreamData = nil;
}
#else
+ (void)setLoggingEnabled:(BOOL)flag {
}
#endif // STRIP_GTM_FETCH_LOGGING

@end

@implementation GTMSessionFetcher (BackwardsCompatibilityOnly)

- (void)setCookieStorageMethod:(NSInteger)method {
  // For backwards compatibility with the old fetcher, we'll support the old constants.
  //
  // Clients using the GTMSessionFetcher class should set the cookie storage explicitly
  // themselves.
  NSHTTPCookieStorage *storage = nil;
  switch(method) {
    case 0:  // kGTMHTTPFetcherCookieStorageMethodStatic
             // nil storage will use [[self class] staticCookieStorage] when the fetch begins.
      break;
    case 1:  // kGTMHTTPFetcherCookieStorageMethodFetchHistory
             // Do nothing; use whatever was set by the fetcher service.
      return;
    case 2:  // kGTMHTTPFetcherCookieStorageMethodSystemDefault
      storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
      break;
    case 3:  // kGTMHTTPFetcherCookieStorageMethodNone
             // Create temporary storage for this fetcher only.
      storage = [[GTMSessionCookieStorage alloc] init];
      break;
    default:
      GTMSESSION_ASSERT_DEBUG(0, @"Invalid cookie storage method: %d", (int)method);
  }
  self.cookieStorage = storage;
}

@end

@implementation GTMSessionCookieStorage {
  NSMutableArray *_cookies;
  NSHTTPCookieAcceptPolicy _policy;
}

- (id)init {
  self = [super init];
  if (self != nil) {
    _cookies = [[NSMutableArray alloc] init];
  }
  return self;
}

- (NSArray *)cookies {
  @synchronized(self) {
    return [_cookies copy];
  }
}

- (void)setCookie:(NSHTTPCookie *)cookie {
  if (!cookie) return;
  if (_policy == NSHTTPCookieAcceptPolicyNever) return;

  @synchronized(self) {
    [self internalSetCookie:cookie];
  }
}

// Note: this should only be called from inside a @synchronized(self) block.
- (void)internalSetCookie:(NSHTTPCookie *)newCookie {
  if (_policy == NSHTTPCookieAcceptPolicyNever) return;

  BOOL isValidCookie = ([[newCookie name] length] > 0
                        && [[newCookie domain] length] > 0
                        && [[newCookie path] length] > 0);
  GTMSESSION_ASSERT_DEBUG(isValidCookie, @"invalid cookie: %@", newCookie);

  if (isValidCookie) {
    // Remove the cookie if it's currently in the array.
    NSHTTPCookie *oldCookie = [self cookieMatchingCookie:newCookie];
    if (oldCookie) {
      [_cookies removeObjectIdenticalTo:oldCookie];
    }

    if (![[self class] hasCookieExpired:newCookie]) {
      [_cookies addObject:newCookie];
    }
  }
}

// Add all cookies in the new cookie array to the storage,
// replacing stored cookies as appropriate.
//
// Side effect: removes expired cookies from the storage array.
- (void)setCookies:(NSArray *)newCookies {
  @synchronized(self) {
    [self removeExpiredCookies];

    for (NSHTTPCookie *newCookie in newCookies) {
      [self internalSetCookie:newCookie];
    }
  }
}

- (void)setCookies:(NSArray *)cookies forURL:(NSURL *)URL mainDocumentURL:(NSURL *)mainDocumentURL {
  @synchronized(self) {
    if (_policy == NSHTTPCookieAcceptPolicyNever) return;

    if (_policy == NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain) {
      NSString *mainHost = [mainDocumentURL host];
      NSString *associatedHost = [URL host];
      if (![associatedHost hasSuffix:mainHost]) {
        return;
      }
    }
  }
  [self setCookies:cookies];
}

- (void)deleteCookie:(NSHTTPCookie *)cookie {
  if (!cookie) return;

  @synchronized(self) {
    NSHTTPCookie *foundCookie = [self cookieMatchingCookie:cookie];
    if (foundCookie) {
      [_cookies removeObjectIdenticalTo:foundCookie];
    }
  }
}

// Retrieve all cookies appropriate for the given URL, considering
// domain, path, cookie name, expiration, security setting.
// Side effect: removed expired cookies from the storage array.
- (NSArray *)cookiesForURL:(NSURL *)theURL {
  NSMutableArray *foundCookies = nil;

  @synchronized(self) {
    [self removeExpiredCookies];

    // We'll prepend "." to the desired domain, since we want the
    // actual domain "nytimes.com" to still match the cookie domain
    // ".nytimes.com" when we check it below with hasSuffix.
    NSString *host = [[theURL host] lowercaseString];
    NSString *path = [theURL path];
    NSString *scheme = [theURL scheme];

    NSString *requestingDomain = nil;
    BOOL isLocalhostRetrieval = NO;

    if (IsLocalhost(host)) {
      isLocalhostRetrieval = YES;
    } else {
      if ([host length] > 0) {
        requestingDomain = [@"." stringByAppendingString:host];
      }
    }

    for (NSHTTPCookie *storedCookie in _cookies) {
      NSString *cookieDomain = [[storedCookie domain] lowercaseString];
      NSString *cookiePath = [storedCookie path];
      BOOL cookieIsSecure = [storedCookie isSecure];

      BOOL isDomainOK;

      if (isLocalhostRetrieval) {
        // Prior to 10.5.6, the domain stored into NSHTTPCookies for localhost
        // is "localhost.local"
        isDomainOK = (IsLocalhost(cookieDomain)
                      || [cookieDomain isEqual:@"localhost.local"]);
      } else {
        // Ensure we're matching exact domain names. We prepended a dot to the
        // requesting domain, so we can also prepend one here if needed before
        // checking if the request contains the cookie domain.
        if (![cookieDomain hasPrefix:@"."]) {
          cookieDomain = [@"." stringByAppendingString:cookieDomain];
        }
        isDomainOK = [requestingDomain hasSuffix:cookieDomain];
      }

      BOOL isPathOK = [cookiePath isEqual:@"/"] || [path hasPrefix:cookiePath];
      BOOL isSecureOK = (!cookieIsSecure
                         || [scheme caseInsensitiveCompare:@"https"] == NSOrderedSame);

      if (isDomainOK && isPathOK && isSecureOK) {
        if (foundCookies == nil) {
          foundCookies = [NSMutableArray array];
        }
        [foundCookies addObject:storedCookie];
      }
    }
  }
  return foundCookies;
}

// Return a cookie from the array with the same name, domain, and path as the
// given cookie, or else return nil if none found.
//
// Both the cookie being tested and all cookies in the storage array should
// be valid (non-nil name, domains, paths).
//
// Note: this should only be called from inside a @synchronized(self) block
- (NSHTTPCookie *)cookieMatchingCookie:(NSHTTPCookie *)cookie {
  NSString *name = [cookie name];
  NSString *domain = [cookie domain];
  NSString *path = [cookie path];

  GTMSESSION_ASSERT_DEBUG(name && domain && path,
                          @"Invalid stored cookie (name:%@ domain:%@ path:%@)", name, domain, path);

  for (NSHTTPCookie *storedCookie in _cookies) {
    if ([[storedCookie name] isEqual:name]
        && [[storedCookie domain] isEqual:domain]
        && [[storedCookie path] isEqual:path]) {
      return storedCookie;
    }
  }
  return nil;
}

// Internal routine to remove any expired cookies from the array, excluding
// cookies with nil expirations.
//
// Note: this should only be called from inside a @synchronized(self) block
- (void)removeExpiredCookies {
  // Count backwards since we're deleting items from the array
  for (NSInteger idx = (NSInteger)[_cookies count] - 1; idx >= 0; idx--) {
    NSHTTPCookie *storedCookie = [_cookies objectAtIndex:(NSUInteger)idx];
    if ([[self class] hasCookieExpired:storedCookie]) {
      [_cookies removeObjectAtIndex:(NSUInteger)idx];
    }
  }
}

+ (BOOL)hasCookieExpired:(NSHTTPCookie *)cookie {
  NSDate *expiresDate = [cookie expiresDate];
  if (expiresDate == nil) {
    // Cookies seem to have a Expires property even when the expiresDate method returns nil.
    id expiresVal = [[cookie properties] objectForKey:NSHTTPCookieExpires];
    if ([expiresVal isKindOfClass:[NSDate class]]) {
      expiresDate = expiresVal;
    }
  }
  BOOL hasExpired = (expiresDate != nil && [expiresDate timeIntervalSinceNow] < 0);
  return hasExpired;
}

- (void)removeAllCookies {
  @synchronized(self) {
    [_cookies removeAllObjects];
  }
}

- (NSHTTPCookieAcceptPolicy)cookieAcceptPolicy {
  @synchronized(self) {
    return _policy;
  }
}

- (void)setCookieAcceptPolicy:(NSHTTPCookieAcceptPolicy)cookieAcceptPolicy {
  @synchronized(self) {
    _policy = cookieAcceptPolicy;
  }
}

@end

void GTMSessionFetcherAssertValidSelector(id obj, SEL sel, ...) {
  // Verify that the object's selector is implemented with the proper
  // number and type of arguments
#if DEBUG
  va_list argList;
  va_start(argList, sel);

  if (obj && sel) {
    // Check that the selector is implemented
    if (![obj respondsToSelector:sel]) {
      NSLog(@"\"%@\" selector \"%@\" is unimplemented or misnamed",
                             NSStringFromClass([obj class]),
                             NSStringFromSelector(sel));
      NSCAssert(0, @"callback selector unimplemented or misnamed");
    } else {
      const char *expectedArgType;
      unsigned int argCount = 2; // skip self and _cmd
      NSMethodSignature *sig = [obj methodSignatureForSelector:sel];

      // Check that each expected argument is present and of the correct type
      while ((expectedArgType = va_arg(argList, const char*)) != 0) {

        if ([sig numberOfArguments] > argCount) {
          const char *foundArgType = [sig getArgumentTypeAtIndex:argCount];

          if (0 != strncmp(foundArgType, expectedArgType, strlen(expectedArgType))) {
            NSLog(@"\"%@\" selector \"%@\" argument %d should be type %s",
                  NSStringFromClass([obj class]),
                  NSStringFromSelector(sel), (argCount - 2), expectedArgType);
            NSCAssert(0, @"callback selector argument type mistake");
          }
        }
        argCount++;
      }

      // Check that the proper number of arguments are present in the selector
      if (argCount != [sig numberOfArguments]) {
        NSLog(@"\"%@\" selector \"%@\" should have %d arguments",
              NSStringFromClass([obj class]),
              NSStringFromSelector(sel), (argCount - 2));
        NSCAssert(0, @"callback selector arguments incorrect");
      }
    }
  }

  va_end(argList);
#endif
}

NSString *GTMFetcherCleanedUserAgentString(NSString *str) {
  // Reference http://www.w3.org/Protocols/rfc2616/rfc2616-sec2.html
  // and http://www-archive.mozilla.org/build/user-agent-strings.html

  if (str == nil) return nil;

  NSMutableString *result = [NSMutableString stringWithString:str];

  // Replace spaces and commas with underscores
  [result replaceOccurrencesOfString:@" "
                          withString:@"_"
                             options:0
                               range:NSMakeRange(0, [result length])];
  [result replaceOccurrencesOfString:@","
                          withString:@"_"
                             options:0
                               range:NSMakeRange(0, [result length])];

  // Delete http token separators and remaining whitespace
  static NSCharacterSet *charsToDelete = nil;
  if (charsToDelete == nil) {
    // Make a set of unwanted characters
    NSString *const kSeparators = @"()<>@;:\\\"/[]?={}";

    NSMutableCharacterSet *mutableChars =
        [[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy];
    [mutableChars addCharactersInString:kSeparators];
    charsToDelete = [mutableChars copy]; // hang on to an immutable copy
  }

  while (1) {
    NSRange separatorRange = [result rangeOfCharacterFromSet:charsToDelete];
    if (separatorRange.location == NSNotFound) break;

    [result deleteCharactersInRange:separatorRange];
  };

  return result;
}

NSString *GTMFetcherSystemVersionString(void) {
  static NSString *sSavedSystemString;

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
#if TARGET_OS_MAC && !TARGET_OS_IPHONE
    // Mac build
    // With Gestalt inexplicably deprecated in 10.8, we're reduced to reading
    // the system plist file.
    NSString *const kPath = @"/System/Library/CoreServices/SystemVersion.plist";
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kPath];
    NSString *versString = [plist objectForKey:@"ProductVersion"];
    if ([versString length] == 0) {
      versString = @"10.?.?";
    }
    sSavedSystemString = [[NSString alloc] initWithFormat:@"MacOSX/%@", versString];
#elif TARGET_OS_IPHONE
    // Compiling against the iPhone SDK
    // Avoid the slowness of calling currentDevice repeatedly on the iPhone
    UIDevice* currentDevice = [UIDevice currentDevice];

    NSString *rawModel = [currentDevice model];
    NSString *model = GTMFetcherCleanedUserAgentString(rawModel);

    NSString *systemVersion = [currentDevice systemVersion];

#if TARGET_IPHONE_SIMULATOR
    NSString *hardwareModel = @"sim";
#else
    NSString *hardwareModel;
    struct utsname unameRecord;
    if (uname(&unameRecord) == 0) {
      NSString *machineName = [NSString stringWithCString:unameRecord.machine
                                                 encoding:NSUTF8StringEncoding];
      hardwareModel = GTMFetcherCleanedUserAgentString(machineName);
    } else {
      hardwareModel = @"unk";
    }
#endif

    sSavedSystemString = [[NSString alloc] initWithFormat:@"%@/%@ hw/%@",
                          model, systemVersion, hardwareModel];
    // Example:  iPod_Touch/2.2 hw/iPod1_1
#elif defined(_SYS_UTSNAME_H)
    // Foundation-only build
    struct utsname unameRecord;
    uname(&unameRecord);

    sSavedSystemString = [NSString stringWithFormat:@"%s/%s",
                          unameRecord.sysname, unameRecord.release]; // "Darwin/8.11.1"
#endif
  });
  return sSavedSystemString;
}

// Return a generic name and version for the current application; this avoids
// anonymous server transactions.
NSString *GTMFetcherApplicationIdentifier(NSBundle *bundle) {
  @synchronized([GTMSessionFetcher class]) {
    static NSMutableDictionary *sAppIDMap = nil;

    // If there's a bundle ID, use that; otherwise, use the process name
    if (bundle == nil) {
      bundle = [NSBundle mainBundle];
    }
    NSString *bundleID = [bundle bundleIdentifier];
    if (bundleID == nil) {
      bundleID = @"";
    }

    NSString *identifier = [sAppIDMap objectForKey:bundleID];
    if (identifier) return identifier;

    // Apps may add a string to the info.plist to uniquely identify different builds.
    identifier = [bundle objectForInfoDictionaryKey:@"GTMUserAgentID"];
    if ([identifier length] == 0) {
      if ([bundleID length] > 0) {
        identifier = bundleID;
      } else {
        // Fall back on the procname, prefixed by "proc" to flag that it's
        // autogenerated and perhaps unreliable
        NSString *procName = [[NSProcessInfo processInfo] processName];
        identifier = [NSString stringWithFormat:@"proc_%@", procName];
      }
    }

    // Clean up whitespace and special characters
    identifier = GTMFetcherCleanedUserAgentString(identifier);

    // If there's a version number, append that
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if ([version length] == 0) {
      version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    }

    // Clean up whitespace and special characters
    version = GTMFetcherCleanedUserAgentString(version);

    // Glue the two together (cleanup done above or else cleanup would strip the
    // slash)
    if ([version length] > 0) {
      identifier = [identifier stringByAppendingFormat:@"/%@", version];
    }

    if (sAppIDMap == nil) {
      sAppIDMap = [[NSMutableDictionary alloc] init];
    }
    [sAppIDMap setObject:identifier forKey:bundleID];
    return identifier;
  }
}
