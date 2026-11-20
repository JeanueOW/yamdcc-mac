/*
 * MSIEC — match the firmware EC and expose mediated ACPI byte access.
 * Part of YAMDCC for macOS. GPL-3.0-or-later.
 *
 * No EC access at start, no port I/O. All reads and writes go through the
 * ACPI interpreter to fields and methods in the SCM0 device, so AppleACPIEC
 * performs the EC transaction and owns the EC lock. Writes additionally
 * require the audited helper SSDT (MSIEC-ECCTL.aml) whose hash is baked in
 * below; without it the driver stays read-only ("acpi-probe"). A private
 * lock only limits our own callers; it does not replace AppleACPIEC.
 */

#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <kern/clock.h>
#include <kern/task.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSIterator.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/libkern.h>

namespace {
constexpr UInt32 kProbeClientType = 0x59414d44; // "YAMD", not the legacy EC transport
constexpr UInt32 kSnapshotSelector = 0;
constexpr UInt32 kReadByteSelector = 1;
constexpr UInt32 kWriteByteSelector = 2;
constexpr UInt32 kReadBlockSelector = 3;
constexpr UInt32 kProbeABI = 2;
constexpr UInt32 kMaxBlock = 32;

// Baked from Kext/MSIEC/MSIEC-ECCTL.aml (gen-ecctl.py). Any change to that
// SSDT invalidates writes until this driver is rebuilt and re-audited.
constexpr UInt32 kHelperLength = 1067;
constexpr UInt64 kHelperFNV = 0xA6200B25A350E8BDULL;
constexpr UInt32 kReplyHeaderWords = 2; // stage, then IOReturn as UInt32
constexpr char kECPath[] = "IOACPIPlane:/_SB/PC00@0/LPCB@1f0000/EC";
constexpr char kSCMPath[] = "IOACPIPlane:/_SB/PC00@0/LPCB@1f0000/EC/SCM0";

enum ProbeStage : UInt32 {
    kProbeComplete = 0,
    kProbeProvider = 1,
    kProbeRateLimit = 2,
    kProbeAppleEC = 3,
    kProbeDSDT = 4,
    kProbeScope = 5,
    kProbeECReady = 6,
    kProbeFieldBase = 0x100, // field index added to this base
};

// This identifies the exact DSDT inspected on the test machine. The general
// PNP0C09 device ID or MSI OEM ID alone says nothing about these field names.
bool matchesAuditedDSDT(const IOACPIPlatformDevice *ec)
{
    constexpr unsigned int kLength = 619957;
    const OSData *table = ec->getACPITableData("DSDT");
    if (!table || table->getLength() != kLength) {
        return false;
    }
    const auto *bytes = static_cast<const UInt8 *>(table->getBytesNoCopy());
    if (!bytes) {
        return false;
    }
    UInt64 hash = 0xcbf29ce484222325ULL;
    for (unsigned int i = 0; i < kLength; ++i) {
        hash = (hash ^ bytes[i]) * 0x100000001b3ULL;
    }
    return hash == 0x89c6d629850daa9fULL;
}

UInt64 tableFNV(const OSData *table)
{
    const auto *bytes = static_cast<const UInt8 *>(table->getBytesNoCopy());
    if (!bytes) {
        return 0;
    }
    UInt64 hash = 0xcbf29ce484222325ULL;
    for (unsigned int i = 0; i < table->getLength(); ++i) {
        hash = (hash ^ bytes[i]) * 0x100000001b3ULL;
    }
    return hash;
}

// The helper SSDT adds EC fields for offsets the firmware DSDT does not
// declare and one serialized write method per writable register.
bool hasHelperTable(const IOACPIPlatformDevice *ec)
{
    for (UInt32 i = 0; i < 64; ++i) {
        const OSData *table = ec->getACPITableData("SSDT", i);
        if (!table) {
            break;
        }
        if (table->getLength() == kHelperLength && tableFNV(table) == kHelperFNV) {
            return true;
        }
    }
    return false;
}

// Fallback presence check: the helper's own read method. It performs one
// normal EC read through AppleACPIEC and has no side effects.
bool helperReadable()
{
    auto *entry = IORegistryEntry::fromPath(kSCMPath);
    auto *scm = entry ? OSDynamicCast(IOACPIPlatformDevice, entry) : nullptr;
    UInt64 value = 0;
    const bool readable = scm && !scm->isInactive() &&
        scm->evaluateInteger("YR98", &value) == kIOReturnSuccess;
    if (entry) {
        entry->release();
    }
    return readable;
}

bool hasReadyAppleEC(const IOACPIPlatformDevice *ec)
{
    auto clients = ec->getClientIterator();
    if (!clients) {
        return false;
    }
    bool found = false;
    while (auto *object = clients->getNextObject()) {
        auto *service = OSDynamicCast(IOService, object);
        if (service && service->metaCast("AppleACPIEC") &&
            (service->getState() & (kIOServiceRegisteredState | kIOServiceInactiveState)) ==
                kIOServiceRegisteredState && service->getBusyState() == 0) {
            found = true;
            break;
        }
    }
    clients->release();
    return found;
}

// Firmware fields, not control methods. All are byte-aligned, ByteAcc
// EmbeddedControl fields in SCM0. AppleACPIPlatform's evaluation API takes a
// single NameSeg (at most 4 characters), not a fully qualified AML path.
constexpr char kFields[][5] = {
    "TD68", "TD80", // CPU, GPU temperature
    "TD71", "TD89", // CPU, GPU fan duty
    "TDC8", "TDC9", // CPU tach period, high/low
    "TDCA", "TDCB", // GPU tach period, high/low
};
constexpr UInt32 kFieldCount = sizeof(kFields) / sizeof(kFields[0]);
constexpr UInt32 kReplyWords = kReplyHeaderWords + kFieldCount;

// Byte registers reachable from userspace. Read names exist either in the
// firmware DSDT (TDxx) or in the helper SSDT (YRxx); write methods exist only
// for registers the fan controller legitimately changes.
struct RegEntry {
    UInt8 reg;
    const char *readName;
    const char *writeMethod;
};

constexpr RegEntry kRegisters[] = {
    {0x68, "TD68", nullptr}, {0x71, "TD71", nullptr},
    {0x80, "TD80", nullptr}, {0x89, "TD89", nullptr},
    {0xA0, "TDA0", nullptr},
    {0xA1, "TDA1", nullptr},
    {0xA2, "TDA2", nullptr},
    {0xA3, "TDA3", nullptr},
    {0xA4, "TDA4", nullptr},
    {0xA5, "TDA5", nullptr},
    {0xA6, "TDA6", nullptr},
    {0xA7, "TDA7", nullptr},
    {0xA8, "TDA8", nullptr},
    {0xA9, "TDA9", nullptr},
    {0xAA, "TDAA", nullptr},
    {0xAB, "TDAB", nullptr},
    {0xAC, "TDAC", nullptr},
    {0xAD, "TDAD", nullptr},
    {0xAE, "TDAE", nullptr},
    {0xAF, "TDAF", nullptr},
    {0xB0, "TDB0", nullptr},
    {0xB1, "TDB1", nullptr},
    {0xB2, "TDB2", nullptr},
    {0xB3, "TDB3", nullptr},
    {0xB4, "TDB4", nullptr},
    {0xB5, "TDB5", nullptr},
    {0xB6, "TDB6", nullptr},
    {0xB7, "TDB7", nullptr},
    {0xB8, "TDB8", nullptr},
    {0xB9, "TDB9", nullptr},
    {0xBA, "TDBA", nullptr},
    {0xBB, "TDBB", nullptr},
    {0xBC, "TDBC", nullptr},
    {0xBD, "TDBD", nullptr},
    {0xBE, "TDBE", nullptr},
    {0xBF, "TDBF", nullptr},
    {0xC8, "TDC8", nullptr}, {0xC9, "TDC9", nullptr},
    {0xCA, "TDCA", nullptr}, {0xCB, "TDCB", nullptr},
    {0x6A, "TD6A", "YW6A"}, {0x6B, "TD6B", "YW6B"}, {0x6C, "TD6C", "YW6C"},
    {0x6D, "TD6D", "YW6D"}, {0x6E, "TD6E", "YW6E"}, {0x6F, "TD6F", "YW6F"},
    {0x72, "TD72", "YW72"}, {0x73, "TD73", "YW73"}, {0x74, "TD74", "YW74"},
    {0x75, "TD75", "YW75"}, {0x76, "TD76", "YW76"}, {0x77, "TD77", "YW77"},
    {0x78, "TD78", "YW78"},
    {0x7A, "TD7A", "YW7A"}, {0x7B, "TD7B", "YW7B"}, {0x7C, "TD7C", "YW7C"},
    {0x7D, "TD7D", "YW7D"}, {0x7E, "TD7E", "YW7E"}, {0x7F, "TD7F", "YW7F"},
    {0x82, "TD82", "YW82"}, {0x83, "TD83", "YW83"}, {0x84, "TD84", "YW84"},
    {0x85, "TD85", "YW85"}, {0x86, "TD86", "YW86"}, {0x87, "TD87", "YW87"},
    {0x8A, "TD8A", "YW8A"}, {0x8B, "TD8B", "YW8B"}, {0x8C, "TD8C", "YW8C"},
    {0x8D, "TD8D", "YW8D"}, {0x8E, "TD8E", "YW8E"}, {0x8F, "TD8F", "YW8F"},
    {0x90, "TD90", "YW90"},
    {0x92, "YR92", "YW92"}, {0x93, "YR93", "YW93"}, {0x94, "YR94", "YW94"},
    {0x95, "YR95", "YW95"}, {0x96, "YR96", "YW96"}, {0x97, "YR97", "YW97"},
    {0x98, "YR98", "YW98"},
    {0xD2, "TDD2", "YWD2"}, {0xD3, "TDD3", "YWD3"}, {0xD4, "TDD4", "YWD4"},
    {0xD7, "YRD7", "YWD7"},
    {0xE8, "TDE8", "YWE8"},
};
constexpr UInt32 kRegisterCount = sizeof(kRegisters) / sizeof(kRegisters[0]);

const RegEntry *findRegister(UInt8 reg)
{
    for (UInt32 i = 0; i < kRegisterCount; ++i) {
        if (kRegisters[i].reg == reg) {
            return &kRegisters[i];
        }
    }
    return nullptr;
}

IOReturn readTelemetry(IOACPIPlatformDevice *ec, UInt64 *output, UInt32 &stage)
{
    stage = kProbeAppleEC;
    if (!hasReadyAppleEC(ec)) {
        return kIOReturnNotReady;
    }
    stage = kProbeDSDT;
    if (!matchesAuditedDSDT(ec)) {
        return kIOReturnUnsupported;
    }
    stage = kProbeScope;
    auto *entry = IORegistryEntry::fromPath(kSCMPath);
    if (!entry) {
        return kIOReturnNotFound;
    }
    auto *scm = OSDynamicCast(IOACPIPlatformDevice, entry);
    if (!scm || scm->isInactive() || scm->getParentEntry(gIOACPIPlane) != ec) {
        entry->release();
        return kIOReturnNotAttached;
    }

    // MYEC is an in-memory AML Name maintained by _REG. Its value is a
    // rejection check, not a guarantee against subsequent power transitions.
    stage = kProbeECReady;
    UInt64 ecConnected = 0;
    IOReturn result = ec->evaluateInteger("MYEC", &ecConnected);
    if (result == kIOReturnSuccess && ecConnected != 1) {
        result = kIOReturnNotReady;
    }
    UInt64 snapshot[kFieldCount] = {};
    for (UInt32 i = 0; i < kFieldCount && result == kIOReturnSuccess; ++i) {
        stage = kProbeFieldBase + i;
        result = scm->evaluateInteger(kFields[i], &snapshot[i]);
        if (result == kIOReturnSuccess && snapshot[i] > 0xff) {
            result = kIOReturnBadMedia;
        }
    }
    entry->release();

    if (result == kIOReturnSuccess) {
        for (UInt32 i = 0; i < kFieldCount; ++i) {
            output[i] = snapshot[i];
        }
        stage = kProbeComplete;
    }
    return result;
}
}

