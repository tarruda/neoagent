-- Standalone Windows sandbox host. Elevated --setup provisions dedicated
-- launch authority, account-management rights, and persistent WFP policy.
-- Ordinary launches create a private account, lease its filesystem access,
-- and spawn the restricted target directly into a native Job. Journal locking
-- covers authority changes; live invocations own independent native guards.
-- Targets inherit neither the host's identity nor its privileged logon token.

local ffi = require("ffi")
local bit = require("bit")
-- All sizeof calls use concrete allocations or fixed-size C types.
local sizeof = ffi.sizeof --[[@as fun(value: string|ffi.cdata*): integer]]
local exit = os.exit --[[@as fun(code: integer): never]]

if jit.os ~= "Windows" then
  io.stderr:write("neoagent Windows sandbox runtime requires Windows\n")
  exit(2)
end

local source = assert(debug.getinfo(1, "S")).source:sub(2)
local checkout = assert(vim.fs.dirname(assert(vim.fs.dirname(source))))
---@type Neoagent.WindowsCommand
local windows_command = dofile(vim.fs.joinpath(
  checkout, "lua", "neoagent", "process", "windows_command.lua"))
local native_job = dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_job.lua"))
local kernel_objects = dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_objects.lua"))
local journal_owner = dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_authority.lua"))

-- LuaJIT FFI calls the Win32 ABI directly. These declarations cover process
-- creation, access tokens, filesystem ACLs, jobs, named pipes, local accounts,
-- the Windows Filtering Platform, and the small Winsock probe.
ffi.cdef([[
typedef void *HANDLE;
typedef void *HLOCAL;
typedef void *PVOID;
typedef unsigned char BYTE;
typedef unsigned char UCHAR;
typedef unsigned short WORD;
typedef unsigned short WCHAR;
typedef unsigned long DWORD;
typedef unsigned long ULONG;
typedef unsigned int UINT;
typedef unsigned long long ULONG_PTR;
typedef long BOOL;
typedef long LONG;
typedef unsigned long long ULONGLONG;
typedef long long LONGLONG;
typedef unsigned long long SIZE_T;
typedef unsigned long long UINT64;
typedef unsigned short USHORT;
typedef unsigned char BOOLEAN;
typedef uintptr_t SOCKET;

typedef struct _SECURITY_ATTRIBUTES {
  DWORD nLength;
  PVOID lpSecurityDescriptor;
  BOOL bInheritHandle;
} SECURITY_ATTRIBUTES;

typedef struct _LSA_UNICODE_STRING {
  USHORT Length;
  USHORT MaximumLength;
  WCHAR *Buffer;
} LSA_UNICODE_STRING;
typedef struct _LSA_OBJECT_ATTRIBUTES {
  ULONG Length;
  HANDLE RootDirectory;
  LSA_UNICODE_STRING *ObjectName;
  ULONG Attributes;
  void *SecurityDescriptor;
  void *SecurityQualityOfService;
} LSA_OBJECT_ATTRIBUTES;

typedef struct _STARTUPINFOW {
  DWORD cb;
  WCHAR *lpReserved;
  WCHAR *lpDesktop;
  WCHAR *lpTitle;
  DWORD dwX;
  DWORD dwY;
  DWORD dwXSize;
  DWORD dwYSize;
  DWORD dwXCountChars;
  DWORD dwYCountChars;
  DWORD dwFillAttribute;
  DWORD dwFlags;
  WORD wShowWindow;
  WORD cbReserved2;
  BYTE *lpReserved2;
  HANDLE hStdInput;
  HANDLE hStdOutput;
  HANDLE hStdError;
} STARTUPINFOW;

typedef struct _STARTUPINFOEXW {
  STARTUPINFOW StartupInfo;
  void *lpAttributeList;
} STARTUPINFOEXW;

typedef struct _PROCESS_INFORMATION {
  HANDLE hProcess;
  HANDLE hThread;
  DWORD dwProcessId;
  DWORD dwThreadId;
} PROCESS_INFORMATION;

typedef struct _SID SID;
typedef struct _ACL ACL;
typedef struct _SID_AND_ATTRIBUTES {
  SID *Sid;
  DWORD Attributes;
} SID_AND_ATTRIBUTES;
typedef struct _TOKEN_USER {
  SID_AND_ATTRIBUTES User;
} TOKEN_USER;
typedef struct _TOKEN_GROUPS {
  DWORD GroupCount;
  SID_AND_ATTRIBUTES Groups[1];
} TOKEN_GROUPS;
typedef struct _TOKEN_DEFAULT_DACL {
  ACL *DefaultDacl;
} TOKEN_DEFAULT_DACL;
typedef struct _LUID {
  DWORD LowPart;
  LONG HighPart;
} LUID;
typedef struct _LUID_AND_ATTRIBUTES {
  LUID Luid;
  DWORD Attributes;
} LUID_AND_ATTRIBUTES;
typedef struct _TOKEN_PRIVILEGES {
  DWORD PrivilegeCount;
  LUID_AND_ATTRIBUTES Privileges[1];
} TOKEN_PRIVILEGES;

typedef struct _TRUSTEE_W {
  struct _TRUSTEE_W *pMultipleTrustee;
  LONG MultipleTrusteeOperation;
  LONG TrusteeForm;
  LONG TrusteeType;
  WCHAR *ptstrName;
} TRUSTEE_W;
typedef struct _EXPLICIT_ACCESS_W {
  DWORD grfAccessPermissions;
  LONG grfAccessMode;
  DWORD grfInheritance;
  TRUSTEE_W Trustee;
} EXPLICIT_ACCESS_W;

typedef struct _USER_INFO_1 {
  WCHAR *usri1_name;
  WCHAR *usri1_password;
  DWORD usri1_password_age;
  DWORD usri1_priv;
  WCHAR *usri1_home_dir;
  WCHAR *usri1_comment;
  DWORD usri1_flags;
  WCHAR *usri1_script_path;
} USER_INFO_1;
typedef struct _USER_INFO_1003 {
  WCHAR *usri1003_password;
} USER_INFO_1003;

typedef struct _DATA_BLOB {
  DWORD cbData;
  BYTE *pbData;
} DATA_BLOB;

typedef struct _BY_HANDLE_FILE_INFORMATION {
  DWORD dwFileAttributes;
  DWORD ftCreationTimeLow;
  DWORD ftCreationTimeHigh;
  DWORD ftLastAccessTimeLow;
  DWORD ftLastAccessTimeHigh;
  DWORD ftLastWriteTimeLow;
  DWORD ftLastWriteTimeHigh;
  DWORD dwVolumeSerialNumber;
  DWORD nFileSizeHigh;
  DWORD nFileSizeLow;
  DWORD nNumberOfLinks;
  DWORD nFileIndexHigh;
  DWORD nFileIndexLow;
} BY_HANDLE_FILE_INFORMATION;

typedef struct _GUID {
  DWORD Data1;
  WORD Data2;
  WORD Data3;
  BYTE Data4[8];
} GUID;
typedef struct _FWP_BYTE_BLOB {
  DWORD size;
  BYTE *data;
} FWP_BYTE_BLOB;
typedef union _FWP_VALUE0_UNION {
  UCHAR uint8;
  USHORT uint16;
  DWORD uint32;
  UINT64 *uint64;
  LONGLONG *int64;
  FWP_BYTE_BLOB *byteBlob;
  SID *sid;
  FWP_BYTE_BLOB *sd;
  WCHAR *unicodeString;
  void *pointer;
} FWP_VALUE0_UNION;
typedef struct _FWP_VALUE0 {
  LONG type;
  FWP_VALUE0_UNION value;
} FWP_VALUE0;
typedef FWP_VALUE0 FWP_CONDITION_VALUE0;
typedef struct _FWPM_DISPLAY_DATA0 {
  WCHAR *name;
  WCHAR *description;
} FWPM_DISPLAY_DATA0;
typedef struct _FWPM_SESSION0 {
  GUID sessionKey;
  FWPM_DISPLAY_DATA0 displayData;
  DWORD flags;
  DWORD txnWaitTimeoutInMSec;
  DWORD processId;
  SID *sid;
  WCHAR *username;
  BOOL kernelMode;
} FWPM_SESSION0;
typedef struct _FWPM_PROVIDER0 {
  GUID providerKey;
  FWPM_DISPLAY_DATA0 displayData;
  DWORD flags;
  FWP_BYTE_BLOB providerData;
  WCHAR *serviceName;
} FWPM_PROVIDER0;
typedef struct _FWPM_SUBLAYER0 {
  GUID subLayerKey;
  FWPM_DISPLAY_DATA0 displayData;
  DWORD flags;
  GUID *providerKey;
  FWP_BYTE_BLOB providerData;
  WORD weight;
} FWPM_SUBLAYER0;
typedef struct _FWPM_FILTER_CONDITION0 {
  GUID fieldKey;
  LONG matchType;
  FWP_CONDITION_VALUE0 conditionValue;
} FWPM_FILTER_CONDITION0;
typedef union _FWPM_ACTION0_UNION {
  GUID filterType;
  GUID calloutKey;
} FWPM_ACTION0_UNION;
typedef struct _FWPM_ACTION0 {
  DWORD type;
  FWPM_ACTION0_UNION value;
} FWPM_ACTION0;
typedef union _FWPM_FILTER0_UNION {
  UINT64 rawContext;
  GUID providerContextKey;
} FWPM_FILTER0_UNION;
typedef struct _FWPM_FILTER0 {
  GUID filterKey;
  FWPM_DISPLAY_DATA0 displayData;
  DWORD flags;
  GUID *providerKey;
  FWP_BYTE_BLOB providerData;
  GUID layerKey;
  GUID subLayerKey;
  FWP_VALUE0 weight;
  DWORD numFilterConditions;
  FWPM_FILTER_CONDITION0 *filterCondition;
  FWPM_ACTION0 action;
  FWPM_FILTER0_UNION context;
  GUID *reserved;
  UINT64 filterId;
  FWP_VALUE0 effectiveWeight;
} FWPM_FILTER0;

typedef struct _WSADATA {
  WORD wVersion;
  WORD wHighVersion;
  WORD iMaxSockets;
  WORD iMaxUdpDg;
  char *lpVendorInfo;
  char szDescription[257];
  char szSystemStatus[129];
} WSADATA;
typedef struct _IN_ADDR {
  DWORD s_addr;
} IN_ADDR;
typedef struct _SOCKADDR_IN {
  short sin_family;
  USHORT sin_port;
  IN_ADDR sin_addr;
  char sin_zero[8];
} SOCKADDR_IN;

DWORD __stdcall GetLastError(void);
void __stdcall SetLastError(DWORD);
HANDLE __stdcall GetCurrentProcess(void);
DWORD __stdcall GetCurrentProcessId(void);
HANDLE __stdcall GetStdHandle(DWORD);
BOOL __stdcall ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
BOOL __stdcall WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
BOOL __stdcall CloseHandle(HANDLE);
HLOCAL __stdcall LocalFree(HLOCAL);
DWORD __stdcall WaitForSingleObject(HANDLE, DWORD);
BOOL __stdcall GetExitCodeProcess(HANDLE, DWORD *);
void __stdcall Sleep(DWORD);
HANDLE __stdcall CreateMutexW(SECURITY_ATTRIBUTES *, BOOL, const WCHAR *);
BOOL __stdcall ReleaseMutex(HANDLE);
BOOL __stdcall CreatePipe(HANDLE *, HANDLE *, SECURITY_ATTRIBUTES *, DWORD);
BOOL __stdcall InitializeProcThreadAttributeList(
  void *, DWORD, DWORD, SIZE_T *);
BOOL __stdcall UpdateProcThreadAttribute(
  void *, DWORD, ULONG_PTR, void *, SIZE_T, void *, SIZE_T *);
void __stdcall DeleteProcThreadAttributeList(void *);
BOOL __stdcall SetHandleInformation(HANDLE, DWORD, DWORD);
BOOL __stdcall PeekNamedPipe(HANDLE, void *, DWORD, DWORD *, DWORD *, DWORD *);
HANDLE __stdcall CreateFileW(const WCHAR *, DWORD, DWORD,
  SECURITY_ATTRIBUTES *, DWORD, DWORD, HANDLE);
BOOL __stdcall GetFileInformationByHandle(HANDLE, BY_HANDLE_FILE_INFORMATION *);
BOOL __stdcall CreateDirectoryW(const WCHAR *, SECURITY_ATTRIBUTES *);
BOOL __stdcall DeleteFileW(const WCHAR *);
BOOL __stdcall RemoveDirectoryW(const WCHAR *);
BOOL __stdcall FlushFileBuffers(HANDLE);
BOOL __stdcall GetFileSizeEx(HANDLE, LONGLONG *);
BOOL __stdcall MoveFileExW(const WCHAR *, const WCHAR *, DWORD);
int __stdcall MultiByteToWideChar(UINT, DWORD, const char *, int, WCHAR *, int);
int __stdcall CompareStringOrdinal(const WCHAR *, int, const WCHAR *, int, BOOL);
int __stdcall WideCharToMultiByte(UINT, DWORD, const WCHAR *, int,
  char *, int, const char *, BOOL *);

BOOL __stdcall OpenProcessToken(HANDLE, DWORD, HANDLE *);
BOOL __stdcall LogonUserW(const WCHAR *, const WCHAR *, const WCHAR *, DWORD, DWORD, HANDLE *);
LONG __stdcall LsaOpenPolicy(LSA_UNICODE_STRING *, LSA_OBJECT_ATTRIBUTES *, DWORD, HANDLE *);
LONG __stdcall LsaAddAccountRights(HANDLE, SID *, LSA_UNICODE_STRING *, ULONG);
ULONG __stdcall LsaNtStatusToWinError(LONG);
LONG __stdcall LsaClose(HANDLE);
BOOL __stdcall GetTokenInformation(HANDLE, LONG, void *, DWORD, DWORD *);
BOOL __stdcall ConvertStringSidToSidW(const WCHAR *, SID **);
BOOL __stdcall ConvertSidToStringSidW(SID *, WCHAR **);
BOOL __stdcall LookupAccountNameW(const WCHAR *, const WCHAR *, SID *,
  DWORD *, WCHAR *, DWORD *, LONG *);
BOOL __stdcall CreateRestrictedToken(HANDLE, DWORD, DWORD,
  SID_AND_ATTRIBUTES *, DWORD, LUID_AND_ATTRIBUTES *, DWORD,
  SID_AND_ATTRIBUTES *, HANDLE *);
BOOL __stdcall SetTokenInformation(HANDLE, LONG, void *, DWORD);
BOOL __stdcall LookupPrivilegeValueW(const WCHAR *, const WCHAR *, LUID *);
BOOL __stdcall AdjustTokenPrivileges(HANDLE, BOOL, TOKEN_PRIVILEGES *,
  DWORD, TOKEN_PRIVILEGES *, DWORD *);
BOOL __stdcall ImpersonateLoggedOnUser(HANDLE);
BOOL __stdcall RevertToSelf(void);
DWORD __stdcall GetNamedSecurityInfoW(WCHAR *, LONG, DWORD, SID **, SID **,
  ACL **, ACL **, void **);
DWORD __stdcall SetNamedSecurityInfoW(WCHAR *, LONG, DWORD, SID *, SID *,
  ACL *, ACL *);
DWORD __stdcall SetSecurityInfo(HANDLE, LONG, DWORD, SID *, SID *, ACL *, ACL *);
DWORD __stdcall SetEntriesInAclW(ULONG, EXPLICIT_ACCESS_W *, ACL *, ACL **);
BOOL __stdcall ConvertStringSecurityDescriptorToSecurityDescriptorW(
  const WCHAR *, DWORD, void **, ULONG *);
BOOL __stdcall SetFileSecurityW(const WCHAR *, DWORD, void *);
DWORD __stdcall BuildSecurityDescriptorW(TRUSTEE_W *, TRUSTEE_W *, ULONG,
  EXPLICIT_ACCESS_W *, ULONG, EXPLICIT_ACCESS_W *, void *, ULONG *, void **);
BOOL __stdcall CreateProcessAsUserW(HANDLE, const WCHAR *, WCHAR *,
  SECURITY_ATTRIBUTES *, SECURITY_ATTRIBUTES *, BOOL, DWORD, void *,
  const WCHAR *, STARTUPINFOW *, PROCESS_INFORMATION *);
DWORD __stdcall ResumeThread(HANDLE);

DWORD __stdcall NetUserAdd(const WCHAR *, DWORD, BYTE *, DWORD *);
DWORD __stdcall NetUserGetInfo(const WCHAR *, const WCHAR *, DWORD, BYTE **);
DWORD __stdcall NetApiBufferFree(void *);
DWORD __stdcall NetUserSetInfo(const WCHAR *, const WCHAR *, DWORD,
  BYTE *, DWORD *);

BOOL __stdcall CryptProtectData(DATA_BLOB *, const WCHAR *, DATA_BLOB *,
  void *, void *, DWORD, DATA_BLOB *);
BOOL __stdcall CryptUnprotectData(DATA_BLOB *, WCHAR **, DATA_BLOB *,
  void *, void *, DWORD, DATA_BLOB *);

HANDLE __stdcall CreateDesktopW(const WCHAR *, const WCHAR *, void *,
  DWORD, DWORD, SECURITY_ATTRIBUTES *);
BOOL __stdcall CloseDesktop(HANDLE);
HANDLE __stdcall GetProcessWindowStation(void);
HANDLE __stdcall CreateWindowStationW(const WCHAR *, DWORD, DWORD, SECURITY_ATTRIBUTES *);
BOOL __stdcall SetProcessWindowStation(HANDLE);
BOOL __stdcall CloseWindowStation(HANDLE);

DWORD __stdcall FwpmEngineOpen0(const WCHAR *, DWORD, void *,
  FWPM_SESSION0 *, HANDLE *);
DWORD __stdcall FwpmEngineClose0(HANDLE);
DWORD __stdcall FwpmTransactionBegin0(HANDLE, DWORD);
DWORD __stdcall FwpmTransactionCommit0(HANDLE);
DWORD __stdcall FwpmTransactionAbort0(HANDLE);
DWORD __stdcall FwpmProviderAdd0(HANDLE, FWPM_PROVIDER0 *, void *);
DWORD __stdcall FwpmSubLayerAdd0(HANDLE, FWPM_SUBLAYER0 *, void *);
DWORD __stdcall FwpmFilterAdd0(HANDLE, FWPM_FILTER0 *, void *, UINT64 *);
DWORD __stdcall FwpmFilterDeleteByKey0(HANDLE, const GUID *);

int __stdcall WSAStartup(WORD, WSADATA *);
int __stdcall WSACleanup(void);
SOCKET __stdcall socket(int, int, int);
int __stdcall connect(SOCKET, const void *, int);
int __stdcall closesocket(SOCKET);
int __stdcall WSAGetLastError(void);
USHORT __stdcall htons(USHORT);
]])

