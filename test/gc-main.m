#include "test.h"

@interface Main @end
@implementation Main @end

int main(int argc __attribute__((unused)), char **argv)
{
    succeed(basename(argv[0]));
}