class com_yamdcc_MSIEC : public IOService
{
    OSDeclareDefaultStructors(com_yamdcc_MSIEC)

public:
    bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    void free() APPLE_KEXT_OVERRIDE;
    IOReturn newUserClient(task_t task, void *securityToken, UInt32 type,
                           OSDictionary *properties, IOUserClient **handler) APPLE_KEXT_OVERRIDE;
    IOReturn probe(UInt64 *output, UInt32 &stage);
    IOReturn readRegisters(UInt8 reg, UInt8 *values, UInt32 count);
    IOReturn readRegister(UInt8 reg, UInt8 &value);
    IOReturn writeRegister(UInt8 reg, UInt8 value);

    bool isWritable() const { return fCoordinated; }
    void refreshMode();

private:
    IOACPIPlatformDevice *fEC = nullptr;
    IOLock *fProbeLock = nullptr;
    UInt64 fNextProbe = 0;
    UInt64 fProbeInterval = 0;
    bool fCoordinated = false;
};

class com_yamdcc_MSIECProbeClient : public IOUserClient
{
    OSDeclareDefaultStructors(com_yamdcc_MSIECProbeClient)

public:
    bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    void free() APPLE_KEXT_OVERRIDE;
    IOReturn clientClose() APPLE_KEXT_OVERRIDE;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *args,
                            IOExternalMethodDispatch *, OSObject *, void *) APPLE_KEXT_OVERRIDE;

