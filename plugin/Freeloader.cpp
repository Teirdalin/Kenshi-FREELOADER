#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <wincrypt.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <Debug.h>
#include <core/Functions.h>
#include <kenshi/GameWorld.h>
#include <kenshi/Globals.h>
#include <kenshi/PlayerInterface.h>
#include <kenshi/SharedKing.h>
#include <kenshi/ZoneManager.h>
#include "../src/StreamingPolicy.h"
#include "NativeContract.h"

typedef char ZoneLayoutCheck[sizeof(ZoneMap) == 0x168 ? 1 : -1];
typedef char PhaseLayoutCheck[offsetof(ZoneManager, loadingPhase) == 0x1681d8 ? 1 : -1];
typedef char CountdownLayoutCheck[offsetof(ZoneMap, activatedCountdown) == 0xc0 ? 1 : -1];

namespace {
void (*originalUpdate)(ZoneManager*, const Ogre::Vector3&) = 0;
void (*originalReset)(GameWorld*) = 0;
void (*originalGameReset)(GameWorld*) = 0;
bool active = false;
volatile LONG resetting = 0;
volatile LONG epoch = 0;
LONG observedEpoch = -1;
DWORD updateThread = 0;
freeloader::Predictor predictor;
freeloader::Sector leases[freeloader::MaxLeases];
unsigned int nextSample = 0, lastRequest = 0, lastReport = 0;
unsigned int requests = 0, frames = 0, loadingFrames = 0;
double worstUpdateMs = 0;
LARGE_INTEGER frequency;
int leadDistance = 1800, maxActiveZones = 32, intervalMs = 500;
bool diagnostics = true;

void resetState() {
    predictor.reset();
    for (int i = 0; i < freeloader::MaxLeases; ++i) leases[i] = freeloader::Sector();
    nextSample = lastRequest = GetTickCount();
    lastReport = nextSample;
    requests = frames = loadingFrames = 0; worstUpdateMs = 0;
}

void resetHook(GameWorld* world) {
    InterlockedIncrement(&resetting);
    InterlockedIncrement(&epoch);
    originalReset(world);
    InterlockedDecrement(&resetting);
}

void gameResetHook(GameWorld* world) {
    InterlockedIncrement(&resetting);
    InterlockedIncrement(&epoch);
    originalGameReset(world);
    InterlockedDecrement(&resetting);
}

bool hashExecutable() {
    wchar_t path[MAX_PATH];
    DWORD length = GetModuleFileNameW(0, path, MAX_PATH);
    if (!length || length >= MAX_PATH) return false;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              0, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, 0);
    if (file == INVALID_HANDLE_VALUE) return false;
    HCRYPTPROV provider = 0;
    HCRYPTHASH hash = 0;
    bool ok = CryptAcquireContextW(&provider, 0, 0, PROV_RSA_AES, CRYPT_VERIFYCONTEXT) != 0;
    if (ok) ok = CryptCreateHash(provider, CALG_SHA_256, 0, 0, &hash) != 0;
    BYTE buffer[65536];
    DWORD read = 0;
    while (ok) {
        ok = ReadFile(file, buffer, sizeof(buffer), &read, 0) != 0;
        if (!ok || !read) break;
        ok = CryptHashData(hash, buffer, read, 0) != 0;
    }
    BYTE digest[32]; DWORD size = sizeof(digest);
    if (ok) ok = CryptGetHashParam(hash, HP_HASHVAL, digest, &size, 0) != 0;
    if (ok) ok = size == 32 && memcmp(digest, NativeEngineSHA256, 32) == 0;
    if (hash) CryptDestroyHash(hash);
    if (provider) CryptReleaseContext(provider, 0);
    CloseHandle(file);
    return ok;
}

bool addressMatches(intptr_t address, unsigned int expected) {
    return address != 0 && address - reinterpret_cast<intptr_t>(GetModuleHandleW(0)) == expected;
}

