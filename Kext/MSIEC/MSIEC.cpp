/*
 * MSIEC — minimal MSI embedded-controller access kext for macOS.
 *
 * Part of YAMDCC for macOS. GPL-3.0-or-later.
 *
 * macOS does not expose EC port I/O (0x62/0x66) to user space. This kext
 * implements the same command protocol as YAMDCC's Windows EC library and
 * exposes it through a tiny IOUserClient:
 *
 *   selector 0: read(reg)                  -> scalar output 0
 *   selector 1: write(reg, value)          -> scalar output 0 (echo)
 *   selector 2: readBlock(reg, length)     -> struct output (<= 64 bytes)
 *
 * Build with build.sh (Command Line Tools are enough).
 */

#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOKitKeys.h>

#define super IOService

// MARK: - Port I/O
//
// The SDK does not ship <i386/io.h> for kernel extensions any more, so the
// two instructions we need are provided inline.

static inline UInt8 ecInb(UInt16 port)
{
    UInt8 value;
    __asm__ __volatile__("inb %w1, %0" : "=a"(value) : "Nd"(port));
    return value;
}

static inline void ecOutb(UInt16 port, UInt8 value)
{
    __asm__ __volatile__("outb %0, %w1" : : "a"(value), "Nd"(port));
}

// MARK: - Constants

static const UInt16 kECStatusPort = 0x66;
static const UInt16 kECDataPort   = 0x62;

static const UInt8 kECReadCmd     = 0x80;
static const UInt8 kECWriteCmd    = 0x81;

static const UInt8 kECOBF = 0x01; // output buffer full
static const UInt8 kECIBF = 0x02; // input buffer full

static const UInt32 kMaxPolls = 2000;   // ~100 ms with 50 µs delay
static const UInt32 kPollDelayUs = 50;

enum {
    kSelectorReadEC = 0,
    kSelectorWriteEC = 1,
    kSelectorReadBlock = 2,
};

// MARK: - Driver

class com_yamdcc_MSIECUserClient;

class com_yamdcc_MSIEC : public IOService
{
    OSDeclareDefaultStructors(com_yamdcc_MSIEC)

public:
    virtual bool init(OSDictionary *dictionary = 0) APPLE_KEXT_OVERRIDE;
    virtual void free() APPLE_KEXT_OVERRIDE;
    virtual IOService *probe(IOService *provider, SInt32 *score) APPLE_KEXT_OVERRIDE;
    virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;

    virtual IOReturn newUserClient(task_t owningTask, void *securityID,
                                   UInt32 type, OSDictionary *properties,
                                   IOUserClient **handler) APPLE_KEXT_OVERRIDE;

    IOReturn readEC(UInt8 reg, UInt8 *value);
    IOReturn writeEC(UInt8 reg, UInt8 value);
    IOReturn readBlockEC(UInt8 reg, UInt8 *buffer, UInt32 length);

private:
    IOLock *fLock = nullptr;
    bool waitInputBufferEmpty();
    bool waitOutputBufferFull();
};

OSDefineMetaClassAndStructors(com_yamdcc_MSIEC, IOService)

bool com_yamdcc_MSIEC::init(OSDictionary *dictionary)
{
    if (!super::init(dictionary)) {
        return false;
    }
    fLock = IOLockAlloc();
    return fLock != nullptr;
}

void com_yamdcc_MSIEC::free()
{
    if (fLock) {
        IOLockFree(fLock);
        fLock = nullptr;
    }
    super::free();
}

IOService *com_yamdcc_MSIEC::probe(IOService *provider, SInt32 *score)
{
    IOService *result = super::probe(provider, score);
    if (!result) {
        return nullptr;
    }
    // A missing/floating EC usually reads back 0xFF on the status port.
    UInt8 status = ecInb(kECStatusPort);
    if (status == 0xFF) {
        IOLog("MSIEC: no embedded controller found (status=0xFF)\n");
        return nullptr;
    }
    return result;
}

