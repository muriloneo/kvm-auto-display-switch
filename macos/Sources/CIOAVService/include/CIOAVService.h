#ifndef CIOAVSERVICE_H
#define CIOAVSERVICE_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

// Private API exported by IOKit on Apple Silicon. Same entry points used by
// MonitorControl (Arm64DDC) and m1ddc. Not declared in any public SDK header.
typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef _Nullable IOAVServiceCreateWithService(CFAllocatorRef _Nullable allocator,
                                                            io_service_t service) CF_RETURNS_RETAINED;

extern IOReturn IOAVServiceReadI2C(IOAVServiceRef _Nonnull service, uint32_t chipAddress,
                                   uint32_t offset, void *_Nonnull outputBuffer,
                                   uint32_t outputBufferSize);

extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef _Nonnull service, uint32_t chipAddress,
                                    uint32_t dataAddress, void *_Nonnull inputBuffer,
                                    uint32_t inputBufferSize);

#endif