-- Each short name identifies the system DLL that owns a group of operations:
-- kernel/process I/O, security, accounts, encryption, desktops, firewall, and
-- sockets respectively.
-- Native field contracts mirror the Win32 structures declared above.
---@class Neoagent.Win32.SECURITY_ATTRIBUTES: ffi.cdata*
---@field nLength integer
---@field lpSecurityDescriptor ffi.cdata*
---@field bInheritHandle integer

---@class Neoagent.Win32.STARTUPINFOW: ffi.cdata*
---@field cb integer
---@field lpReserved ffi.cdata*?
---@field lpDesktop ffi.cdata*?
---@field lpTitle ffi.cdata*?
---@field dwX integer
---@field dwY integer
---@field dwXSize integer
---@field dwYSize integer
---@field dwXCountChars integer
---@field dwYCountChars integer
---@field dwFillAttribute integer
---@field dwFlags integer
---@field wShowWindow integer
---@field cbReserved2 integer
---@field lpReserved2 ffi.cdata*?
---@field hStdInput ffi.cdata*
---@field hStdOutput ffi.cdata*
---@field hStdError ffi.cdata*

---@class Neoagent.Win32.STARTUPINFOEXW: ffi.cdata*
---@field StartupInfo Neoagent.Win32.STARTUPINFOW
---@field lpAttributeList ffi.cdata*?

---@class Neoagent.Win32.PROCESS_INFORMATION: ffi.cdata*
---@field hProcess ffi.cdata*
---@field hThread ffi.cdata*
---@field dwProcessId integer
---@field dwThreadId integer

---@class Neoagent.Win32.SID_AND_ATTRIBUTES: ffi.cdata*
---@field Sid ffi.cdata*?
---@field Attributes integer

---@class Neoagent.Win32.TOKEN_USER: ffi.cdata*
---@field User Neoagent.Win32.SID_AND_ATTRIBUTES

---@class Neoagent.Win32.TOKEN_GROUPS: ffi.cdata*
---@field GroupCount integer
---@field Groups Neoagent.FfiArray<Neoagent.Win32.SID_AND_ATTRIBUTES>

---@class Neoagent.Win32.TOKEN_DEFAULT_DACL: ffi.cdata*
---@field DefaultDacl ffi.cdata*?

---@class Neoagent.Win32.LUID: ffi.cdata*
---@field LowPart integer
---@field HighPart integer

---@class Neoagent.Win32.LUID_AND_ATTRIBUTES: ffi.cdata*
---@field Luid Neoagent.Win32.LUID
---@field Attributes integer

---@class Neoagent.Win32.TOKEN_PRIVILEGES: ffi.cdata*
---@field PrivilegeCount integer
---@field Privileges Neoagent.FfiArray<Neoagent.Win32.LUID_AND_ATTRIBUTES>

---@class Neoagent.Win32.TRUSTEE_W: ffi.cdata*
---@field pMultipleTrustee ffi.cdata*?
---@field MultipleTrusteeOperation integer
---@field TrusteeForm integer
---@field TrusteeType integer
---@field ptstrName ffi.cdata*?

---@class Neoagent.Win32.EXPLICIT_ACCESS_W: ffi.cdata*
---@field grfAccessPermissions integer
---@field grfAccessMode integer
---@field grfInheritance integer
---@field Trustee Neoagent.Win32.TRUSTEE_W

---@class Neoagent.Win32.USER_INFO_1: ffi.cdata*
---@field usri1_name ffi.cdata*?
---@field usri1_password ffi.cdata*?
---@field usri1_password_age integer
---@field usri1_priv integer
---@field usri1_home_dir ffi.cdata*?
---@field usri1_comment ffi.cdata*?
---@field usri1_flags integer
---@field usri1_script_path ffi.cdata*?

---@class Neoagent.Win32.USER_INFO_1003: ffi.cdata*
---@field usri1003_password ffi.cdata*?

---@class Neoagent.Win32.DATA_BLOB: ffi.cdata*
---@field cbData integer
---@field pbData ffi.cdata*?

---@class Neoagent.Win32.BY_HANDLE_FILE_INFORMATION: ffi.cdata*
---@field dwFileAttributes integer
---@field ftCreationTimeLow integer
---@field ftCreationTimeHigh integer
---@field ftLastAccessTimeLow integer
---@field ftLastAccessTimeHigh integer
---@field ftLastWriteTimeLow integer
---@field ftLastWriteTimeHigh integer
---@field dwVolumeSerialNumber integer
---@field nFileSizeHigh integer
---@field nFileSizeLow integer
---@field nNumberOfLinks integer
---@field nFileIndexHigh integer
---@field nFileIndexLow integer

---@class Neoagent.Win32.GUID: ffi.cdata*
---@field Data1 integer
---@field Data2 integer
---@field Data3 integer
---@field Data4 Neoagent.FfiArray<integer>

---@class Neoagent.Win32.FWP_BYTE_BLOB: ffi.cdata*
---@field size integer
---@field data ffi.cdata*?

---@class Neoagent.Win32.FWP_VALUE0_UNION: ffi.cdata*
---@field uint8 integer
---@field uint16 integer
---@field uint32 integer
---@field uint64 ffi.cdata*?
---@field int64 ffi.cdata*?
---@field byteBlob ffi.cdata*?
---@field sid ffi.cdata*?
---@field sd ffi.cdata*?
---@field unicodeString ffi.cdata*?
---@field pointer ffi.cdata*?

---@class Neoagent.Win32.FWP_VALUE0: ffi.cdata*
---@field type integer
---@field value Neoagent.Win32.FWP_VALUE0_UNION

---@class Neoagent.Win32.FWPM_DISPLAY_DATA0: ffi.cdata*
---@field name ffi.cdata*?
---@field description ffi.cdata*?

---@class Neoagent.Win32.FWPM_SESSION0: ffi.cdata*
---@field sessionKey Neoagent.Win32.GUID
---@field displayData Neoagent.Win32.FWPM_DISPLAY_DATA0
---@field flags integer
---@field txnWaitTimeoutInMSec integer
---@field processId integer
---@field sid ffi.cdata*?
---@field username ffi.cdata*?
---@field kernelMode integer

---@class Neoagent.Win32.FWPM_PROVIDER0: ffi.cdata*
---@field providerKey Neoagent.Win32.GUID
---@field displayData Neoagent.Win32.FWPM_DISPLAY_DATA0
---@field flags integer
---@field providerData Neoagent.Win32.FWP_BYTE_BLOB
---@field serviceName ffi.cdata*?

---@class Neoagent.Win32.FWPM_SUBLAYER0: ffi.cdata*
---@field subLayerKey Neoagent.Win32.GUID
---@field displayData Neoagent.Win32.FWPM_DISPLAY_DATA0
---@field flags integer
---@field providerKey ffi.cdata*?
---@field providerData Neoagent.Win32.FWP_BYTE_BLOB
---@field weight integer

---@class Neoagent.Win32.FWPM_FILTER_CONDITION0: ffi.cdata*
---@field fieldKey Neoagent.Win32.GUID
---@field matchType integer
---@field conditionValue Neoagent.Win32.FWP_VALUE0

---@class Neoagent.Win32.FWPM_ACTION0_UNION: ffi.cdata*
---@field filterType Neoagent.Win32.GUID
---@field calloutKey Neoagent.Win32.GUID

---@class Neoagent.Win32.FWPM_ACTION0: ffi.cdata*
---@field type integer
---@field value Neoagent.Win32.FWPM_ACTION0_UNION

---@class Neoagent.Win32.FWPM_FILTER0_UNION: ffi.cdata*
---@field rawContext integer|ffi.cdata*
---@field providerContextKey Neoagent.Win32.GUID

---@class Neoagent.Win32.FWPM_FILTER0: ffi.cdata*
---@field filterKey Neoagent.Win32.GUID
---@field displayData Neoagent.Win32.FWPM_DISPLAY_DATA0
---@field flags integer
---@field providerKey ffi.cdata*?
---@field providerData Neoagent.Win32.FWP_BYTE_BLOB
---@field layerKey Neoagent.Win32.GUID
---@field subLayerKey Neoagent.Win32.GUID
---@field weight Neoagent.Win32.FWP_VALUE0
---@field numFilterConditions integer
---@field filterCondition ffi.cdata*?
---@field action Neoagent.Win32.FWPM_ACTION0
---@field context Neoagent.Win32.FWPM_FILTER0_UNION
---@field reserved ffi.cdata*?
---@field filterId integer|ffi.cdata*
---@field effectiveWeight Neoagent.Win32.FWP_VALUE0

---@class Neoagent.Win32.WSADATA: ffi.cdata*
---@field wVersion integer
---@field wHighVersion integer
---@field iMaxSockets integer
---@field iMaxUdpDg integer
---@field lpVendorInfo ffi.cdata*?
---@field szDescription Neoagent.FfiArray<integer>
---@field szSystemStatus Neoagent.FfiArray<integer>

---@class Neoagent.Win32.IN_ADDR: ffi.cdata*
---@field s_addr integer

---@class Neoagent.Win32.SOCKADDR_IN: ffi.cdata*
---@field sin_family integer
---@field sin_port integer
---@field sin_addr Neoagent.Win32.IN_ADDR
---@field sin_zero Neoagent.FfiArray<integer>

local K = ffi.load("kernel32")
local A = ffi.load("advapi32")
local N = ffi.load("netapi32")
local C = ffi.load("crypt32")
local U = ffi.load("user32")
local F = ffi.load("fwpuclnt")
local W = ffi.load("ws2_32")

-- This isolated headless runtime groups Win32 constants by subsystem. A
-- single lexical table also keeps the chunk within LuaJIT's 200-local limit.
local WIN32 = {
  HANDLE = {
    INVALID = ffi.cast("HANDLE", -1),
    STD_INPUT = 0xfffffff6,
    STD_OUTPUT = 0xfffffff5,
    INHERIT = 0x1,
  },
  WAIT = {
    INFINITE = 0xffffffff,
    OBJECT_0 = 0,
    ABANDONED = 0x80,
    TIMEOUT = 0x102,
  },
  ERROR = {
    SUCCESS = 0,
    FILE_NOT_FOUND = 2,
    PATH_NOT_FOUND = 3,
    ACCESS_DENIED = 5,
    INVALID_PARAMETER = 87,
    BROKEN_PIPE = 109,
    ALREADY_EXISTS = 183,
    PIPE_BUSY = 231,
    NO_DATA = 232,
    PIPE_CONNECTED = 535,
    PIPE_LISTENING = 536,
    USER_EXISTS = 2224,
    WSA_ACCESS_DENIED = 10013,
  },
  TOKEN = {
    ASSIGN_PRIMARY = 0x0001,
    DUPLICATE = 0x0002,
    QUERY = 0x0008,
    ADJUST_PRIVILEGES = 0x0020,
    ADJUST_DEFAULT = 0x0080,
    ADJUST_SESSION_ID = 0x0100,
    USER_CLASS = 1,
    GROUPS_CLASS = 2,
    DEFAULT_DACL_CLASS = 6,
    DISABLE_MAX_PRIVILEGE = 0x01,
    LUA = 0x04,
    WRITE_RESTRICTED = 0x08,
    LOGON_INTERACTIVE = 2,
  },
  ACCESS = {
    GENERIC_READ = 0x80000000,
    GENERIC_WRITE = 0x40000000,
    GENERIC_ALL = 0x10000000,
    DELETE = 0x00010000,
    READ_CONTROL = 0x00020000,
    WRITE_DACL = 0x00040000,
    WRITE_OWNER = 0x00080000,
    SYNCHRONIZE = 0x00100000,
  },
  FILE = {
    READ_DATA = 0x0001,
    WRITE_DATA = 0x0002,
    APPEND_DATA = 0x0004,
    READ_EA = 0x0008,
    WRITE_EA = 0x0010,
    EXECUTE = 0x0020,
    DELETE_CHILD = 0x0040,
    READ_ATTRIBUTES = 0x0080,
    WRITE_ATTRIBUTES = 0x0100,
    ALL_ACCESS = 0x001f01ff,
    SHARE_READ = 0x1,
    SHARE_WRITE = 0x2,
    SHARE_DELETE = 0x4,
    CREATE_NEW = 1,
    CREATE_ALWAYS = 2,
    OPEN_EXISTING = 3,
    ATTRIBUTE_DIRECTORY = 0x10,
    ATTRIBUTE_NORMAL = 0x80,
    ATTRIBUTE_TEMPORARY = 0x100,
    ATTRIBUTE_REPARSE_POINT = 0x400,
    INVALID_ATTRIBUTES = 0xffffffff,
    FLAG_BACKUP_SEMANTICS = 0x02000000,
    FLAG_OPEN_REPARSE_POINT = 0x00200000,
    MOVE_REPLACE_EXISTING = 0x1,
    MOVE_WRITE_THROUGH = 0x8,
  },
  SECURITY = {
    PRIVILEGE_ENABLED = 0x2,
    GROUP_LOGON_ID = bit.tobit(0xc0000000),
    FILE_OBJECT = 1,
    KERNEL_OBJECT = 6,
    DACL_INFORMATION = 0x4,
    PROTECTED_DACL_INFORMATION = 0x80000000,
    SET_ACCESS = 2,
    GRANT_ACCESS = 1,
    DENY_ACCESS = 3,
    REVOKE_ACCESS = 4,
    TRUSTEE_SID = 0,
    TRUSTEE_UNKNOWN = 0,
    CONTAINER_INHERIT_ACE = 0x2,
    OBJECT_INHERIT_ACE = 0x1,
  },
  DESKTOP = {
    NAME = 2,
    ALL_ACCESS = 0x000f01ff,
    STATION_ALL_ACCESS = 0x000f037f,
  },
  PIPE = {
    ACCESS_OUTBOUND = 0x2,
    ACCESS_DUPLEX = 0x3,
    TYPE_BYTE = 0,
    READMODE_BYTE = 0,
    WAIT = 0,
    NOWAIT = 1,
  },
  PROCESS = {
    STARTF_USESTDHANDLES = 0x100,
    CREATE_SUSPENDED = 0x4,
    CREATE_NO_WINDOW = 0x08000000,
    CREATE_UNICODE_ENVIRONMENT = 0x400,
    EXTENDED_STARTUPINFO_PRESENT = 0x00080000,
    ATTRIBUTE_HANDLE_LIST = 0x00020002,
    ATTRIBUTE_JOB_LIST = 0x0002000d,
  },
  ACCOUNT = {
    PRIVILEGE_USER = 1,
    SCRIPT = 0x1,
    PASSWORD_CANNOT_CHANGE = 0x40,
    NORMAL = 0x200,
    PASSWORD_NEVER_EXPIRES = 0x10000,
  },
  CRYPT = {
    UI_FORBIDDEN = 0x1,
  },
  WFP = {
    EMPTY = 0,
    SECURITY_DESCRIPTOR_TYPE = 14,
    MATCH_EQUAL = 0,
    ACTION_BLOCK = 0x1001,
    ACCESS_MATCH_FILTER = 0x1,
    FILTER_PERSISTENT = 0x1,
    PROVIDER_PERSISTENT = 0x1,
    SUBLAYER_PERSISTENT = 0x1,
    ALREADY_EXISTS = 0x80320009,
    FILTER_NOT_FOUND = 0x80320003,
    NOT_FOUND = 0x80320008,
  },
  SOCKET = {
    INVALID = ffi.cast("SOCKET", -1),
    AF_INET = 2,
    STREAM = 1,
    TCP = 6,
  },
}

WIN32.FILE.GENERIC_READ = bit.bor(
  WIN32.ACCESS.READ_CONTROL, WIN32.FILE.READ_DATA,
  WIN32.FILE.READ_ATTRIBUTES, WIN32.FILE.READ_EA,
  WIN32.ACCESS.SYNCHRONIZE)
WIN32.FILE.GENERIC_WRITE = bit.bor(
  WIN32.ACCESS.READ_CONTROL, WIN32.FILE.WRITE_DATA,
  WIN32.FILE.WRITE_ATTRIBUTES, WIN32.FILE.WRITE_EA,
  WIN32.FILE.APPEND_DATA, WIN32.ACCESS.SYNCHRONIZE)
WIN32.FILE.GENERIC_EXECUTE = bit.bor(
  WIN32.ACCESS.READ_CONTROL, WIN32.FILE.EXECUTE,
  WIN32.FILE.READ_ATTRIBUTES, WIN32.ACCESS.SYNCHRONIZE)
WIN32.FILE.SANDBOX_READ = bit.bor(
  WIN32.FILE.GENERIC_READ, WIN32.FILE.GENERIC_EXECUTE)
WIN32.FILE.SANDBOX_WRITE = bit.bor(
  WIN32.FILE.GENERIC_READ, WIN32.FILE.GENERIC_WRITE,
  WIN32.FILE.GENERIC_EXECUTE, WIN32.ACCESS.DELETE)
WIN32.FILE.SANDBOX_DENY_WRITE = bit.bor(
  WIN32.FILE.WRITE_DATA, WIN32.FILE.APPEND_DATA,
  WIN32.FILE.WRITE_EA, WIN32.FILE.WRITE_ATTRIBUTES, WIN32.ACCESS.DELETE,
  WIN32.FILE.DELETE_CHILD, WIN32.ACCESS.WRITE_DACL,
  WIN32.ACCESS.WRITE_OWNER)

