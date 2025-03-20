//
//  FGTranslator.m
//  Fargate
//
//  Created by George Polak on 1/14/13.
//
//

#import "FGTranslator.h"
#import "FGTranslateRequest.h"
#import "NSString+FGTranslator.h"
#import <AFNetworking/AFNetworking.h>
#import <PINCache/PINCache.h>

typedef NSInteger FGTranslatorState;

enum FGTranslatorState
{
    FGTranslatorStateInitial = 0,
    FGTranslatorStateInProgress = 1,
    FGTranslatorStateCompleted = 2
};

typedef enum : NSUInteger {
    FGTranslatorServiceTypeGoogle,
    FGTranslatorServiceTypeMicrosoft,
    FGTranslatorServiceTypeUnknown,
    FGTranslatorServiceTypeDeepl,
} FGTranslatorServiceType;

float const FGTranslatorUnknownConfidence = -1;

@interface FGTranslator()
{
}

@property (nonatomic) NSString *googleAPIKey;
@property (nonatomic) NSString *azureAPIKey;
@property (nonatomic) NSString *deeplAPIKey;

//@property (nonatomic) FGTranslatorState translatorState;

@property (nonatomic) NSMutableArray <AFHTTPRequestOperation*> *operations;
@property (nonatomic, copy) FGTranslatorCompletionHandler completionHandler;

@end


@implementation FGTranslator

- (id)initWithGoogleAPIKey:(NSString *)key
{
    self = [self initGeneric];
    if (self)
    {
        self.googleAPIKey = key;
    }

    return self;
}

- (id)initWithAzureAPIKey:(NSString *)apiKey
{
    self = [self initGeneric];
    if (self)
    {
        self.azureAPIKey = apiKey;
    }

    return self;
}

- (id)initWithDeepLAPIKey:(NSString *)apiKey
{
    self = [self initGeneric];
    if (self)
    {
        self.deeplAPIKey = apiKey;
    }

    return self;
}

- (id)initGeneric
{
    self = [super init];
    if (self)
    {
        self.preferSourceGuess = YES;
        self.operations = [NSMutableArray array];
//        self.translatorState = FGTranslatorStateInitial;

        // limit translation cache to 5 MB
        PINCache *cache = [PINCache sharedCache];
        cache.diskCache.byteLimit = 5000000;
    }

    return self;
}

+ (void)flushCache
{
    [[PINCache sharedCache] removeAllObjects];
}

// TODO: also add source to cache
// make a hash for cache? works better when caching very long string
- (NSString *)cacheKeyForText:(NSString *)text target:(NSString *)target
{
    NSParameterAssert(text);

    NSMutableString *cacheKey = [NSMutableString stringWithString:text];

    if (target) {
        [cacheKey appendFormat:@"|%@", target];
    }

    switch (self.translationServiceType) {
        case FGTranslatorServiceTypeGoogle:
            [cacheKey appendFormat:@"|Google"];
            break;
        case FGTranslatorServiceTypeMicrosoft:
            [cacheKey appendFormat:@"|Azure"];
            break;
        case FGTranslatorServiceTypeDeepl:
            [cacheKey appendFormat:@"|Deepl"];
            break;
        default:
            break;
    }

    return cacheKey;
}

- (void)cacheText:(NSString *)text translated:(NSString *)translated source:(NSString *)source target: (NSString *)target
{
    if (!text || !translated)
        return;

    NSMutableDictionary *cached = [NSMutableDictionary new];
    [cached setObject:translated forKey:@"txt"];
    if (source)
        [cached setObject:source forKey:@"src"];

    [[PINCache sharedCache] setObject:cached forKey:[self cacheKeyForText:text target:target]];
}

- (void)translateText:(NSString *)text
           completion:(FGTranslatorCompletionHandler)completion
{
    [self translateText:text withSource:nil target:nil completion:completion];
}

- (void)translateText:(NSString *)text
           withSource:(NSString *)source
               target:(NSString *)target
           completion:(FGTranslatorCompletionHandler)completion
{
    [self translateTexts:@[text]
              withSource:source
                  target:target
              completion:^(NSError *error, NSArray<NSString *> *translated, NSArray<NSString *> *sourceLanguage) {
                  completion(error, translated[0], sourceLanguage[0]);
              }];
}


