#import "VSTContext.h"
// Sanitized from the 2026-10-05 device experiment; see docs/VALIDATION.md.

#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
static void Fail(NSString *s){fprintf(stderr,"%s\n",s.UTF8String);exit(1);}
static void Save(id object,NSString *path){NSError *e=nil;NSData *d=[NSPropertyListSerialization dataWithPropertyList:object format:NSPropertyListBinaryFormat_v1_0 options:0 error:&e];if(!d||![d writeToFile:path options:NSDataWritingAtomic error:&e])Fail([e description]);if(chown(path.fileSystemRepresentation,501,501)||chmod(path.fileSystemRepresentation,0600))Fail(@"file permissions failed");id read=[NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:path] options:0 format:NULL error:&e];if(![read isEqual:object])Fail(@"readback failed");}
int main(int argc,const char **argv){@autoreleasepool{
 if(argc!=2||getuid()!=0)Fail(@"root finalize required");
 NSString *base=@(argv[1]);if(![base isEqual:VSTBackupPath()])Fail(@"invalid destination");
 NSString *mp=[base stringByAppendingPathComponent:@"manifest.plist"];
 NSMutableDictionary *manifest=[[NSDictionary dictionaryWithContentsOfFile:mp] mutableCopy];if(![manifest[@"bundleID"] isEqual:@"lt.manodrabuziai.fr"])Fail(@"manifest missing");
 NSString *source=VSTSystemIdentifiersPath();
 NSDictionary *root=[NSDictionary dictionaryWithContentsOfFile:source];NSDictionary *vendor=root[@"LSVendors"][@"Vinted Limited"];
 NSDictionary *identity=[NSDictionary dictionaryWithContentsOfFile:[base stringByAppendingPathComponent:@"identity/idfv.plist"]];
 if(![vendor[@"LSApplications"] isEqual:@[@"lt.manodrabuziai.fr"]]||![vendor[@"LSVendorIdentifier"] isEqual:identity[@"IDFV"]])Fail(@"system vendor identity mismatch");
 Save(@{@"sourcePlist":source,@"vendorName":@"Vinted Limited",@"vendorRecord":vendor},[base stringByAppendingPathComponent:@"identity/system-vendor-record.plist"]);
 manifest[@"status"]=@"complete";manifest[@"verificationPolicy"]=@"core file hashes and keychain plist readback; remaining file path/type/size/mode inventory only";manifest[@"systemVendorRecordMatchesAPI"]=@YES;manifest[@"OSVersion"]=[NSProcessInfo processInfo].operatingSystemVersionString;
 Save(manifest,mp);
 puts("backup_status=complete; vendor_record_matches=true; manifest_readback=true");
}return 0;}