-- Protocol and lifecycle limits live together so bounded reads, output
-- polling and cleanup remain easy to audit.
local RUNTIME = {
  ADMISSION_TIMEOUT_MS = 60 * 1000,
  MAX_FRAME = 1024 * 1024,
  STATE_VERSION = 9,
  PROTOCOL_VERSION = 1,
  OUTPUT_POLL_MS = 10,
  OUTPUT_DRAIN_POLLS = 1000,
}

---@class Neoagent.WindowsLsaAttributes: ffi.cdata*
---@field Length integer

---@class Neoagent.WindowsLsaString: ffi.cdata*
---@field Length integer
---@field MaximumLength integer
---@field Buffer Neoagent.FfiArray<integer>

---@class Neoagent.WindowsRuntimeError
---@field sandbox_runtime_error? boolean
---@field stage string
---@field errno integer

---@class Neoagent.WindowsRuntimeAccount
---@field name string
---@field marker string Native creation comment, reserved before allocation.
---@field sid? string Absent until setup observes the reserved native principal.
---@field password string

---@class Neoagent.WindowsPathIdentity
---@field volume integer
---@field high integer
---@field low integer

---@class Neoagent.WindowsPlaceholder
---@field path string
---@field marker string
---@field nonce string
---@field marker_ready boolean
---@field volume? integer
---@field high? integer
---@field low? integer

---@class Neoagent.WindowsAuthorityLease
---@field job "unstarted"|"unconfirmed"|"empty" Durable execution evidence, independent of Job-name availability.
---@field policy Neoagent.WindowsAuthorityPolicy
---@field account Neoagent.WindowsPrivateAccount
---@field logon_sid? string
---@field launch_sid? string Trusted creation token's temporary read access.
---@field namespaces? string[] Session object directories granted to the private account.
---@field paths string[]

---@class Neoagent.WindowsAuthorityPolicy
---@field write_roots string[]
---@field deny_write string[] Includes every read-only and denied boundary.

---@class Neoagent.WindowsRuntimeState
---@field v integer
---@field owner_sid string
---@field coordinator string
---@field provisioned boolean Ordinary admission requires completed persistent setup.
---@field launcher Neoagent.WindowsRuntimeAccount
---@field offline_group Neoagent.WindowsOfflineGroup
---@field leases table<string, Neoagent.WindowsAuthorityLease>
---@field placeholders Neoagent.WindowsPlaceholder[]
---@field wfp {filters: string[]}

---@class Neoagent.WindowsRuntimeSpec: Neoagent.WindowsSandboxSpec
---@field profile Neoagent.WindowsSandboxProfile
---@field cwd string

---@class Neoagent.WindowsTarget
---@field ready? boolean The target was resumed and its readiness frame delivered.
---@field stdin? ffi.cdata*
---@field stdin_write? ffi.cdata*
---@field stdout? ffi.cdata*
---@field stdout_write? ffi.cdata*
---@field stderr? ffi.cdata*
---@field stderr_write? ffi.cdata*
---@field process? ffi.cdata*
---@field thread? ffi.cdata*
---@field job? Neoagent.WindowsSandboxJob
---@field desktop? Neoagent.WindowsDesktop
---@field attributes? Neoagent.WindowsProcessAttributes

---@class Neoagent.WindowsProcessAttributes
---@field storage ffi.cdata*
---@field list? ffi.cdata*
---@field handles Neoagent.FfiArray<ffi.cdata*>
---@field jobs Neoagent.FfiArray<ffi.cdata*>

---@class Neoagent.WindowsDesktop
---@field desktop ffi.cdata*
---@field station ffi.cdata*
---@field name Neoagent.FfiArray<integer>

---@alias Neoagent.WindowsWireOutput Neoagent.SandboxProtocolEvent
---@alias Neoagent.WindowsOutput fun(stream: 'stdout'|'stderr', data: string)

-- This owner is private to the standalone Windows host. The editor-facing
-- lease continues to observe the existing readiness/cleanup/release protocol.
local authority = {}

---@param handle? ffi.cdata*
---@return boolean
local function invalid_handle(handle)
  return handle == nil
    or handle == WIN32.HANDLE.INVALID
end

---@param handle? ffi.cdata*
local function close_handle(handle)
  if not invalid_handle(handle) then K.CloseHandle(handle) end
end

---@return integer
local function last_error()
  return (tonumber(K.GetLastError()) --[[@as integer]])
end

---@param stage string
---@param code? integer
---@return never
local function failure(stage, code)
  error({
    sandbox_runtime_error = true,
    stage = stage,
    errno = (tonumber(code or last_error()) --[[@as integer]]),
  }, 0)
end

---@param value unknown
---@param fallback? string
---@return Neoagent.WindowsRuntimeError
local function error_value(value, fallback)
  if type(value) == "table" and value.sandbox_runtime_error then
    return value
  end
  return {
    stage = fallback or "runtime",
    errno = 0,
  }
end