private:
    com_yamdcc_MSIEC *fDriver = nullptr;
};

OSDefineMetaClassAndStructors(com_yamdcc_MSIEC, IOService)
OSDefineMetaClassAndStructors(com_yamdcc_MSIECProbeClient, IOUserClient)

bool com_yamdcc_MSIEC::start(IOService *provider)
{
    if (!IOService::start(provider)) {
        return false;
    }
    auto *ec = OSDynamicCast(IOACPIPlatformDevice, provider);
    char path[128] = {};
    int length = sizeof(path);
    if (ec && gIOACPIPlane && ec->getPath(path, &length, gIOACPIPlane) &&
        strcmp(path, kECPath) == 0) {
        fProbeLock = IOLockAlloc();
        if (!fProbeLock) {
            return false;
        }
        ec->retain();
        fEC = ec;
        clock_interval_to_absolutetime_interval(2, 1000000000u, &fProbeInterval);
    }
    if (fEC) {
        fCoordinated = hasHelperTable(fEC);
    }
    if (!setProperty("MSIECAccess", fEC ? (fCoordinated ? "coordinated" : "acpi-probe")
                                        : "match-only") ||
        !setProperty("MSIECWritable", fCoordinated) ||
        (fEC && !setProperty("MSIECProbeABI", kProbeABI, 32))) {
        return false;
    }
    registerService();
    return true;
}

