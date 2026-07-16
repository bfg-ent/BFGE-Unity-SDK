#import "KeyChainPlugin.h"
#import "UICKeyChainStore.h"
 
@implementation KeyChainPlugin
 
extern "C" {
    char* getKey(const char* key);
    void setKey(const char* userId, const char* uuid);
    void deleteKey(const char* key);
}

char* getKey(const char* key)
{
    NSString *nsKey = [NSString stringWithCString: key encoding:NSUTF8StringEncoding];
    
    NSString *value = [UICKeyChainStore stringForKey:nsKey];
    
    return makeStringCopy([value UTF8String]);
}

void setKey(const char* key, const char* value)
{
    NSString *nsKey = [NSString stringWithCString: key encoding:NSUTF8StringEncoding];
    NSString *nsValue = [NSString stringWithCString: value encoding:NSUTF8StringEncoding];
 
    [UICKeyChainStore setString:nsValue forKey:nsKey];
}
 
void deleteKey(const char* key)
{
    NSString *nsKey = [NSString stringWithCString: key encoding:NSUTF8StringEncoding];
    
    [UICKeyChainStore removeItemForKey:nsKey];
}

char* makeStringCopy(const char* str)
{
    if (str == NULL) {
        return NULL;
    }
 
    char* res = (char*)malloc(strlen(str) + 1);
    strcpy(res, str);
    return res;
}
@end
