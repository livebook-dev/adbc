#include <windows.h>

#include <cstring>
#include <erl_nif.h>
#include <libloaderapi.h>
#include <sstream>
#include <stdlib.h>
#include <string>
#include <wchar.h>
#include <winbase.h>

ERL_NIF_TERM adbc_dll_unused(ErlNifEnv *env, int argc,
                             const ERL_NIF_TERM argv[]) {
  (void)(env);
  (void)(argc);
  (void)(argv);
  return enif_make_int(env, 0);
}

int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data,
            ERL_NIF_TERM load_info) {
  // Silence "unused var" warnings.
  (void)(env);
  (void)(priv_data);
  (void)(old_priv_data);
  (void)(load_info);

  return 0;
}

int load(ErlNifEnv *, void **, ERL_NIF_TERM) {
  wchar_t dll_path_c[65536];
  char err_msg[128] = {'\0'};
  HMODULE hm = NULL;

  if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                             GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         (LPCWSTR)&load, &hm) == 0) {
    int ret = GetLastError();
    printf("GetModuleHandle failed, error = %d\n", ret);
    return 1;
  }

  if (GetModuleFileNameW(hm, (LPWSTR)dll_path_c, sizeof(dll_path_c)) == 0) {
    int ret = GetLastError();
    printf("GetModuleFileName failed, error = %d\n", ret);
    return 1;
  }

  std::wstring dll_path = dll_path_c;
  auto pos = dll_path.find_last_of(L'\\');
  auto priv_dir = dll_path.substr(0, pos);

  std::wstringstream torch_dir_ss;
  torch_dir_ss << priv_dir << L"\\bin";
  std::wstring torch_dir = torch_dir_ss.str();
  PCWSTR directory_pcwstr = torch_dir.c_str();

  WCHAR path_buffer[65536];
  DWORD path_len = GetEnvironmentVariableW(L"PATH", path_buffer, 65536);
  WCHAR new_path[65536];
  new_path[0] = L'\0';
  wcscpy_s(new_path, _countof(new_path), (const wchar_t *)path_buffer);
  wcscat_s(new_path, _countof(new_path), (const wchar_t *)L";");
  wcscat_s(new_path, _countof(new_path), (const wchar_t *)directory_pcwstr);
  SetEnvironmentVariableW(L"PATH", new_path);

  SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS |
                           LOAD_LIBRARY_SEARCH_USER_DIRS);
  DLL_DIRECTORY_COOKIE ret = AddDllDirectory(directory_pcwstr);

  if (ret == 0) {
    DWORD last_error = GetLastError();
    LPTSTR error_text = nullptr;
    FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_ALLOCATE_BUFFER |
                      FORMAT_MESSAGE_IGNORE_INSERTS,
                  NULL, HRESULT_FROM_WIN32(last_error),
                  MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                  (LPTSTR)&error_text, 0, NULL);

    if (error_text != nullptr) {
      printf("Error: %s\n", error_text);
      LocalFree(error_text);
    } else {
      printf("Error: error happened when adding adbc driver runtime path, but "
             "cannot get formatted error message\n");
    }

    return 1;
  }

  return 0;
}

static ErlNifFunc nif_functions[] = {{"__unused__", 0, adbc_dll_unused, 0}};

ERL_NIF_INIT(Elixir.Adbc.DLLLoaderNif, nif_functions, load, NULL, upgrade,
             NULL);
