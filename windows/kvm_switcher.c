// KVM Switcher for Windows: a tray app that sends the monitor back to the other
// computer when the KVM's USB devices leave this PC. Mirror of the macOS app.
//
// Monitors like the 34D901 only accept DDC/CI on the input they are showing, so the
// computer on screen must switch the monitor away; the returning computer cannot.
//
// Only built-in Windows APIs: dxva2 (DDC/CI), SetupAPI (USB presence),
// RegisterDeviceNotification (USB change events), Shell_NotifyIcon (tray).
// Config: kvm-switcher.ini next to the exe. Log: kvm-switcher.log next to the exe.

#define WIN32_LEAN_AND_MEAN
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <dbt.h>
#include <setupapi.h>
#include <shellapi.h>
#include <shlwapi.h>
#include <physicalmonitorenumerationapi.h>
#include <lowlevelmonitorconfigurationapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

#define APP_NAME L"KVM Switcher"
#define WM_TRAY (WM_APP + 1)
#define WM_SWITCH_DONE (WM_APP + 2)
#define TIMER_DEBOUNCE 1
#define DEBOUNCE_MS 400
#define VCP_INPUT 0x60

enum { ID_SWITCH = 100, ID_AUTO, ID_LOGIN, ID_LOG, ID_SETTINGS, ID_QUIT };

// GUID_DEVINTERFACE_USB_DEVICE
static const GUID kUsbDeviceInterface = {0xA5DCBF10, 0x6530, 0x11D2, {0x90, 0x1F, 0x00, 0xC0, 0x4F, 0xB9, 0x51, 0xED}};

static struct {
    wchar_t exeDir[MAX_PATH];
    wchar_t iniPath[MAX_PATH];
    wchar_t logPath[MAX_PATH];
    DWORD target;         // VCP 0x60 value of the other computer's input (0x06 = Mac HDMI on the 34D901)
    wchar_t vid[8];       // KVM USB vendor ID, hex (35D6 = Bridgesil)
    wchar_t pids[64];     // optional comma-separated product IDs, hex
    BOOL autoSwitch;
} cfg;

static HWND gWnd;
static NOTIFYICONDATAW gTray;
static BOOL gKvmHere;      // last settled KVM state
static int gKvmFullCount;  // most KVM devices seen at once; losing any of them means the KVM left
static volatile LONG gSwitching;
static ULONGLONG gEventTick;  // GetTickCount64 at the USB event that triggered the current switch

static ULONGLONG sinceEvent(void) { return gEventTick ? GetTickCount64() - gEventTick : 0; }

// MARK: Logging

