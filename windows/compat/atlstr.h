// The secure-storage dependency only uses ATL for these two conversions.
// Keep its Windows Credential Manager / BCrypt implementation intact while
// allowing the standard Flutter C++ Build Tools workload without ATL/MFC.
#pragma once
#include <windows.h>
#include <string>

class CA2W {
 public:
  explicit CA2W(const char* source) {
    if (source == nullptr) source = "";
    const int length = MultiByteToWideChar(CP_UTF8, 0, source, -1, nullptr, 0);
    value_.resize(length > 0 ? length : 1);
    if (length > 0) MultiByteToWideChar(CP_UTF8, 0, source, -1, value_.data(), length);
    m_psz = value_.data();
  }
  operator const wchar_t*() const { return m_psz; }
  wchar_t* m_psz = nullptr;
 private:
  std::wstring value_;
};

inline std::string CW2A(const wchar_t* source) {
  if (source == nullptr) return {};
  const int length = WideCharToMultiByte(CP_UTF8, 0, source, -1, nullptr, 0, nullptr, nullptr);
  if (length <= 0) return {};
  std::string result(length, '\0');
  WideCharToMultiByte(CP_UTF8, 0, source, -1, result.data(), length, nullptr, nullptr);
  result.pop_back();
  return result;
}