int setting(const wchar_t* path, const wchar_t* keyName, int fallback, int lo, int hi) {
    int v = static_cast<int>(GetPrivateProfileIntW(L"Freeloader", keyName, fallback, path));
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

bool configure() {
    HMODULE module = 0;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(&configure), &module)) return false;
    wchar_t path[MAX_PATH];
    DWORD length = GetModuleFileNameW(module, path, MAX_PATH);
    if (!length || length >= MAX_PATH) return false;
    wchar_t* slash = wcsrchr(path, L'\\');
    if (!slash || static_cast<size_t>(slash - path) + 16 >= MAX_PATH) return false;
    wcscpy(slash + 1, L"Freeloader.ini");
    if (!setting(path, L"Enabled", 1, 0, 1)) return false;
    diagnostics = setting(path, L"Diagnostics", 1, 0, 1) != 0;
    leadDistance = setting(path, L"LookAheadDistance", 1800, 500, 3500);
    maxActiveZones = setting(path, L"MaxActiveZones", 32, 12, 64);
    intervalMs = setting(path, L"RequestIntervalMs", 500, 250, 5000);
    return true;
}

bool localAreaReady(ZoneManager* manager, const Ogre::Vector3& camera) {
    // Match the native camera envelope, with an additional collision check.
    for (int x = -1; x <= 1; x += 2) for (int z = -1; z <= 1; z += 2) {
        freeloader::Sector s = freeloader::sectorAt(camera.x + x * 600.0, camera.z + z * 600.0);
        if (!s.valid()) return false;
        ZoneMap* zone = manager->getZoneMap(s.x, s.z);
        if (!zone || !zone->isLoadedMT() || !zone->isTerrainCollisionLoaded()) return false;
    }
    return true;
}

void prefetch(ZoneManager* manager, unsigned int now) {
    if (!ou || ou->gameResetting || !shou || shou->isLevelEditMode() ||
        ou->zoneMgr != manager || !ou->player || !ou->player->getCamera() ||
        !manager->getCentralZone() || manager->justLoadedAGame || ou->isPaused()) {
        predictor.reset(); return;
    }
    if (now - nextSample < 250) return;
    nextSample = now;
    const Ogre::Vector3 camera = ou->player->getCameraCenter();
    freeloader::Candidates candidates = predictor.update(camera.x, camera.z, now, leadDistance);
    if (manager->isLoading() != 0 || candidates.count == 0 || !localAreaReady(manager, camera)) return;

    int freeSlot = -1;
    for (int i = 0; i < freeloader::MaxLeases; ++i) {
        if (leases[i].valid()) {
            ZoneMap* zone = manager->getZoneMap(leases[i].x, leases[i].z);
            if (!zone || (!zone->isActive() && !zone->isBeingLoadedMT())) leases[i] = freeloader::Sector();
            else if (candidates.contains(leases[i]) && zone->isLoadedMT() &&
                     zone->activatedCountdown[ACTIVATION_CAMERA] < 30.0f) {
                zone->_activate(0, ACTIVATION_CAMERA, 60.0f);
            }
        }
        if (!leases[i].valid() && freeSlot < 0) freeSlot = i;
    }
    if (freeSlot < 0 || now - lastRequest < static_cast<unsigned int>(intervalMs) ||
        manager->getNumActiveZones() >= maxActiveZones) return;
    MEMORYSTATUSEX memory = { sizeof(MEMORYSTATUSEX) };
    if (!GlobalMemoryStatusEx(&memory) || memory.ullAvailPhys < (2ull * 1024 * 1024 * 1024)) return;

    for (int i = 0; i < candidates.count; ++i) {
        const freeloader::Sector s = candidates.sectors[i];
        ZoneMap* zone = manager->getZoneMap(s.x, s.z);
        if (!zone || zone->isLoadedMT() || zone->isBeingLoadedMT() || zone->isActive()) continue;
        lastRequest = now;
        // The manager owns registration and the native phases own completion.
        // Range zero queues exactly one sector; never change centralZone or pause.
        bool queued = manager->activateZoneMap(zone, iVector2(s.x, s.z), 0, ACTIVATION_CAMERA, 60.0f);
        if (queued || zone->isBeingLoadedMT()) leases[freeSlot] = s;
        if (queued) {
            ++requests;
            if (diagnostics) {
                char message[192];
                sprintf(message, "Freeloader: prefetch sector=(%d,%d) active=%d phase=%d",
                        s.x, s.z, manager->getNumActiveZones(), manager->isLoading());
                DebugLog(message);
            }
        }
        break;
    }
}