void com_yamdcc_MSIEC::free()
{
    if (fProbeLock) {
        IOLockFree(fProbeLock);
    }
    if (fEC) {
        fEC->release();
    }
    IOService::free();
}

IOReturn com_yamdcc_MSIEC::newUserClient(task_t task, void *securityToken, UInt32 type,
                                         OSDictionary *properties, IOUserClient **handler)
{
    if (!handler) {
        return kIOReturnBadArgument;
    }
    *handler = nullptr;
    // type 0 comes from IOServiceOpen (control channel), kProbeClientType from
    // the snapshot probe. Both are handled by the same bounded client.
    if (!fEC || isInactive() || (type != 0 && type != kProbeClientType)) {
        return kIOReturnUnsupported;
    }
    // The client can only touch the fixed register whitelist below (no raw
    // ports, no arbitrary offsets), so any local process may use it and the
    // GUI works without a root helper. Security boundary: kRegisters[] only.
    (void)securityToken;

    refreshMode();

    auto *client = OSTypeAlloc(com_yamdcc_MSIECProbeClient);
    if (!client) {
        return kIOReturnNoMemory;
    }
    if (!client->initWithTask(task, securityToken, type, properties) || !client->attach(this)) {
        client->release();
        return kIOReturnNotAttached;
    }
    if (!client->start(this)) {
        client->detach(this);
        client->release();
        return kIOReturnNotReady;
    }
    *handler = client;
    return kIOReturnSuccess;
}