- (void)chunkedTranslateTexts:(NSArray <NSString*> *)texts
                   withSource:(NSString*)source
                       target:(NSString*)target
                   completion:(void(^)(NSError *error, NSArray<NSString*>*))completion {
    NSUInteger chunkLength = self.translationServiceType == FGTranslatorServiceTypeMicrosoft ? 25 :
                             self.translationServiceType == FGTranslatorServiceTypeGoogle ? 200 :
                             self.translationServiceType == FGTranslatorServiceTypeDeepl ? 50 :
                             INT_MAX;
    [self chunkedTranslationsWithTexts:texts
                        chunkCondition:^BOOL(NSArray<NSString *> *texts, NSString *thisText) {
                            return texts.count < chunkLength;
                        } translate:^(NSArray<NSString *> *texts, void (^callback)(NSError *error, NSArray<NSString *> *results)) {
                            [self translateTexts:texts
                                      withSource:source
                                          target:target completion:^(NSError *error, NSArray<NSString *> *translated, NSArray<NSString *> *sourceLanguage) {
                                              callback(error, translated);
                                          }];
                        } complete:^(NSError *error, NSArray<NSString *> *translated) {
                            completion(error, translated);
                        }];
}

- (void)translateTexts:(NSArray <NSString*> *)texts
            withSource:(NSString*)source
                target:(NSString*)target
            completion:(FGTranslatorMultipleCompletionHandler)completion {
    if (!texts || texts.count == 0) {
        completion(nil, nil, nil);
        return;
    }

    // TODO: Make this class support multiple operation at the same time

    if (self.translationServiceType == FGTranslatorServiceTypeUnknown)
    {
        NSError *error = [self errorWithCode:FGTranslatorErrorMissingCredentials
                                 description:@"missing Google or Bing credentials"];
        completion(error, nil, nil);
        return;
    }

    NSMutableArray *cachedSources = [NSMutableArray arrayWithCapacity:texts.count];
    NSMutableArray *cachedTranslations = [NSMutableArray arrayWithCapacity:texts.count];
    NSMutableArray *textsToTranslate = [NSMutableArray array];

    for (NSString *text in texts) {
        // check cache for existing translation
        NSDictionary *cached = [[PINCache sharedCache] objectForKey:[self cacheKeyForText:text target:target]];
        if (cached)
        {
            NSString *cachedSource = [cached objectForKey:@"src"];
            NSString *cachedTranslation = [cached objectForKey:@"txt"];

            NSLog(@"FGTranslator: returning cached translation");

            [cachedSources addObject:cachedSource ?: [NSNull null]];
            [cachedTranslations addObject:cachedTranslation];
        } else {
            [cachedSources addObject:[NSNull null]];
            [cachedTranslations addObject:[NSNull null]];
            [textsToTranslate addObject:text];
        }
    }

    source = [self filteredLanguageCodeFromCode:source];
    if (!target)
        target = [self filteredLanguageCodeFromCode:[[NSLocale preferredLanguages] objectAtIndex:0]];

    if ([[source lowercaseString] isEqualToString:target])
        source = nil;

    if (self.preferSourceGuess && [self shouldGuessSourceWithText:[texts objectAtIndex:0]])
        source = nil;

    void (^translateCompletion)(NSArray<NSString *> *, NSArray<NSString *> *, NSError *) = ^(NSArray<NSString *> *translatedMessages, NSArray<NSString *> *detectedSources, NSError *error) {
        if (error) {
            completion(error, nil, nil);
            return;
        }

        for (NSInteger i = 0; i < translatedMessages.count; i++) {
            NSString *translated = translatedMessages[i];
            NSString *source = detectedSources[i];

            [self cacheText:textsToTranslate[i]
                 translated:translated
                     source:source
                     target:target];
        }

        NSMutableArray *translated = [NSMutableArray arrayWithArray:translatedMessages];
        NSMutableArray *detected = [NSMutableArray arrayWithArray:detectedSources];

        // merge translated text into cached array
        for (NSInteger i = 0; i < cachedTranslations.count; i++) {
            NSString *cached = [cachedTranslations objectAtIndex:i];
            if ([cached isKindOfClass:[NSNull class]]) {
                [cachedTranslations replaceObjectAtIndex:i withObject:[translated objectAtIndex:0]];
                [cachedSources replaceObjectAtIndex:i withObject:[detected objectAtIndex:0]];
                [translated removeObjectAtIndex:0];
                [detected removeObjectAtIndex:0];
                if (translated.count == 0) {
                    break;
                }
            }
        }
        completion(nil, cachedTranslations, cachedSources);
        // TODO: make cachedSource a string, not array
    };

    if (textsToTranslate.count == 0) {
        translateCompletion(@[], @[], nil);
        return;
    }

    switch (self.translationServiceType) {
        case FGTranslatorServiceTypeGoogle: {
            __block AFHTTPRequestOperation *operation = [FGTranslateRequest googleTranslateMessages:textsToTranslate
                                             withSource:source
                                                 target:target
                                                    key:self.googleAPIKey
                                              quotaUser:self.quotaUser
                                                referer:self.referer
                                             completion:^(NSArray<NSString *> *translatedMessages, NSArray<NSString *> *detectedSources, NSError *error) {
                                                 translateCompletion(translatedMessages, detectedSources, error);
                                                 [self.operations removeObject:operation];
                                             }];
            [self.operations addObject:operation];
        }
            break;
        case FGTranslatorServiceTypeMicrosoft: {
            __block AFHTTPRequestOperation *operation = [FGTranslateRequest bingTranslateMessages:textsToTranslate
                                           withSource:source
                                               target:target
                                               apiKey:self.azureAPIKey
                                           completion:^(NSArray<NSString *> *translatedMessages, NSArray<NSString *> *detectedSource, NSError *error) {
                                               translateCompletion(translatedMessages, detectedSource, error);
                                               [self.operations removeObject:operation];
                                           }];
            [self.operations addObject:operation];
            }
            break;
        case FGTranslatorServiceTypeDeepl: {
            __block AFHTTPRequestOperation *operation = [FGTranslateRequest deeplTranslateMessages:textsToTranslate
                                           withSource:source
                                               target:target
                                               apiKey:self.deeplAPIKey
                                           completion:^(NSArray<NSString *> *translatedMessages, NSArray<NSString *> *detectedSource, NSError *error) {
                                               translateCompletion(translatedMessages, detectedSource, error);
                                               [self.operations removeObject:operation];
                                           }];
            [self.operations addObject:operation];
        }
            break;
        default: {
            NSError *error = [self errorWithCode:FGTranslatorErrorMissingCredentials
                                     description:@"missing Google or Bing credentials"];
            completion(error, nil, nil);

//            self.translatorState = FGTranslatorStateCompleted;
        }
            break;
    }
}