bool com_yamdcc_MSIEC::start(IOService *provider)
{
    if (!super::start(provider)) {
        return false;
    }

    // Publish the EC firmware version so userspace can show it.
    char firmware[13] = {0};
    for (int i = 0; i < 12; i++) {
        UInt8 value = 0;
        if (readEC((UInt8)(0xA0 + i), &value) == kIOReturnSuccess) {
            firmware[i] = (char)value;
        }
    }
    if (firmware[0] != 0) {
        setProperty("ECFirmwareVersion", firmware);
        IOLog("MSIEC: EC firmware %s\n", firmware);
    }

    registerService();
    IOLog("MSIEC: started\n");
    return true;
}

void com_yamdcc_MSIEC::stop(IOService *provider)
{
    IOLog("MSIEC: stopped\n");
    super::stop(provider);
}

// MARK: EC protocol

bool com_yamdcc_MSIEC::waitInputBufferEmpty()
{
    for (UInt32 i = 0; i < kMaxPolls; i++) {
        if ((ecInb(kECStatusPort) & kECIBF) == 0) {
            return true;
        }
        IODelay(kPollDelayUs);
    }
    return false;
}

bool com_yamdcc_MSIEC::waitOutputBufferFull()
{
    for (UInt32 i = 0; i < kMaxPolls; i++) {
        if (ecInb(kECStatusPort) & kECOBF) {
            return true;
        }
        IODelay(kPollDelayUs);
    }
    return false;
}

IOReturn com_yamdcc_MSIEC::readEC(UInt8 reg, UInt8 *value)
{
    if (!fLock) {
        return kIOReturnNotReady;
    }
    IOReturn result = kIOReturnSuccess;

    IOLockLock(fLock);
    do {
        if (!waitInputBufferEmpty()) {
            result = kIOReturnTimeout;
            break;
        }
        ecOutb(kECStatusPort, kECReadCmd);

        if (!waitInputBufferEmpty()) {
            result = kIOReturnTimeout;
            break;
        }
        ecOutb(kECDataPort, reg);

        if (!waitOutputBufferFull()) {
            result = kIOReturnTimeout;
            break;
        }
        *value = ecInb(kECDataPort);
    } while (false);
    IOLockUnlock(fLock);

    return result;
}

IOReturn com_yamdcc_MSIEC::writeEC(UInt8 reg, UInt8 value)
{
    if (!fLock) {
        return kIOReturnNotReady;
    }
    IOReturn result = kIOReturnSuccess;

    IOLockLock(fLock);
    do {
        if (!waitInputBufferEmpty()) {
            result = kIOReturnTimeout;
            break;
        }
        ecOutb(kECStatusPort, kECWriteCmd);

        if (!waitInputBufferEmpty()) {
            result = kIOReturnTimeout;
            break;
        }
        ecOutb(kECDataPort, reg);

        if (!waitInputBufferEmpty()) {
            result = kIOReturnTimeout;
            break;
        }
        ecOutb(kECDataPort, value);
    } while (false);
    IOLockUnlock(fLock);

    return result;
}

IOReturn com_yamdcc_MSIEC::readBlockEC(UInt8 reg, UInt8 *buffer, UInt32 length)
{
    if (length == 0 || length > 64 || (UInt32)reg + length > 256) {
        return kIOReturnBadArgument;
    }
    for (UInt32 i = 0; i < length; i++) {
        IOReturn result = readEC((UInt8)(reg + i), &buffer[i]);
        if (result != kIOReturnSuccess) {
            return result;
        }
    }
    return kIOReturnSuccess;
}

// MARK: - User client

class com_yamdcc_MSIECUserClient : public IOUserClient
{
    OSDeclareDefaultStructors(com_yamdcc_MSIECUserClient)

public:
    virtual bool initWithTask(task_t owningTask, void *securityToken,
                              UInt32 type, OSDictionary *properties) APPLE_KEXT_OVERRIDE;
    virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual IOReturn clientClose(void) APPLE_KEXT_OVERRIDE;
    virtual IOReturn externalMethod(uint32_t selector,
                                    IOExternalMethodArguments *arguments,
                                    IOExternalMethodDispatch *dispatch,
                                    OSObject *target,
                                    void *reference) APPLE_KEXT_OVERRIDE;

private:
    com_yamdcc_MSIEC *fProvider = nullptr;
};