static void applog(const wchar_t *fmt, ...) {
    SYSTEMTIME t;
    GetLocalTime(&t);
    wchar_t line[1024];
    int n = swprintf(line, 1024, L"[%02d:%02d:%02d.%03d] ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_list ap;
    va_start(ap, fmt);
    vswprintf(line + n, 1024 - n, fmt, ap);
    va_end(ap);
    FILE *f = _wfopen(cfg.logPath, L"a, ccs=UTF-8");
    if (f) { fwprintf(f, L"%ls\n", line); fclose(f); }
}

// MARK: Config

static void loadConfig(void) {
    GetModuleFileNameW(NULL, cfg.exeDir, MAX_PATH);
    PathRemoveFileSpecW(cfg.exeDir);
    swprintf(cfg.iniPath, MAX_PATH, L"%ls\\kvm-switcher.ini", cfg.exeDir);
    swprintf(cfg.logPath, MAX_PATH, L"%ls\\kvm-switcher.log", cfg.exeDir);

    if (GetFileAttributesW(cfg.iniPath) == INVALID_FILE_ATTRIBUTES) {
        WritePrivateProfileStringW(L"monitor", L"target", L"0x06", cfg.iniPath);
        WritePrivateProfileStringW(L"kvm", L"vid", L"35D6", cfg.iniPath);
        WritePrivateProfileStringW(L"kvm", L"pids", L"2510,3510", cfg.iniPath);
        WritePrivateProfileStringW(L"app", L"auto", L"0", cfg.iniPath);
    }
    wchar_t buf[32];
    GetPrivateProfileStringW(L"monitor", L"target", L"0x06", buf, 32, cfg.iniPath);
    cfg.target = wcstoul(buf, NULL, 0);
    GetPrivateProfileStringW(L"kvm", L"vid", L"35D6", cfg.vid, 8, cfg.iniPath);
    GetPrivateProfileStringW(L"kvm", L"pids", L"", cfg.pids, 64, cfg.iniPath);
    cfg.autoSwitch = GetPrivateProfileIntW(L"app", L"auto", 0, cfg.iniPath) != 0;
}

static void saveAuto(void) {
    WritePrivateProfileStringW(L"app", L"auto", cfg.autoSwitch ? L"1" : L"0", cfg.iniPath);
}

// MARK: KVM detection (USB presence)

// Hardware IDs look like "USB\VID_35D6&PID_2510&REV_0100".
static BOOL hardwareIdMatches(const wchar_t *id) {
    wchar_t upper[512];
    wcsncpy(upper, id, 511);
    upper[511] = 0;
    _wcsupr(upper);
    wchar_t want[16];
    swprintf(want, 16, L"VID_%ls", cfg.vid);
    _wcsupr(want);
    if (!wcsstr(upper, want)) return FALSE;
    if (!cfg.pids[0]) return TRUE;

    // Split by hand: wcstok's signature differs between msvcrt and ucrt toolchains.
    for (const wchar_t *p = cfg.pids; *p;) {
        while (*p == L',' || *p == L' ') p++;
        size_t len = wcscspn(p, L", ");
        if (len > 0 && len < 8) {
            wchar_t pid[16];
            swprintf(pid, 16, L"PID_%.*ls", (int)len, p);
            _wcsupr(pid);
            if (wcsstr(upper, pid)) return TRUE;
        }
        p += len;
    }
    return FALSE;
}

static BOOL kvmDevicesPresent(int *count) {
    *count = 0;
    HDEVINFO set = SetupDiGetClassDevsW(NULL, L"USB", NULL, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) return FALSE;
    SP_DEVINFO_DATA info = {.cbSize = sizeof(info)};
    for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &info); i++) {
        wchar_t ids[1024] = {0};
        if (!SetupDiGetDeviceRegistryPropertyW(set, &info, SPDRP_HARDWAREID, NULL, (BYTE *)ids, sizeof(ids) - 4, NULL)) continue;
        for (wchar_t *id = ids; *id; id += wcslen(id) + 1) {
            if (hardwareIdMatches(id)) { (*count)++; break; }
        }
    }
    SetupDiDestroyDeviceInfoList(set);
    return *count > 0;
}

// MARK: DDC/CI

typedef struct { int sent, verified, failed; } SwitchReport;

static BOOL CALLBACK switchMonitor(HMONITOR mon, HDC dc, LPRECT rect, LPARAM param) {
    (void)dc; (void)rect;
    SwitchReport *report = (SwitchReport *)param;
    DWORD n = 0;
    if (!GetNumberOfPhysicalMonitorsFromHMONITOR(mon, &n) || n == 0) return TRUE;
    PHYSICAL_MONITOR *pms = calloc(n, sizeof(PHYSICAL_MONITOR));
    if (!GetPhysicalMonitorsFromHMONITOR(mon, n, pms)) { free(pms); return TRUE; }

    applog(L"+%lu ms: %lu physical monitor(s) enumerated", (unsigned long)sinceEvent(), n);
    for (DWORD i = 0; i < n; i++) {
        HANDLE h = pms[i].hPhysicalMonitor;
        DWORD cur = 0, max = 0;
        // Write first, no pre-check: if the monitor is not showing this PC it ignores the
        // write, which is harmless. A pre-read was slow and, when it failed once, skipped the switch.
        BOOL left = FALSE;
        for (int attempt = 1; attempt <= 3 && !left; attempt++) {
            BOOL written = FALSE;
            for (int tries = 0; tries < 3 && !written; tries++) {
                written = SetVCPFeature(h, VCP_INPUT, cfg.target);
                if (!written) { applog(L"  SetVCPFeature failed: error %lu", GetLastError()); Sleep(50); }
            }
            if (!written) continue;
            applog(L"+%lu ms: monitor \"%ls\": sent VCP 0x60 = 0x%02lX (attempt %d/3)", (unsigned long)sinceEvent(),
                   pms[i].szPhysicalMonitorDescription, cfg.target, attempt);
            report->sent++;
            Sleep(1500);
            // Verified when DDC goes silent: the monitor left this PC's input.
            for (int poll = 0; poll < 8 && !left; poll++) {
                if (!GetVCPFeatureAndVCPFeatureReply(h, VCP_INPUT, NULL, &cur, &max)) left = TRUE;
                else Sleep(500);
            }
            if (!left) applog(L"  monitor still answering DDC on this PC's input; retrying");
        }
        if (left) { applog(L"+%lu ms: verified: monitor left this PC's input", (unsigned long)sinceEvent()); report->verified++; }
        else { applog(L"  FAILED: monitor did not leave this PC's input after 3 attempts"); report->failed++; }
    }
    DestroyPhysicalMonitors(n, pms);
    free(pms);
    return TRUE;
}

