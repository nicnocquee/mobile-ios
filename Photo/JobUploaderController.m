//
//  JobUploaderController.m
//  Trovebox
//
//  Created by Patrick Santana on 03/07/12.
//  Copyright 2013 Trovebox
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "JobUploaderController.h"

@interface JobUploaderController (){
    BOOL running;
}
- (void) executeJob;

@end

@implementation JobUploaderController


+ (JobUploaderController*) getController
{
    static dispatch_once_t pred;
    static JobUploaderController *shared = nil;
    
    dispatch_once(&pred, ^{
        shared = [[JobUploaderController alloc] init];
    });
    
    return shared;
}

- (void) start
{
    running = YES;
    
    dispatch_queue_t jobQueue = dispatch_queue_create("job_queue", NULL);
    dispatch_async(jobQueue, ^{
        @try {
            // start the thread
            while (running) {
                // sleep for 3 seconds
                [NSThread sleepForTimeInterval:3];
                // execute the method
                [self executeJob];
            }
        }@catch (NSException *exception) {
            NSLog(@"Error in the job %@", [exception description]);
        }
    });
    dispatch_release(jobQueue);
}

- (void) stop
{
    // this will stop the thread
    running = NO;
}

- (BOOL) isRunning
{
    return running;
}


- (void) executeJob
{
    dispatch_async(dispatch_get_main_queue(), ^{
#ifdef DEVELOPMENT_ENABLED
        NSLog(@"Executing job");
#endif
        
        int i = [Timeline howEntitiesTimelineInManagedObjectContext:[SharedAppDelegate managedObjectContext] type:kUploadStatusTypeUploading];
        int created = [Timeline howEntitiesTimelineInManagedObjectContext:[SharedAppDelegate managedObjectContext] type:kUploadStatusTypeCreated];
        
        // disable or enable the lock screen
        if (created > 0){
            // disable lock screen
            [UIApplication sharedApplication].idleTimerDisabled = YES;
        }else{
            // enable lock screen
            [UIApplication sharedApplication].idleTimerDisabled = NO;
        }
        
        if (i < 2 && created > 0){
            
            //  looks for uploads in the state WAITING
            NSArray *waitings = [Timeline getNextWaitingToUploadInManagedObjectContext:[SharedAppDelegate managedObjectContext] qtd:2-i];
            
            // loop in the list and start to upload
            for (Timeline *photo in waitings){
                photo.status = kUploadStatusTypeUploading;
                
                // create a delegate
                JobUploaderDelegate *delegate = [[JobUploaderDelegate alloc] initWithPhoto:photo size:[NSNumber numberWithInteger:0]];
                
                NSDictionary *dictionary = nil;
                @try {
                    dictionary = [photo toDictionary];
                }
                @catch (NSException *e) {
                    photo.status = kUploadStatusTypeFailed;
                    break;
                }
                
                // send
                NSURL *storedURL = [NSURL URLWithString:photo.photoDataTempUrl];
                NSData *data = [[NSData alloc] initWithContentsOfURL:storedURL];
                
                dispatch_queue_t uploader = dispatch_queue_create("job_uploader", NULL);
                dispatch_async(uploader, ^{
                    
                    @try{
                        // prepare the data to upload
                        NSString *filename = photo.fileName;
   
                        // set size
                        delegate.totalSize = [NSNumber numberWithInteger:data.length];
                        
                        // create the service, check photo exists and send the request
                        WebService *service = [[WebService alloc] init];
                        
                        // before check if the photo already exist
                        if ([service isPhotoAlreadyOnServer:[SHA1 sha1File:data]]){
                            @throw  [NSException exceptionWithName:@"Failed to upload" reason:@"409" userInfo: nil];
                        }else{
                            NSDictionary *response = [service uploadPicture:data metadata:dictionary fileName:filename delegate:delegate];
#ifdef DEVELOPMENT_ENABLED
                            NSLog(@"Photo uploaded correctly");
#endif
                            
                            dispatch_async(dispatch_get_main_queue(), ^{
                                // save the url
                                if (photo.syncedUrl){
                                    // add to the sync list, with that we don't need to show photos already uploaded.
                                    // in the case of edited images via Aviary, we don't save it.
                                    Synced *sync =  [NSEntityDescription insertNewObjectForEntityForName:@"Synced"
                                                                                        inManagedObjectContext:[SharedAppDelegate managedObjectContext]];
                                    sync.filePath = photo.syncedUrl;
                                    sync.status = kSyncedStatusTypeUploaded;
                                    
                                    // used to say which user uploaded this image
                                    sync.userUrl = [SharedAppDelegate userHost];
                                }
                                
                                photo.status = kUploadStatusTypeUploadFinished;
                                photo.photoUploadResponse = [NSDictionarySerializer nsDictionaryToNSData:[response objectForKey:@"result"]];
                                
                                // delete local file
                                NSFileManager *fileManager = [NSFileManager defaultManager];
                                NSError *error;
                                BOOL fileExists = [fileManager fileExistsAtPath:photo.photoDataTempUrl];
#ifdef DEVELOPMENT_ENABLED
                                NSLog(@"Path to file: %@", photo.photoDataTempUrl);
                                NSLog(@"File exists: %d", fileExists);
                                NSLog(@"Is deletable file at path: %d", [fileManager isDeletableFileAtPath:photo.photoDataTempUrl]);
#endif
                                if (fileExists)
                                {
                                    BOOL success = [fileManager removeItemAtPath:photo.photoDataTempUrl error:&error];
                                    if (!success) NSLog(@"Error: %@", [error localizedDescription]);
                                }
                                
                                // check if there is more files to upload
                                // if not, refresh the Home page
                                if ( [Timeline howEntitiesTimelineInManagedObjectContext:[SharedAppDelegate managedObjectContext] type:kUploadStatusTypeUploading] == 0 &&
                                    [Timeline howEntitiesTimelineInManagedObjectContext:[SharedAppDelegate managedObjectContext] type:kUploadStatusTypeCreated] == 0){
                                    
                                    // set that needs update - Home
                                    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationNeededsUpdateHome object:nil];
                                    // refresh profile details
                                    [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationProfileRefresh object:nil userInfo:nil];
                                    
                                    // also lets save the Managed Context
                                    NSError *saveError = nil;
                                    if (![[SharedAppDelegate managedObjectContext] save:&saveError]){
                                        NSLog(@"Error to save context = %@",[saveError localizedDescription]);
                                    }
                                }
                            });
                        }
                    }@catch (NSException* e) {
                        NSLog(@"Error to upload image:%@", [e description]);
                        
                        // if it fails for any reason, set status FAILED in the main thread
                        dispatch_async(dispatch_get_main_queue(), ^{
                            // check if it is duplicated
                            if ([[e description] hasPrefix:@"Error: 409 - This photo already exists based on a"] ||
                                [[e description] hasPrefix:@"409"]){
                                
                                // this photo is already uploaded
                                if (photo.syncedUrl){
                                    // add to the sync list, with that we don't need to show photos already uploaded.
                                    // in the case of edited images via Aviary, we don't save it.
                                    Synced *sync =  [NSEntityDescription insertNewObjectForEntityForName:@"Synced"
                                                                                  inManagedObjectContext:[SharedAppDelegate managedObjectContext]];
                                    sync.filePath = photo.syncedUrl;
                                    sync.status = kSyncedStatusTypeUploaded;
                                    
                                    // used to say which user uploaded this image
                                    sync.userUrl = [SharedAppDelegate userHost];
                                }
                                photo.status = kUploadStatusTypeDuplicated;
                            }else if ([[e description] hasPrefix:@"402"]){
                                photo.status = kUploadStatusTypeLimitReached;
                                photo.photoUploadProgress = 0;
                            }else {
                                photo.status = kUploadStatusTypeFailed;
                                photo.photoUploadProgress = 0;
                            }
                            
                            if ( [Timeline howEntitiesTimelineInManagedObjectContext:[SharedAppDelegate managedObjectContext] type:kUploadStatusTypeUploading] == 0 &&
                                [Timeline howEntitiesTimelineInManagedObjectContext:[SharedAppDelegate managedObjectContext] type:kUploadStatusTypeCreated] == 0){
                                
                                // set that needs update - Home
                                [[NSNotificationCenter defaultCenter] postNotificationName:kNotificationNeededsUpdateHome object:nil];
                            }
                        });
                    }@finally{
                        // delete local file
                        NSFileManager *fileManager = [NSFileManager defaultManager];
                        NSError *error;
                        BOOL fileExists = [fileManager fileExistsAtPath:photo.photoDataTempUrl];
#ifdef DEVELOPMENT_ENABLED
                        NSLog(@"Path to file: %@", photo.photoDataTempUrl);
                        NSLog(@"File exists: %d", fileExists);
                        NSLog(@"Is deletable file at path: %d", [fileManager isDeletableFileAtPath:photo.photoDataTempUrl]);
#endif
                        if (fileExists)
                        {
                            BOOL success = [fileManager removeItemAtPath:photo.photoDataTempUrl error:&error];
                            if (!success) NSLog(@"Error: %@", [error localizedDescription]);
                        }
                        
                    }
                });
                dispatch_release(uploader);
            }
        }
    });
}
@end