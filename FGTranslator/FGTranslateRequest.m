//
//  FGTranslateRequest.m
//  FGTranslatorDemo
//
//  Created by George Polak on 8/12/14.
//  Copyright (c) 2014 George Polak. All rights reserved.
//

#import "FGTranslateRequest.h"
#import "NSString+FGTranslator.h"
#import "XMLDictionary.h"
#import "FGTranslator.h"

@implementation FGTranslateRequest

NSString *const FG_TRANSLATOR_ERROR_DOMAIN = @"FGTranslatorErrorDomain";

NSString *const FG_TRANSLATOR_AZURE_TOKEN = @"FG_TRANSLATOR_AZURE_TOKEN";
NSString *const FG_TRANSLATOR_AZURE_TOKEN_EXPIRY = @"FG_TRANSLATOR_AZURE_TOKEN_EXPIRY";


#pragma mark - Google

+ (AFHTTPRequestOperation *)googleTranslateMessages:(NSArray <NSString*> *)messages
                                         withSource:(NSString *)source
                                             target:(NSString *)target
                                                key:(NSString *)key
                                          quotaUser:(NSString *)quotaUser
                                            referer:(NSString*)referer
                                         completion:(void (^)(NSArray <NSString*> *translatedMessages,
                                                              NSArray <NSString*> *detectedSources,
                                                              NSError *error))completion {
    
    NSURL *requestURL = [NSURL URLWithString:@"https://www.googleapis.com/language/translate/v2"];
    
    NSMutableString *queryString = [NSMutableString string];
    // API key
    [queryString appendFormat:@"key=%@", key];
    // output style
    [queryString appendString:@"&format=text"];
    [queryString appendString:@"&prettyprint=false"];
    
    // source language
    if (source)
        [queryString appendFormat:@"&source=%@", source];
    
    // target language
    [queryString appendFormat:@"&target=%@", target];
    
    // quota
    if (quotaUser.length > 0)
        [queryString appendFormat:@"&quotaUser=%@", quotaUser];
    
    // message
    for (NSString *message in messages) {
        [queryString appendFormat:@"&q=%@", [NSString urlEncodedStringFromString:message]];
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];

    [request setHTTPMethod:@"POST"];
    [request setValue:@"GET" forHTTPHeaderField:@"X-HTTP-Method-Override"];
    [request setHTTPBody:[queryString dataUsingEncoding:NSUTF8StringEncoding]];
    
    if (referer) {
        [request setValue:referer forHTTPHeaderField:@"Referer"];
    }
    
    AFHTTPRequestOperation *operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
    operation.responseSerializer = [AFJSONResponseSerializer serializer];
    
    [operation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject)
    {
        NSArray *translations = [[responseObject objectForKey:@"data"] objectForKey:@"translations"];
        
        NSMutableArray <NSString*> *translatedTexts = [NSMutableArray arrayWithCapacity:translations.count];
        NSMutableArray <NSString*> *detectedSources = [NSMutableArray arrayWithCapacity:translations.count];
        
        for (NSDictionary *translation in translations) {
            [translatedTexts addObject:[translation objectForKey:@"translatedText"]];
            [detectedSources addObject:[translation objectForKey:@"detectedSourceLanguage"] ?: source];
        }
        
        completion(translatedTexts, detectedSources, nil);
        
    } failure:^(AFHTTPRequestOperation *operation, NSError *error)
    {
        NSLog(@"FGTranslator: failed Google translate: %@", operation.responseObject);
        
        NSInteger code = error.code == 400 ? FGTranslationErrorBadRequest : FGTranslationErrorOther;
        NSError *fgError = [NSError errorWithDomain:FG_TRANSLATOR_ERROR_DOMAIN code:code userInfo:@{
            NSLocalizedDescriptionKey: operation.responseObject[@"error"][@"errors"][0][@"message"] ?: @""
        }];
        
        completion(nil, nil, fgError);
    }];
    [operation start];
    
    return operation;
}