static DWORD WINAPI switchThread(LPVOID unused) {
    (void)unused;
    SwitchReport report = {0};
    EnumDisplayMonitors(NULL, NULL, switchMonitor, (LPARAM)&report);
    applog(L"+%lu ms: switch done: verified=%d failed=%d", (unsigned long)sinceEvent(), report.verified, report.failed);
    PostMessageW(gWnd, WM_SWITCH_DONE, report.failed ? 1 : 0, 0);
    return 0;
}

static void startSwitch(const wchar_t *reason) {
    if (InterlockedCompareExchange(&gSwitching, 1, 0) != 0) { applog(L"switch ignored (%ls): already switching", reason); return; }
    applog(L"switching monitor to 0x%02lX (%ls)", cfg.target, reason);
    HANDLE t = CreateThread(NULL, 0, switchThread, NULL, 0, NULL);
    if (t) CloseHandle(t);
    else InterlockedExchange(&gSwitching, 0);
}

// MARK: Launch at login

static const wchar_t *kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

static BOOL launchAtLogin(void) {
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_READ, &key) != ERROR_SUCCESS) return FALSE;
    LONG r = RegQueryValueExW(key, L"KVMSwitcher", NULL, NULL, NULL, NULL);
    RegCloseKey(key);
    return r == ERROR_SUCCESS;
}

static void setLaunchAtLogin(BOOL on) {
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return;
    if (on) {
        wchar_t exe[MAX_PATH], cmd[MAX_PATH + 2];
        GetModuleFileNameW(NULL, exe, MAX_PATH);
        swprintf(cmd, MAX_PATH + 2, L"\"%ls\"", exe);
        RegSetValueExW(key, L"KVMSwitcher", 0, REG_SZ, (BYTE *)cmd, (DWORD)((wcslen(cmd) + 1) * sizeof(wchar_t)));
    } else {
        RegDeleteValueW(key, L"KVMSwitcher");
    }
    RegCloseKey(key);
    applog(L"launch at login: %ls", on ? L"on" : L"off");
}

// MARK: Tray

static void updateTray(void) {
    swprintf(gTray.szTip, 128, L"%ls: KVM %ls%ls", APP_NAME, gKvmHere ? L"on this PC" : L"on the other computer",
             cfg.autoSwitch ? L", auto switch on" : L"");
    Shell_NotifyIconW(NIM_MODIFY, &gTray);
}

static void showMenu(void) {
    HMENU m = CreatePopupMenu();
    AppendMenuW(m, MF_STRING | MF_GRAYED, 0, APP_NAME);
    AppendMenuW(m, MF_STRING | MF_GRAYED, 0, gKvmHere ? L"KVM: this PC" : L"KVM: other computer");
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    wchar_t label[64];
    swprintf(label, 64, L"Send monitor to other computer (0x%02lX)", cfg.target);
    AppendMenuW(m, MF_STRING | (gSwitching ? MF_GRAYED : 0), ID_SWITCH, label);
    AppendMenuW(m, MF_STRING | (cfg.autoSwitch ? MF_CHECKED : 0), ID_AUTO, L"Auto switch");
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    AppendMenuW(m, MF_STRING | (launchAtLogin() ? MF_CHECKED : 0), ID_LOGIN, L"Launch at login");
    AppendMenuW(m, MF_STRING, ID_SETTINGS, L"Settings...");
    AppendMenuW(m, MF_STRING, ID_LOG, L"Open log");
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    AppendMenuW(m, MF_STRING, ID_QUIT, L"Quit KVM Switcher");

    POINT p;
    GetCursorPos(&p);
    SetForegroundWindow(gWnd); // required for the menu to close when clicking elsewhere
    TrackPopupMenu(m, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, p.x, p.y, 0, gWnd, NULL);
    DestroyMenu(m);
}

static void kvmSettled(void) {
    int count;
    kvmDevicesPresent(&count);
    if (count > gKvmFullCount) gKvmFullCount = count;
    // Windows removes child devices before their hub, and the two hubs go one after the
    // other: treating the first missing hub as "KVM left" avoids waiting for the full teardown.
    BOOL here = count > 0 && count == gKvmFullCount;
    if (!here) gKvmFullCount = count;
    if (here == gKvmHere) return;
    gKvmHere = here;
    applog(L"+%lu ms: kvm switched: %ls (%d KVM devices present)", (unsigned long)sinceEvent(),
           here ? L"this PC" : L"other computer", count);
    updateTray();
    if (!here && cfg.autoSwitch) startSwitch(L"KVM left this PC");
    else if (here) applog(L"KVM returned; the other computer must switch the monitor here");
}