IOReturn com_yamdcc_MSIEC::probe(UInt64 *output, UInt32 &stage)
{
    stage = kProbeProvider;
    if (!fEC || isInactive() || fEC->isInactive()) {
        return kIOReturnNotAttached;
    }
    stage = kProbeRateLimit;
    if (!IOLockTryLock(fProbeLock)) {
        return kIOReturnBusy;
    }

    UInt64 now;
    clock_get_uptime(&now);
    if (now < fNextProbe) {
        IOLockUnlock(fProbeLock);
        return kIOReturnBusy;
    }

    IOReturn result = readTelemetry(fEC, output, stage);
    clock_get_uptime(&now);
    fNextProbe = now + fProbeInterval;
    IOLockUnlock(fProbeLock);
    return result;
}

void com_yamdcc_MSIEC::refreshMode()
{
    if (!fEC) {
        return;
    }
    // Table hashes only; the read fallback is used when the table list is not
    // enumerable, which normally only happens before AppleACPIPlatform is up.
    bool coordinated = hasHelperTable(fEC);
    if (!coordinated) {
        coordinated = helperReadable();
    }
    if (coordinated == fCoordinated) {
        return;
    }
    fCoordinated = coordinated;
    setProperty("MSIECAccess", coordinated ? "coordinated" : "acpi-probe");
    setProperty("MSIECWritable", coordinated);
}

IOReturn com_yamdcc_MSIEC::readRegister(UInt8 reg, UInt8 &value)
{
    if (!fEC || isInactive()) {
        return kIOReturnNotAttached;
    }
    const RegEntry *entry = findRegister(reg);
    if (!entry || !entry->readName) {
        return kIOReturnUnsupported;
    }
    if (!IOLockTryLock(fProbeLock)) {
        return kIOReturnBusy;
    }

    auto *raw = IORegistryEntry::fromPath(kSCMPath);
    auto *scm = raw ? OSDynamicCast(IOACPIPlatformDevice, raw) : nullptr;
    IOReturn result = kIOReturnNotAttached;
    if (scm && !scm->isInactive() && scm->getParentEntry(gIOACPIPlane) == fEC) {
        UInt64 fetched = 0;
        result = scm->evaluateInteger(entry->readName, &fetched);
        if (result == kIOReturnSuccess) {
            if (fetched > 0xff) {
                result = kIOReturnBadMedia;
            } else {
                value = static_cast<UInt8>(fetched);
            }
        }
    }
    if (raw) {
        raw->release();
    }
    IOLockUnlock(fProbeLock);
    return result;
}

IOReturn com_yamdcc_MSIEC::readRegisters(UInt8 reg, UInt8 *values, UInt32 count)
{
    if (!values || count == 0 || count > kMaxBlock) {
        return kIOReturnBadArgument;
    }
    for (UInt32 i = 0; i < count; ++i) {
        if (findRegister(static_cast<UInt8>(reg + i)) == nullptr) {
            return kIOReturnUnsupported;
        }
        const IOReturn result = readRegister(static_cast<UInt8>(reg + i), values[i]);
        if (result != kIOReturnSuccess) {
            return result;
        }
    }
    return kIOReturnSuccess;
}

IOReturn com_yamdcc_MSIEC::writeRegister(UInt8 reg, UInt8 value)
{
    if (!fEC || isInactive()) {
        return kIOReturnNotAttached;
    }
    if (!fCoordinated) {
        // No audited helper SSDT: stay read-only rather than touching fields
        // the firmware may not have declared.
        return kIOReturnUnsupported;
    }
    const RegEntry *entry = findRegister(reg);
    if (!entry || !entry->writeMethod) {
        return kIOReturnUnsupported;
    }
    if (!IOLockTryLock(fProbeLock)) {
        return kIOReturnBusy;
    }

    auto *raw = IORegistryEntry::fromPath(kSCMPath);
    auto *scm = raw ? OSDynamicCast(IOACPIPlatformDevice, raw) : nullptr;
    IOReturn result = kIOReturnNotAttached;
    if (scm && !scm->isInactive() && scm->getParentEntry(gIOACPIPlane) == fEC) {
        auto *number = OSNumber::withNumber(static_cast<UInt64>(value), 8);
        if (!number) {
            result = kIOReturnNoMemory;
        } else {
            OSObject *params[1] = { number };
            UInt64 ignored = 0;
            result = scm->evaluateInteger(entry->writeMethod, &ignored, params, 1);
            number->release();
        }
    }
    if (raw) {
        raw->release();
    }
    IOLockUnlock(fProbeLock);
    return result;
}