+ (AFHTTPRequestOperation *)googleDetectLanguage:(NSString *)text
                                             key:(NSString *)key
                                       quotaUser:(NSString *)quotaUser
                                         referer:(NSString*)referer
                                      completion:(void (^)(NSString *detectedSource, float confidence, NSError *error))completion
{
    NSURL *base = [NSURL URLWithString:@"https://www.googleapis.com/language/translate/v2/detect"];
    
    NSMutableString *queryString = [NSMutableString string];
    // API key
    [queryString appendFormat:@"?key=%@", key];
    // output style
    [queryString appendString:@"&format=text"];
    [queryString appendString:@"&prettyprint=false"];
    
    // quota
    if (quotaUser.length > 0)
        [queryString appendFormat:@"&quotaUser=%@", quotaUser];
    
    // message
    [queryString appendFormat:@"&q=%@", [NSString urlEncodedStringFromString:text]];
    
    NSURL *requestURL = [NSURL URLWithString:queryString relativeToURL:base];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
    if (referer) {
        [request setValue:referer forHTTPHeaderField:@"Referer"];
    }
    
    AFHTTPRequestOperation *operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
    operation.responseSerializer = [AFJSONResponseSerializer serializer];
    
    [operation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject)
     {
         NSDictionary *translation = [[[[responseObject objectForKey:@"data"] objectForKey:@"detections"] objectAtIndex:0] objectAtIndex:0];
         NSString *detectedSource = [translation objectForKey:@"language"];
         float confidence = [[translation objectForKey:@"confidence"] floatValue];
         
         completion(detectedSource, confidence, nil);
         
     } failure:^(AFHTTPRequestOperation *operation, NSError *error)
     {
         NSLog(@"FGTranslator: failed Google language detect: %@", operation.responseObject);
         
         NSInteger code = error.code == 400 ? FGTranslationErrorBadRequest : FGTranslationErrorOther;
         NSError *fgError = [NSError errorWithDomain:FG_TRANSLATOR_ERROR_DOMAIN code:code userInfo:nil];
         
         completion(nil, FGTranslatorUnknownConfidence, fgError);
     }];
    [operation start];
    
    return operation;
}

+ (AFHTTPRequestOperation *)googleSupportedLanguagesWithKey:(NSString *)key
                                                  quotaUser:(NSString *)quotaUser
                                                    referer:(NSString*)referer
                                                 completion:(void (^)(NSArray *languageCodes, NSError *error))completion
{
    NSURL *base = [NSURL URLWithString:@"https://www.googleapis.com/language/translate/v2/languages"];
    
    NSMutableString *queryString = [NSMutableString string];
    // API key
    [queryString appendFormat:@"?key=%@", key];
    // output style
    [queryString appendString:@"&format=text"];
    [queryString appendString:@"&prettyprint=false"];
    
    // quota
    if (quotaUser.length > 0)
        [queryString appendFormat:@"&quotaUser=%@", quotaUser];
    
    NSURL *requestURL = [NSURL URLWithString:queryString relativeToURL:base];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
    if (referer) {
        [request setValue:referer forHTTPHeaderField:@"Referer"];
    }
    
    AFHTTPRequestOperation *operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
    operation.responseSerializer = [AFJSONResponseSerializer serializer];
    
    [operation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject)
    {
        NSMutableArray *languageCodes = [NSMutableArray new];
        
        NSArray *languages = [[responseObject objectForKey:@"data"] objectForKey:@"languages"];
        for (NSDictionary *element in languages)
        {
            NSString *code = [element objectForKey:@"language"];
            if (code.length > 0)
                [languageCodes addObject:code];
        }
         
        completion(languageCodes, nil);
         
     } failure:^(AFHTTPRequestOperation *operation, NSError *error)
     {
         NSLog(@"FGTranslator: failed Google supported languages: %@", operation.responseObject);
         
         NSInteger code = error.code == 400 ? FGTranslationErrorBadRequest : FGTranslationErrorOther;
         NSError *fgError = [NSError errorWithDomain:FG_TRANSLATOR_ERROR_DOMAIN code:code userInfo:nil];
         
         completion(nil, fgError);
     }];
    [operation start];
    
    return operation;
}


#pragma mark - Bing

