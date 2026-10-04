#include "flutter_window.h"
#include <flutter/standard_method_codec.h>
#include <tlhelp32.h>
#include <wtsapi32.h>
#include <algorithm>
#include <cwchar>
#include <optional>
#include <string>
#include <vector>
#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
const wchar_t* kRunKey = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
std::wstring Wide(const std::string& text) {
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (length <= 0) return {};
  std::wstring result(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, result.data(), length);
  result.resize(static_cast<size_t>(length - 1));
  return result;
}
std::string ProcessPath(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return {};
  std::wstring buffer(32768, L'\0');
  DWORD length = static_cast<DWORD>(buffer.size());
  const BOOL ok = QueryFullProcessImageNameW(process, 0, buffer.data(), &length);
  CloseHandle(process);
  if (!ok) return {};
  buffer.resize(length);
  return Utf8FromUtf16(buffer.c_str());
}
bool StartupEnabled() {
  DWORD bytes = 0;
  return RegGetValueW(HKEY_CURRENT_USER, kRunKey, L"Timebud", RRF_RT_REG_SZ,
                      nullptr, nullptr, &bytes) == ERROR_SUCCESS;
}
LONG SetStartup(bool enabled) {
  HKEY key = nullptr;
  LONG status = RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
                               KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) return status;
  if (enabled) {
    std::wstring executable(32768, L'\0');
    const DWORD length = GetModuleFileNameW(nullptr, executable.data(),
                                           static_cast<DWORD>(executable.size()));
    if (length == 0 || length >= executable.size()) {
      RegCloseKey(key);
      return ERROR_BAD_PATHNAME;
    }
    executable.resize(length);
    const std::wstring command = L"\"" + executable + L"\" --tray";
    status = RegSetValueExW(key, L"Timebud", 0, REG_SZ,
                           reinterpret_cast<const BYTE*>(command.c_str()),
                           static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = RegDeleteValueW(key, L"Timebud");
    if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return status;
}
bool SecureDesktop() {
  HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
  if (!desktop) return true;
  wchar_t name[256]{};
  DWORD needed = 0;
  const BOOL ok = GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &needed);
  CloseDesktop(desktop);
  return !ok || _wcsicmp(name, L"Default") != 0;
}
}
FlutterWindow::FlutterWindow(const flutter::DartProject& project) : project_(project) {}
FlutterWindow::~FlutterWindow() = default;
void FlutterWindow::AddTray() {
  tray_.cbSize = sizeof(tray_);
  tray_.hWnd = GetHandle();
  tray_.uID = 1;
  tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_.uCallbackMessage = kTrayMessage;
  tray_.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(tray_.szTip, L"Sprout - Ready to track");
  Shell_NotifyIconW(NIM_ADD, &tray_);
}
void FlutterWindow::ShowFromTray() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}
bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;
  const RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) return false;
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "dev.beesan.timebud/platform",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    using flutter::EncodableList;
    using flutter::EncodableMap;
    using flutter::EncodableValue;
    const std::string& method = call.method_name();
    if (method == "snapshot") {
      EncodableList processes;
      const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
      if (snapshot != INVALID_HANDLE_VALUE) {
        PROCESSENTRY32W entry{};
        entry.dwSize = sizeof(entry);
        if (Process32FirstW(snapshot, &entry)) {
          do {
            const std::string path = ProcessPath(entry.th32ProcessID);
            if (path.empty()) continue;
            processes.emplace_back(EncodableMap{
                {EncodableValue("path"), EncodableValue(path)},
                {EncodableValue("name"), EncodableValue(Utf8FromUtf16(entry.szExeFile))},
                {EncodableValue("pid"), EncodableValue(static_cast<int64_t>(entry.th32ProcessID))},
            });
          } while (Process32NextW(snapshot, &entry));
        }
        CloseHandle(snapshot);
      }
      DWORD focused_pid = 0;
      GetWindowThreadProcessId(GetForegroundWindow(), &focused_pid);
      LASTINPUTINFO input{};
      input.cbSize = sizeof(input);
      const DWORD idle = GetLastInputInfo(&input) ? GetTickCount() - input.dwTime : 0;
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("processes"), EncodableValue(processes)},
          {EncodableValue("focused"), EncodableValue(ProcessPath(focused_pid))},
          {EncodableValue("idleMs"), EncodableValue(static_cast<int64_t>(idle))},
          {EncodableValue("locked"), EncodableValue(locked_ || suspended_ || SecureDesktop())},
      }));
    } else if (method == "startupEnabled") {
      result->Success(EncodableValue(StartupEnabled()));
    } else if (method == "setStartup") {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      const LONG status = enabled ? SetStartup(*enabled) : ERROR_INVALID_PARAMETER;
      if (status == ERROR_SUCCESS) result->Success();
      else result->Error("startup", "Could not update Windows startup.");
    } else if (method == "updateTimer") {
      const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
      if (args) {
        const auto name = args->find(EncodableValue("name"));
        if (name != args->end()) {
          const auto* text = std::get_if<std::string>(&name->second);
          if (text) {
            const std::wstring tip = L"Sprout - " + Wide(*text);
            wcsncpy_s(tray_.szTip, tip.c_str(), _TRUNCATE);
            Shell_NotifyIconW(NIM_MODIFY, &tray_);
          }
        }
      }
      result->Success();
    } else if (method == "quit") {
      quitting_ = true;
      result->Success();
      PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
    } else {
      result->NotImplemented();
    }
  });
  AddTray();
  WTSRegisterSessionNotification(GetHandle(), NOTIFY_FOR_THIS_SESSION);
  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    const auto args = GetCommandLineArguments();
    if (std::find(args.begin(), args.end(), "--tray") == args.end()) Show();
  });
  flutter_controller_->ForceRedraw();
  return true;
}
void FlutterWindow::OnDestroy() {
  Shell_NotifyIconW(NIM_DELETE, &tray_);
  WTSUnRegisterSessionNotification(GetHandle());
  channel_.reset();
  flutter_controller_.reset();
  Win32Window::OnDestroy();
}
LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) noexcept {
  static const UINT taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  if (message == taskbar_created) { AddTray(); return 0; }
  if (message == WM_CLOSE && !quitting_) { ShowWindow(hwnd, SW_HIDE); return 0; }
  if (message == WM_WTSSESSION_CHANGE) {
    if (wparam == WTS_SESSION_LOCK) locked_ = true;
    if (wparam == WTS_SESSION_UNLOCK) locked_ = false;
  }
  if (message == WM_POWERBROADCAST) {
    if (wparam == PBT_APMSUSPEND) suspended_ = true;
    if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) suspended_ = false;
  }
  if (message == kTrayMessage) {
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) ShowFromTray();
    if (lparam == WM_RBUTTONUP) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"Open Sprout");
      AppendMenuW(menu, MF_STRING, 2, L"Stop timer");
      AppendMenuW(menu, MF_STRING, 3, L"Toggle automatic tracking");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, 4, L"Quit");
      POINT point{};
      GetCursorPos(&point);
      SetForegroundWindow(hwnd);
      const UINT selection = static_cast<UINT>(TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY,
          point.x, point.y, 0, hwnd, nullptr));
      DestroyMenu(menu);
      if (selection == 1) ShowFromTray();
      if (channel_) {
        if (selection == 2) channel_->InvokeMethod("stop", nullptr);
        if (selection == 3) channel_->InvokeMethod("toggleAutomatic", nullptr);
        if (selection == 4) channel_->InvokeMethod("quit", nullptr);
      }
      PostMessageW(hwnd, WM_NULL, 0, 0);
    }
    return 0;
  }
  if (flutter_controller_) {
    const std::optional<LRESULT> result = flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (result) return *result;
    if (message == WM_FONTCHANGE) flutter_controller_->engine()->ReloadSystemFonts();
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