OSDefineMetaClassAndStructors(com_yamdcc_MSIECUserClient, IOUserClient)

bool com_yamdcc_MSIECUserClient::initWithTask(task_t owningTask, void *securityToken,
                                              UInt32 type, OSDictionary *properties)
{
    if (!IOUserClient::initWithTask(owningTask, securityToken, type, properties)) {
        return false;
    }
    fProvider = nullptr;
    return true;
}

bool com_yamdcc_MSIECUserClient::start(IOService *provider)
{
    if (!IOUserClient::start(provider)) {
        return false;
    }
    fProvider = OSDynamicCast(com_yamdcc_MSIEC, provider);
    if (!fProvider) {
        return false;
    }
    fProvider->retain();
    return true;
}

void com_yamdcc_MSIECUserClient::stop(IOService *provider)
{
    if (fProvider) {
        fProvider->release();
        fProvider = nullptr;
    }
    IOUserClient::stop(provider);
}

IOReturn com_yamdcc_MSIECUserClient::clientClose(void)
{
    if (fProvider) {
        fProvider->release();
        fProvider = nullptr;
    }
    return IOUserClient::clientClose();
}

IOReturn com_yamdcc_MSIECUserClient::externalMethod(uint32_t selector,
                                                    IOExternalMethodArguments *arguments,
                                                    IOExternalMethodDispatch *dispatch,
                                                    OSObject *target,
                                                    void *reference)
{
    if (!fProvider || !arguments) {
        return kIOReturnNotAttached;
    }

    switch (selector) {
    case kSelectorReadEC: {
        if (arguments->scalarInputCount < 1 || arguments->scalarOutputCount < 1) {
            return kIOReturnBadArgument;
        }
        UInt8 value = 0;
        IOReturn result = fProvider->readEC((UInt8)arguments->scalarInput[0], &value);
        if (result == kIOReturnSuccess) {
            arguments->scalarOutput[0] = value;
            arguments->scalarOutputCount = 1;
        }
        return result;
    }

    case kSelectorWriteEC: {
        if (arguments->scalarInputCount < 2) {
            return kIOReturnBadArgument;
        }
        return fProvider->writeEC((UInt8)arguments->scalarInput[0],
                                  (UInt8)arguments->scalarInput[1]);
    }

    case kSelectorReadBlock: {
        if (arguments->scalarInputCount < 2) {
            return kIOReturnBadArgument;
        }
        UInt32 length = (UInt32)arguments->scalarInput[1];
        if (length == 0 || length > arguments->structureOutputSize || !arguments->structureOutput) {
            return kIOReturnBadArgument;
        }
        return fProvider->readBlockEC((UInt8)arguments->scalarInput[0],
                                      (UInt8 *)arguments->structureOutput, length);
    }

    default:
        (void)dispatch;
        (void)target;
        (void)reference;
        return kIOReturnUnsupported;
    }
}

// MARK: - Class registration for the user client

// IOUserClient subclasses are looked up by the IOKit matching machinery only
// for published services, but our subclass is instantiated in C++, so nothing
// else is required here.

// MARK: - Driver: user client factory (defined after the user client class)

IOReturn com_yamdcc_MSIEC::newUserClient(task_t owningTask, void *securityID,
                                         UInt32 type, OSDictionary *properties,
                                         IOUserClient **handler)
{
    if (type != 0 || !handler) {
        return kIOReturnUnsupported;
    }

    com_yamdcc_MSIECUserClient *client = new com_yamdcc_MSIECUserClient;
    if (!client) {
        return kIOReturnNoMemory;
    }
    if (!client->initWithTask(owningTask, securityID, type, properties)) {
        client->release();
        return kIOReturnBadArgument;
    }
    if (!client->attach(this)) {
        client->release();
        return kIOReturnError;
    }
    if (!client->start(this)) {
        client->detach(this);
        client->release();
        return kIOReturnError;
    }

    *handler = client;
    return kIOReturnSuccess;
}