+ (AFHTTPRequestOperation *)bingTranslateMessages:(NSArray <NSString*> *)messages
                                       withSource:(NSString *)source
                                           target:(NSString *)target
                                           apiKey:(NSString *)apiKey
                                       completion:(void (^)(NSArray <NSString*> *translatedMessage, NSArray <NSString*> *detectedSource, NSError *error))completion {

    NSMutableString *queryString = [NSMutableString stringWithString:@"api-version=3.0"];

    // target language
    [queryString appendFormat:@"&to=%@", target];

    // source language
    if (source)
        [queryString appendFormat:@"&from=%@", source];

    // message

    NSMutableArray <NSDictionary<NSString*, NSString*>*> *reqBody = [NSMutableArray arrayWithCapacity:messages.count];
    for (NSString *message in messages) {
        [reqBody addObject:@{@"text": message}];
    }

    NSURL *requestURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.cognitive.microsofttranslator.com/translate?%@", queryString]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
    [request setHTTPMethod:@"POST"];
    [request setValue:apiKey forHTTPHeaderField:@"Ocp-Apim-Subscription-Key"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSError *error = nil;

    [request setHTTPBody:[NSJSONSerialization dataWithJSONObject:reqBody
                                                         options:0
                                                           error:&error]];

    AFHTTPRequestOperation *operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
    operation.responseSerializer = [AFJSONResponseSerializer serializer];

    // Microsoft doesn't like standard
    operation.responseSerializer.acceptableContentTypes = [NSSet setWithObject:@"application/json"];

    [operation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, NSArray *responseObject)
     {
         NSMutableArray *translated = [NSMutableArray array];
         NSMutableArray *sources = [NSMutableArray array];

         for (NSDictionary *dict in responseObject) {
             NSArray *translations = dict[@"translations"];
             [translated addObject:translations[0][@"text"]];
             [sources addObject:source];
         }
         completion(translated, sources, nil);
     }
                                     failure:^(AFHTTPRequestOperation *operation, NSError *error)
     {
         NSError *fgError = [NSError errorWithDomain:FG_TRANSLATOR_ERROR_DOMAIN code:FGTranslationErrorOther userInfo:error.userInfo];
         completion(nil, nil, fgError);
     }];

    [operation start];
    return operation;
}

#pragma mark - DeepL

+ (AFHTTPRequestOperation *)deeplTranslateMessages:(NSArray <NSString*> *)messages
                                        withSource:(NSString *)source
                                            target:(NSString *)target
                                            apiKey:(NSString *)apiKey
                                        completion:(void (^)(NSArray <NSString*> *translatedMessage, NSArray <NSString*> *detectedSource, NSError *error))completion {

    NSDictionary *reqBody = @{
        @"text": messages,
        @"target_lang": target,
        @"source_lang": source
    };

    NSURL *requestURL = [NSURL URLWithString:@"https://api-free.deepl.com/v2/translate"];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"DeepL-Auth-Key %@", apiKey] forHTTPHeaderField:@"Authorization"];

    NSError *error = nil;

    [request setHTTPBody:[NSJSONSerialization dataWithJSONObject:reqBody
                                                         options:0
                                                           error:&error]];

    AFHTTPRequestOperation *operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
    operation.responseSerializer = [AFJSONResponseSerializer serializer];

    // Microsoft doesn't like standard
    operation.responseSerializer.acceptableContentTypes = [NSSet setWithObject:@"application/json"];

    [operation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject)
     {
        NSLog(@"responseObject %@", responseObject);
         NSMutableArray *translated = [NSMutableArray array];
         NSMutableArray *sources = [NSMutableArray array];
        for (NSDictionary *translation in responseObject[@"translations"]) {
            NSString *translatedText = translation[@"text"];
            [translated addObject:translatedText];
            [sources addObject:translation[@"detected_source_language"] ?: source];
        }
        completion(translated, sources, nil);
     }
                                     failure:^(AFHTTPRequestOperation *operation, NSError *error)
     {
         NSError *fgError = [NSError errorWithDomain:FG_TRANSLATOR_ERROR_DOMAIN code:FGTranslationErrorOther userInfo:error.userInfo];
         completion(nil, nil, fgError);
     }];

    [operation start];
    return operation;
}

@end