static LRESULT CALLBACK wndProc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_DEVICECHANGE:
        // Removal: check presence now. Every USB device behind the KVM sends its own event,
        // so debouncing removals delayed the switch until the last one finished tearing down.
        if (wp == DBT_DEVICEREMOVECOMPLETE || wp == DBT_DEVNODES_CHANGED) {
            if (gKvmHere) {
                if (!gSwitching) gEventTick = GetTickCount64();
                kvmSettled();
            }
            if (!gKvmHere) return TRUE;
        }
        // Arrival (or a removal that left KVM devices present): settle after the burst.
        if (wp == DBT_DEVICEARRIVAL || wp == DBT_DEVICEREMOVECOMPLETE || wp == DBT_DEVNODES_CHANGED)
            SetTimer(w, TIMER_DEBOUNCE, DEBOUNCE_MS, NULL);
        return TRUE;
    case WM_TIMER:
        if (wp == TIMER_DEBOUNCE) { KillTimer(w, TIMER_DEBOUNCE); kvmSettled(); }
        return 0;
    case WM_TRAY:
        if (LOWORD(lp) == WM_RBUTTONUP || LOWORD(lp) == WM_LBUTTONUP) showMenu();
        return 0;
    case WM_SWITCH_DONE:
        InterlockedExchange(&gSwitching, 0);
        if (wp) {
            gTray.uFlags = NIF_INFO;
            wcscpy(gTray.szInfoTitle, APP_NAME);
            wcscpy(gTray.szInfo, L"Monitor switch failed. See the log.");
            Shell_NotifyIconW(NIM_MODIFY, &gTray);
            gTray.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        }
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_SWITCH: gEventTick = GetTickCount64(); startSwitch(L"menu"); break;
        case ID_AUTO:
            cfg.autoSwitch = !cfg.autoSwitch;
            saveAuto();
            applog(L"auto switch %ls", cfg.autoSwitch ? L"on" : L"off");
            updateTray();
            break;
        case ID_LOGIN: setLaunchAtLogin(!launchAtLogin()); break;
        case ID_SETTINGS: ShellExecuteW(NULL, L"open", cfg.iniPath, NULL, NULL, SW_SHOWNORMAL); break;
        case ID_LOG: ShellExecuteW(NULL, L"open", cfg.logPath, NULL, NULL, SW_SHOWNORMAL); break;
        case ID_QUIT: DestroyWindow(w); break;
        }
        return 0;
    case WM_DESTROY:
        Shell_NotifyIconW(NIM_DELETE, &gTray);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(w, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE prev, PWSTR cmd, int show) {
    (void)prev; (void)cmd; (void)show;
    HANDLE single = CreateMutexW(NULL, TRUE, L"Local\\KVMSwitcherSingleInstance");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    loadConfig();
    int count;
    gKvmHere = kvmDevicesPresent(&count); // starting state only; launching never switches
    gKvmFullCount = count;
    applog(L"started: target=0x%02lX vid=%ls pids=%ls auto=%d; KVM %ls (%d devices)", cfg.target, cfg.vid,
         cfg.pids, cfg.autoSwitch, gKvmHere ? L"on this PC" : L"on the other computer", count);

    WNDCLASSW wc = {.lpfnWndProc = wndProc, .hInstance = inst, .lpszClassName = L"KVMSwitcherWnd"};
    RegisterClassW(&wc);
    // A hidden top-level window (not message-only): RegisterDeviceNotification needs one to deliver WM_DEVICECHANGE.
    gWnd = CreateWindowExW(0, wc.lpszClassName, APP_NAME, 0, 0, 0, 0, 0, NULL, NULL, inst, NULL);

    DEV_BROADCAST_DEVICEINTERFACE_W filter = {
        .dbcc_size = sizeof(filter), .dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE, .dbcc_classguid = kUsbDeviceInterface};
    RegisterDeviceNotificationW(gWnd, &filter, DEVICE_NOTIFY_WINDOW_HANDLE);

    gTray = (NOTIFYICONDATAW){.cbSize = sizeof(gTray), .hWnd = gWnd, .uID = 1,
                              .uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP, .uCallbackMessage = WM_TRAY,
                              .hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1))};
    if (!gTray.hIcon) gTray.hIcon = LoadIconW(NULL, IDI_APPLICATION);
    Shell_NotifyIconW(NIM_ADD, &gTray);
    updateTray();

    MSG m;
    while (GetMessageW(&m, NULL, 0, 0) > 0) {
        TranslateMessage(&m);
        DispatchMessageW(&m);
    }
    ReleaseMutex(single);
    return 0;
}