---@param value string
---@return Neoagent.FfiArray<integer>
local function wide(value)
  value = tostring(value)
  if value:find("\0", 1, true) then failure("utf16", 0) end
  local length = K.MultiByteToWideChar(65001, 0x8, value, #value, nil, 0)
  if length <= 0 and #value > 0 then failure("utf16") end
  local buffer = (ffi.new("WCHAR[?]", length + 1) --[[@as Neoagent.FfiArray<integer>]])
  if length > 0
      and K.MultiByteToWideChar(65001, 0x8, value, #value, buffer, length) ~= length then
    failure("utf16")
  end
  buffer[length] = 0
  return buffer
end

-- Native environment comparison is case-insensitive Unicode ordering. Use
-- the same comparison for duplicate admission and the process environment.
---@param environment table<string, string>
---@return string[]
local function environment_names(environment)
  local names = vim.tbl_keys(environment)
  local encoded = {}
  for _, name in ipairs(names) do encoded[name] = wide(name) end
  local function compare(left, right)
    local order = K.CompareStringOrdinal(encoded[left], -1, encoded[right], -1, 1)
    if order == 0 then failure("environment-order") end
    return order
  end
  table.sort(names, function(left, right) return compare(left, right) == 1 end)
  for index = 2, #names do
    if compare(names[index - 1], names[index]) == 2 then
      failure("specification-environment", 0)
    end
  end
  return names
end

---@param pointer? ffi.cdata*
---@param length? integer
---@return string?
local function utf8(pointer, length)
  ---@cast pointer Neoagent.FfiArray<integer>?
  if pointer == nil then return nil end
  if length == nil then
    length = 0
    while pointer[length] ~= 0 do length = length + 1 end
  end
  local size = K.WideCharToMultiByte(
    65001, 0, pointer, length, nil, 0, nil, nil)
  if size <= 0 and length > 0 then failure("utf8") end
  local buffer = (ffi.new("char[?]", math.max(size, 1)) --[[@as Neoagent.FfiArray<integer>]])
  if size > 0
      and K.WideCharToMultiByte(
        65001, 0, pointer, length, buffer, size, nil, nil) ~= size then
    failure("utf8")
  end
  return ffi.string(buffer, size)
end

---@param bytes integer
---@return string
local function random_hex(bytes)
  local value = vim.uv.random(bytes)
  if type(value) ~= "string" or #value ~= bytes then failure("random", 0) end
  return (value:gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

-- Runtime protocol -----------------------------------------------------------
--
-- Frames use a four-byte big-endian length followed by a MessagePack map. The
-- host publishes ready/output events and acknowledges cleanup at completion.
---@param handle ffi.cdata*
---@param data string
---@return true?, integer?
local function write_all(handle, data)
  local offset = 0
  local written = (ffi.new("DWORD[1]") --[[@as Neoagent.FfiArray<integer>]])
  while offset < #data do
    local size = math.min(#data - offset, 65536)
    if K.WriteFile(handle, data:sub(offset + 1, offset + size),
        size, written, nil) == 0 then
      return nil, last_error()
    end
    local count = written[0]
    if count <= 0 then return nil, WIN32.ERROR.BROKEN_PIPE end
    offset = offset + count
  end
  return true
end

---@param handle ffi.cdata*
---@param size integer
---@return string?, integer?
local function read_some(handle, size)
  local buffer = (ffi.new("BYTE[?]", size) --[[@as Neoagent.FfiArray<integer>]])
  local count = (ffi.new("DWORD[1]") --[[@as Neoagent.FfiArray<integer>]])
  if K.ReadFile(handle, buffer, size, count, nil) == 0 then
    return nil, last_error()
  end
  return ffi.string(buffer, count[0])
end

---@param handle ffi.cdata*
---@param size integer
---@return string?, integer?
local function read_exact(handle, size)
  local chunks, received = {}, 0
  while received < size do
    local chunk, err = read_some(handle, math.min(size - received, 65536))
    if not chunk then return nil, err end
    if chunk == "" then return nil, WIN32.ERROR.BROKEN_PIPE end
    chunks[#chunks + 1] = chunk
    received = received + #chunk
  end
  return table.concat(chunks)
end

---@param value integer
---@return string
local function u32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256)
end

---@param value Neoagent.WindowsWireOutput
---@return string
local function frame_data(value)
  local payload = vim.mpack.encode(value)
  if #payload <= 0 or #payload > RUNTIME.MAX_FRAME then failure("protocol-size", 0) end
  return u32(#payload) .. payload
end

---@param handle ffi.cdata*
---@param value Neoagent.WindowsWireOutput
---@return true?, integer?
local function write_frame(handle, value)
  return write_all(handle, frame_data(value))
end

---@param value Neoagent.WindowsWireOutput
local function stdout_frame(value)
  local handle = K.GetStdHandle(WIN32.HANDLE.STD_OUTPUT)
  if invalid_handle(handle) or not write_frame(handle, value) then
    exit(125)
  end
end

---@param handle? ffi.cdata*
---@param value unknown
---@param cleanup? Neoagent.SandboxCleanupObservation
local function emit_error(handle, value, cleanup)
  value = error_value(value)
  local event = {
    v = 1,
    type = "error",
    stage = value.stage,
    errno = value.errno,
    cleanup = cleanup,
  }
  if handle then
    write_frame(handle, event)
  else
    stdout_frame(event --[[@as Neoagent.SandboxProtocolEvent]])
  end
end

-- Windows security identities and ACLs --------------------------------------
--
-- A SID is Windows' stable identity value for a user or capability. ACL
-- entries grant or deny permissions to SIDs. These helpers convert SID forms,
-- inspect tokens, and apply narrowly scoped entries to filesystem objects.
---@param sid ffi.cdata*
---@return string
local function sid_string(sid)
  local pointer = (ffi.new("WCHAR *[1]") --[[@as Neoagent.FfiArray<Neoagent.FfiArray<integer>>]])
  if A.ConvertSidToStringSidW(sid, pointer) == 0 then
    failure("sid-string")
  end
  local result = assert(utf8(pointer[0]))
  K.LocalFree(pointer[0])
  return result
end

---@param value string
---@return ffi.cdata*
local function sid_from_string(value)
  local pointer = (ffi.new("SID *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local encoded = wide(value)
  if A.ConvertStringSidToSidW(encoded, pointer) == 0 then
    failure("sid-parse")
  end
  return pointer[0]
end

---@return ffi.cdata*
local function current_token()
  local desired = bit.bor(
    WIN32.TOKEN.ASSIGN_PRIMARY,
    WIN32.TOKEN.DUPLICATE,
    WIN32.TOKEN.QUERY,
    WIN32.TOKEN.ADJUST_PRIVILEGES,
    WIN32.TOKEN.ADJUST_DEFAULT,
    WIN32.TOKEN.ADJUST_SESSION_ID)
  local token = (ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  if A.OpenProcessToken(K.GetCurrentProcess(), desired, token) == 0 then
    failure("open-token")
  end
  return token[0]
end

---@param token ffi.cdata*
---@param class integer
---@return ffi.cdata*, integer
local function token_information(token, class)
  local needed = (ffi.new("DWORD[1]") --[[@as Neoagent.FfiArray<integer>]])
  A.GetTokenInformation(token, class, nil, 0, needed)
  if needed[0] == 0 then failure("token-information") end
  local buffer = (ffi.new("BYTE[?]", needed[0]) --[[@as Neoagent.FfiArray<integer>]])
  if A.GetTokenInformation(
      token, class, buffer, needed[0], needed) == 0 then
    failure("token-information")
  end
  return buffer, needed[0]
end

---@param token ffi.cdata*
---@return ffi.cdata*, ffi.cdata*
local function token_user_sid(token)
  local buffer = token_information(token, WIN32.TOKEN.USER_CLASS)
  return (ffi.cast("TOKEN_USER *", buffer) --[[@as Neoagent.Win32.TOKEN_USER]]).User.Sid --[[@as ffi.cdata*]], buffer
end

---@param token ffi.cdata*
---@return ffi.cdata*, ffi.cdata*
local function token_logon_sid(token)
  local buffer = token_information(token, WIN32.TOKEN.GROUPS_CLASS)
  local groups = (ffi.cast("TOKEN_GROUPS *", buffer) --[[@as Neoagent.Win32.TOKEN_GROUPS]])
  local entries = (ffi.cast("SID_AND_ATTRIBUTES *",
    ffi.cast("BYTE *", buffer) + ffi.offsetof("TOKEN_GROUPS", "Groups")) --[[@as Neoagent.FfiArray<Neoagent.Win32.SID_AND_ATTRIBUTES>]])
  local selected
  for index = 0, groups.GroupCount - 1 do
    if bit.band(entries[index].Attributes, WIN32.SECURITY.GROUP_LOGON_ID)
        == WIN32.SECURITY.GROUP_LOGON_ID then
      selected = entries[index].Sid
      break
    end
  end
  if not selected then failure("token-logon-sid") end
  return selected, buffer
end

---@return string
local function current_user_sid_string()
  local token = current_token()
  local sid, storage = token_user_sid(token)
  local result = sid_string(sid)
  storage = storage
  close_handle(token)
  return result
end

---@param name string
---@return string?, integer?
local function account_sid(name)
  local encoded = wide(name)
  local sid_size = (ffi.new("DWORD[1]") --[[@as Neoagent.FfiArray<integer>]])
  local domain_size = (ffi.new("DWORD[1]") --[[@as Neoagent.FfiArray<integer>]])
  local use = (ffi.new("LONG[1]") --[[@as Neoagent.FfiArray<integer>]])
  A.LookupAccountNameW(
    nil, encoded, nil, sid_size, nil, domain_size, use)
  if sid_size[0] == 0 then return nil, last_error() end
  local sid = (ffi.new("BYTE[?]", sid_size[0]) --[[@as Neoagent.FfiArray<integer>]])
  local domain = (ffi.new("WCHAR[?]", math.max(domain_size[0], 1)) --[[@as Neoagent.FfiArray<integer>]])
  if A.LookupAccountNameW(nil, encoded, ffi.cast("SID *", sid), sid_size,
      domain, domain_size, use) == 0 then
    return nil, last_error()
  end
  return sid_string(ffi.cast("SID *", sid))
end

---@param sddl string
---@return ffi.cdata*
local function security_descriptor(sddl)
  local result = (ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local encoded = wide(sddl)
  if A.ConvertStringSecurityDescriptorToSecurityDescriptorW(
      encoded, 1, result, nil) == 0 then
    failure("security-descriptor")
  end
  return result[0]
end

---@param path string
---@param owner_sid string
local function protect_path(path, owner_sid)
  local descriptor = security_descriptor(string.format(
    "D:P(A;OICI;FA;;;%s)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", owner_sid))
  local encoded = wide(path)
  local ok = A.SetFileSecurityW(encoded,
    bit.bor(WIN32.SECURITY.DACL_INFORMATION, WIN32.SECURITY.PROTECTED_DACL_INFORMATION),
    descriptor)
  K.LocalFree(descriptor)
  if ok == 0 then failure("protect-state") end
end

---@param sid ffi.cdata*
---@param permissions integer
---@param mode integer
---@param inheritance integer
---@return Neoagent.Win32.EXPLICIT_ACCESS_W
local function explicit_access(sid, permissions, mode, inheritance)
  local value = (ffi.new("EXPLICIT_ACCESS_W") --[[@as Neoagent.Win32.EXPLICIT_ACCESS_W]])
  value.grfAccessPermissions = permissions
  value.grfAccessMode = mode
  value.grfInheritance = inheritance or 0
  value.Trustee.pMultipleTrustee = nil
  value.Trustee.MultipleTrusteeOperation = 0
  value.Trustee.TrusteeForm = WIN32.SECURITY.TRUSTEE_SID
  value.Trustee.TrusteeType = WIN32.SECURITY.TRUSTEE_UNKNOWN
  value.Trustee.ptstrName = (ffi.cast("WCHAR *", sid) --[[@as Neoagent.FfiArray<integer>]])
  return value
end

---@param path string
---@param entries Neoagent.Win32.EXPLICIT_ACCESS_W[]
local function update_acl(path, entries)
  local encoded = wide(path)
  local old_acl = (ffi.new("ACL *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local descriptor = (ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local code = A.GetNamedSecurityInfoW(encoded, WIN32.SECURITY.FILE_OBJECT,
    WIN32.SECURITY.DACL_INFORMATION, nil, nil, old_acl, nil, descriptor)
  if code ~= WIN32.ERROR.SUCCESS then failure("acl-read", code) end
  local array = (ffi.new("EXPLICIT_ACCESS_W[?]", #entries) --[[@as Neoagent.FfiArray<Neoagent.Win32.EXPLICIT_ACCESS_W>]])
  for index, entry in ipairs(entries) do
    array[index - 1] = entry
  end
  local new_acl = (ffi.new("ACL *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  code = A.SetEntriesInAclW(#entries, array, old_acl[0], new_acl)
  if code ~= WIN32.ERROR.SUCCESS then
    if descriptor[0] ~= nil then K.LocalFree(descriptor[0]) end
    failure("acl-build", code)
  end
  code = A.SetNamedSecurityInfoW(encoded, WIN32.SECURITY.FILE_OBJECT,
    WIN32.SECURITY.DACL_INFORMATION, nil, nil, new_acl[0], nil)
  if new_acl[0] ~= nil then K.LocalFree(new_acl[0]) end
  if descriptor[0] ~= nil then K.LocalFree(descriptor[0]) end
  if code ~= WIN32.ERROR.SUCCESS then failure("acl-write", code) end
end

---@param path string
---@param sids ffi.cdata*[]
---@param permissions integer
---@param inherited? boolean
local function allow_path(path, sids, permissions, inherited)
  local entries = {}
  local inheritance = inherited
      and bit.bor(
        WIN32.SECURITY.CONTAINER_INHERIT_ACE,
        WIN32.SECURITY.OBJECT_INHERIT_ACE)
      or 0
  for _, sid in ipairs(sids) do
    entries[#entries + 1] =
      explicit_access(sid, permissions, WIN32.SECURITY.SET_ACCESS, inheritance)
  end
  update_acl(path, entries)
end

---@param path string
---@param sid ffi.cdata*
---@param permissions integer
local function deny_path(path, sid, permissions)
  update_acl(path, {
    explicit_access(sid, permissions, WIN32.SECURITY.DENY_ACCESS,
      bit.bor(WIN32.SECURITY.CONTAINER_INHERIT_ACE, WIN32.SECURITY.OBJECT_INHERIT_ACE)),
  })
end

---@param path string
---@param sid ffi.cdata*
local function revoke_path(path, sid)
  local stat = vim.uv.fs_lstat(path)
  if not stat then return end
  update_acl(path, {
    explicit_access(sid, 0, WIN32.SECURITY.REVOKE_ACCESS,
      bit.bor(WIN32.SECURITY.CONTAINER_INHERIT_ACE, WIN32.SECURITY.OBJECT_INHERIT_ACE)),
  })
end

local accounts = dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_accounts.lua")).new({
  wide = wide,
  utf8 = utf8,
  sid = sid_from_string,
  lookup = account_sid,
  access = explicit_access,
  failure = failure,
})
local namespace = dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_namespace.lua")).new({
  wide = wide,
  sid = sid_from_string,
  access = explicit_access,
  failure = failure,
})
authority.coordinator = dofile(vim.fs.joinpath(checkout, "scripts", "sandbox_windows_coordinator.lua"))
authority.registration = authority.coordinator.new({ wide = wide, utf8 = utf8, failure = failure })

-- Persistent setup state -----------------------------------------------------
--
-- Setup keeps one trusted launch account whose random password is protected
-- with DPAPI. Target accounts belong to individual journaled invocations;
-- persistent WFP rules select the offline group they join before logon.
---@param value string
---@param decrypt boolean
---@return string
local function dpapi(value, decrypt)
  local source = (ffi.new("BYTE[?]", math.max(#value, 1)) --[[@as Neoagent.FfiArray<integer>]])
  if #value > 0 then ffi.copy(source, value, #value) end
  local input = (ffi.new("DATA_BLOB") --[[@as Neoagent.Win32.DATA_BLOB]])
  input.cbData = #value
  input.pbData = source
  local entropy_value = "neoagent-windows-sandbox-state-v1"
  local entropy_bytes = (ffi.new("BYTE[?]", #entropy_value) --[[@as Neoagent.FfiArray<integer>]])
  ffi.copy(entropy_bytes, entropy_value, #entropy_value)
  local entropy = (ffi.new("DATA_BLOB") --[[@as Neoagent.Win32.DATA_BLOB]])
  entropy.cbData = #entropy_value
  entropy.pbData = entropy_bytes
  local output = (ffi.new("DATA_BLOB") --[[@as Neoagent.Win32.DATA_BLOB]])
  local description = (ffi.new("WCHAR *[1]") --[[@as Neoagent.FfiArray<Neoagent.FfiArray<integer>>]])
  local ok
  if decrypt then
    ok = C.CryptUnprotectData(
      input, description, entropy, nil, nil,
      WIN32.CRYPT.UI_FORBIDDEN, output)
  else
    ok = C.CryptProtectData(
      input, nil, entropy, nil, nil,
      WIN32.CRYPT.UI_FORBIDDEN, output)
  end
  if description[0] ~= nil then K.LocalFree(description[0]) end
  if ok == 0 then failure(decrypt and "state-decrypt" or "state-encrypt") end
  local result = ffi.string(output.pbData, output.cbData)
  if output.pbData ~= nil then K.LocalFree(output.pbData) end
  return result
end

-- Retry only storage operations, while the surrounding transaction retains
-- its mutex, lease, and native evidence. Parsing and identity validation stay
-- outside this boundary; neither authority effects nor invalid data retry.
---@generic T
---@param deadline? number
---@param operation fun(): T
---@return T
local function journal_io(deadline, operation)
  while true do
    local ok, value = pcall(operation)
    if ok then return value end
    local stage = type(value) == "table" and value.sandbox_runtime_error and value.stage or nil
    if stage ~= "state-read" and stage ~= "state-open" and stage ~= "state-write"
        and stage ~= "state-close" and stage ~= "state-replace" then
      error(value, 0)
    end
    local remaining = deadline and math.floor((deadline - vim.uv.hrtime()) / 1000000) or 0
    if remaining <= 0 then error(value, 0) end
    K.Sleep(math.min(remaining, 100))
  end
end

---@param deadline number
local function check_admission(deadline)
  if vim.uv.hrtime() >= deadline then failure("admission-timeout", WIN32.WAIT.TIMEOUT) end
end

---@param path string
---@return string?
local function read_file_once(path)
  local fd, _, code = vim.uv.fs_open(path, "r", 0)
  if not fd then
    if code == "ENOENT" then return nil end
    failure("state-read", 0)
  end
  local stat = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    failure("state-read", 0)
  end
  if stat.type ~= "file" then
    vim.uv.fs_close(fd)
    failure("state-format", 0)
  end
  local data = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not data then failure("state-read", 0) end
  return data
end

---@param path string
---@param deadline? number
---@return string?
local function read_file(path, deadline)
  return journal_io(deadline, function() return read_file_once(path) end)
end

---@param path string
---@param data string
local function atomic_write(path, data)
  local temporary = path .. "." .. random_hex(8) .. ".tmp"
  local fd, open_err = vim.uv.fs_open(temporary, "wx", 384)
  if not fd then failure("state-open", open_err and 0 or nil) end
  local offset = 0
  while offset < #data do
    local count = vim.uv.fs_write(fd, data:sub(offset + 1), offset)
    if not count then
      vim.uv.fs_close(fd)
      vim.uv.fs_unlink(temporary)
      failure("state-write", 0)
    end
    offset = offset + count
  end
  local closed = vim.uv.fs_close(fd)
  if not closed then
    vim.uv.fs_unlink(temporary)
    failure("state-close", 0)
  end
  local from, to = wide(temporary), wide(path)
  if K.MoveFileExW(from, to,
      bit.bor(
        WIN32.FILE.MOVE_REPLACE_EXISTING,
        WIN32.FILE.MOVE_WRITE_THROUGH)) == 0 then
    local err = last_error()
    vim.uv.fs_unlink(temporary)
    failure("state-replace", err)
  end
end

---@param directory string
---@return string
local function state_path(directory)
  return vim.fs.joinpath(directory, "state.json")
end

---@param directory string
---@param deadline? number
---@return Neoagent.WindowsRuntimeState
local function decode_state(directory, deadline)
  local data = read_file(state_path(directory), deadline)
  if type(data) ~= "string" then failure("state-missing", WIN32.ERROR.FILE_NOT_FOUND) end
  local ok, state = pcall(vim.json.decode, data)
  if not ok or type(state) ~= "table" or state.v ~= RUNTIME.STATE_VERSION
      or type(state.owner_sid) ~= "string" or type(state.provisioned) ~= "boolean" then
    failure("state-format", 0)
  end
  if type(state.coordinator) ~= "string" or #state.coordinator ~= 32 or not state.coordinator:match("^%x+$") then
    failure("state-coordinator", 0)
  end
  for _, name in ipairs({ "launcher", "offline_group" }) do
    local principal = state[name]
    if type(principal) ~= "table" or type(principal.name) ~= "string"
        or #principal.name ~= 19 or not principal.name:match(name == "launcher" and "^neoagent_run_%x+$" or "^neoagent_net_%x+$")
        or type(principal.marker) ~= "string" or #principal.marker ~= 32 or not principal.marker:match("^%x+$")
        or principal.sid ~= nil and type(principal.sid) ~= "string"
        or state.provisioned and principal.sid == nil then
      failure("state-format", 0)
    end
  end
  if type(state.launcher.password) ~= "string" or type(state.wfp) ~= "table"
      or type(state.wfp.filters) ~= "table" or not vim.islist(state.wfp.filters) or #state.wfp.filters ~= 4 then
    failure("state-format", 0)
  end
  for _, key in ipairs(state.wfp.filters) do
    if type(key) ~= "string" or not key:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
      failure("state-format", 0)
    end
  end
  if type(state.leases) ~= "table" or type(state.placeholders) ~= "table"
      or not state.provisioned and (next(state.leases) ~= nil or next(state.placeholders) ~= nil) then
    failure("state-format", 0)
  end
  for id, lease in pairs(state.leases) do
    if type(id) ~= "string" or not id:match("^%x+$") or #id ~= 32
        or type(lease) ~= "table"
        or lease.job ~= "unstarted" and lease.job ~= "unconfirmed" and lease.job ~= "empty"
        or lease.logon_sid ~= nil and type(lease.logon_sid) ~= "string"
        or lease.launch_sid ~= nil and type(lease.launch_sid) ~= "string"
        or type(lease.paths) ~= "table" or not vim.islist(lease.paths)
        or type(lease.account) ~= "table" or type(lease.account.name) ~= "string"
        or not lease.account.name:match("^na_%x+$") or #lease.account.name ~= 19
        or lease.account.sid ~= nil and type(lease.account.sid) ~= "string"
        or lease.account.absent ~= nil and type(lease.account.absent) ~= "boolean" then
      failure("state-format", 0)
    end
    for _, path in ipairs(lease.paths) do
      if type(path) ~= "string" or path == "" then failure("state-format", 0) end
    end
    if type(lease.policy) ~= "table" then failure("state-format", 0) end
    for _, name in ipairs({ "write_roots", "deny_write" }) do
      local paths = lease.policy[name]
      if type(paths) ~= "table" or not vim.islist(paths) then failure("state-format", 0) end
      for _, path in ipairs(paths) do
        if type(path) ~= "string" or path == "" then failure("state-format", 0) end
      end
    end
    if lease.namespaces ~= nil then
      if type(lease.namespaces) ~= "table" or not vim.islist(lease.namespaces) then failure("state-format", 0) end
      for _, path in ipairs(lease.namespaces) do
        if type(path) ~= "string" or path ~= "\\BaseNamedObjects"
            and not path:match("^\\Sessions\\BNOLINKS\\%d+$") then failure("state-format", 0) end
      end
    end
  end
  return state
end

---@param directory string
---@param state Neoagent.WindowsRuntimeState
---@param deadline? number Absolute monotonic deadline for a journal transaction.
local function encode_state(directory, state, deadline)
  local path, data = state_path(directory), vim.json.encode(state)
  journal_io(deadline, function() atomic_write(path, data) end)
end

---@param account Neoagent.WindowsRuntimeAccount
---@return string
local function account_password(account)
  local ok, encrypted = pcall(vim.base64.decode, account.password)
  if not ok or type(encrypted) ~= "string" then failure("state-password", 0) end
  return dpapi(encrypted, true)
end

---@return string
local function password_value()
  return "Aa1!" .. random_hex(24)
end

---@param prefix string
---@return string
local function account_name(prefix)
  local selected
  for _ = 1, 32 do
    local name = prefix .. random_hex(3)
    if not account_sid(name) then
      selected = name
      break
    end
  end
  if not selected then failure("account-name", WIN32.ERROR.ALREADY_EXISTS) end
  return selected
end

---@param account Neoagent.WindowsRuntimeAccount
---@return string
local function allocate_launcher(account)
  local buffer = (ffi.new("BYTE *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local encoded_name = wide(account.name)
  local code = N.NetUserGetInfo(nil, encoded_name, 1, buffer)
  if code == WIN32.ERROR.SUCCESS then
    local info = (ffi.cast("USER_INFO_1 *", buffer[0]) --[[@as Neoagent.FfiArray<Neoagent.Win32.USER_INFO_1>]])
    local ok, comment = pcall(utf8, info[0].usri1_comment)
    N.NetApiBufferFree(buffer[0])
    if not ok then error(comment, 0) end
    local sid = account_sid(account.name)
    if not sid or comment ~= account.marker or account.sid and account.sid ~= sid then
      failure("account-identity", WIN32.ERROR.ACCESS_DENIED)
    end
    return sid
  elseif code ~= 2221 then -- NERR_UserNotFound.
    failure("account-read", code)
  end
  if account.sid then failure("account-identity", WIN32.ERROR.ACCESS_DENIED) end
  local encoded_password, comment = wide(account_password(account)), wide(account.marker)
  local info = (ffi.new("USER_INFO_1") --[[@as Neoagent.Win32.USER_INFO_1]])
  info.usri1_name = encoded_name
  info.usri1_password = encoded_password
  info.usri1_priv = WIN32.ACCOUNT.PRIVILEGE_USER
  info.usri1_comment = comment
  info.usri1_flags = bit.bor(
    WIN32.ACCOUNT.SCRIPT, WIN32.ACCOUNT.PASSWORD_CANNOT_CHANGE,
    WIN32.ACCOUNT.NORMAL, WIN32.ACCOUNT.PASSWORD_NEVER_EXPIRES)
  local parameter = (ffi.new("DWORD[1]") --[[@as Neoagent.FfiArray<integer>]])
  code = N.NetUserAdd(nil, 1, (ffi.cast("BYTE *", info) --[[@as Neoagent.FfiArray<integer>]]), parameter)
  if code ~= WIN32.ERROR.SUCCESS then failure("account-create", code) end
  local sid, sid_err = account_sid(account.name)
  if not sid then failure("account-sid", sid_err) end
  return sid
end

-- Only the trusted host uses this unrestricted logon token, during one
-- CreateProcessAsUser call. Targets receive a token with privileges removed.
---@param account string
local function provision_launch_rights(account)
  local attributes = (ffi.new("LSA_OBJECT_ATTRIBUTES") --[[@as Neoagent.WindowsLsaAttributes]])
  attributes.Length = sizeof(attributes)
  local policy = (ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local status = A.LsaOpenPolicy(nil, attributes, 0x810, policy) -- LOOKUP_NAMES | CREATE_ACCOUNT
  if status ~= 0 then failure("setup-launch-policy", A.LsaNtStatusToWinError(status)) end
  local sid = sid_from_string(account)
  local rights = (ffi.new("LSA_UNICODE_STRING[2]") --[[@as Neoagent.FfiArray<Neoagent.WindowsLsaString>]])
  local names = { wide("SeAssignPrimaryTokenPrivilege"), wide("SeIncreaseQuotaPrivilege") }
  for index, name in ipairs(names) do
    rights[index - 1].Buffer = name
    rights[index - 1].Length = sizeof(name) - 2
    rights[index - 1].MaximumLength = sizeof(name)
  end
  status = A.LsaAddAccountRights(policy[0], sid, rights, 2)
  K.LocalFree(sid)
  A.LsaClose(policy[0])
  if status ~= 0 then failure("setup-launch-rights", A.LsaNtStatusToWinError(status)) end
end

---@param value string
---@return Neoagent.Win32.GUID
local function guid(value)
  local a, b, c, d, e = value:match(
    "^([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-"
      .. "([0-9a-fA-F]+)%-([0-9a-fA-F]+)$")
  if not a or #a ~= 8 or #b ~= 4 or #c ~= 4 or #d ~= 4 or #e ~= 12 then
    failure("guid", 0)
  end
  local result = (ffi.new("GUID") --[[@as Neoagent.Win32.GUID]])
  result.Data1 = (tonumber(a, 16) --[[@as integer]])
  result.Data2 = (tonumber(assert(b), 16) --[[@as integer]])
  result.Data3 = (tonumber(assert(c), 16) --[[@as integer]])
  local tail = d .. e
  for index = 0, 7 do
    result.Data4[index] = (tonumber(tail:sub(index * 2 + 1, index * 2 + 2), 16) --[[@as integer]])
  end
  return result
end

-- Windows Filtering Platform rules attach network policy to the offline
-- account SID. Outbound connect and local bind layers cover IPv4 and IPv6, so
-- every process running as that account receives the same kernel policy.
local WFP = {
  PROVIDER = guid("51b8691c-e229-49b4-b796-91b3989dcf11"),
  SUBLAYER = guid("b00928a8-a6ac-4988-a737-7f06e9ece8c1"),
  USER = guid("af043a0a-b34d-4f86-979c-c90371af6e66"),
  FILTERS = {
    {
      layer = guid("c38d57d1-05a7-4c33-904f-7fbceee60e82"),
      name = "Neoagent offline outbound IPv4",
    },
    {
      layer = guid("4a72393b-319f-44bc-84c3-ba54dcb3b6b4"),
      name = "Neoagent offline outbound IPv6",
    },
    {
      layer = guid("1247d66d-0b60-4a15-8d44-7155d0f53a0c"),
      name = "Neoagent offline bind IPv4",
    },
    {
      layer = guid("55a650e1-5f0a-4eca-a653-88f53b26aa8c"),
      name = "Neoagent offline bind IPv6",
    },
  },
}

---@return string
function random_guid()
  local random = vim.uv.random(16)
  if type(random) ~= "string" or #random ~= 16 then failure("random", 0) end
  ---@type integer[]
  local bytes = { random:byte(1, 16) }
  if #bytes ~= 16 then failure("random", 0) end
  bytes[7] = bit.bor(bit.band(bytes[7], 0x0f), 0x40)
  bytes[9] = bit.bor(bit.band(bytes[9], 0x3f), 0x80)
  local hex = {}
  for index, byte in ipairs(bytes) do
    hex[index] = string.format("%02x", byte)
  end
  return table.concat(hex, "", 1, 4)
    .. "-" .. table.concat(hex, "", 5, 6)
    .. "-" .. table.concat(hex, "", 7, 8)
    .. "-" .. table.concat(hex, "", 9, 10)
    .. "-" .. table.concat(hex, "", 11, 16)
end

---@param code integer
---@param stage string
---@param allowed? integer[]
local function wfp_ok(code, stage, allowed)
  code = code
  if code == WIN32.ERROR.SUCCESS then return end
  for _, value in ipairs(allowed or {}) do
    if code == value then return end
  end
  failure(stage, code)
end

---@param account_sid_string string
---@return ffi.cdata*, Neoagent.FfiArray<Neoagent.Win32.FWP_BYTE_BLOB>
local function wfp_user_condition(account_sid_string)
  local account = sid_from_string(account_sid_string)
  local access = (ffi.new("EXPLICIT_ACCESS_W[1]") --[[@as Neoagent.FfiArray<Neoagent.Win32.EXPLICIT_ACCESS_W>]])
  access[0] = explicit_access(
    account, WIN32.WFP.ACCESS_MATCH_FILTER, WIN32.SECURITY.GRANT_ACCESS, 0)
  local descriptor = (ffi.new("void *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local length = (ffi.new("ULONG[1]") --[[@as Neoagent.FfiArray<integer>]])
  local code = A.BuildSecurityDescriptorW(
    nil, nil, 1, access, 0, nil, nil, length, descriptor)
  K.LocalFree(account)
  if code ~= WIN32.ERROR.SUCCESS then failure("wfp-user", code) end
  local blob = (ffi.new("FWP_BYTE_BLOB[1]") --[[@as Neoagent.FfiArray<Neoagent.Win32.FWP_BYTE_BLOB>]])
  blob[0].size = length[0]
  blob[0].data = (ffi.cast("BYTE *", descriptor[0]) --[[@as Neoagent.FfiArray<integer>]])
  return descriptor[0], blob
end

---@param account_sid_string string
---@param filter_keys string[]
local function install_wfp(account_sid_string, filter_keys)
  local session_name = wide("Neoagent Windows sandbox")
  local session = (ffi.new("FWPM_SESSION0") --[[@as Neoagent.Win32.FWPM_SESSION0]])
  session.displayData.name = session_name
  session.txnWaitTimeoutInMSec = WIN32.WAIT.INFINITE
  local engine = (ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  wfp_ok(F.FwpmEngineOpen0(nil, 10, nil, session, engine), "wfp-open")

  local transaction = false
  local ok, err = pcall(function()
    wfp_ok(F.FwpmTransactionBegin0(engine[0], 0), "wfp-transaction")
    transaction = true

    local provider_name = wide("Neoagent Windows sandbox")
    local provider_description =
      wide("Persistent network policy for Neoagent sandbox accounts")
    local provider = (ffi.new("FWPM_PROVIDER0") --[[@as Neoagent.Win32.FWPM_PROVIDER0]])
    provider.providerKey = WFP.PROVIDER
    provider.displayData.name = provider_name
    provider.displayData.description = provider_description
    provider.flags = WIN32.WFP.PROVIDER_PERSISTENT
    wfp_ok(F.FwpmProviderAdd0(engine[0], provider, nil),
      "wfp-provider", { WIN32.WFP.ALREADY_EXISTS })

    local sublayer_name = wide("Neoagent Windows sandbox")
    local sublayer_description =
      wide("Persistent outbound isolation for Neoagent sandbox accounts")
    local provider_key = (ffi.new("GUID[1]", WFP.PROVIDER) --[[@as Neoagent.FfiArray<Neoagent.Win32.GUID>]])
    local sublayer = (ffi.new("FWPM_SUBLAYER0") --[[@as Neoagent.Win32.FWPM_SUBLAYER0]])
    sublayer.subLayerKey = WFP.SUBLAYER
    sublayer.displayData.name = sublayer_name
    sublayer.displayData.description = sublayer_description
    sublayer.flags = WIN32.WFP.SUBLAYER_PERSISTENT
    sublayer.providerKey = provider_key
    sublayer.weight = 0x8000
    wfp_ok(F.FwpmSubLayerAdd0(engine[0], sublayer, nil),
      "wfp-sublayer", { WIN32.WFP.ALREADY_EXISTS })

    local descriptor, user_blob =
      wfp_user_condition(account_sid_string)
    local condition = (ffi.new("FWPM_FILTER_CONDITION0[1]") --[[@as Neoagent.FfiArray<Neoagent.Win32.FWPM_FILTER_CONDITION0>]])
    condition[0].fieldKey = WFP.USER
    condition[0].matchType = WIN32.WFP.MATCH_EQUAL
    condition[0].conditionValue.type = WIN32.WFP.SECURITY_DESCRIPTOR_TYPE
    condition[0].conditionValue.value.sd = user_blob
    local sublayer_key = WFP.SUBLAYER
    for index, item in ipairs(WFP.FILTERS) do
      local filter_key = guid(assert(filter_keys[index]))
      wfp_ok(F.FwpmFilterDeleteByKey0(
        engine[0], (ffi.new("GUID[1]", filter_key) --[[@as Neoagent.FfiArray<Neoagent.Win32.GUID>]])),
        "wfp-filter-delete", { WIN32.WFP.FILTER_NOT_FOUND, WIN32.WFP.NOT_FOUND })
      local name = wide(item.name)
      local description =
        wide("Block all network traffic from offline sandbox accounts")
      local filter = (ffi.new("FWPM_FILTER0") --[[@as Neoagent.Win32.FWPM_FILTER0]])
      filter.filterKey = filter_key
      filter.displayData.name = name
      filter.displayData.description = description
      filter.flags = WIN32.WFP.FILTER_PERSISTENT
      filter.providerKey = provider_key
      filter.layerKey = item.layer
      filter.subLayerKey = sublayer_key
      filter.weight.type = WIN32.WFP.EMPTY
      filter.numFilterConditions = 1
      filter.filterCondition = condition
      filter.action.type = WIN32.WFP.ACTION_BLOCK
      local id = (ffi.new("UINT64[1]") --[[@as Neoagent.FfiArray<integer|ffi.cdata*>]])
      wfp_ok(F.FwpmFilterAdd0(engine[0], filter, nil, id),
        "wfp-filter-add")
    end
    K.LocalFree(descriptor)
    wfp_ok(F.FwpmTransactionCommit0(engine[0]), "wfp-commit")
    transaction = false
  end)
  if not ok and transaction then F.FwpmTransactionAbort0(engine[0]) end
  F.FwpmEngineClose0(engine[0])
  if not ok then error(err, 0) end
end

---@param path string
local function mkdir(path)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then return end
  local ok, err = vim.fn.mkdir(path, "p")
  if ok == 0 and not vim.uv.fs_stat(path) then
    failure("state-directory", (tonumber(err) --[[@as integer?]]) or 0)
  end
end

-- Setup owns persistent authority through the same journal that owns invocation
-- effects. Planned identities precede allocation; a native creation comment
-- identifies a principal after interruption before its SID could be saved.
---@param directory string
---@param deadline number
local function setup(directory, deadline)
  accounts.check_host()
  local registration = authority.location(directory, true)
  directory = registration.directory
  local owner_sid = current_user_sid_string()
  local existing = read_file(state_path(directory))
  if registration.initialized and not existing then failure("state-missing", WIN32.ERROR.FILE_NOT_FOUND) end

  ---@type Neoagent.WindowsRuntimeState
  local state
  if existing then
    state = decode_state(directory)
    if state.owner_sid ~= owner_sid then failure("state-owner", WIN32.ERROR.ACCESS_DENIED) end
    if state.coordinator ~= registration.id then failure("state-coordinator", WIN32.ERROR.ACCESS_DENIED) end
    authority.journal(directory, state, deadline):recover()
    if next(state.leases) then failure("setup-active-leases", WIN32.ERROR.ACCESS_DENIED) end
  else
    state = {
      v = RUNTIME.STATE_VERSION, owner_sid = owner_sid, coordinator = registration.id,
      provisioned = false, leases = {}, placeholders = {},
      launcher = {
        name = account_name("neoagent_run_"), marker = random_hex(16),
        password = vim.base64.encode(dpapi(password_value(), false)),
      },
      offline_group = { name = account_name("neoagent_net_"), marker = random_hex(16) },
      wfp = { filters = {} },
    }
    for index = 1, #WFP.FILTERS do state.wfp.filters[index] = random_guid() end
  end
  protect_path(directory, owner_sid)
  state.provisioned = false
  encode_state(directory, state)
  -- From this point the established inventory must never be treated as absent,
  -- even while provisioning is incomplete. No native allocation precedes it.
  if not registration.initialized then
    registration.initialized = true
    authority.registration.write(vim.json.encode(registration))
  end

  authority.registration.prepare_executions(owner_sid)
  state.launcher.sid = allocate_launcher(state.launcher)
  encode_state(directory, state)
  provision_launch_rights(state.launcher.sid)
  state.offline_group.sid = accounts.allocate_group(state.offline_group)
  encode_state(directory, state)
  accounts.delegate(owner_sid, state.launcher.sid, state.offline_group)
  install_wfp(state.offline_group.sid, state.wfp.filters)
  mkdir(vim.fs.joinpath(directory, "shared-tmp"))
  protect_path(directory, owner_sid)
  state.provisioned = true
  encode_state(directory, state)
  protect_path(state_path(directory), owner_sid)
  io.stdout:write(vim.json.encode({
    v = RUNTIME.PROTOCOL_VERSION, ok = true, platform = "windows", setup_version = RUNTIME.STATE_VERSION,
  }))
end

-- Request preparation --------------------------------------------------------
--
-- One machine-wide mutex serializes journal/ACL mutations, never execution.
-- Its registered inventory is independent of requested storage locations.
-- Per-lease mutexes remain owned by their native hosts. A nonblocking attempt
-- distinguishes a live owner from an abandoned lease without probing a PID.
-- Paths are normalized, resolved, and compared case-insensitively before any
-- access rule is changed. Existing paths must retain the identity selected by
-- validation.
---@param directory string
---@param suffix? string
---@return string
local function authority_name(directory, suffix)
  return "NeoagentSandbox-" .. vim.fn.sha256(
    tostring(directory):gsub("/", "\\"):lower()):sub(1, 32) .. (suffix or "")
end

-- One namespace remains owned for the entire host lifetime, including while
-- it releases the journal mutex but retains its lease guard. Every waiter
-- retains the same namespace across departure of its original creator.
---@type Neoagent.WindowsPrivateNamespace?
local coordination

---@param name string
---@param timeout_ms integer
---@param identity string
---@return ffi.cdata*?
local function acquire_named_mutex(name, timeout_ms, identity)
  local descriptor = security_descriptor("D:P(A;;GA;;;" .. identity .. ")(A;;GA;;;SY)")
  local attributes = (ffi.new("SECURITY_ATTRIBUTES") --[[@as Neoagent.Win32.SECURITY_ATTRIBUTES]])
  attributes.nLength, attributes.lpSecurityDescriptor = sizeof(attributes), descriptor
  local handle = K.CreateMutexW(attributes, 0, wide(name))
  local err = last_error()
  K.LocalFree(descriptor)
  if invalid_handle(handle) then failure("mutex-create", err) end
  local result = (tonumber(K.WaitForSingleObject(handle, timeout_ms)) --[[@as integer]])
  if result == WIN32.WAIT.TIMEOUT then
    close_handle(handle)
    return nil
  end
  if result ~= WIN32.WAIT.OBJECT_0 and result ~= WIN32.WAIT.ABANDONED then
    close_handle(handle)
    failure("mutex-wait", result)
  end
  return handle
end

---@param timeout_ms integer
---@return ffi.cdata*
local function acquire_mutex(timeout_ms)
  local deadline = vim.uv.hrtime() + timeout_ms * 1000000
  local identity = current_user_sid_string()
  coordination = coordination or kernel_objects.new(authority.coordinator.namespace, {
    identity = identity, wide = wide, failure = failure,
  })
  coordination:join(deadline)
  local remaining = math.max(0, math.ceil((deadline - vim.uv.hrtime()) / 1000000))
  local handle = acquire_named_mutex(coordination:path("journal"), remaining, identity)
  if not handle then failure("mutex-wait-timeout", WIN32.WAIT.TIMEOUT) end
  return handle
end

---@param id string
---@return ffi.cdata*?
local function acquire_lease(id)
  return acquire_named_mutex(assert(coordination):path("lease-" .. id), 0, current_user_sid_string())
end

---@param handle? ffi.cdata*
local function release_mutex(handle)
  if not invalid_handle(handle) then
    K.ReleaseMutex(handle)
    close_handle(handle)
  end
end

---@param path string
---@return string
local function path_key(path)
  return tostring(path):gsub("/", "\\"):gsub("\\+$", ""):lower()
end

---@param root string
---@param path string
---@return boolean
local function path_contains(root, path)
  root, path = path_key(root), path_key(path)
  return path == root or path:sub(1, #root + 1) == root .. "\\"
end

---@param left string
---@param right string
---@return boolean
local function path_overlap(left, right)
  return path_contains(left, right) or path_contains(right, left)
end

---@param path unknown
---@param stage? string
---@return string
function normalized_profile_path(path, stage)
  if type(path) ~= "string" or path == ""
      or path:find("\0", 1, true) then
    failure(stage or "path", 0)
  end
  local native = path:gsub("/", "\\")
  if native:sub(1, 4) == "\\\\.\\"
      or native:sub(1, 4) == "\\??\\"
      or native:sub(1, 4) == "\\\\?\\"
      or not native:match("^[A-Za-z]:\\")
        and not native:match("^\\\\[^\\]+\\[^\\]+") then
    failure(stage or "path", 0)
  end
  local ok, normalized = pcall(vim.fs.normalize, path)
  if not ok or type(normalized) ~= "string" then
    failure(stage or "path", 0)
  end
  return normalized
end

---@param path unknown
---@param stage? string
---@return string
local function canonical_existing(path, stage)
  local normalized = normalized_profile_path(path, stage)
  local resolved = vim.uv.fs_realpath(normalized)
  if type(resolved) ~= "string" then failure(stage or "path", 0) end
  resolved = vim.fs.normalize(resolved)
  if path_key(resolved) ~= path_key(normalized) then
    failure((stage or "path") .. "-changed", WIN32.ERROR.ACCESS_DENIED)
  end
  return resolved
end

---@param value unknown
---@return Neoagent.SandboxFilesystemEntry[], table<string, Neoagent.SandboxFilesystemEntry>
function copy_protected(value)
  if type(value) ~= "table" or not vim.islist(value) then
    failure("profile-protected-create", 0)
  end
  local result, by_path = {}, {}
  for _, item in ipairs(value) do
    if type(item) ~= "table"
        or item.access ~= "read" and item.access ~= "deny"
        or type(item.path) ~= "string" then
      failure("profile-protected-create", 0)
    end
    for key in pairs(item) do
      if key ~= "path" and key ~= "access" then
        failure("profile-protected-create", 0)
      end
    end
    local path = normalized_profile_path(
      item.path, "profile-protected-create")
    local key = path_key(path)
    if by_path[key] then failure("profile-protected-create", 0) end
    local resolved = vim.uv.fs_realpath(path)
    if resolved then
      path = canonical_existing(path, "profile-protected-create")
    else
      local parent = canonical_existing(
        vim.fs.dirname(path), "profile-protected-parent")
      local expected = vim.fs.joinpath(parent, vim.fs.basename(path))
      if path_key(expected) ~= key then
        failure("profile-protected-create-changed", WIN32.ERROR.ACCESS_DENIED)
      end
    end
    local entry = { path = path, access = item.access }
    result[#result + 1] = entry
    by_path[path_key(path)] = entry
  end
  return result, by_path
end

---@param value unknown
---@param stage string
---@param missing? table<string, Neoagent.SandboxFilesystemEntry>
---@return string[]
local function copy_list(value, stage, missing)
  if type(value) ~= "table" or not vim.islist(value) then
    failure(stage, 0)
  end
  local result = {}
  for _, item in ipairs(value) do
    local path = normalized_profile_path(item, stage)
    if vim.uv.fs_realpath(path) then
      path = canonical_existing(path, stage)
    elseif not missing or not missing[path_key(path)] then
      failure(stage, 0)
    end
    result[#result + 1] = path
  end
  return result
end

-- Validation turns the request into canonical paths and checks that runtime
-- files, target executables, temporary storage, and protected paths form a
-- coherent policy. The later ACL code can therefore operate on resolved
-- objects with a bounded, well-typed specification.
---@param spec unknown
---@param directory string
---@return Neoagent.WindowsRuntimeSpec
local function validate_spec(spec, directory)
  if type(spec) ~= "table" or spec.v ~= RUNTIME.PROTOCOL_VERSION then
    failure("specification-version", 0)
  end
  if spec.mode ~= "probe" and spec.mode ~= "exec" then
    failure("specification-mode", 0)
  end
  if spec.mode == "exec" and (type(spec.lease) ~= "string" or #spec.lease ~= 32 or not spec.lease:match("^%x+$")) then
    failure("specification-lease", 0)
  end
  if type(spec.admission_timeout_ms) ~= "number"
      or spec.admission_timeout_ms % 1 ~= 0
      or spec.admission_timeout_ms <= 0
      or spec.admission_timeout_ms > 0x7fffffff then
    failure("specification-admission-timeout", 0)
  end
  if type(spec.profile) ~= "table"
      or spec.profile.network ~= "restricted"
        and spec.profile.network ~= "enabled"
      or type(spec.profile.windows) ~= "table"
      or spec.profile.windows.version ~= 1 then
    failure("specification-profile", 0)
  end
  local filesystem = spec.profile.windows
  local protected_entries, protected =
    copy_protected(filesystem.protected_create)
  filesystem.protected_create = protected_entries
  filesystem.write_roots =
    copy_list(filesystem.write_roots, "profile-write-root")
  filesystem.deny_read =
    copy_list(filesystem.deny_read, "profile-deny-read", protected)
  filesystem.deny_write =
    copy_list(filesystem.deny_write, "profile-deny-write", protected)
  local deny_read, deny_write = {}, {}
  for _, path in ipairs(filesystem.deny_read) do
    deny_read[path_key(path)] = true
  end
  for _, path in ipairs(filesystem.deny_write) do
    deny_write[path_key(path)] = true
  end
  for key, entry in pairs(protected) do
    if not deny_write[key]
        or entry.access == "deny" and not deny_read[key] then
      failure("profile-protected-create", 0)
    end
  end
  local protected_state = canonical_existing(directory, "state-directory")
  local shared_root = canonical_existing(
    vim.fs.joinpath(directory, "shared-tmp"), "temporary-root")
  for _, root in ipairs(filesystem.write_roots) do
    if not path_contains(shared_root, root)
        and path_overlap(root, protected_state) then
      failure("profile-state-overlap", WIN32.ERROR.ACCESS_DENIED)
    end
  end
  spec.cwd = canonical_existing(spec.cwd, "specification-cwd")
  if type(spec.env) ~= "table"
      or vim.islist(spec.env) and next(spec.env) then
    failure("specification-environment", 0)
  end
  for name, value in pairs(spec.env) do
    if type(name) ~= "string"
        or not name:match("^[^=%z]+$")
        or type(value) ~= "string" or value:find("\0", 1, true) then
      failure("specification-environment", 0)
    end
  end
  environment_names(spec.env)
  spec.read_paths = copy_list(spec.read_paths, "bootstrap-read-path")
  if spec.mode == "exec" then
    if type(spec.argv) ~= "table" or not vim.islist(spec.argv)
        or #spec.argv == 0 then
      failure("command-argv", 0)
    end
    for index, value in ipairs(spec.argv) do
      if type(value) ~= "string" or value:find("\0", 1, true)
          or index == 1 and value == "" then
        failure("command-argv", index)
      end
    end
    spec.argv[1] = canonical_existing(spec.argv[1], "command-executable")
  elseif spec.argv ~= nil then
    if type(spec.argv) ~= "table" or next(spec.argv) ~= nil then
      failure("command-argv", 0)
    end
  end
  return spec
end

-- Per-request ACL lease and recovery ----------------------------------------
--
-- Private accounts separate ownership of child-created files and native
-- objects. Their logon SIDs receive the profile's grants and denials; a
-- trusted creation logon receives temporary loader access independently.

---@param values string[]
---@return string[]
local function unique_paths(values)
  local result, seen = {}, {}
  for _, value in ipairs(values) do
    local key = path_key(value)
    if not seen[key] then
      seen[key] = true
      result[#result + 1] = value
    end
  end
  table.sort(result, function(left, right)
    return path_key(left) < path_key(right)
  end)
  return result
end

-- Preserve the names leading to a protected object as well as its own DACL.
-- A writer may still edit siblings and create children; it cannot rename an
-- ancestor and recreate the denied pathname under the broader parent grant.
---@param filesystem Neoagent.WindowsSandboxPolicy
---@return string[]
local function protected_ancestors(filesystem)
  local paths, boundaries = {}, {}
  for _, path in ipairs(filesystem.deny_write) do boundaries[path_key(path)] = true end
  for _, path in ipairs(filesystem.deny_write) do
    for _, root in ipairs(filesystem.write_roots) do
      local parent = vim.fs.dirname(path)
      while parent and path_contains(root, parent) do
        if not boundaries[path_key(parent)] then paths[#paths + 1] = parent end
        if path_key(parent) == path_key(root) then break end
        parent = vim.fs.dirname(parent)
      end
    end
  end
  return unique_paths(paths)
end

---@param path string
---@return Neoagent.WindowsPathIdentity?, integer?
function path_identity(path)
  local handle = K.CreateFileW(wide(path), 0,
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_WRITE, WIN32.FILE.SHARE_DELETE),
    nil, WIN32.FILE.OPEN_EXISTING,
    bit.bor(WIN32.FILE.FLAG_BACKUP_SEMANTICS, WIN32.FILE.FLAG_OPEN_REPARSE_POINT), nil)
  if invalid_handle(handle) then return nil, last_error() end
  local information = (ffi.new("BY_HANDLE_FILE_INFORMATION") --[[@as Neoagent.Win32.BY_HANDLE_FILE_INFORMATION]])
  if K.GetFileInformationByHandle(handle, information) == 0 then
    local err = last_error()
    close_handle(handle)
    return nil, err
  end
  close_handle(handle)
  if bit.band(information.dwFileAttributes,
      WIN32.FILE.ATTRIBUTE_REPARSE_POINT) ~= 0 then
    return nil, WIN32.ERROR.ACCESS_DENIED
  end
  return {
    volume = information.dwVolumeSerialNumber,
    high = information.nFileIndexHigh,
    low = information.nFileIndexLow,
  }
end

---@param record Neoagent.WindowsPlaceholder|Neoagent.WindowsPathIdentity
---@param identity? Neoagent.WindowsPathIdentity
---@return boolean?
function same_identity(record, identity)
  return identity
    and type(record.volume) == "number"
    and type(record.high) == "number"
    and type(record.low) == "number"
    and record.volume == identity.volume
    and record.high == identity.high
    and record.low == identity.low
end

-- Elevated setup binds one host account and one physical directory to the
-- machine coordinator. Ordinary hosts cannot register another inventory, and
-- replacement of the registered directory cannot silently reset ownership.
---@param directory string
---@param register? boolean
---@return Neoagent.WindowsCoordinatorRegistration
function authority.location(directory, register)
  local encoded = authority.registration.read()
  local owner = current_user_sid_string()
  if encoded then
    local ok, record = pcall(vim.json.decode, encoded)
    if not ok or type(record) ~= "table" or record.v ~= 1
        or type(record.id) ~= "string" or #record.id ~= 32 or not record.id:match("^%x+$")
        or type(record.owner_sid) ~= "string" or type(record.directory) ~= "string"
        or type(record.initialized) ~= "boolean" then
      failure("coordinator-format", 0)
    end
    if record.owner_sid ~= owner then failure("coordinator-owner", WIN32.ERROR.ACCESS_DENIED) end
    local resolved = canonical_existing(directory, "coordinator-location")
    if path_key(resolved) ~= path_key(record.directory) then
      failure("coordinator-location", WIN32.ERROR.ACCESS_DENIED)
    end
    if not same_identity(record, path_identity(record.directory)) then
      failure("coordinator-identity", WIN32.ERROR.ACCESS_DENIED)
    end
    if not register and not record.initialized then failure("setup-incomplete", 0) end
    return record
  end
  if not register then failure("coordinator-missing", WIN32.ERROR.FILE_NOT_FOUND) end
  mkdir(directory)
  directory = canonical_existing(directory, "coordinator-location")
  local previous = read_file(state_path(directory))
  if previous then failure("coordinator-registration-missing", WIN32.ERROR.ACCESS_DENIED) end
  local identity, err = path_identity(directory)
  if not identity then failure("coordinator-identity", err) end
  protect_path(directory, owner)
  local record = {
    v = 1, id = random_hex(16), owner_sid = owner, directory = directory,
    initialized = false,
    volume = identity.volume, high = identity.high, low = identity.low,
  }
  authority.registration.write(vim.json.encode(record))
  return record
end

---@param record Neoagent.WindowsPlaceholder
---@return string?
function marker_path(record)
  if type(record.path) ~= "string"
      or type(record.marker) ~= "string"
      or not record.marker:match("^%.neoagent%-placeholder%-%x+$") then
    return nil
  end
  return vim.fs.joinpath(record.path, record.marker)
end

---@param record Neoagent.WindowsPlaceholder
function write_placeholder_marker(record)
  local path = marker_path(record)
  if not path or type(record.nonce) ~= "string" then
    failure("placeholder-record", 0)
  end
  local handle = K.CreateFileW(wide(path), WIN32.ACCESS.GENERIC_WRITE,
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_DELETE), nil,
    WIN32.FILE.CREATE_NEW, WIN32.FILE.ATTRIBUTE_NORMAL, nil)
  if invalid_handle(handle) then failure("placeholder-marker") end
  local ok, err = write_all(handle, record.nonce)
  if ok and K.FlushFileBuffers(handle) == 0 then
    ok, err = nil, last_error()
  end
  close_handle(handle)
  if not ok then
    K.DeleteFileW(wide(path))
    failure("placeholder-marker", err)
  end
end

---@param path string
---@return string?
function read_small_file(path)
  local handle = K.CreateFileW(wide(path), WIN32.ACCESS.GENERIC_READ,
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_WRITE, WIN32.FILE.SHARE_DELETE),
    nil, WIN32.FILE.OPEN_EXISTING, WIN32.FILE.ATTRIBUTE_NORMAL, nil)
  if invalid_handle(handle) then return nil end
  local length = (ffi.new("LONGLONG[1]") --[[@as Neoagent.FfiArray<integer|ffi.cdata*>]])
  if K.GetFileSizeEx(handle, length) == 0
      or (tonumber(length[0]) --[[@as integer]]) > 256 then
    close_handle(handle)
    return nil
  end
  local data = read_exact(handle, (tonumber(length[0]) --[[@as integer]]))
  close_handle(handle)
  return data
end

---@param record Neoagent.WindowsPlaceholder
function cleanup_placeholder(record)
  local path = type(record) == "table" and record.path or nil
  if type(path) ~= "string" then return end
  local identity = path_identity(path)
  if not same_identity(record, identity) then return end
  local marker = marker_path(record)
  if marker and read_small_file(marker) == record.nonce then
    K.DeleteFileW(wide(marker))
  elseif record.marker_ready then
    return
  end
  K.RemoveDirectoryW(wide(path))
end

---@param state Neoagent.WindowsRuntimeState
local function cleanup_placeholders(state)
  for index = #state.placeholders, 1, -1 do
    local record = state.placeholders[index]
    local referenced = false
    for _, lease in pairs(state.leases) do
      for _, path in ipairs(lease.paths) do
        if path_contains(record.path, path) then referenced = true end
      end
    end
    if not referenced then
      cleanup_placeholder(record)
      table.remove(state.placeholders, index)
    end
  end
end

---@param paths string[]
---@param identity string
local function revoke_paths(paths, identity)
  local sid = sid_from_string(identity)
  local first_error
  for _, path in ipairs(paths) do
    local ok, err = pcall(revoke_path, path, sid)
    if not ok and not first_error then first_error = err end
  end
  K.LocalFree(sid)
  if first_error then error(first_error, 0) end
end

---@param lease Neoagent.WindowsAuthorityLease
local function retire_authority(lease)
  if lease.logon_sid then revoke_paths(lease.paths, lease.logon_sid) end
  if lease.launch_sid then revoke_paths(lease.paths, lease.launch_sid) end
  for _, path in ipairs(lease.namespaces or {}) do
    namespace.change(path, assert(lease.account.sid), false)
  end
  accounts.retire(lease.account)
end

---@param directory string
---@param id string
---@return Neoagent.WindowsSandboxJob
local function new_job(directory, id)
  local objects = kernel_objects.new(authority_name(directory, "-job-" .. id), {
    identity = current_user_sid_string(), wide = wide, failure = failure,
  })
  return native_job.new(objects, { wide = wide, failure = failure })
end

---@param directory string
---@param state Neoagent.WindowsRuntimeState
---@param deadline number
---@return Neoagent.WindowsAuthorityJournal
function authority.journal(directory, state, deadline)
  return journal_owner.new(state, {
    save = function(value) encode_state(directory, value, deadline) end,
    retire = retire_authority,
    prune = cleanup_placeholders,
    acquire = function(id)
      check_admission(deadline)
      local guard = acquire_lease(id)
      if guard then return function() release_mutex(guard) end end
    end,
    new_job = function(id) return new_job(directory, id) end,
    mark_execution = authority.registration.mark_execution,
    execution_exists = authority.registration.execution_exists,
    clear_execution = authority.registration.clear_execution,
    failure = failure,
    path_key = path_key,
    contains = path_contains,
    overlap = path_overlap,
  })
end

---@param directory string
---@param state Neoagent.WindowsRuntimeState
---@param spec Neoagent.WindowsRuntimeSpec
---@param deadline number
function materialize_protected(directory, state, spec, deadline)
  local protected = spec.profile.windows.protected_create
  for _, entry in ipairs(protected) do
    check_admission(deadline)
    if not vim.uv.fs_realpath(entry.path) then
      local nonce = random_hex(24)
      local record = {
        path = entry.path,
        marker = ".neoagent-placeholder-" .. random_hex(12),
        nonce = nonce,
        marker_ready = false,
      }
      local placeholders = state.placeholders
      placeholders[#placeholders + 1] = record
      encode_state(directory, state)
      if K.CreateDirectoryW(wide(entry.path), nil) == 0 then
        local err = last_error()
        if err ~= WIN32.ERROR.ALREADY_EXISTS then
          failure("placeholder-create", err)
        end
        table.remove(placeholders)
        encode_state(directory, state)
      else
        local identity, identity_err = path_identity(entry.path)
        if not identity then failure("placeholder-identity", identity_err) end
        record.volume = identity.volume
        record.high = identity.high
        record.low = identity.low
        encode_state(directory, state)
        write_placeholder_marker(record)
        record.marker_ready = true
        encode_state(directory, state)
      end
    end
    entry.path =
      canonical_existing(entry.path, "profile-protected-create")
  end
  local filesystem = spec.profile.windows
  for _, name in ipairs({ "deny_read", "deny_write" }) do
    for index, path in ipairs(filesystem[name]) do
      filesystem[name][index] = canonical_existing(
        path, "profile-" .. name:gsub("_", "-"))
    end
  end
end

---@param paths string[]
---@param path string
---@return boolean
local function covered_by(paths, path)
  for _, root in ipairs(paths) do
    if path_contains(root, path) then return true end
  end
  return false
end

---@param spec Neoagent.WindowsRuntimeSpec
---@return string[]
local function authority_paths(spec)
  local filesystem = spec.profile.windows
  local paths = { spec.cwd }
  vim.list_extend(paths, filesystem.write_roots)
  vim.list_extend(paths, filesystem.deny_read)
  vim.list_extend(paths, filesystem.deny_write)
  vim.list_extend(paths, protected_ancestors(filesystem))
  vim.list_extend(paths, spec.read_paths)
  return unique_paths(paths)
end

-- Each fresh logon receives its profile before native process creation.
-- Its complete path set was journaled before creating placeholders. That set
-- also pins any existing placeholder on which this invocation's policy relies.
---@param spec Neoagent.WindowsRuntimeSpec
---@param lease Neoagent.WindowsAuthorityLease
---@param deadline number
local function apply_runtime_acls(spec, lease, deadline)
  check_admission(deadline)
  local filesystem = spec.profile.windows
  local read_paths = { spec.cwd }
  local required_paths = vim.deepcopy(read_paths)
  local read_roots = spec.read_paths
  if spec.argv and spec.argv[1] then
    required_paths[#required_paths + 1] = spec.argv[1]
  end
  for _, path in ipairs(required_paths) do
    if covered_by(filesystem.deny_read, path) then
      failure("required-path-denied", WIN32.ERROR.ACCESS_DENIED)
    end
  end
  for _, path in ipairs(read_roots) do
    if covered_by(filesystem.deny_read, path) then
      failure("required-path-denied", WIN32.ERROR.ACCESS_DENIED)
    end
  end
  local logon = sid_from_string(assert(lease.logon_sid))
  local launch = sid_from_string(assert(lease.launch_sid))
  local ok, err = pcall(function()
  for _, path in ipairs(unique_paths(vim.list_extend(vim.deepcopy(read_roots), filesystem.write_roots))) do
    check_admission(deadline)
    allow_path(path, { launch }, WIN32.FILE.SANDBOX_READ, true)
  end
  allow_path(spec.cwd, { launch }, WIN32.FILE.SANDBOX_READ, false)
  for _, path in ipairs(filesystem.write_roots) do
    check_admission(deadline)
    allow_path(path, { logon }, WIN32.FILE.SANDBOX_WRITE, true)
  end
  for _, path in ipairs(filesystem.deny_write) do
    check_admission(deadline)
    deny_path(path, logon, WIN32.FILE.SANDBOX_DENY_WRITE)
  end
  for _, path in ipairs(filesystem.deny_read) do
    check_admission(deadline)
    deny_path(path, logon,
      bit.bor(WIN32.FILE.SANDBOX_READ, WIN32.ACCESS.READ_CONTROL))
  end
  -- Apply loader grants recursively before process creation. Neovim opens
  -- packaged DLLs and runtime files before the worker starts its protocol.
  for _, path in ipairs(read_roots) do
    if not covered_by(filesystem.write_roots, path) then
      check_admission(deadline)
      allow_path(path, { logon }, WIN32.FILE.SANDBOX_READ, true)
    end
  end
  -- Target executables use their ambient Windows ACLs. System programs grant
  -- read and execute access to local accounts, while rewriting their protected
  -- DACLs requires administrative rights. Executables below write roots use
  -- the profile grant; other private executables fail closed at process launch.
  -- Write roots already give the logon read and execute access.
  -- SetEntriesInAclW's SET_ACCESS mode replaces a logon ACE, so required
  -- paths covered by a write root retain that broader grant.
  -- The same logon SID participates in ordinary and restricted write checks.
  for _, path in ipairs(read_paths) do
    if not covered_by(filesystem.write_roots, path) then
      check_admission(deadline)
      allow_path(path, { logon }, WIN32.FILE.SANDBOX_READ, false)
    end
  end
  for _, path in ipairs(protected_ancestors(filesystem)) do
    check_admission(deadline)
    update_acl(path, { explicit_access(logon, WIN32.ACCESS.DELETE, WIN32.SECURITY.DENY_ACCESS, 0) })
  end
  end)
  K.LocalFree(logon)
  K.LocalFree(launch)
  if not ok then error(err, 0) end
end

-- Command construction and process containment ------------------------------

local command_line = windows_command.line

---@param value string
---@return Neoagent.FfiArray<integer>
local function wide_mutable(value)
  local source = wide(value)
  local length = (sizeof(source) / sizeof("WCHAR")) --[[@as integer]]
  local result = (ffi.new("WCHAR[?]", length) --[[@as Neoagent.FfiArray<integer>]])
  ffi.copy(result, source, sizeof(source))
  return result
end

---@param environment table<string, string>
---@return Neoagent.FfiArray<integer>
local function utf16_block(environment)
  local names = environment_names(environment)
  ---@type integer
  local units = #names == 0 and 2 or 1
  local encoded = {}
  for _, name in ipairs(names) do
    local item = wide(name .. "=" .. environment[name])
    encoded[#encoded + 1] = item
    units = units + ((sizeof(item) / sizeof("WCHAR")) --[[@as integer]])
  end
  local block = (ffi.new("WCHAR[?]", units) --[[@as Neoagent.FfiArray<integer>]])
  local offset = 0
  for _, item in ipairs(encoded) do
    local count = (sizeof(item) / sizeof("WCHAR")) --[[@as integer]]
    ffi.copy(block + offset, item, sizeof(item))
    offset = offset + count
  end
  block[offset] = 0
  return block
end

-- Extended startup attributes place the target in its job during creation and
-- expose exactly the three standard-stream handles. Containment and handle
-- ownership are established before the first target instruction runs.
---@param job ffi.cdata*
---@param stdin_handle ffi.cdata*
---@param stdout_handle ffi.cdata*
---@param stderr_handle ffi.cdata*
---@return Neoagent.WindowsProcessAttributes
local function target_process_attributes(job, stdin_handle, stdout_handle,
    stderr_handle)
  local size = (ffi.new("SIZE_T[1]") --[[@as Neoagent.FfiArray<integer|ffi.cdata*>]])
  K.InitializeProcThreadAttributeList(nil, 2, 0, size)
  if size[0] == 0 then failure("target-attributes-size") end
  local storage = (ffi.new("BYTE[?]", (tonumber(size[0]) --[[@as integer]])) --[[@as Neoagent.FfiArray<integer>]])
  local list = ffi.cast("void *", storage)
  if K.InitializeProcThreadAttributeList(list, 2, 0, size) == 0 then
    failure("target-attributes-create")
  end
  local handles = (ffi.new("HANDLE[3]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  handles[0] = stdin_handle
  handles[1] = stdout_handle
  handles[2] = stderr_handle
  local jobs = (ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  jobs[0] = job
  local ok, err = pcall(function()
    -- An explicit handle list gives the child exactly its three standard
    -- handles. Other inheritable host handles remain outside the sandbox
    -- target and cannot keep its pipe endpoints alive.
    if K.UpdateProcThreadAttribute(list, 0,
        WIN32.PROCESS.ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles),
        nil, nil) == 0 then
      failure("target-attributes-handles")
    end
    -- Job membership takes effect as part of process creation, so neither the
    -- target nor an immediate descendant can run before containment applies.
    if K.UpdateProcThreadAttribute(list, 0,
        WIN32.PROCESS.ATTRIBUTE_JOB_LIST, jobs, sizeof(jobs),
        nil, nil) == 0 then
      failure("target-attributes-job")
    end
  end)
  if not ok then
    K.DeleteProcThreadAttributeList(list)
    error(err, 0)
  end
  return {
    storage = storage,
    list = list,
    handles = handles,
    jobs = jobs,
  }
end

---@param token ffi.cdata*
---@param logon ffi.cdata*
local function set_default_dacl(token, logon)
  local owner_rights = sid_from_string("S-1-3-4")
  local entries = (ffi.new("EXPLICIT_ACCESS_W[2]") --[[@as Neoagent.FfiArray<Neoagent.Win32.EXPLICIT_ACCESS_W>]])
  entries[0] = explicit_access(logon, WIN32.ACCESS.GENERIC_ALL, WIN32.SECURITY.GRANT_ACCESS, 0)
  -- Give this invocation explicit control over its native objects. The owner
  -- entry keeps permission checks explicit where Windows uses this DACL.
  entries[1] = explicit_access(owner_rights, WIN32.ACCESS.READ_CONTROL, WIN32.SECURITY.GRANT_ACCESS, 0)
  local acl = (ffi.new("ACL *[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local code = A.SetEntriesInAclW(2, entries, nil, acl)
  K.LocalFree(owner_rights)
  if code ~= WIN32.ERROR.SUCCESS then failure("token-dacl", code) end
  local value = (ffi.new("TOKEN_DEFAULT_DACL") --[[@as Neoagent.Win32.TOKEN_DEFAULT_DACL]])
  value.DefaultDacl = acl[0]
  local ok = A.SetTokenInformation(
    token, WIN32.TOKEN.DEFAULT_DACL_CLASS, value, sizeof(value))
  local err = last_error()
  -- The token object has its own DACL, independent of TokenDefaultDacl. Its
  -- holder must be able to query and duplicate the restricted token when
  -- creating children.
  if ok ~= 0 then
    code = A.SetSecurityInfo(token, WIN32.SECURITY.KERNEL_OBJECT,
      WIN32.SECURITY.DACL_INFORMATION, nil, nil, acl[0], nil)
  end
  K.LocalFree(acl[0])
  if ok == 0 then failure("token-dacl", err) end
  if code ~= WIN32.ERROR.SUCCESS then failure("token-object-dacl", code) end
end

---@param token ffi.cdata*
---@param name string
local function enable_privilege(token, name)
  local luid = (ffi.new("LUID") --[[@as Neoagent.Win32.LUID]])
  if A.LookupPrivilegeValueW(nil, wide(name), luid) == 0 then
    failure("token-privilege-lookup")
  end
  local privileges = (ffi.new("TOKEN_PRIVILEGES") --[[@as Neoagent.Win32.TOKEN_PRIVILEGES]])
  privileges.PrivilegeCount = 1
  privileges.Privileges[0].Luid = luid
  privileges.Privileges[0].Attributes = WIN32.SECURITY.PRIVILEGE_ENABLED
  K.SetLastError(WIN32.ERROR.SUCCESS)
  if A.AdjustTokenPrivileges(
      token, 0, privileges, sizeof(privileges), nil, nil) == 0 then
    failure("token-privilege")
  end
  local err = last_error()
  if err ~= WIN32.ERROR.SUCCESS then failure("token-privilege", err) end
end

---@param name string
---@param secret string
---@return ffi.cdata*
local function logon_account(name, secret)
  local password = wide(secret)
  local token = (ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local ok = A.LogonUserW(wide(name), wide("."), password,
    WIN32.TOKEN.LOGON_INTERACTIVE, 0, token)
  local err = last_error()
  ffi.fill(password, sizeof(password), 0)
  if ok == 0 then failure("account-logon", err) end
  return token[0]
end

-- Restricted target identity -------------------------------------------------
--
-- Each target has a private account and logon SID. Including that account in
-- the restricting set preserves Win32's default named-pipe access checks while
-- keeping ownership separate from every peer. Logon ACEs grant only this
-- invocation's profile, and CreateRestrictedToken removes launch privileges.
---@param base ffi.cdata*
---@return ffi.cdata*, string
local function restricted_token(base)
  local everyone = sid_from_string("S-1-1-0")
  local logon, logon_storage = token_logon_sid(base)
  local logon_sid_string = sid_string(logon)
  local user, user_storage = token_user_sid(base)
  local restricting = (ffi.new("SID_AND_ATTRIBUTES[3]") --[[@as Neoagent.FfiArray<Neoagent.Win32.SID_AND_ATTRIBUTES>]])
  restricting[0].Sid = logon
  restricting[0].Attributes = 0
  restricting[1].Sid = everyone
  restricting[1].Attributes = 0
  restricting[2].Sid = user
  restricting[2].Attributes = 0
  local result = (ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local ok = A.CreateRestrictedToken(base,
    bit.bor(
      WIN32.TOKEN.DISABLE_MAX_PRIVILEGE,
      WIN32.TOKEN.LUA,
      WIN32.TOKEN.WRITE_RESTRICTED),
    0, nil, 0, nil, 3, restricting, result)
  if ok == 0 then
    K.LocalFree(everyone)
    failure("restricted-token")
  end
  local configured, err = pcall(function()
    -- Child-created IPC belongs to this invocation. Windows system objects
    -- retain their ambient access.
    set_default_dacl(result[0], logon)
    enable_privilege(result[0], "SeChangeNotifyPrivilege")
  end)
  logon_storage, user_storage = logon_storage, user_storage
  K.LocalFree(everyone)
  if not configured then
    close_handle(result[0])
    error(err, 0)
  end
  return result[0], logon_sid_string
end

---@param value? Neoagent.WindowsDesktop
local function close_private_desktop(value)
  if not value then return end
  if not invalid_handle(value.desktop) then U.CloseDesktop(value.desktop) end
  if not invalid_handle(value.station) then U.CloseWindowStation(value.station) end
end

-- A private desktop gives GUI-aware libraries a valid windowing namespace
-- while the process remains headless. Access is limited to the logon identity
-- and Windows administrative identities.
---@param logon_sid_string string
---@return Neoagent.WindowsDesktop
local function private_desktop(logon_sid_string)
  local previous = U.GetProcessWindowStation()
  if invalid_handle(previous) then failure("window-station") end
  local descriptor = security_descriptor(string.format(
    "D:P(A;;GA;;;%s)(A;;GA;;;%s)(A;;GA;;;SY)", logon_sid_string, current_user_sid_string()))
  local attributes = (ffi.new("SECURITY_ATTRIBUTES") --[[@as Neoagent.Win32.SECURITY_ATTRIBUTES]])
  attributes.nLength = sizeof(attributes)
  attributes.lpSecurityDescriptor = descriptor
  attributes.bInheritHandle = 0
  local station_name = "NeoagentSandbox-" .. random_hex(12)
  local station = U.CreateWindowStationW(wide(station_name), 0, WIN32.DESKTOP.STATION_ALL_ACCESS, attributes)
  local station_err = last_error()
  if invalid_handle(station) then
    K.LocalFree(descriptor)
    failure("window-station-create", station_err)
  end
  if U.SetProcessWindowStation(station) == 0 then
    local err = last_error()
    K.LocalFree(descriptor)
    U.CloseWindowStation(station)
    failure("window-station-select", err)
  end
  local desktop_name = "NeoagentSandbox-" .. random_hex(12)
  local desktop = U.CreateDesktopW(
    wide(desktop_name), nil, nil, 0, WIN32.DESKTOP.ALL_ACCESS, attributes)
  local desktop_err = last_error()
  -- The host remains on its original station outside this native setup.
  if U.SetProcessWindowStation(previous) == 0 then exit(125) end
  K.LocalFree(descriptor)
  if invalid_handle(desktop) then
    U.CloseWindowStation(station)
    failure("desktop-create", desktop_err)
  end
  return {
    desktop = desktop,
    station = station,
    name = wide(station_name .. "\\" .. desktop_name),
  }
end

-- Probe checks run while impersonating the same restricted token used for
-- target commands.
---@generic T, U, V
---@param token ffi.cdata*
---@param callback fun(): T, U?, V?
---@return T, U?, V?
local function with_impersonation(token, callback)
  if A.ImpersonateLoggedOnUser(token) == 0 then
    failure("impersonate")
  end
  local ok, value, extra, detail = pcall(callback)
  local reverted = A.RevertToSelf()
  if reverted == 0 then failure("revert-token") end
  if not ok then error(value, 0) end
  return value, extra, detail
end

-- Target execution -----------------------------------------------------------
--
-- The host forwards stdin and drains stdout and stderr through anonymous
-- pipes while watching the target process. Output becomes ordered protocol
-- events; the owning worker lease controls forced termination.
---@param handle ffi.cdata*
---@param event Neoagent.SandboxProtocolEvent
local function send_event(handle, event)
  local ok, err = write_frame(handle, event)
  if not ok then failure("protocol-write", err) end
end

---@param handle ffi.cdata*
---@return Neoagent.WindowsOutput
local function output_sender(handle)
  local sequence = 0
  return function(stream, data)
    if data == "" then return end
    local offset = 1
    while offset <= #data do
      local chunk = data:sub(offset, offset + 65535)
      sequence = sequence + 1
      send_event(handle, {
        v = RUNTIME.PROTOCOL_VERSION,
        type = "output",
        stream = stream,
        seq = sequence,
        data = chunk,
      })
      offset = offset + #chunk
    end
  end
end

---@return Neoagent.Win32.SECURITY_ATTRIBUTES
local function inheritable_attributes()
  local attributes = (ffi.new("SECURITY_ATTRIBUTES") --[[@as Neoagent.Win32.SECURITY_ATTRIBUTES]])
  attributes.nLength = sizeof(attributes)
  attributes.lpSecurityDescriptor = nil
  attributes.bInheritHandle = 1
  return attributes
end

---@param handle ffi.cdata*
---@param enabled boolean
local function set_inherit(handle, enabled)
  if K.SetHandleInformation(handle, WIN32.HANDLE.INHERIT,
      enabled and WIN32.HANDLE.INHERIT or 0) == 0 then
    failure("handle-inheritance")
  end
end

---@return ffi.cdata*, ffi.cdata*
local function create_output_pipe()
  local read_end = (ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local write_end = (ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local attributes = inheritable_attributes()
  if K.CreatePipe(read_end, write_end, attributes, 0) == 0 then
    failure("output-pipe")
  end
  local ok, err = pcall(set_inherit, read_end[0], false)
  if not ok then
    close_handle(read_end[0])
    close_handle(write_end[0])
    error(err, 0)
  end
  return read_end[0], write_end[0]
end

---@return ffi.cdata*, ffi.cdata*
local function create_input_pipe()
  local read_end = (ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local write_end = (ffi.new("HANDLE[1]") --[[@as Neoagent.FfiArray<ffi.cdata*>]])
  local attributes = inheritable_attributes()
  if K.CreatePipe(read_end, write_end, attributes, 0) == 0 then
    failure("input-pipe")
  end
  local ok, err = pcall(set_inherit, write_end[0], false)
  if not ok then
    close_handle(read_end[0])
    close_handle(write_end[0])
    error(err, 0)
  end
  return read_end[0], write_end[0]
end

---@param handle ffi.cdata*
---@param stage? string
---@return integer?
local function pipe_available(handle, stage)
  local available = (ffi.new("DWORD[1]") --[[@as Neoagent.FfiArray<integer>]])
  if K.PeekNamedPipe(handle, nil, 0, nil, available, nil) == 0 then
    local err = last_error()
    if err == WIN32.ERROR.BROKEN_PIPE or err == WIN32.ERROR.NO_DATA then
      return nil
    end
    failure(stage or "output-peek", err)
  end
  return available[0]
end

---@param handle ffi.cdata*
---@param stream 'stdout'|'stderr'
---@param output Neoagent.WindowsOutput
---@return boolean
local function drain_pipe(handle, stream, output)
  local available = pipe_available(handle)
  if available == nil then return false end
  if available == 0 then return true end
  local chunk, err = read_some(handle, math.min(available, 65536))
  if not chunk then
    if err == WIN32.ERROR.BROKEN_PIPE
        or err == WIN32.ERROR.NO_DATA then
      return false
    end
    failure("output-read", err)
  end
  output(stream, chunk)
  return true
end

---@param input ffi.cdata*
---@param target_stdin ffi.cdata*
---@return boolean
local function forward_target_input(input, target_stdin)
  local available = pipe_available(input, "stdin-peek")
  if available == nil then return false end
  if available == 0 then return true end
  local data, err = read_some(input, math.min(available, 65536))
  if not data then
    if err == WIN32.ERROR.BROKEN_PIPE or err == WIN32.ERROR.NO_DATA then return false end
    failure("stdin-read", err)
  end
  if data == "" then return false end
  local written, write_err = write_all(target_stdin, data)
  if not written and write_err ~= WIN32.ERROR.BROKEN_PIPE and write_err ~= WIN32.ERROR.NO_DATA then
    failure("target-stdin-write", write_err)
  end
  return written == true
end

---@param target Neoagent.WindowsTarget
---@param field 'stdin'|'stdin_write'|'stdout'|'stdout_write'|'stderr'|'stderr_write'|'process'|'thread'
local function close_target_handle(target, field)
  close_handle(target[field])
  target[field] = nil
end

---@param target Neoagent.WindowsTarget
local function close_target(target)
  local ok, err = pcall(function()
    if target.job then target.job:stop() end
  end)
  if target.attributes and target.attributes.list then
    K.DeleteProcThreadAttributeList(target.attributes.list)
    target.attributes.list = nil
  end
  for _, field in ipairs({ "stdin", "stdin_write", "stdout", "stdout_write", "stderr", "stderr_write",
      "process", "thread" }) do
    close_target_handle(target, field)
  end
  close_private_desktop(target.desktop)
  target.desktop = nil
  if not ok then error(err, 0) end
end

-- The host creates the restricted target directly, with its Job and standard
-- handles assigned atomically. Its privileged logon token is impersonated only
-- for native creation and is never inherited by the target.
---@param spec Neoagent.WindowsRuntimeSpec
---@param base ffi.cdata*
---@param token ffi.cdata*
---@param logon_sid_string string
---@param target Neoagent.WindowsTarget
---@param deadline number
---@return Neoagent.SandboxExitEvent
local function spawn_target(spec, base, token, logon_sid_string, target, deadline)
  check_admission(deadline)
  local argv = assert(spec.argv)
  target.stdin, target.stdin_write = create_input_pipe()
  target.stdout, target.stdout_write = create_output_pipe()
  target.stderr, target.stderr_write = create_output_pipe()
  target.desktop = private_desktop(logon_sid_string)
  target.attributes = target_process_attributes(assert(assert(target.job).handle), assert(target.stdin),
    assert(target.stdout_write), assert(target.stderr_write))
  local startup = (ffi.new("STARTUPINFOEXW") --[[@as Neoagent.Win32.STARTUPINFOEXW]])
  startup.StartupInfo.cb = sizeof(startup)
  startup.StartupInfo.dwFlags = WIN32.PROCESS.STARTF_USESTDHANDLES
  startup.StartupInfo.hStdInput = target.stdin
  startup.StartupInfo.hStdOutput = target.stdout_write
  startup.StartupInfo.hStdError = target.stderr_write
  startup.StartupInfo.lpDesktop = target.desktop.name
  startup.lpAttributeList = target.attributes.list
  local process = (ffi.new("PROCESS_INFORMATION") --[[@as Neoagent.Win32.PROCESS_INFORMATION]])
  local command = wide_mutable(command_line(argv))
  local executable = wide(assert(argv[1]))
  local cwd = wide(spec.cwd)
  local environment = utf16_block(spec.env)
  local flags = bit.bor(WIN32.PROCESS.CREATE_NO_WINDOW, WIN32.PROCESS.CREATE_UNICODE_ENVIRONMENT,
    WIN32.PROCESS.EXTENDED_STARTUPINFO_PRESENT, WIN32.PROCESS.CREATE_SUSPENDED)
  check_admission(deadline)
  local ok, err = with_impersonation(base, function()
    local created = A.CreateProcessAsUserW(token, executable, command, nil, nil, 1,
      flags, environment, cwd, startup.StartupInfo, process)
    return created, last_error()
  end)
  K.DeleteProcThreadAttributeList(target.attributes.list)
  target.attributes.list = nil
  close_target_handle(target, "stdout_write")
  close_target_handle(target, "stderr_write")
  if ok == 0 then failure("target-create", err) end
  target.process, target.thread = process.hProcess, process.hThread
  -- Process creation itself can outlast admission. Keep the new thread
  -- suspended until the owner checks the cutoff, with its Job already owned.
  check_admission(deadline)
  if K.ResumeThread(target.thread) == 0xffffffff then failure("target-resume") end
  close_target_handle(target, "thread")
  close_target_handle(target, "stdin")
  stdout_frame({ v = RUNTIME.PROTOCOL_VERSION, type = "ready" })
  target.ready = true
  local output = output_sender(K.GetStdHandle(WIN32.HANDLE.STD_OUTPUT))
  local input = K.GetStdHandle(WIN32.HANDLE.STD_INPUT)
  local stdout_open, stderr_open = true, true
  local process_status = K.WaitForSingleObject(process.hProcess, 0)
  while process_status == WIN32.WAIT.TIMEOUT do
    if target.stdin_write and not forward_target_input(input, target.stdin_write) then
      close_target_handle(target, "stdin_write")
    end
    if stdout_open then stdout_open = drain_pipe(assert(target.stdout), "stdout", output) end
    if stderr_open then stderr_open = drain_pipe(assert(target.stderr), "stderr", output) end
    K.Sleep(RUNTIME.OUTPUT_POLL_MS)
    process_status = K.WaitForSingleObject(process.hProcess, 0)
  end
  close_target_handle(target, "stdin_write")
  if process_status ~= WIN32.WAIT.OBJECT_0 then failure("target-wait", process_status) end
  assert(target.job):stop()
  for _ = 1, RUNTIME.OUTPUT_DRAIN_POLLS do
    if stdout_open then stdout_open = drain_pipe(assert(target.stdout), "stdout", output) end
    if stderr_open then stderr_open = drain_pipe(assert(target.stderr), "stderr", output) end
    if not stdout_open and not stderr_open then break end
    K.Sleep(1)
  end
  if stdout_open or stderr_open then failure("output-drain-timeout") end
  local exit_code = (ffi.new("DWORD[1]") --[[@as Neoagent.FfiArray<integer>]])
  if K.GetExitCodeProcess(process.hProcess, exit_code) == 0 then failure("target-status") end
  return { v = RUNTIME.PROTOCOL_VERSION, type = "exit", code = exit_code[0], signal = 0 }
end

---@param path string
---@param disposition integer
---@return true?, integer?
local function probe_write(path, disposition)
  local handle = K.CreateFileW(wide(path),
    bit.bor(WIN32.ACCESS.GENERIC_READ, WIN32.ACCESS.GENERIC_WRITE),
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_DELETE),
    nil, disposition, WIN32.FILE.ATTRIBUTE_NORMAL, nil)
  if invalid_handle(handle) then return nil, last_error() end
  local ok, err = write_all(handle, "probe")
  if ok and K.FlushFileBuffers(handle) == 0 then
    ok, err = nil, last_error()
  end
  close_handle(handle)
  return ok, err
end

-- Probe mode checks observable sandbox behavior. Filesystem checks execute
-- under the restricted token, and the offline account verifies that WFP rejects
-- even a loopback connection attempt.
---@return boolean, integer
local function network_is_blocked()
  local data = (ffi.new("WSADATA") --[[@as Neoagent.Win32.WSADATA]])
  local code = W.WSAStartup(0x0202, data)
  if code ~= 0 then failure("winsock-startup", code) end
  local socket = W.socket(WIN32.SOCKET.AF_INET, WIN32.SOCKET.STREAM, WIN32.SOCKET.TCP)
  if socket == WIN32.SOCKET.INVALID then
    local err = W.WSAGetLastError()
    W.WSACleanup()
    failure("winsock-socket", err)
  end
  local address = (ffi.new("SOCKADDR_IN") --[[@as Neoagent.Win32.SOCKADDR_IN]])
  address.sin_family = WIN32.SOCKET.AF_INET
  address.sin_port = W.htons(9)
  address.sin_addr.s_addr = 0x0100007f
  local connected = W.connect(socket, address, sizeof(address))
  local err = connected == 0 and 0 or W.WSAGetLastError()
  W.closesocket(socket)
  W.WSACleanup()
  return connected ~= 0 and err == WIN32.ERROR.WSA_ACCESS_DENIED, err
end

---@param path string
---@param access integer
---@param flags integer
---@return true?, integer?
local function open_probe(path, access, flags)
  local handle = K.CreateFileW(wide(path), access,
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_WRITE, WIN32.FILE.SHARE_DELETE),
    nil, WIN32.FILE.OPEN_EXISTING, flags or WIN32.FILE.ATTRIBUTE_NORMAL, nil)
  if invalid_handle(handle) then return nil, last_error() end
  close_handle(handle)
  return true
end

---@param spec Neoagent.WindowsRuntimeSpec
---@param token ffi.cdata*
local function run_probe(spec, token)
  if type(spec.probe) ~= "table"
      or type(spec.probe.write) ~= "string"
      or type(spec.probe.deny_write) ~= "string"
      or type(spec.probe.deny_read) ~= "string" then
    failure("probe-specification", 0)
  end
  local ok, stage, code = with_impersonation(token, function()
    local written, write_err = probe_write(spec.probe.write, WIN32.FILE.CREATE_NEW)
    if not written then return nil, "probe-write", write_err end
    K.DeleteFileW(wide(spec.probe.write))
    local denied_write, denied_write_err =
      probe_write(spec.probe.deny_write, WIN32.FILE.CREATE_ALWAYS)
    if denied_write or denied_write_err ~= WIN32.ERROR.ACCESS_DENIED then
      return nil, "probe-deny-write", denied_write_err or 0
    end
    local denied_read, denied_read_err = open_probe(
      spec.probe.deny_read, WIN32.ACCESS.GENERIC_READ, WIN32.FILE.FLAG_BACKUP_SEMANTICS)
    if denied_read or denied_read_err ~= WIN32.ERROR.ACCESS_DENIED then
      return nil, "probe-deny-read", denied_read_err or 0
    end
    if spec.profile.network == "restricted" then
      local blocked, network_err = network_is_blocked()
      if not blocked then return nil, "probe-network", network_err end
    end
    return true
  end)
  if not ok then failure(assert(stage), code) end
end

-- Admission and finalization each own one journal transaction. In between,
-- the private guard and named Job own this lease independently of every other
-- host. The target cannot run before its identity and ACLs are recorded.
---@param directory string
---@param cleanup Neoagent.SandboxCleanupObservation
local function host_main(directory, cleanup)
  accounts.check_host()
  local encoded = vim.uv.os_getenv(
    "NEOAGENT_SANDBOX_SPEC", 1024 * 1024 + 1)
  local unsetenv = vim.uv.os_unsetenv --[[@as fun(name: string): boolean?, string?]]
  unsetenv("NEOAGENT_SANDBOX_SPEC")
  if type(encoded) ~= "string" or #encoded > 1024 * 1024 then
    failure("specification-environment", 0)
  end
  local decoded, spec = pcall(vim.json.decode, encoded)
  if not decoded then failure("specification-json", 0) end
  local timeouts = {}
  for _, name in ipairs({ "admission", "finalization" }) do
    local value = type(spec) == "table" and spec[name .. "_timeout_ms"] or nil
    if type(value) ~= "number" or value % 1 ~= 0 or value <= 0 or value > 0x7fffffff then
      failure("specification-" .. name .. "-timeout", 0)
    end
    timeouts[name] = value
  end
  local admission_deadline = vim.uv.hrtime() + timeouts.admission * 1000000
  ---@type ffi.cdata*?
  local mutex = acquire_mutex(timeouts.admission)
  ---@type Neoagent.WindowsRuntimeState?
  local state
  ---@type Neoagent.WindowsTarget
  local target = {}
  ---@type ffi.cdata*?
  local base, token, target_base
  ---@type Neoagent.SandboxTerminalEvent?
  local terminal
  ---@type string?
  local id
  ---@type ffi.cdata*?
  local guard
  local ok, err = pcall(function()
    local registration = authority.location(directory)
    directory = registration.directory
    state = decode_state(directory)
    if state.owner_sid ~= current_user_sid_string() then
      failure("state-owner", WIN32.ERROR.ACCESS_DENIED)
    end
    if not state.provisioned then failure("setup-incomplete", 0) end
    if state.coordinator ~= registration.id then failure("state-coordinator", WIN32.ERROR.ACCESS_DENIED) end
    local journal = authority.journal(directory, state, admission_deadline)
    if spec.mode == "recover" then
      if spec.v ~= RUNTIME.PROTOCOL_VERSION or type(spec.lease) ~= "string" or #spec.lease ~= 32 or not spec.lease:match("^%x+$") then
        failure("specification-lease", 0)
      end
      journal:recover(spec.lease)
      if state.leases[spec.lease] then failure("lease-still-owned", 0) end
      stdout_frame({ v = RUNTIME.PROTOCOL_VERSION, type = "ready" })
      terminal = { v = RUNTIME.PROTOCOL_VERSION, type = "exit", code = 0, signal = 0 }
      return
    end
    journal:recover()
    check_admission(admission_deadline)
    spec = validate_spec(spec, directory)
    local policy = {
      write_roots = vim.deepcopy(spec.profile.windows.write_roots),
      deny_write = vim.deepcopy(spec.profile.windows.deny_write),
    }
    journal:admit(policy)
    local launcher = assert(state.launcher)
    if account_sid(launcher.name) ~= launcher.sid then
      failure("account-identity", WIN32.ERROR.ACCESS_DENIED)
    end
    check_admission(admission_deadline)
    id = spec.mode == "exec" and assert(spec.lease) or random_hex(16)
    guard = acquire_lease(id)
    if not guard or state.leases[id] then failure("lease-identity", WIN32.ERROR.ALREADY_EXISTS) end
    ---@type Neoagent.WindowsPrivateAccount
    local account = { name = "na_" .. random_hex(8) }
    ---@type Neoagent.WindowsAuthorityLease
    local lease = { job = "unstarted", account = account, paths = authority_paths(spec), policy = policy }
    cleanup.released = false
    journal:reserve(id, lease)
    do
      local password = password_value()
      accounts.create(account, assert(launcher.sid), state.owner_sid, password,
        spec.profile.network == "restricted" and assert(state.offline_group) or nil,
        function() encode_state(directory, state) end)
      check_admission(admission_deadline)
      target_base = logon_account(account.name, password)
    end
    local logon
    token, logon = restricted_token(target_base)
    base = logon_account(launcher.name, account_password(launcher))
    local launch_sid, launch_storage = token_logon_sid(base)
    lease.logon_sid, lease.launch_sid = logon, sid_string(launch_sid)
    launch_storage = launch_storage
    local session_info = token_information(token, 12) -- TokenSessionId.
    local session = (ffi.cast("DWORD *", session_info) --[[@as Neoagent.FfiArray<integer>]])[0]
    local objects = session == 0 and "\\BaseNamedObjects" or "\\Sessions\\BNOLINKS\\" .. tostring(session)
    lease.namespaces = { objects }
    encode_state(directory, state)
    namespace.change(objects, assert(account.sid), true)
    local privileges, privilege_error = pcall(function()
      enable_privilege(base, "SeAssignPrimaryTokenPrivilege")
      enable_privilege(base, "SeIncreaseQuotaPrivilege")
    end)
    if not privileges then
      failure("setup-launch-rights", error_value(privilege_error).errno)
    end
    check_admission(admission_deadline)
    if spec.mode == "exec" then
      target.job = new_job(directory, id)
      if not target.job:open() then failure("target-custody", WIN32.ERROR.FILE_NOT_FOUND) end
    end
    materialize_protected(directory, state, spec, admission_deadline)
    apply_runtime_acls(spec, lease, admission_deadline)
    check_admission(admission_deadline)
    if spec.mode == "probe" then
      -- Probe under the private token in this host; it creates no process.
      -- Crashing here therefore leaves an unstarted, recoverable reservation.
      run_probe(spec, token)
      stdout_frame({ v = RUNTIME.PROTOCOL_VERSION, type = "ready" })
      terminal = { v = RUNTIME.PROTOCOL_VERSION, type = "exit", code = 0, signal = 0 }
    else
      journal:permit_launch(id)
      release_mutex(mutex)
      mutex = nil
      terminal = spawn_target(spec, base, token, logon, target, admission_deadline)
    end
  end)
  local finalization_deadline = vim.uv.hrtime() + timeouts.finalization * 1000000
  if not target.ready then
    -- Failed admission cannot start a fresh window beyond the total budget
    -- supervised by the parent. Blocking native calls may consume that time;
    -- when it is exhausted, preserve uncertainty instead of extending it.
    local limit = admission_deadline + timeouts.finalization * 1000000
    if finalization_deadline > limit then finalization_deadline = limit end
  end
  local stopped, stop_err = pcall(close_target, target)
  local cleaned, cleanup_err = pcall(function()
    if not stopped then error(stop_err, 0) end
    if not cleanup.released then
      if not mutex then
        local remaining = math.max(0, math.ceil((finalization_deadline - vim.uv.hrtime()) / 1000000))
        mutex = acquire_mutex(remaining)
        local registration = authority.location(directory)
        state = decode_state(directory, finalization_deadline)
        if state.coordinator ~= registration.id then failure("state-coordinator", WIN32.ERROR.ACCESS_DENIED) end
      end
      authority.journal(directory, assert(state), finalization_deadline):finish(assert(id), target.job)
    end
  end)
  release_mutex(mutex)
  release_mutex(guard)
  close_handle(token)
  close_handle(target_base)
  close_handle(base)
  cleanup.released = cleaned
  if not cleaned then
    local value = error_value(cleanup_err)
    cleanup.error = { stage = value.stage, errno = value.errno }
  end
  if not ok then error(err, 0) end
  assert(terminal).cleanup = cleanup
  stdout_frame(assert(terminal))
end

---@return string
local function default_state_directory()
  local configured = vim.uv.os_getenv("NEOAGENT_WINDOWS_SANDBOX_STATE")
  if type(configured) == "string" and configured ~= "" then
    return vim.fs.normalize(configured)
  end
  return vim.fs.joinpath(
    (vim.fn.stdpath("state") --[[@as string]]), "neoagent", "windows-sandbox")
end

-- Entrypoint -----------------------------------------------------------------
--
-- Setup emits a small JSON result for the manual provisioning command. Host
-- mode uses the framed runtime protocol described above.
local arguments = {}
for index = 1, #arg do arguments[index] = arg[index] end
if arguments[1] == "--" then table.remove(arguments, 1) end

if jit.arch ~= "x64" then
  emit_error(nil, {
    sandbox_runtime_error = true,
    stage = "architecture",
    errno = 0,
  }, { released = true })
  exit(125)
end

local directory = default_state_directory()
if arguments[1] == "--setup" then
  local mutex, bootstrap_mutex
  local bootstrap = kernel_objects.new(authority.coordinator.setup_namespace, {
    identity = authority.coordinator.administrators, wide = wide, failure = failure,
  })
  local ok, err = pcall(function()
    local deadline = vim.uv.hrtime() + RUNTIME.ADMISSION_TIMEOUT_MS * 1000000
    -- Before registration there is no host identity to share. Only elevated
    -- administrators can create/open this machine-wide bootstrap namespace.
    bootstrap:join(deadline)
    local remaining = math.max(0, math.ceil((deadline - vim.uv.hrtime()) / 1000000))
    bootstrap_mutex = acquire_named_mutex(bootstrap:path("setup"), remaining, authority.coordinator.administrators)
    if not bootstrap_mutex then failure("mutex-wait-timeout", WIN32.WAIT.TIMEOUT) end
    remaining = math.max(0, math.ceil((deadline - vim.uv.hrtime()) / 1000000))
    mutex = acquire_mutex(remaining)
    setup(directory, deadline)
  end)
  release_mutex(mutex)
  release_mutex(bootstrap_mutex)
  bootstrap:close(false)
  if not ok then
    local value = error_value(err, "setup")
    io.stderr:write(vim.json.encode({
      v = RUNTIME.PROTOCOL_VERSION,
      ok = false,
      stage = value.stage,
      errno = value.errno,
    }))
    exit(1)
  end
else
  -- Startup can fail without allocating authority. After journal publication,
  -- only confirmed Job termination and ACL cleanup acknowledge release.
  local cleanup = { released = true }
  local ok, err = pcall(host_main, directory, cleanup)
  if not ok then
    emit_error(nil, err, cleanup)
    exit(125)
  end
end
if coordination then coordination:close(false) end