bool com_yamdcc_MSIECProbeClient::start(IOService *provider)
{
    if (!IOUserClient::start(provider)) {
        return false;
    }
    fDriver = OSDynamicCast(com_yamdcc_MSIEC, provider);
    if (!fDriver) {
        return false;
    }
    fDriver->retain();
    return true;
}

void com_yamdcc_MSIECProbeClient::free()
{
    if (fDriver) {
        fDriver->release();
    }
    IOUserClient::free();
}

IOReturn com_yamdcc_MSIECProbeClient::clientClose()
{
    terminate();
    return kIOReturnSuccess;
}

IOReturn com_yamdcc_MSIECProbeClient::externalMethod(uint32_t selector,
                                                      IOExternalMethodArguments *args,
                                                      IOExternalMethodDispatch *, OSObject *, void *)
{
    if (!args || args->version != kIOExternalMethodArgumentsCurrentVersion ||
        args->asyncWakePort != MACH_PORT_NULL || args->asyncReferenceCount != 0 ||
        args->structureInputSize != 0 || args->structureInputDescriptor ||
        args->structureOutputDescriptor || args->structureOutputDescriptorSize != 0 ||
        args->structureVariableOutputData) {
        return kIOReturnBadArgument;
    }
    if (!fDriver || isInactive()) {
        return kIOReturnNotAttached;
    }

    switch (selector) {
    case kSnapshotSelector: {
        if (args->scalarInputCount != 0 || args->scalarOutputCount != kReplyWords ||
            !args->scalarOutput || args->structureOutputSize != 0) {
            return kIOReturnBadArgument;
        }
        // Transport success means the reply was delivered, not that ACPI read
        // succeeded. On failure return the stage and status, but no partial data.
        auto *reply = args->scalarOutput;
        for (UInt32 i = 0; i < kReplyWords; ++i) {
            reply[i] = 0;
        }
        UInt32 stage = kProbeProvider;
        const IOReturn result = fDriver->probe(reply + kReplyHeaderWords, stage);
        reply[0] = stage;
        reply[1] = static_cast<UInt32>(result);
        return kIOReturnSuccess;
    }
    case kReadByteSelector: {
        if (args->scalarInputCount != 1 || args->scalarOutputCount != 1 ||
            !args->scalarInput || !args->scalarOutput || args->structureOutputSize != 0 ||
            args->scalarInput[0] > 0xff) {
            return kIOReturnBadArgument;
        }
        UInt8 value = 0;
        args->scalarOutput[0] = 0;
        const IOReturn result = fDriver->readRegister(static_cast<UInt8>(args->scalarInput[0]), value);
        if (result == kIOReturnSuccess) {
            args->scalarOutput[0] = value;
        }
        return result;
    }
    case kWriteByteSelector: {
        if (args->scalarInputCount != 2 || args->scalarOutputCount != 1 ||
            !args->scalarInput || !args->scalarOutput || args->structureOutputSize != 0 ||
            args->scalarInput[0] > 0xff || args->scalarInput[1] > 0xff) {
            return kIOReturnBadArgument;
        }
        args->scalarOutput[0] = 0;
        const IOReturn result = fDriver->writeRegister(static_cast<UInt8>(args->scalarInput[0]),
                                                       static_cast<UInt8>(args->scalarInput[1]));
        if (result == kIOReturnSuccess) {
            args->scalarOutput[0] = 1;
        }
        return result;
    }
    case kReadBlockSelector: {
        if (args->scalarInputCount != 2 || args->scalarOutputCount != 0 ||
            !args->scalarInput || !args->structureOutput || args->structureOutputSize == 0 ||
            args->structureOutputSize > kMaxBlock || args->scalarInput[0] > 0xff) {
            return kIOReturnBadArgument;
        }
        UInt32 count = static_cast<UInt32>(args->scalarInput[1]);
        if (count == 0 || count > args->structureOutputSize) {
            return kIOReturnBadArgument;
        }
        return fDriver->readRegisters(static_cast<UInt8>(args->scalarInput[0]),
                                      static_cast<UInt8 *>(args->structureOutput), count);
    }
    default:
        return kIOReturnUnsupported;
    }
}