- (void)handleError:(NSError *)error
{
    FGTranslatorError errorState = error.code == FGTranslationErrorBadRequest ? FGTranslatorErrorUnableToTranslate : FGTranslatorErrorNetworkError;

    NSError *fgError = [self errorWithCode:errorState description:nil];
    if (self.completionHandler)
        self.completionHandler(fgError, nil, nil);
}

- (void)handleSuccessWithOriginal:(NSString *)original
                translatedMessage:(NSString *)translatedMessage
                   detectedSource:(NSString *)detectedSource
						   target:(NSString *)target
{
    self.completionHandler(nil, translatedMessage, detectedSource);
    [self cacheText:original translated:translatedMessage source:detectedSource target:target];
}

- (void)cancel
{
    self.completionHandler = nil;
    for (AFHTTPRequestOperation *operation in self.operations) {
        [operation cancel];
    }
}


#pragma mark - Utils

- (FGTranslatorServiceType)translationServiceType {
    if (self.googleAPIKey.length) {
        return FGTranslatorServiceTypeGoogle;
    } else if (self.azureAPIKey.length) {
        return FGTranslatorServiceTypeMicrosoft;
    } else if (self.deeplAPIKey.length) {
        return FGTranslatorServiceTypeDeepl;
    }
    return FGTranslatorServiceTypeUnknown;
}

- (BOOL)shouldGuessSourceWithText:(NSString *)text
{
    return [text wordCount] >= 5 && [text wordCharacterCount] >= 25;
}

- (NSError *)errorWithCode:(NSInteger)code description:(NSString *)description
{
    NSDictionary *userInfo = nil;
    if (description)
        userInfo = [NSDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];

    return [NSError errorWithDomain:FG_TRANSLATOR_ERROR_DOMAIN code:code userInfo:userInfo];
}