void updateHook(ZoneManager* manager, const Ogre::Vector3& camera) {
    if (!active || InterlockedCompareExchange(&resetting, 0, 0)) { originalUpdate(manager, camera); return; }
    DWORD thread = GetCurrentThreadId();
    if (!updateThread) updateThread = thread;
    if (thread != updateThread) { originalUpdate(manager, camera); return; }
    LONG currentEpoch = InterlockedCompareExchange(&epoch, 0, 0);
    if (observedEpoch != currentEpoch) { resetState(); observedEpoch = currentEpoch; }
    LARGE_INTEGER start, end;
    QueryPerformanceCounter(&start);
    unsigned int now = GetTickCount();
    prefetch(manager, now);
    originalUpdate(manager, camera);
    QueryPerformanceCounter(&end);
    double duration = (end.QuadPart - start.QuadPart) * 1000.0 / frequency.QuadPart;
    if (duration > worstUpdateMs) worstUpdateMs = duration;
    ++frames;
    if (manager->isLoading()) ++loadingFrames;
    if (diagnostics && now - lastReport >= 30000) {
        char message[224];
        sprintf(message, "Freeloader: 30s sample requests=%u updates=%u loading_updates=%u worst_update_ms=%.2f phase=%d",
                requests, frames, loadingFrames, worstUpdateMs, manager->isLoading());
        DebugLog(message);
        lastReport = now; requests = frames = loadingFrames = 0; worstUpdateMs = 0;
    }
}
}

__declspec(dllexport) void startPlugin() {
    DebugLog("Freeloader 0.1.0 experimental predictive streaming; " __DATE__ " " __TIME__);
    if (!configure()) { DebugLog("Freeloader: disabled by configuration or unavailable module path"); return; }
    if (!hashExecutable()) { ErrorLog("Freeloader: unsupported executable; no hooks installed"); return; }
    bool (ZoneManager::*activate)(ZoneMap*, iVector2, int, ZoneActivationType, float) = &ZoneManager::activateZoneMap;
    intptr_t update = KenshiLib::GetRealAddress(&ZoneManager::updateMainThread);
    intptr_t reset = KenshiLib::GetRealAddress(&GameWorld::_clearAndDestroyGameWorldStuff);
    intptr_t gameReset = KenshiLib::GetRealAddress(&GameWorld::resetGame);
    if (!addressMatches(update, NativeUpdateRVA) || !addressMatches(reset, NativeResetRVA) ||
        !addressMatches(gameReset, NativeGameResetRVA) ||
        !addressMatches(KenshiLib::GetRealAddress(activate), NativeActivateRVA) ||
        !addressMatches(KenshiLib::GetRealAddress(&ZoneManager::processLoading), NativeProcessRVA)) {
        ErrorLog("Freeloader: unsupported RVA mapping; no hooks installed"); return;
    }
    if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) return;
    if (KenshiLib::AddHook(gameReset, gameResetHook, &originalGameReset) != KenshiLib::SUCCESS ||
        KenshiLib::AddHook(reset, resetHook, &originalReset) != KenshiLib::SUCCESS ||
        KenshiLib::AddHook(update, updateHook, &originalUpdate) != KenshiLib::SUCCESS) {
        ErrorLog("Freeloader: hook installation failed; prefetch disabled"); return;
    }
    resetState();
    active = true;
    char message[192];
    sprintf(message, "Freeloader: hooks installed; lookahead=%d max_active=%d interval_ms=%d max_extra=%d; native loading guards enabled",
            leadDistance, maxActiveZones, intervalMs, freeloader::MaxLeases);
    DebugLog(message);
}