// massage languge code to make Google Translate happy
// TODO: do we really need this
- (NSString *)filteredLanguageCodeFromCode:(NSString *)code
{
    if (!code || code.length <= 3)
        return code;

    if ([code isEqualToString:@"zh-Hant"] || [code isEqualToString:@"zh-TW"])
        return @"zh-TW";
    else if ([code hasSuffix:@"input"])
        // use phone's default language if crazy (keyboard) inputs are detected
        return [[NSLocale preferredLanguages] objectAtIndex:0];
    else
        // trim stuff like en-GB to just en which Google Translate understands
        return [code substringToIndex:2];
}
#pragma mark - Batch and fallback

- (void)cachedTranslationsWithTexts:(NSArray <NSString*> *)texts
                             source:(NSString *)source
                             target:(NSString *)target
                          translate:(void(^)(NSArray <NSString *>*texts, void(^)(NSError *error, NSArray <NSString*> *results)))translate
                           complete:(void(^)(NSError *error, NSArray <NSString*> *translated))callback {
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:texts.count];
    NSMutableArray *toTranslate = [NSMutableArray array];
    for (NSInteger i = 0; i < texts.count; i++) {
        NSString *text = texts[i];
        // TODO: here!
        NSString *cached = [self cacheKeyForText:text target:target];
        if (cached) {
            [results addObject:cached];
        } else {
            [results addObject:[NSNull null]];
            [toTranslate addObject:text];
        }
    }
    if (!toTranslate.count) {
        callback(nil, results);
        return;
    }
    translate(toTranslate, ^(NSError *error, NSArray <NSString *> *translationResults) {
        if (error) {
            callback(error, nil);
            return;
        }
        for (NSInteger i = 0, j = 0; i < results.count; i++) {
            if ([results[i] isKindOfClass:[NSNull class]]) {
                [results replaceObjectAtIndex:i
                                   withObject:translationResults[j]];
                j++;
            }
        }
        callback(nil, results);
    });
}

- (void)chunkedTranslationsWithTexts:(NSArray <NSString*> *)texts
                      chunkCondition:(BOOL(^)(NSArray <NSString*> *texts, NSString *thisText))condition
                           translate:(void(^)(NSArray <NSString *>*texts, void(^)(NSError *error, NSArray <NSString*> *results)))translate
                            complete:(void(^)(NSError *error, NSArray <NSString*> *translated))callback {
    NSMutableArray *allTexts = [NSMutableArray arrayWithArray:texts];
    NSMutableArray <NSArray<NSString*>*> *chunks = [NSMutableArray array];
    while (allTexts.count) {
        NSMutableArray *thisChunkTexts = [NSMutableArray array];
        while (allTexts.count) {
            NSString *thisText = allTexts[0];
            if (!thisChunkTexts.count /* Dont allow empty chunk */ || condition(thisChunkTexts, thisText)) {
                [thisChunkTexts addObject:thisText];
                [allTexts removeObjectAtIndex:0];
            } else {
                break;
            }
        }
        [chunks addObject:thisChunkTexts];
    }

    NSMutableArray *errors = [NSMutableArray arrayWithCapacity:chunks.count];
    NSMutableArray *translatedChunks = [NSMutableArray arrayWithCapacity:chunks.count];
    NSLock *errorArrayLock = [[NSLock alloc] init];
    dispatch_group_t group = dispatch_group_create();
    for (NSArray <NSString*> *thisTexts in chunks) {
        NSMutableArray *thisChunk = [NSMutableArray array];
        [translatedChunks addObject:thisChunk];
        dispatch_group_enter(group);
        translate(thisTexts, ^(NSError *error, NSArray <NSString *> *results) {
            [thisChunk addObjectsFromArray:results];
            if (error) {
                [errorArrayLock lock];
                [errors addObject:error];
                [errorArrayLock unlock];
            }
            dispatch_group_leave(group);
        });
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (errors.count) {
            NSString *jointErrorString = [[errors valueForKey:@"localizedDescription"] componentsJoinedByString:@"\n"];
            NSError *error = [self errorWithCode:FGTranslatorErrorUnableToTranslate
                    description:[NSString stringWithFormat:NSLocalizedString(@"Errors during translation:\n%@", nil), jointErrorString]];
            callback(error, nil);
            return;
        }
        NSArray <NSString*> *flattenedArray = [translatedChunks valueForKeyPath: @"@unionOfArrays.self"];
        callback(nil, flattenedArray);
    });
}

@end
