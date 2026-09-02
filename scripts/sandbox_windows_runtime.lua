-- This file is a standalone LuaJIT program launched by Neoagent. It has three
-- entry modes:
--
--   --setup    create dedicated local accounts and persistent network policy
--   default    validate a request, lease filesystem access, and start a runner
--   --runner   create a restricted token and supervise the target command
--
-- A normal request creates this process tree:
--
--   host runtime (the invoking user)
--     `- account runner (dedicated offline or online local account)
--          `- target command and its descendants (restricted token)
--
-- The host and runner exchange length-prefixed MessagePack frames over
-- identity-checked named pipes. The host owns temporary ACL changes and crash
-- recovery; the runner owns the target job, standard streams, and deadline.

local ffi = require("ffi")
local bit = require("bit")

if jit.os ~= "Windows" then
  io.stderr:write("neoagent Windows sandbox runtime requires Windows\n")
  os.exit(2)
end

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

typedef struct _IO_COUNTERS {
  ULONGLONG ReadOperationCount;
  ULONGLONG WriteOperationCount;
  ULONGLONG OtherOperationCount;
  ULONGLONG ReadTransferCount;
  ULONGLONG WriteTransferCount;
  ULONGLONG OtherTransferCount;
} IO_COUNTERS;
typedef struct _JOBOBJECT_BASIC_LIMIT_INFORMATION {
  LONGLONG PerProcessUserTimeLimit;
  LONGLONG PerJobUserTimeLimit;
  DWORD LimitFlags;
  SIZE_T MinimumWorkingSetSize;
  SIZE_T MaximumWorkingSetSize;
  DWORD ActiveProcessLimit;
  ULONG_PTR Affinity;
  DWORD PriorityClass;
  DWORD SchedulingClass;
} JOBOBJECT_BASIC_LIMIT_INFORMATION;
typedef struct _JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
  JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
  IO_COUNTERS IoInfo;
  SIZE_T ProcessMemoryLimit;
  SIZE_T JobMemoryLimit;
  SIZE_T PeakProcessMemoryUsed;
  SIZE_T PeakJobMemoryUsed;
} JOBOBJECT_EXTENDED_LIMIT_INFORMATION;

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
ULONGLONG __stdcall GetTickCount64(void);
HANDLE __stdcall GetStdHandle(DWORD);
BOOL __stdcall ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
BOOL __stdcall WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
BOOL __stdcall CloseHandle(HANDLE);
HLOCAL __stdcall LocalFree(HLOCAL);
DWORD __stdcall WaitForSingleObject(HANDLE, DWORD);
DWORD __stdcall WaitForMultipleObjects(DWORD, const HANDLE *, BOOL, DWORD);
BOOL __stdcall GetExitCodeProcess(HANDLE, DWORD *);
DWORD __stdcall ResumeThread(HANDLE);
BOOL __stdcall TerminateProcess(HANDLE, UINT);
void __stdcall Sleep(DWORD);
HANDLE __stdcall CreateMutexW(SECURITY_ATTRIBUTES *, BOOL, const WCHAR *);
BOOL __stdcall ReleaseMutex(HANDLE);
HANDLE __stdcall CreateJobObjectW(SECURITY_ATTRIBUTES *, const WCHAR *);
BOOL __stdcall SetInformationJobObject(HANDLE, LONG, void *, DWORD);
BOOL __stdcall AssignProcessToJobObject(HANDLE, HANDLE);
BOOL __stdcall TerminateJobObject(HANDLE, UINT);
BOOL __stdcall CreatePipe(HANDLE *, HANDLE *, SECURITY_ATTRIBUTES *, DWORD);
BOOL __stdcall InitializeProcThreadAttributeList(
  void *, DWORD, DWORD, SIZE_T *);
BOOL __stdcall UpdateProcThreadAttribute(
  void *, DWORD, ULONG_PTR, void *, SIZE_T, void *, SIZE_T *);
void __stdcall DeleteProcThreadAttributeList(void *);
BOOL __stdcall SetHandleInformation(HANDLE, DWORD, DWORD);
HANDLE __stdcall CreateNamedPipeW(const WCHAR *, DWORD, DWORD, DWORD,
  DWORD, DWORD, DWORD, SECURITY_ATTRIBUTES *);
BOOL __stdcall ConnectNamedPipe(HANDLE, void *);
BOOL __stdcall DisconnectNamedPipe(HANDLE);
BOOL __stdcall GetNamedPipeClientProcessId(HANDLE, ULONG *);
BOOL __stdcall GetNamedPipeServerProcessId(HANDLE, ULONG *);
BOOL __stdcall PeekNamedPipe(HANDLE, void *, DWORD, DWORD *, DWORD *, DWORD *);
BOOL __stdcall SetNamedPipeHandleState(HANDLE, DWORD *, DWORD *, DWORD *);
BOOL __stdcall WaitNamedPipeW(const WCHAR *, DWORD);
HANDLE __stdcall CreateFileW(const WCHAR *, DWORD, DWORD,
  SECURITY_ATTRIBUTES *, DWORD, DWORD, HANDLE);
BOOL __stdcall GetFileInformationByHandle(HANDLE, BY_HANDLE_FILE_INFORMATION *);
DWORD __stdcall GetFileType(HANDLE);
DWORD __stdcall GetFileAttributesW(const WCHAR *);
BOOL __stdcall CreateDirectoryW(const WCHAR *, SECURITY_ATTRIBUTES *);
BOOL __stdcall DeleteFileW(const WCHAR *);
BOOL __stdcall RemoveDirectoryW(const WCHAR *);
BOOL __stdcall SetFilePointerEx(HANDLE, LONGLONG, LONGLONG *, DWORD);
BOOL __stdcall FlushFileBuffers(HANDLE);
BOOL __stdcall GetFileSizeEx(HANDLE, LONGLONG *);
BOOL __stdcall MoveFileExW(const WCHAR *, const WCHAR *, DWORD);
int __stdcall MultiByteToWideChar(UINT, DWORD, const char *, int, WCHAR *, int);
int __stdcall WideCharToMultiByte(UINT, DWORD, const WCHAR *, int,
  char *, int, const char *, BOOL *);

BOOL __stdcall OpenProcessToken(HANDLE, DWORD, HANDLE *);
BOOL __stdcall GetTokenInformation(HANDLE, LONG, void *, DWORD, DWORD *);
BOOL __stdcall CopySid(DWORD, SID *, SID *);
DWORD __stdcall GetLengthSid(SID *);
BOOL __stdcall EqualSid(SID *, SID *);
BOOL __stdcall ConvertStringSidToSidW(const WCHAR *, SID **);
BOOL __stdcall ConvertSidToStringSidW(SID *, WCHAR **);
BOOL __stdcall LookupAccountNameW(const WCHAR *, const WCHAR *, SID *,
  DWORD *, WCHAR *, DWORD *, LONG *);
BOOL __stdcall CreateWellKnownSid(LONG, SID *, SID *, DWORD *);
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
DWORD __stdcall SetEntriesInAclW(ULONG, EXPLICIT_ACCESS_W *, ACL *, ACL **);
BOOL __stdcall ConvertStringSecurityDescriptorToSecurityDescriptorW(
  const WCHAR *, DWORD, void **, ULONG *);
BOOL __stdcall SetFileSecurityW(const WCHAR *, DWORD, void *);
DWORD __stdcall BuildSecurityDescriptorW(TRUSTEE_W *, TRUSTEE_W *, ULONG,
  EXPLICIT_ACCESS_W *, ULONG, EXPLICIT_ACCESS_W *, void *, ULONG *, void **);
BOOL __stdcall CreateProcessWithLogonW(const WCHAR *, const WCHAR *,
  const WCHAR *, DWORD, const WCHAR *, WCHAR *, DWORD, void *,
  const WCHAR *, STARTUPINFOW *, PROCESS_INFORMATION *);
BOOL __stdcall CreateProcessAsUserW(HANDLE, const WCHAR *, WCHAR *,
  SECURITY_ATTRIBUTES *, SECURITY_ATTRIBUTES *, BOOL, DWORD, void *,
  const WCHAR *, STARTUPINFOW *, PROCESS_INFORMATION *);

DWORD __stdcall NetUserAdd(const WCHAR *, DWORD, BYTE *, DWORD *);
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
BOOL __stdcall GetUserObjectInformationW(HANDLE, int, void *, DWORD, DWORD *);

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
    OPEN_ALWAYS = 4,
    ATTRIBUTE_DIRECTORY = 0x10,
    ATTRIBUTE_NORMAL = 0x80,
    ATTRIBUTE_TEMPORARY = 0x100,
    ATTRIBUTE_REPARSE_POINT = 0x400,
    INVALID_ATTRIBUTES = 0xffffffff,
    FLAG_DELETE_ON_CLOSE = 0x04000000,
    FLAG_BACKUP_SEMANTICS = 0x02000000,
    FLAG_OPEN_REPARSE_POINT = 0x00200000,
    TYPE_DISK = 1,
    BEGIN = 0,
    END_ = 2,
    MOVE_REPLACE_EXISTING = 0x1,
    MOVE_WRITE_THROUGH = 0x8,
  },
  SECURITY = {
    PRIVILEGE_ENABLED = 0x2,
    GROUP_LOGON_ID = bit.tobit(0xc0000000),
    FILE_OBJECT = 1,
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
  JOB = {
    KILL_ON_CLOSE = 0x2000,
    EXTENDED_LIMIT_INFORMATION = 9,
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
  WIN32.FILE.GENERIC_WRITE, WIN32.ACCESS.DELETE,
  WIN32.FILE.DELETE_CHILD, WIN32.ACCESS.WRITE_DACL,
  WIN32.ACCESS.WRITE_OWNER)

-- Protocol and lifecycle limits live together so bounded reads, output
-- polling, cleanup, and state migrations remain easy to audit.
local RUNTIME = {
  MAX_FRAME = 1024 * 1024,
  STATE_VERSION = 1,
  PROTOCOL_VERSION = 1,
  OUTPUT_POLL_MS = 10,
  OUTPUT_DRAIN_POLLS = 1000,
  PROCESS_SHUTDOWN_MS = 5000,
}

local function invalid_handle(handle)
  return handle == nil or handle == ffi.NULL
    or handle == WIN32.HANDLE.INVALID
end

local function close_handle(handle)
  if not invalid_handle(handle) then K.CloseHandle(handle) end
end

local function last_error()
  return tonumber(K.GetLastError())
end

local function failure(stage, code)
  error({
    sandbox_runtime_error = true,
    stage = stage,
    errno = tonumber(code or last_error()),
  }, 0)
end

local function error_value(value, fallback)
  if type(value) == "table" and value.sandbox_runtime_error then
    return value
  end
  return {
    stage = fallback or "runtime",
    errno = 0,
  }
end

local function wide(value)
  value = tostring(value)
  if value:find("\0", 1, true) then failure("utf16", 0) end
  local length = K.MultiByteToWideChar(65001, 0x8, value, #value, nil, 0)
  if length <= 0 and #value > 0 then failure("utf16") end
  local buffer = ffi.new("WCHAR[?]", length + 1)
  if length > 0
      and K.MultiByteToWideChar(65001, 0x8, value, #value, buffer, length) ~= length then
    failure("utf16")
  end
  buffer[length] = 0
  return buffer
end

local function utf8(pointer, length)
  if pointer == nil or pointer == ffi.NULL then return nil end
  if length == nil then
    length = 0
    while pointer[length] ~= 0 do length = length + 1 end
  end
  local size = K.WideCharToMultiByte(
    65001, 0, pointer, length, nil, 0, nil, nil)
  if size <= 0 and length > 0 then failure("utf8") end
  local buffer = ffi.new("char[?]", math.max(size, 1))
  if size > 0
      and K.WideCharToMultiByte(
        65001, 0, pointer, length, buffer, size, nil, nil) ~= size then
    failure("utf8")
  end
  return ffi.string(buffer, size)
end

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
-- same format is used between Neoagent and the host runtime and between the
-- host and account runner.
local function write_all(handle, data)
  local offset = 0
  local written = ffi.new("DWORD[1]")
  while offset < #data do
    local size = math.min(#data - offset, 65536)
    if K.WriteFile(handle, data:sub(offset + 1, offset + size),
        size, written, nil) == 0 then
      return nil, last_error()
    end
    local count = tonumber(written[0])
    if count <= 0 then return nil, WIN32.ERROR.BROKEN_PIPE end
    offset = offset + count
  end
  return true
end

local function read_some(handle, size)
  local buffer = ffi.new("BYTE[?]", size)
  local count = ffi.new("DWORD[1]")
  if K.ReadFile(handle, buffer, size, count, nil) == 0 then
    return nil, last_error()
  end
  return ffi.string(buffer, tonumber(count[0]))
end

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

local function u32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256)
end

local function frame_data(value)
  local payload = vim.mpack.encode(value)
  if #payload <= 0 or #payload > RUNTIME.MAX_FRAME then failure("protocol-size", 0) end
  return u32(#payload) .. payload
end

local function write_frame(handle, value)
  return write_all(handle, frame_data(value))
end

local function read_frame(handle)
  local header, header_err = read_exact(handle, 4)
  if not header then return nil, header_err end
  local a, b, c, d = header:byte(1, 4)
  local size = ((a * 256 + b) * 256 + c) * 256 + d
  if size <= 0 or size > RUNTIME.MAX_FRAME then return nil, 0 end
  local payload, payload_err = read_exact(handle, size)
  if not payload then return nil, payload_err end
  local ok, value = pcall(vim.mpack.decode, payload)
  if not ok or type(value) ~= "table" then return nil, 0 end
  return value
end

local function stdout_frame(value)
  local handle = K.GetStdHandle(WIN32.HANDLE.STD_OUTPUT)
  if invalid_handle(handle) or not write_frame(handle, value) then
    os.exit(125)
  end
end

local function emit_error(handle, value)
  value = error_value(value)
  local event = {
    v = 1,
    type = "error",
    stage = value.stage,
    errno = value.errno,
  }
  if handle then
    write_frame(handle, event)
  else
    stdout_frame(event)
  end
end

local function read_standard_input()
  local handle = K.GetStdHandle(WIN32.HANDLE.STD_INPUT)
  if invalid_handle(handle) then return "" end
  local chunks = {}
  while true do
    local chunk, err = read_some(handle, 65536)
    if not chunk then
      if err == WIN32.ERROR.BROKEN_PIPE then break end
      failure("stdin", err)
    end
    if chunk == "" then break end
    chunks[#chunks + 1] = chunk
  end
  return table.concat(chunks)
end

-- Windows security identities and ACLs --------------------------------------
--
-- A SID is Windows' stable identity value for a user or capability. ACL
-- entries grant or deny permissions to SIDs. These helpers convert SID forms,
-- inspect tokens, and apply narrowly scoped entries to filesystem objects.
local function sid_string(sid)
  local pointer = ffi.new("WCHAR *[1]")
  if A.ConvertSidToStringSidW(sid, pointer) == 0 then
    failure("sid-string")
  end
  local result = utf8(pointer[0])
  K.LocalFree(pointer[0])
  return result
end

local function sid_from_string(value)
  local pointer = ffi.new("SID *[1]")
  local encoded = wide(value)
  if A.ConvertStringSidToSidW(encoded, pointer) == 0 then
    failure("sid-parse")
  end
  return pointer[0]
end

local function current_token()
  local desired = bit.bor(
    WIN32.TOKEN.ASSIGN_PRIMARY,
    WIN32.TOKEN.DUPLICATE,
    WIN32.TOKEN.QUERY,
    WIN32.TOKEN.ADJUST_PRIVILEGES,
    WIN32.TOKEN.ADJUST_DEFAULT,
    WIN32.TOKEN.ADJUST_SESSION_ID)
  local token = ffi.new("HANDLE[1]")
  if A.OpenProcessToken(K.GetCurrentProcess(), desired, token) == 0 then
    failure("open-token")
  end
  return token[0]
end

local function token_information(token, class)
  local needed = ffi.new("DWORD[1]")
  A.GetTokenInformation(token, class, nil, 0, needed)
  if needed[0] == 0 then failure("token-information") end
  local buffer = ffi.new("BYTE[?]", tonumber(needed[0]))
  if A.GetTokenInformation(
      token, class, buffer, needed[0], needed) == 0 then
    failure("token-information")
  end
  return buffer, tonumber(needed[0])
end

local function token_user_sid(token)
  local buffer = token_information(token, WIN32.TOKEN.USER_CLASS)
  return ffi.cast("TOKEN_USER *", buffer).User.Sid, buffer
end

local function token_logon_sid(token)
  local buffer = token_information(token, WIN32.TOKEN.GROUPS_CLASS)
  local groups = ffi.cast("TOKEN_GROUPS *", buffer)
  local entries = ffi.cast("SID_AND_ATTRIBUTES *",
    ffi.cast("BYTE *", buffer) + ffi.offsetof("TOKEN_GROUPS", "Groups"))
  for index = 0, tonumber(groups.GroupCount) - 1 do
    if bit.band(entries[index].Attributes, WIN32.SECURITY.GROUP_LOGON_ID)
        == WIN32.SECURITY.GROUP_LOGON_ID then
      return entries[index].Sid, buffer
    end
  end
  failure("token-logon-sid")
end

local function current_user_sid_string()
  local token = current_token()
  local sid, storage = token_user_sid(token)
  local result = sid_string(sid)
  storage = storage
  close_handle(token)
  return result
end

local function account_sid(name)
  local encoded = wide(name)
  local sid_size = ffi.new("DWORD[1]")
  local domain_size = ffi.new("DWORD[1]")
  local use = ffi.new("LONG[1]")
  A.LookupAccountNameW(
    nil, encoded, nil, sid_size, nil, domain_size, use)
  if sid_size[0] == 0 then return nil, last_error() end
  local sid = ffi.new("BYTE[?]", tonumber(sid_size[0]))
  local domain = ffi.new("WCHAR[?]", math.max(tonumber(domain_size[0]), 1))
  if A.LookupAccountNameW(nil, encoded, ffi.cast("SID *", sid), sid_size,
      domain, domain_size, use) == 0 then
    return nil, last_error()
  end
  return sid_string(ffi.cast("SID *", sid))
end

local function security_descriptor(sddl)
  local result = ffi.new("void *[1]")
  local encoded = wide(sddl)
  if A.ConvertStringSecurityDescriptorToSecurityDescriptorW(
      encoded, 1, result, nil) == 0 then
    failure("security-descriptor")
  end
  return result[0]
end

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

local function explicit_access(sid, permissions, mode, inheritance)
  local value = ffi.new("EXPLICIT_ACCESS_W")
  value.grfAccessPermissions = permissions
  value.grfAccessMode = mode
  value.grfInheritance = inheritance or 0
  value.Trustee.pMultipleTrustee = nil
  value.Trustee.MultipleTrusteeOperation = 0
  value.Trustee.TrusteeForm = WIN32.SECURITY.TRUSTEE_SID
  value.Trustee.TrusteeType = WIN32.SECURITY.TRUSTEE_UNKNOWN
  value.Trustee.ptstrName = ffi.cast("WCHAR *", sid)
  return value
end

local function update_acl(path, entries)
  local encoded = wide(path)
  local old_acl = ffi.new("ACL *[1]")
  local descriptor = ffi.new("void *[1]")
  local code = A.GetNamedSecurityInfoW(encoded, WIN32.SECURITY.FILE_OBJECT,
    WIN32.SECURITY.DACL_INFORMATION, nil, nil, old_acl, nil, descriptor)
  if code ~= WIN32.ERROR.SUCCESS then failure("acl-read", code) end
  local array = ffi.new("EXPLICIT_ACCESS_W[?]", #entries)
  for index, entry in ipairs(entries) do
    array[index - 1] = entry
  end
  local new_acl = ffi.new("ACL *[1]")
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

local function deny_path(path, sid, permissions)
  update_acl(path, {
    explicit_access(sid, permissions, WIN32.SECURITY.DENY_ACCESS,
      bit.bor(WIN32.SECURITY.CONTAINER_INHERIT_ACE, WIN32.SECURITY.OBJECT_INHERIT_ACE)),
  })
end

local function revoke_path(path, sid)
  local stat = vim.uv.fs_lstat(path)
  if not stat then return end
  update_acl(path, {
    explicit_access(sid, 0, WIN32.SECURITY.REVOKE_ACCESS,
      bit.bor(WIN32.SECURITY.CONTAINER_INHERIT_ACE, WIN32.SECURITY.OBJECT_INHERIT_ACE)),
  })
end

-- Persistent setup state -----------------------------------------------------
--
-- Setup creates two ordinary local accounts: an offline identity covered by
-- firewall rules and an online identity for network-enabled profiles. Their
-- random passwords are encrypted for the invoking user with DPAPI. Atomic
-- replacement keeps the account, firewall, and recovery records well formed
-- across interruption.
local function dpapi(value, decrypt)
  local source = ffi.new("BYTE[?]", math.max(#value, 1))
  if #value > 0 then ffi.copy(source, value, #value) end
  local input = ffi.new("DATA_BLOB")
  input.cbData = #value
  input.pbData = source
  local entropy_value = "neoagent-windows-sandbox-state-v1"
  local entropy_bytes = ffi.new("BYTE[?]", #entropy_value)
  ffi.copy(entropy_bytes, entropy_value, #entropy_value)
  local entropy = ffi.new("DATA_BLOB")
  entropy.cbData = #entropy_value
  entropy.pbData = entropy_bytes
  local output = ffi.new("DATA_BLOB")
  local description = ffi.new("WCHAR *[1]")
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
  local result = ffi.string(output.pbData, tonumber(output.cbData))
  if output.pbData ~= nil then K.LocalFree(output.pbData) end
  return result
end

local function read_file(path)
  local fd, err = vim.uv.fs_open(path, "r", 0)
  if not fd then return nil, err end
  local stat, stat_err = vim.uv.fs_fstat(fd)
  if not stat or stat.type ~= "file" then
    vim.uv.fs_close(fd)
    return nil, stat_err or "not a regular file"
  end
  local data, read_err = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  return data, read_err
end

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
    vim.uv.fs_unlink(temporary)
    failure("state-replace")
  end
end

local function state_path(directory)
  return vim.fs.joinpath(directory, "state.json")
end

local function decode_state(directory)
  local data = read_file(state_path(directory))
  if type(data) ~= "string" then
    failure("state-missing", WIN32.ERROR.FILE_NOT_FOUND)
  end
  local ok, state = pcall(vim.json.decode, data)
  if not ok or type(state) ~= "table" or state.v ~= RUNTIME.STATE_VERSION
      or type(state.owner_sid) ~= "string"
      or type(state.accounts) ~= "table" then
    failure("state-format", 0)
  end
  for _, name in ipairs({ "offline", "online" }) do
    local account = state.accounts[name]
    if type(account) ~= "table" or type(account.name) ~= "string"
        or type(account.sid) ~= "string"
        or type(account.password) ~= "string" then
      failure("state-format", 0)
    end
  end
  state.acl = type(state.acl) == "table" and state.acl or {}
  state.recovery = type(state.recovery) == "table" and state.recovery or {}
  return state
end

local function encode_state(directory, state)
  atomic_write(state_path(directory), vim.json.encode(state))
end

local function account_password(account)
  local ok, encrypted = pcall(vim.base64.decode, account.password)
  if not ok or type(encrypted) ~= "string" then failure("state-password", 0) end
  return dpapi(encrypted, true)
end

local function password_value()
  return "Aa1!" .. random_hex(24)
end

local function account_name(prefix)
  for _ = 1, 32 do
    local name = prefix .. random_hex(3)
    if not account_sid(name) then return name end
  end
  failure("account-name", WIN32.ERROR.ALREADY_EXISTS)
end

local function create_or_update_account(name, password)
  local existing = account_sid(name)
  local encoded_password = wide(password)
  if existing then
    local info = ffi.new("USER_INFO_1003")
    info.usri1003_password = encoded_password
    local parameter = ffi.new("DWORD[1]")
    local code = N.NetUserSetInfo(
      nil, wide(name), 1003, ffi.cast("BYTE *", info), parameter)
    if code ~= WIN32.ERROR.SUCCESS then failure("account-password", code) end
    return existing
  end
  local encoded_name = wide(name)
  local comment = wide("Neoagent Windows sandbox account")
  local info = ffi.new("USER_INFO_1")
  info.usri1_name = encoded_name
  info.usri1_password = encoded_password
  info.usri1_password_age = 0
  info.usri1_priv = WIN32.ACCOUNT.PRIVILEGE_USER
  info.usri1_home_dir = nil
  info.usri1_comment = comment
  info.usri1_flags = bit.bor(
    WIN32.ACCOUNT.SCRIPT, WIN32.ACCOUNT.PASSWORD_CANNOT_CHANGE,
    WIN32.ACCOUNT.NORMAL, WIN32.ACCOUNT.PASSWORD_NEVER_EXPIRES)
  info.usri1_script_path = nil
  local parameter = ffi.new("DWORD[1]")
  local code = N.NetUserAdd(nil, 1, ffi.cast("BYTE *", info), parameter)
  if code ~= WIN32.ERROR.SUCCESS and code ~= WIN32.ERROR.USER_EXISTS then
    failure("account-create", code)
  end
  local sid, sid_err = account_sid(name)
  if not sid then failure("account-sid", sid_err) end
  return sid
end

local function guid(value)
  local a, b, c, d, e = value:match(
    "^([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-([0-9a-fA-F]+)%-"
      .. "([0-9a-fA-F]+)%-([0-9a-fA-F]+)$")
  if not a or #a ~= 8 or #b ~= 4 or #c ~= 4 or #d ~= 4 or #e ~= 12 then
    failure("guid", 0)
  end
  local result = ffi.new("GUID")
  result.Data1 = tonumber(a, 16)
  result.Data2 = tonumber(b, 16)
  result.Data3 = tonumber(c, 16)
  local tail = d .. e
  for index = 0, 7 do
    result.Data4[index] = tonumber(tail:sub(index * 2 + 1, index * 2 + 2), 16)
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

function random_guid()
  local random = vim.uv.random(16)
  if type(random) ~= "string" or #random ~= 16 then failure("random", 0) end
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

local function wfp_ok(code, stage, allowed)
  code = tonumber(code)
  if code == WIN32.ERROR.SUCCESS then return end
  for _, value in ipairs(allowed or {}) do
    if code == value then return end
  end
  failure(stage, code)
end

local function wfp_user_condition(account_sid_string)
  local account = sid_from_string(account_sid_string)
  local access = ffi.new("EXPLICIT_ACCESS_W[1]")
  access[0] = explicit_access(
    account, WIN32.WFP.ACCESS_MATCH_FILTER, WIN32.SECURITY.GRANT_ACCESS, 0)
  local descriptor = ffi.new("void *[1]")
  local length = ffi.new("ULONG[1]")
  local code = A.BuildSecurityDescriptorW(
    nil, nil, 1, access, 0, nil, nil, length, descriptor)
  K.LocalFree(account)
  if code ~= WIN32.ERROR.SUCCESS then failure("wfp-user", code) end
  local blob = ffi.new("FWP_BYTE_BLOB[1]")
  blob[0].size = length[0]
  blob[0].data = ffi.cast("BYTE *", descriptor[0])
  return descriptor[0], blob
end

local function install_wfp(account_sid_string, filter_keys)
  local session_name = wide("Neoagent Windows sandbox")
  local session = ffi.new("FWPM_SESSION0")
  session.displayData.name = session_name
  session.txnWaitTimeoutInMSec = WIN32.WAIT.INFINITE
  local engine = ffi.new("HANDLE[1]")
  wfp_ok(F.FwpmEngineOpen0(nil, 10, nil, session, engine), "wfp-open")

  local transaction = false
  local ok, err = pcall(function()
    wfp_ok(F.FwpmTransactionBegin0(engine[0], 0), "wfp-transaction")
    transaction = true

    local provider_name = wide("Neoagent Windows sandbox")
    local provider_description =
      wide("Persistent network policy for Neoagent sandbox accounts")
    local provider = ffi.new("FWPM_PROVIDER0")
    provider.providerKey = WFP.PROVIDER
    provider.displayData.name = provider_name
    provider.displayData.description = provider_description
    provider.flags = WIN32.WFP.PROVIDER_PERSISTENT
    wfp_ok(F.FwpmProviderAdd0(engine[0], provider, nil),
      "wfp-provider", { WIN32.WFP.ALREADY_EXISTS })

    local sublayer_name = wide("Neoagent Windows sandbox")
    local sublayer_description =
      wide("Persistent outbound isolation for Neoagent sandbox accounts")
    local provider_key = ffi.new("GUID[1]", WFP.PROVIDER)
    local sublayer = ffi.new("FWPM_SUBLAYER0")
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
    local condition = ffi.new("FWPM_FILTER_CONDITION0[1]")
    condition[0].fieldKey = WFP.USER
    condition[0].matchType = WIN32.WFP.MATCH_EQUAL
    condition[0].conditionValue.type = WIN32.WFP.SECURITY_DESCRIPTOR_TYPE
    condition[0].conditionValue.value.sd = user_blob
    local sublayer_key = WFP.SUBLAYER
    for index, item in ipairs(WFP.FILTERS) do
      local filter_key = guid(filter_keys[index])
      wfp_ok(F.FwpmFilterDeleteByKey0(
        engine[0], ffi.new("GUID[1]", filter_key)),
        "wfp-filter-delete", { WIN32.WFP.FILTER_NOT_FOUND, WIN32.WFP.NOT_FOUND })
      local name = wide(item.name)
      local description =
        wide("Block all network traffic from the offline sandbox account")
      local filter = ffi.new("FWPM_FILTER0")
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
      local id = ffi.new("UINT64[1]")
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

local function mkdir(path)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then return end
  local ok, err = vim.fn.mkdir(path, "p")
  if ok == 0 and not vim.uv.fs_stat(path) then
    failure("state-directory", tonumber(err) or 0)
  end
end

-- Setup is the privileged, persistent phase. It creates or refreshes both
-- accounts, installs the offline account's firewall filters, prepares a shared
-- temporary directory, and protects the saved state for the invoking user.
local function setup(directory)
  mkdir(directory)
  local owner_sid = current_user_sid_string()
  protect_path(directory, owner_sid)

  local state
  local existing = read_file(state_path(directory))
  if existing then
    state = decode_state(directory)
    if state.owner_sid ~= owner_sid then
      failure("state-owner", WIN32.ERROR.ACCESS_DENIED)
    end
  else
    state = {
      v = RUNTIME.STATE_VERSION,
      owner_sid = owner_sid,
      accounts = {},
      recovery = {},
    }
  end

  for _, kind in ipairs({ "offline", "online" }) do
    local record = state.accounts[kind]
    local password
    if record then
      password = account_password(record)
    else
      password = password_value()
      record = {
        name = account_name(kind == "offline"
          and "neoagent_off_" or "neoagent_on_"),
      }
      state.accounts[kind] = record
    end
    record.sid = create_or_update_account(record.name, password)
    record.password = vim.base64.encode(dpapi(password, false))
  end

  if state.wfp == nil then
    state.wfp = { filters = {} }
    for index = 1, #WFP.FILTERS do
      state.wfp.filters[index] = random_guid()
    end
  elseif type(state.wfp) ~= "table"
      or type(state.wfp.filters) ~= "table"
      or not vim.islist(state.wfp.filters)
      or #state.wfp.filters ~= #WFP.FILTERS then
    failure("state-format", 0)
  else
    for _, value in ipairs(state.wfp.filters) do
      if type(value) ~= "string" then failure("state-format", 0) end
    end
  end
  install_wfp(state.accounts.offline.sid, state.wfp.filters)
  local shared = vim.fs.joinpath(directory, "shared-tmp")
  mkdir(shared)
  allow_path(shared, {
    sid_from_string(state.accounts.offline.sid),
    sid_from_string(state.accounts.online.sid),
  }, WIN32.FILE.ALL_ACCESS, true)
  protect_path(directory, owner_sid)
  encode_state(directory, state)
  protect_path(state_path(directory), owner_sid)
  io.stdout:write(vim.json.encode({
    v = RUNTIME.PROTOCOL_VERSION,
    ok = true,
    platform = "windows",
    setup_version = RUNTIME.STATE_VERSION,
  }))
end

-- Request preparation --------------------------------------------------------
--
-- One named mutex serializes ACL leases and recovery for a state directory.
-- Paths are normalized, resolved, and compared case-insensitively before any
-- access rule is changed. Existing paths must retain the identity selected by
-- validation.
local function mutex_name(directory)
  return "Local\\NeoagentSandbox-" .. vim.fn.sha256(
    tostring(directory):lower()):sub(1, 32)
end

local function acquire_mutex(directory)
  local handle = K.CreateMutexW(nil, 0, wide(mutex_name(directory)))
  if invalid_handle(handle) then failure("mutex-create") end
  local result = tonumber(K.WaitForSingleObject(handle, WIN32.WAIT.INFINITE))
  if result ~= WIN32.WAIT.OBJECT_0 and result ~= WIN32.WAIT.ABANDONED then
    close_handle(handle)
    failure("mutex-wait", result)
  end
  return handle
end

local function release_mutex(handle)
  if not invalid_handle(handle) then
    K.ReleaseMutex(handle)
    close_handle(handle)
  end
end

local function path_key(path)
  return tostring(path):gsub("/", "\\"):gsub("\\+$", ""):lower()
end

local function path_contains(root, path)
  root, path = path_key(root), path_key(path)
  return path == root or path:sub(1, #root + 1) == root .. "\\"
end

local function path_overlap(left, right)
  return path_contains(left, right) or path_contains(right, left)
end

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
local function validate_spec(spec, directory)
  if type(spec) ~= "table" or spec.v ~= RUNTIME.PROTOCOL_VERSION then
    failure("specification-version", 0)
  end
  if spec.mode ~= "probe" and spec.mode ~= "exec" and spec.mode ~= "fs" then
    failure("specification-mode", 0)
  end
  if spec.timeout_ms ~= nil
      and (spec.mode ~= "exec"
        or type(spec.timeout_ms) ~= "number"
        or spec.timeout_ms % 1 ~= 0
        or spec.timeout_ms < 0
        or spec.timeout_ms > 0x7fffffff) then
    failure("specification-timeout", 0)
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
    if path_key(root) ~= path_key(shared_root)
        and path_overlap(root, protected_state) then
      failure("profile-state-overlap", WIN32.ERROR.ACCESS_DENIED)
    end
  end
  spec.cwd = canonical_existing(spec.cwd, "specification-cwd")
  if type(spec.env) ~= "table"
      or vim.islist(spec.env) and next(spec.env) then
    failure("specification-environment", 0)
  end
  local by_name = {}
  for name, value in pairs(spec.env) do
    local key = type(name) == "string" and name:lower() or ""
    if type(name) ~= "string"
        or not name:match("^[A-Za-z_][A-Za-z0-9_]*$")
        or type(value) ~= "string" or value:find("\0", 1, true)
        or by_name[key] then
      failure("specification-environment", 0)
    end
    by_name[key] = true
  end
  if type(spec.runner) ~= "table"
      or type(spec.runner.argv) ~= "table"
      or not vim.islist(spec.runner.argv)
      or #spec.runner.argv == 0
      or type(spec.runner.read_roots) ~= "table"
      or not vim.islist(spec.runner.read_roots)
      or #spec.runner.read_roots == 0
      or type(spec.runner.script) ~= "string" then
    failure("specification-runner", 0)
  end
  for index, value in ipairs(spec.runner.argv) do
    if type(value) ~= "string" or value == ""
        or value:find("\0", 1, true) then
      failure("specification-runner", index)
    end
  end
  spec.runner.argv[1] =
    canonical_existing(spec.runner.argv[1], "runner-executable")
  for index, path in ipairs(spec.runner.read_roots) do
    if type(path) ~= "string" then
      failure("specification-runner", index)
    end
    spec.runner.read_roots[index] =
      canonical_existing(path, "runner-read-root")
  end
  spec.runner.script =
    canonical_existing(spec.runner.script, "runner-script")
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
  if spec.mode == "fs" then
    if type(spec.fs) ~= "table"
        or type(spec.fs.path) ~= "string"
        or not ({
          read = true,
          write_all = true,
          mkdirp = true,
          atomic_replace = true,
        })[spec.fs.operation] then
      failure("specification-fs", 0)
    end
    spec.fs.path = vim.fs.normalize(spec.fs.path)
    if spec.fs.path:find("\0", 1, true) then failure("specification-fs", 0) end
  end
  return spec
end

-- Per-request ACL lease and recovery ----------------------------------------
--
-- Each request receives a random capability SID. ACLs combine that capability
-- with the selected account SID: the account identifies the runner, while the
-- capability makes writable grants specific to this request's target token.
local function capability_sid()
  local components = {}
  local random = vim.uv.random(16)
  if type(random) ~= "string" or #random ~= 16 then failure("random", 0) end
  for index = 0, 3 do
    local a, b, c, d = random:byte(index * 4 + 1, index * 4 + 4)
    components[#components + 1] =
      tostring(((a * 256 + b) * 256 + c) * 256 + d)
  end
  return "S-1-5-21-" .. table.concat(components, "-")
end

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

function path_identity(path)
  local handle = K.CreateFileW(wide(path), 0,
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_WRITE, WIN32.FILE.SHARE_DELETE),
    nil, WIN32.FILE.OPEN_EXISTING,
    bit.bor(WIN32.FILE.FLAG_BACKUP_SEMANTICS, WIN32.FILE.FLAG_OPEN_REPARSE_POINT), nil)
  if invalid_handle(handle) then return nil, last_error() end
  local information = ffi.new("BY_HANDLE_FILE_INFORMATION")
  if K.GetFileInformationByHandle(handle, information) == 0 then
    local err = last_error()
    close_handle(handle)
    return nil, err
  end
  close_handle(handle)
  if bit.band(tonumber(information.dwFileAttributes),
      WIN32.FILE.ATTRIBUTE_REPARSE_POINT) ~= 0 then
    return nil, WIN32.ERROR.ACCESS_DENIED
  end
  return {
    volume = tonumber(information.dwVolumeSerialNumber),
    high = tonumber(information.nFileIndexHigh),
    low = tonumber(information.nFileIndexLow),
  }
end

function same_identity(record, identity)
  return identity
    and type(record.volume) == "number"
    and type(record.high) == "number"
    and type(record.low) == "number"
    and record.volume == identity.volume
    and record.high == identity.high
    and record.low == identity.low
end

function marker_path(record)
  if type(record.path) ~= "string"
      or type(record.marker) ~= "string"
      or not record.marker:match("^%.neoagent%-placeholder%-%x+$") then
    return nil
  end
  return vim.fs.joinpath(record.path, record.marker)
end

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

function read_small_file(path)
  local handle = K.CreateFileW(wide(path), WIN32.ACCESS.GENERIC_READ,
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_WRITE, WIN32.FILE.SHARE_DELETE),
    nil, WIN32.FILE.OPEN_EXISTING, WIN32.FILE.ATTRIBUTE_NORMAL, nil)
  if invalid_handle(handle) then return nil end
  local length = ffi.new("LONGLONG[1]")
  if K.GetFileSizeEx(handle, length) == 0
      or tonumber(length[0]) > 256 then
    close_handle(handle)
    return nil
  end
  local data = read_exact(handle, tonumber(length[0]))
  close_handle(handle)
  return data
end

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

-- The state file is also a cleanup journal. Every temporary ACL and placeholder
-- is recorded before enforcement, allowing this pass to revoke an interrupted
-- request on the next launch. File identities and private marker contents prove
-- that a placeholder still belongs to this runtime before removal.
local function recovery_cleanup(state)
  local recovery = state.recovery
  if type(recovery) ~= "table" or type(recovery.paths) ~= "table" then
    state.recovery = {}
    return
  end
  local account = type(recovery.account_sid) == "string"
      and sid_from_string(recovery.account_sid) or nil
  local capability = type(recovery.capability_sid) == "string"
      and sid_from_string(recovery.capability_sid) or nil
  local first_error
  for _, path in ipairs(recovery.paths) do
    if type(path) == "string" then
      if account then
        local ok, err = pcall(revoke_path, path, account)
        if not ok and not first_error then first_error = err end
      end
      if capability then
        local ok, err = pcall(revoke_path, path, capability)
        if not ok and not first_error then first_error = err end
      end
    end
  end
  local placeholders = type(recovery.placeholders) == "table"
      and recovery.placeholders or {}
  table.sort(placeholders, function(left, right)
    return type(left) == "table" and type(right) == "table"
      and #(left.path or "") > #(right.path or "")
  end)
  for _, record in ipairs(placeholders) do
    local ok, err = pcall(cleanup_placeholder, record)
    if not ok and not first_error then first_error = err end
  end
  if account then K.LocalFree(account) end
  if capability then K.LocalFree(capability) end
  if first_error then error(first_error, 0) end
  state.recovery = {}
end

function materialize_protected(directory, state, spec)
  local protected = spec.profile.windows.protected_create
  for _, entry in ipairs(protected) do
    if not vim.uv.fs_realpath(entry.path) then
      local nonce = random_hex(24)
      local record = {
        path = entry.path,
        marker = ".neoagent-placeholder-" .. random_hex(12),
        nonce = nonce,
        marker_ready = false,
      }
      local placeholders = state.recovery.placeholders
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

local function covered_by(paths, path)
  for _, root in ipairs(paths) do
    if path_contains(root, path) then return true end
  end
  return false
end

-- Windows enforces the profile through temporary ACL entries. Account grants
-- let the runner load Neovim and enter required paths; capability grants and
-- deny entries constrain the restricted target token. All touched paths are
-- journaled before their ACLs change.
local function apply_runtime_acls(directory, state, spec, account_sid_string,
    capability_sid_string)
  local filesystem = spec.profile.windows
  local read_paths = {
    spec.cwd,
    spec.runner.argv[1],
    spec.runner.script,
  }
  local required_paths = vim.deepcopy(read_paths)
  local read_roots = spec.runner.read_roots
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
  local paths = {}
  vim.list_extend(paths, filesystem.write_roots)
  vim.list_extend(paths, filesystem.deny_read)
  vim.list_extend(paths, filesystem.deny_write)
  vim.list_extend(paths, read_paths)
  vim.list_extend(paths, read_roots)
  local shared_root = canonical_existing(
    vim.fs.joinpath(directory, "shared-tmp"), "temporary-root")
  paths[#paths + 1] = shared_root
  paths = unique_paths(paths)
  state.recovery.account_sid = account_sid_string
  state.recovery.capability_sid = capability_sid_string
  state.recovery.paths = paths
  state.recovery.placeholders =
    type(state.recovery.placeholders) == "table"
      and state.recovery.placeholders or {}
  encode_state(directory, state)

  local account = sid_from_string(account_sid_string)
  local capability = sid_from_string(capability_sid_string)
  allow_path(shared_root, { account }, WIN32.FILE.SANDBOX_WRITE, true)
  for _, path in ipairs(filesystem.write_roots) do
    allow_path(path, { account, capability }, WIN32.FILE.SANDBOX_WRITE, true)
  end
  for _, path in ipairs(filesystem.deny_write) do
    deny_path(path, capability, WIN32.FILE.SANDBOX_DENY_WRITE)
  end
  for _, path in ipairs(filesystem.deny_read) do
    deny_path(path, account,
      bit.bor(WIN32.FILE.SANDBOX_READ, WIN32.ACCESS.READ_CONTROL))
  end
  -- Apply loader grants recursively before process creation. Neovim opens
  -- packaged DLLs and runtime files before Lua reaches the pipe handshake.
  for _, path in ipairs(read_roots) do
    if not covered_by(filesystem.write_roots, path) then
      allow_path(path, { account }, WIN32.FILE.SANDBOX_READ, true)
    end
  end
  -- Target executables use their ambient Windows ACLs. System programs grant
  -- read and execute access to local accounts, while rewriting their protected
  -- DACLs requires administrative rights. Executables below write roots use
  -- the profile grant; other private executables fail closed at process launch.
  -- Write roots already give the account read and execute access.
  -- SetEntriesInAclW's SET_ACCESS mode replaces an account ACE, so required
  -- paths covered by a write root retain that broader grant.
  -- Restricted-token writes pass only when both the account and capability
  -- checks allow them.
  for _, path in ipairs(read_paths) do
    if not covered_by(filesystem.write_roots, path) then
      allow_path(path, { account }, WIN32.FILE.SANDBOX_READ, false)
    end
  end
  K.LocalFree(account)
  K.LocalFree(capability)
end

local function finish_runtime_acls(directory, state)
  recovery_cleanup(state)
  encode_state(directory, state)
end

-- Command construction and process containment ------------------------------
--
-- CreateProcess receives one mutable command-line string, so arguments follow
-- the documented Windows backslash-and-quote encoding. cmd.exe command tails
-- use a temporary batch file because cmd applies its own command-language
-- parsing after CreateProcess has parsed the executable arguments.
local function quote_argument(value)
  if value == "" then return '""' end
  if not value:find('[%s"]') then return value end
  local result, backslashes = { '"' }, 0
  for index = 1, #value do
    local char = value:sub(index, index)
    if char == "\\" then
      backslashes = backslashes + 1
    elseif char == '"' then
      result[#result + 1] = string.rep("\\", backslashes * 2 + 1)
      result[#result + 1] = '"'
      backslashes = 0
    else
      if backslashes > 0 then
        result[#result + 1] = string.rep("\\", backslashes)
        backslashes = 0
      end
      result[#result + 1] = char
    end
  end
  if backslashes > 0 then
    result[#result + 1] = string.rep("\\", backslashes * 2)
  end
  result[#result + 1] = '"'
  return table.concat(result)
end

local function command_line(argv)
  local values = {}
  for index, value in ipairs(argv) do
    values[index] = quote_argument(value)
  end
  return table.concat(values, " ")
end

local function cmd_command_index(argv)
  local basename = argv[1]:gsub("/", "\\"):match("([^\\]+)$")
  if not basename or basename:lower() ~= "cmd.exe" then return nil end
  for index = 2, #argv do
    local option = argv[index]:lower()
    if option == "/c" or option == "/k" then
      return index
    end
  end
end

local function target_command_line(argv, command_index, command_file)
  if not command_file then return command_line(argv) end
  local values = {}
  -- The batch file supplies the complete command string and owns its quote
  -- parsing. The process prefix carries the remaining cmd options through
  -- /c or /k, and its executable token uses native backslash path syntax.
  for index = 1, command_index do
    if index == 1 or argv[index]:lower() ~= "/s" then
      local value = index == 1 and argv[index]:gsub("/", "\\") or argv[index]
      values[#values + 1] = quote_argument(value)
    end
  end
  -- cmd.exe receives the batch path directly after /c or /k. The shared
  -- runtime directory uses an ordinary Windows path, and cmd reads the
  -- command's quotes, redirections, and metacharacters from the file.
  local path = command_file:gsub("/", "\\")
  values[#values + 1] =
    path:find("[%s&<>()|%^]") and ('""' .. path .. '""') or path
  return table.concat(values, " ")
end

local function wide_mutable(value)
  local source = wide(value)
  local length = ffi.sizeof(source) / ffi.sizeof("WCHAR")
  local result = ffi.new("WCHAR[?]", length)
  ffi.copy(result, source, ffi.sizeof(source))
  return result
end

local function utf16_block(environment)
  local names = vim.tbl_keys(environment)
  table.sort(names, function(left, right)
    local left_key, right_key = left:lower(), right:lower()
    return left_key == right_key and left < right or left_key < right_key
  end)
  local units = #names == 0 and 2 or 1
  local encoded = {}
  for _, name in ipairs(names) do
    local item = wide(name .. "=" .. environment[name])
    encoded[#encoded + 1] = item
    units = units + ffi.sizeof(item) / ffi.sizeof("WCHAR")
  end
  local block = ffi.new("WCHAR[?]", units)
  local offset = 0
  for _, item in ipairs(encoded) do
    local count = ffi.sizeof(item) / ffi.sizeof("WCHAR")
    ffi.copy(block + offset, item, ffi.sizeof(item))
    offset = offset + count
  end
  block[offset] = 0
  return block
end

-- A kill-on-close job groups a process with all descendants. Closing or
-- terminating the runner and target jobs therefore provides bounded cleanup
-- for both process trees.
local function create_job(stage)
  local job = K.CreateJobObjectW(nil, nil)
  if invalid_handle(job) then failure(stage or "job-create") end
  local limits = ffi.new("JOBOBJECT_EXTENDED_LIMIT_INFORMATION")
  limits.BasicLimitInformation.LimitFlags =
    WIN32.JOB.KILL_ON_CLOSE
  if K.SetInformationJobObject(job,
      WIN32.JOB.EXTENDED_LIMIT_INFORMATION,
      limits, ffi.sizeof(limits)) == 0 then
    close_handle(job)
    failure(stage or "job-configure")
  end
  return job
end

local function assign_job(job, process, stage)
  if K.AssignProcessToJobObject(job, process) == 0 then
    failure(stage or "job-assign")
  end
end

-- Extended startup attributes place the target in its job during creation and
-- expose exactly the three standard-stream handles. Containment and handle
-- ownership are established before the first target instruction runs.
local function target_process_attributes(job, stdin_handle, stdout_handle,
    stderr_handle)
  local size = ffi.new("SIZE_T[1]")
  K.InitializeProcThreadAttributeList(nil, 2, 0, size)
  if size[0] == 0 then failure("target-attributes-size") end
  local storage = ffi.new("BYTE[?]", tonumber(size[0]))
  local list = ffi.cast("void *", storage)
  if K.InitializeProcThreadAttributeList(list, 2, 0, size) == 0 then
    failure("target-attributes-create")
  end
  local handles = ffi.new("HANDLE[3]")
  handles[0] = stdin_handle
  handles[1] = stdout_handle
  handles[2] = stderr_handle
  local jobs = ffi.new("HANDLE[1]")
  jobs[0] = job
  local ok, err = pcall(function()
    -- An explicit handle list gives the child exactly its three standard
    -- handles. Other inheritable runner handles remain outside the sandbox
    -- target and cannot keep its pipe endpoints alive.
    if K.UpdateProcThreadAttribute(list, 0,
        WIN32.PROCESS.ATTRIBUTE_HANDLE_LIST, handles, ffi.sizeof(handles),
        nil, nil) == 0 then
      failure("target-attributes-handles")
    end
    -- Job membership takes effect as part of process creation, so neither the
    -- target nor an immediate descendant can run before containment applies.
    if K.UpdateProcThreadAttribute(list, 0,
        WIN32.PROCESS.ATTRIBUTE_JOB_LIST, jobs, ffi.sizeof(jobs),
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

-- Named pipes form the private host-runner control channel. Their ACL names the
-- selected account, and both endpoints verify the connecting process ID. This
-- pairs the expected account identity with the exact process launched by the
-- host.
local function pipe_security(account_sid_string)
  local descriptor = security_descriptor(
    "D:(A;;GA;;;" .. account_sid_string .. ")")
  local attributes = ffi.new("SECURITY_ATTRIBUTES")
  attributes.nLength = ffi.sizeof(attributes)
  attributes.lpSecurityDescriptor = descriptor
  attributes.bInheritHandle = 0
  return attributes, descriptor
end

local function create_server_pipe(name, access, account_sid_string)
  local attributes, descriptor = pipe_security(account_sid_string)
  local handle = K.CreateNamedPipeW(wide(name), access,
    bit.bor(WIN32.PIPE.TYPE_BYTE, WIN32.PIPE.READMODE_BYTE, WIN32.PIPE.NOWAIT),
    1, 65536, 65536, 0, attributes)
  K.LocalFree(descriptor)
  if invalid_handle(handle) then failure("pipe-create") end
  return handle
end

local function connect_server_pipe(handle, expected_pid, process)
  local connected = false
  for _ = 1, 1000 do
    if K.ConnectNamedPipe(handle, nil) ~= 0 then
      connected = true
      break
    end
    local err = last_error()
    if err == WIN32.ERROR.PIPE_CONNECTED then
      connected = true
      break
    end
    if err ~= WIN32.ERROR.PIPE_LISTENING and err ~= WIN32.ERROR.NO_DATA then
      failure("pipe-connect", err)
    end
    if K.WaitForSingleObject(process, 0) == WIN32.WAIT.OBJECT_0 then
      failure("runner-exited", 0)
    end
    K.Sleep(10)
  end
  if not connected then failure("pipe-connect-timeout", WIN32.WAIT.TIMEOUT) end
  local client_pid = ffi.new("ULONG[1]")
  if K.GetNamedPipeClientProcessId(handle, client_pid) == 0 then
    failure("pipe-client-pid")
  end
  if tonumber(client_pid[0]) ~= tonumber(expected_pid) then
    failure("pipe-client-identity", WIN32.ERROR.ACCESS_DENIED)
  end
  local mode = ffi.new("DWORD[1]", bit.bor(WIN32.PIPE.READMODE_BYTE, WIN32.PIPE.WAIT))
  if K.SetNamedPipeHandleState(handle, mode, nil, nil) == 0 then
    failure("pipe-mode")
  end
end

local function open_client_pipe(name, access, expected_pid)
  local handle
  for _ = 1, 1000 do
    handle = K.CreateFileW(wide(name), access, 0, nil,
      WIN32.FILE.OPEN_EXISTING, WIN32.FILE.ATTRIBUTE_NORMAL, nil)
    if not invalid_handle(handle) then break end
    local err = last_error()
    if err ~= WIN32.ERROR.PIPE_BUSY and err ~= WIN32.ERROR.FILE_NOT_FOUND then
      failure("pipe-open", err)
    end
    K.WaitNamedPipeW(wide(name), 10)
  end
  if invalid_handle(handle) then failure("pipe-open-timeout", WIN32.WAIT.TIMEOUT) end
  local server_pid = ffi.new("ULONG[1]")
  if K.GetNamedPipeServerProcessId(handle, server_pid) == 0 then
    close_handle(handle)
    failure("pipe-server-pid")
  end
  if tonumber(server_pid[0]) ~= expected_pid then
    close_handle(handle)
    failure("pipe-server-identity", WIN32.ERROR.ACCESS_DENIED)
  end
  return handle
end

local function runner_argv(spec, input_pipe, output_pipe, host_pid,
    account_sid_string, capability_sid_string)
  local argv = vim.deepcopy(spec.runner.argv)
  if spec.runner.version ~= "script" then
    failure("runner-version", 0)
  end
  vim.list_extend(argv, {
    "--headless", "-u", "NONE", "-i", "NONE", "-n",
    "-l", spec.runner.script,
  })
  vim.list_extend(argv, {
    "--",
    "--runner",
    input_pipe,
    output_pipe,
    tostring(host_pid),
    account_sid_string,
    capability_sid_string,
  })
  return argv
end

-- The host logs on the selected account and starts a suspended runner. It
-- assigns the runner job before resuming the thread, then completes the
-- identity-checked named-pipe handshake.
local function spawn_runner(spec, account, password, capability_sid_string)
  local suffix = random_hex(16)
  local input_name = "\\\\.\\pipe\\neoagent-sandbox-" .. suffix .. "-in"
  local output_name = "\\\\.\\pipe\\neoagent-sandbox-" .. suffix .. "-out"
  local input = create_server_pipe(
    input_name, WIN32.PIPE.ACCESS_OUTBOUND, account.sid)
  -- The host reads output events, while SetNamedPipeHandleState also needs
  -- GENERIC_WRITE to change the server handle from polling to blocking mode.
  -- The runner opens this endpoint with GENERIC_WRITE only, and the pipe DACL
  -- plus client-PID check retain the protocol boundary.
  local output = create_server_pipe(
    output_name, WIN32.PIPE.ACCESS_DUPLEX, account.sid)
  local host_pid = tonumber(K.GetCurrentProcessId())
  local argv = runner_argv(spec, input_name, output_name, host_pid,
    account.sid, capability_sid_string)
  local command = wide_mutable(command_line(argv))
  local executable = wide(argv[1])
  local username = wide(account.name)
  local domain = wide(".")
  local encoded_password = wide(password)
  -- CI and user installations may keep Neovim below a private user profile.
  -- The requested cwd has an explicit runtime ACL, so the sandbox account can
  -- enter it when CreateProcessWithLogonW starts the runner.
  local cwd = wide(spec.cwd)
  local startup = ffi.new("STARTUPINFOW")
  startup.cb = ffi.sizeof(startup)
  local process = ffi.new("PROCESS_INFORMATION")
  local flags = bit.bor(
    WIN32.PROCESS.CREATE_NO_WINDOW, WIN32.PROCESS.CREATE_UNICODE_ENVIRONMENT,
    WIN32.PROCESS.CREATE_SUSPENDED)
  if A.CreateProcessWithLogonW(username, domain, encoded_password, 0,
      executable, command, flags, nil, cwd, startup, process) == 0 then
    close_handle(input)
    close_handle(output)
    failure("runner-logon")
  end
  local job = create_job("runner-job")
  local ok, err = pcall(function()
    assign_job(job, process.hProcess, "runner-job")
    if K.ResumeThread(process.hThread) == 0xffffffff then
      failure("runner-resume")
    end
    close_handle(process.hThread)
    process.hThread = nil
    connect_server_pipe(input, process.dwProcessId, process.hProcess)
    connect_server_pipe(output, process.dwProcessId, process.hProcess)
  end)
  if not ok then
    K.TerminateProcess(process.hProcess, 125)
    close_handle(process.hThread)
    close_handle(process.hProcess)
    close_handle(input)
    close_handle(output)
    close_handle(job)
    error(err, 0)
  end
  return {
    input = input,
    output = output,
    process = process.hProcess,
    job = job,
  }
end

local function close_runner(runner, terminate)
  if not runner then return end
  if terminate and not invalid_handle(runner.job) then
    K.TerminateJobObject(runner.job, 125)
  end
  if not invalid_handle(runner.input) then
    K.DisconnectNamedPipe(runner.input)
  end
  if not invalid_handle(runner.output) then
    K.DisconnectNamedPipe(runner.output)
  end
  close_handle(runner.input)
  close_handle(runner.output)
  close_handle(runner.process)
  close_handle(runner.job)
end

local function set_default_dacl(token, sids)
  local entries = ffi.new("EXPLICIT_ACCESS_W[?]", #sids)
  for index, sid in ipairs(sids) do
    entries[index - 1] = explicit_access(
      sid, WIN32.ACCESS.GENERIC_ALL, WIN32.SECURITY.GRANT_ACCESS, 0)
  end
  local acl = ffi.new("ACL *[1]")
  local code = A.SetEntriesInAclW(#sids, entries, nil, acl)
  if code ~= WIN32.ERROR.SUCCESS then failure("token-dacl", code) end
  local value = ffi.new("TOKEN_DEFAULT_DACL")
  value.DefaultDacl = acl[0]
  local ok = A.SetTokenInformation(
    token, WIN32.TOKEN.DEFAULT_DACL_CLASS, value, ffi.sizeof(value))
  K.LocalFree(acl[0])
  if ok == 0 then failure("token-dacl") end
end

local function enable_privilege(token, name)
  local luid = ffi.new("LUID")
  if A.LookupPrivilegeValueW(nil, wide(name), luid) == 0 then
    failure("token-privilege-lookup")
  end
  local privileges = ffi.new("TOKEN_PRIVILEGES")
  privileges.PrivilegeCount = 1
  privileges.Privileges[0].Luid = luid
  privileges.Privileges[0].Attributes = WIN32.SECURITY.PRIVILEGE_ENABLED
  K.SetLastError(WIN32.ERROR.SUCCESS)
  if A.AdjustTokenPrivileges(
      token, 0, privileges, ffi.sizeof(privileges), nil, nil) == 0 then
    failure("token-privilege")
  end
  local err = last_error()
  if err ~= WIN32.ERROR.SUCCESS then failure("token-privilege", err) end
end

-- Restricted target identity -------------------------------------------------
--
-- CreateRestrictedToken removes privileges and adds a restricting SID set.
-- Windows access checks must then satisfy the token's ordinary identity and
-- its restricting identities. The account, per-request capability, logon SID,
-- and Everyone SID preserve required runtime access while ACLs constrain file
-- mutations.
local function restricted_token(account_sid_string, capability_sid_string)
  local base = current_token()
  local account = sid_from_string(account_sid_string)
  local capability = sid_from_string(capability_sid_string)
  local everyone = sid_from_string("S-1-1-0")
  local logon, logon_storage = token_logon_sid(base)
  local logon_sid_string = sid_string(logon)
  -- A restricted-token access check also evaluates its restricting SID set.
  -- The logon and Everyone SIDs preserve ordinary Windows runtime objects,
  -- while the capability and account SIDs retain filesystem policy identity.
  -- This is the same token composition used by Codex's elevated Windows
  -- command runner.
  local restricting = ffi.new("SID_AND_ATTRIBUTES[4]")
  restricting[0].Sid = capability
  restricting[0].Attributes = 0
  restricting[1].Sid = account
  restricting[1].Attributes = 0
  restricting[2].Sid = logon
  restricting[2].Attributes = 0
  restricting[3].Sid = everyone
  restricting[3].Attributes = 0
  local result = ffi.new("HANDLE[1]")
  local ok = A.CreateRestrictedToken(base,
    bit.bor(
      WIN32.TOKEN.DISABLE_MAX_PRIVILEGE,
      WIN32.TOKEN.LUA,
      WIN32.TOKEN.WRITE_RESTRICTED),
    0, nil, 0, nil, 4, restricting, result)
  close_handle(base)
  if ok == 0 then
    K.LocalFree(account)
    K.LocalFree(capability)
    K.LocalFree(everyone)
    failure("restricted-token")
  end
  local configured, err = pcall(function()
    -- Identity-only account restrictions stay out of the default DACL.
    -- Logon, Everyone, and capability SIDs let child IPC objects satisfy
    -- both the ordinary and restricted access checks.
    set_default_dacl(result[0], { logon, everyone, capability })
    enable_privilege(result[0], "SeChangeNotifyPrivilege")
  end)
  logon_storage = logon_storage
  K.LocalFree(account)
  K.LocalFree(capability)
  K.LocalFree(everyone)
  if not configured then
    close_handle(result[0])
    error(err, 0)
  end
  return result[0], logon_sid_string
end

local function user_object_name(handle)
  local needed = ffi.new("DWORD[1]")
  U.GetUserObjectInformationW(handle, WIN32.DESKTOP.NAME, nil, 0, needed)
  if needed[0] <= ffi.sizeof("WCHAR") then
    failure("window-station-name")
  end
  local buffer = ffi.new("BYTE[?]", tonumber(needed[0]))
  if U.GetUserObjectInformationW(
      handle, WIN32.DESKTOP.NAME, buffer, needed[0], needed) == 0 then
    failure("window-station-name")
  end
  return utf8(ffi.cast("WCHAR *", buffer))
end

local function close_private_desktop(value)
  if not value then return end
  if not invalid_handle(value.desktop) then U.CloseDesktop(value.desktop) end
end

-- A private desktop gives GUI-aware libraries a valid windowing namespace
-- while the process remains headless. Access is limited to the logon identity
-- and Windows administrative identities.
local function private_desktop(logon_sid_string)
  local station = U.GetProcessWindowStation()
  if invalid_handle(station) then failure("window-station") end
  local station_name = user_object_name(station)
  local descriptor = security_descriptor(string.format(
    "D:P(A;;GA;;;%s)(A;;GA;;;SY)(A;;GA;;;BA)", logon_sid_string))
  local attributes = ffi.new("SECURITY_ATTRIBUTES")
  attributes.nLength = ffi.sizeof(attributes)
  attributes.lpSecurityDescriptor = descriptor
  attributes.bInheritHandle = 0
  -- Explicit lpDesktop access lets restricted-token console programs,
  -- including PowerShell, complete DLL initialization. The logon SID appears
  -- in both the token's ordinary groups and restricting SID set, and already
  -- owns the runner's current window-station connection.
  local desktop_name = "NeoagentSandbox-" .. random_hex(12)
  local desktop = U.CreateDesktopW(
    wide(desktop_name), nil, nil, 0, WIN32.DESKTOP.ALL_ACCESS, attributes)
  K.LocalFree(descriptor)
  if invalid_handle(desktop) then failure("desktop-create") end
  return {
    desktop = desktop,
    name = wide(station_name .. "\\" .. desktop_name),
  }
end

-- Target execution -----------------------------------------------------------
--
-- Target output becomes ordered protocol events. stdin uses a delete-on-close
-- disk file, which gives programs a seekable standard input handle. stdout and
-- stderr use anonymous pipes that the runner drains while watching the process
-- and its deadline.
local function send_event(handle, event)
  local ok, err = write_frame(handle, event)
  if not ok then failure("protocol-write", err) end
end

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

local function inheritable_attributes()
  local attributes = ffi.new("SECURITY_ATTRIBUTES")
  attributes.nLength = ffi.sizeof(attributes)
  attributes.lpSecurityDescriptor = nil
  attributes.bInheritHandle = 1
  return attributes
end

local function set_inherit(handle, enabled)
  if K.SetHandleInformation(handle, WIN32.HANDLE.INHERIT,
      enabled and WIN32.HANDLE.INHERIT or 0) == 0 then
    failure("handle-inheritance")
  end
end

local function create_output_pipe()
  local read_end = ffi.new("HANDLE[1]")
  local write_end = ffi.new("HANDLE[1]")
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

local function command_file(directory, argv, command_index)
  if not command_index or command_index == #argv then return nil end
  local command = {}
  for index = command_index + 1, #argv do
    command[#command + 1] = argv[index]
  end
  local path = vim.fs.joinpath(
    directory, "neoagent-command-" .. random_hex(12) .. ".cmd")
  local handle = K.CreateFileW(wide(path), WIN32.ACCESS.GENERIC_WRITE,
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_DELETE),
    nil, WIN32.FILE.CREATE_NEW, WIN32.FILE.ATTRIBUTE_TEMPORARY, nil)
  if invalid_handle(handle) then failure("command-file-create") end
  -- cmd.exe reads its command language from this file, so argv boundaries
  -- before /c or /k remain process arguments and the complete tail retains
  -- cmd syntax. Echo stays disabled until the requested command changes it.
  local data = "@echo off\r\n" .. table.concat(command, " ") .. "\r\n"
  local ok, err = write_all(handle, data)
  if ok and K.FlushFileBuffers(handle) == 0 then
    ok, err = nil, last_error()
  end
  close_handle(handle)
  if not ok then
    K.DeleteFileW(wide(path))
    failure("command-file-write", err)
  end
  return path
end

local function stdin_file(directory, data)
  local path = vim.fs.joinpath(
    directory, "neoagent-stdin-" .. random_hex(12) .. ".tmp")
  local handle = K.CreateFileW(wide(path),
    bit.bor(WIN32.ACCESS.GENERIC_READ, WIN32.ACCESS.GENERIC_WRITE),
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_DELETE),
    inheritable_attributes(), WIN32.FILE.CREATE_NEW,
    bit.bor(WIN32.FILE.ATTRIBUTE_TEMPORARY, WIN32.FILE.FLAG_DELETE_ON_CLOSE), nil)
  if invalid_handle(handle) then failure("stdin-file") end
  local ok, err = write_all(handle, data)
  if not ok then
    close_handle(handle)
    failure("stdin-write", err)
  end
  if K.SetFilePointerEx(handle, 0, nil, WIN32.FILE.BEGIN) == 0 then
    close_handle(handle)
    failure("stdin-rewind")
  end
  set_inherit(handle, true)
  return handle
end

local function pipe_available(handle)
  local available = ffi.new("DWORD[1]")
  if K.PeekNamedPipe(handle, nil, 0, nil, available, nil) == 0 then
    local err = last_error()
    if err == WIN32.ERROR.BROKEN_PIPE or err == WIN32.ERROR.NO_DATA then
      return nil
    end
    failure("output-peek", err)
  end
  return tonumber(available[0])
end

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

-- The target starts with the restricted primary token, explicit environment
-- and cwd, private desktop, standard handles, and target job already attached.
-- The runner applies the deadline to the whole job, drains both output pipes,
-- and reports one terminal status after descendants release their writers.
local function spawn_target(spec, stdin, output_handle, token,
    logon_sid_string)
  local stdin_handle = stdin_file(spec.temp_root, stdin)
  local stdout_read, stdout_write = create_output_pipe()
  local stderr_read, stderr_write = create_output_pipe()
  local command_index = cmd_command_index(spec.argv)
  local command_path = command_file(spec.temp_root, spec.argv, command_index)
  local desktop = private_desktop(logon_sid_string)
  local job = create_job("target-job")
  local attributes = target_process_attributes(
    job, stdin_handle, stdout_write, stderr_write)
  local startup = ffi.new("STARTUPINFOEXW")
  startup.StartupInfo.cb = ffi.sizeof(startup)
  startup.StartupInfo.dwFlags = WIN32.PROCESS.STARTF_USESTDHANDLES
  startup.StartupInfo.hStdInput = stdin_handle
  startup.StartupInfo.hStdOutput = stdout_write
  startup.StartupInfo.hStdError = stderr_write
  startup.StartupInfo.lpDesktop = desktop.name
  startup.lpAttributeList = attributes.list
  local process = ffi.new("PROCESS_INFORMATION")
  local command_text =
    target_command_line(spec.argv, command_index, command_path)
  local command = wide_mutable(command_text)
  local executable = wide(spec.argv[1])
  local cwd = wide(spec.cwd)
  local environment = utf16_block(spec.env)
  -- The account runner and target remain headless. Explicit standard handles
  -- carry process I/O without allocating a console on the private desktop.
  local flags = bit.bor(
    WIN32.PROCESS.CREATE_NO_WINDOW, WIN32.PROCESS.CREATE_UNICODE_ENVIRONMENT,
    WIN32.PROCESS.EXTENDED_STARTUPINFO_PRESENT)
  local ok = A.CreateProcessAsUserW(token, executable, command,
    nil, nil, 1, flags, environment, cwd, startup.StartupInfo, process)
  K.DeleteProcThreadAttributeList(attributes.list)
  attributes.list = nil
  close_handle(stdout_write)
  close_handle(stderr_write)
  if ok == 0 then
    close_handle(stdin_handle)
    close_handle(stdout_read)
    close_handle(stderr_read)
    if command_path then K.DeleteFileW(wide(command_path)) end
    close_handle(job)
    close_private_desktop(desktop)
    failure("target-create")
  end
  close_handle(process.hThread)
  close_handle(stdin_handle)
  send_event(output_handle, {
    v = RUNTIME.PROTOCOL_VERSION,
    type = "ready",
  })
  local output = output_sender(output_handle)
  local stdout_open, stderr_open = true, true
  local deadline = spec.timeout_ms
      and tonumber(K.GetTickCount64()) + spec.timeout_ms or nil
  local timed_out = false
  local process_status = K.WaitForSingleObject(process.hProcess, 0)
  while process_status == WIN32.WAIT.TIMEOUT do
    if stdout_open then
      stdout_open = drain_pipe(stdout_read, "stdout", output)
    end
    if stderr_open then
      stderr_open = drain_pipe(stderr_read, "stderr", output)
    end
    if deadline and tonumber(K.GetTickCount64()) >= deadline then
      process_status = K.WaitForSingleObject(process.hProcess, 0)
      if process_status == WIN32.WAIT.TIMEOUT then
        timed_out = true
        break
      end
    end
    K.Sleep(RUNTIME.OUTPUT_POLL_MS)
    process_status = K.WaitForSingleObject(process.hProcess, 0)
  end
  if process_status ~= WIN32.WAIT.OBJECT_0
      and process_status ~= WIN32.WAIT.TIMEOUT then
    failure("target-wait", process_status)
  end
  -- The runner owns this job and applies its deadline to the complete target
  -- tree. Job termination also releases every inherited output writer.
  if K.TerminateJobObject(job, timed_out and 124 or 0) == 0 then
    failure("target-job-stop")
  end
  if K.WaitForSingleObject(process.hProcess, RUNTIME.PROCESS_SHUTDOWN_MS)
      ~= WIN32.WAIT.OBJECT_0 then
    failure("target-process-stop")
  end
  -- PeekNamedPipe bounds every read to buffered data and reports closure once
  -- the stopped job releases all inherited write ends.
  for _ = 1, RUNTIME.OUTPUT_DRAIN_POLLS do
    if stdout_open then
      stdout_open = drain_pipe(stdout_read, "stdout", output)
    end
    if stderr_open then
      stderr_open = drain_pipe(stderr_read, "stderr", output)
    end
    if not stdout_open and not stderr_open then break end
    K.Sleep(1)
  end
  if stdout_open or stderr_open then failure("output-drain-timeout") end
  local exit_code = ffi.new("DWORD[1]")
  if K.GetExitCodeProcess(process.hProcess, exit_code) == 0 then
    failure("target-status")
  end
  close_handle(stdout_read)
  close_handle(stderr_read)
  if command_path then K.DeleteFileW(wide(command_path)) end
  close_handle(process.hProcess)
  close_handle(job)
  close_private_desktop(desktop)
  send_event(output_handle, {
    v = RUNTIME.PROTOCOL_VERSION,
    type = "exit",
    code = tonumber(exit_code[0]),
    signal = 0,
    timed_out = timed_out,
  })
end

-- Built-in filesystem operations run inside the runner while impersonating the
-- same restricted token used for target commands. This keeps their access
-- checks identical without starting a separate command process.
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

local function file_attributes(path)
  local value = tonumber(K.GetFileAttributesW(wide(path)))
  if value == WIN32.FILE.INVALID_ATTRIBUTES then return nil, last_error() end
  return value
end

local function direct_read(path)
  local handle = K.CreateFileW(wide(path), WIN32.ACCESS.GENERIC_READ,
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_WRITE, WIN32.FILE.SHARE_DELETE),
    nil, WIN32.FILE.OPEN_EXISTING, WIN32.FILE.ATTRIBUTE_NORMAL, nil)
  if invalid_handle(handle) then return nil, last_error() end
  if K.GetFileType(handle) ~= WIN32.FILE.TYPE_DISK then
    close_handle(handle)
    return nil, WIN32.ERROR.ACCESS_DENIED
  end
  local length = ffi.new("LONGLONG[1]")
  if K.GetFileSizeEx(handle, length) == 0 then
    local err = last_error()
    close_handle(handle)
    return nil, err
  end
  local size = tonumber(length[0])
  if size > 64 * 1024 * 1024 then
    close_handle(handle)
    return nil, 223
  end
  local chunks, remaining = {}, size
  while remaining > 0 do
    local chunk, err = read_some(handle, math.min(remaining, 65536))
    if not chunk then
      close_handle(handle)
      return nil, err
    end
    if chunk == "" then break end
    chunks[#chunks + 1] = chunk
    remaining = remaining - #chunk
  end
  close_handle(handle)
  return table.concat(chunks)
end

local function content_fingerprint(data)
  local seeds = {
    0x811c9dc5, 0x9e3779b9, 0x85ebca6b, 0xc2b2ae35,
    0x27d4eb2f, 0x165667b1, 0xd3a2646c, 0xfd7046c5,
  }
  local parts = {}
  for index, seed in ipairs(seeds) do
    local hash = bit.tobit(seed)
    for offset = 1, #data do
      hash = bit.bxor(hash, data:byte(offset) + index - 1)
      hash = bit.tobit(hash + bit.lshift(hash, 1)
        + bit.lshift(hash, 4) + bit.lshift(hash, 7)
        + bit.lshift(hash, 8) + bit.lshift(hash, 24))
      hash = bit.bxor(hash, bit.rshift(hash, 13))
    end
    parts[index] = bit.tohex(hash, 8)
  end
  return table.concat(parts)
end

local function direct_write(path, data, flags)
  local disposition, append = WIN32.FILE.CREATE_ALWAYS, false
  if flags == "a" then
    disposition, append = WIN32.FILE.OPEN_ALWAYS, true
  elseif flags == "wx" then
    disposition = WIN32.FILE.CREATE_NEW
  elseif flags ~= nil and flags ~= "w" then
    return nil, 87
  end
  local handle = K.CreateFileW(wide(path),
    bit.bor(WIN32.ACCESS.GENERIC_READ, WIN32.ACCESS.GENERIC_WRITE),
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_DELETE),
    nil, disposition, WIN32.FILE.ATTRIBUTE_NORMAL, nil)
  if invalid_handle(handle) then return nil, last_error() end
  if append and K.SetFilePointerEx(handle, 0, nil, WIN32.FILE.END_) == 0 then
    local err = last_error()
    close_handle(handle)
    return nil, err
  end
  local ok, err = write_all(handle, data)
  if ok and K.FlushFileBuffers(handle) == 0 then
    ok, err = nil, last_error()
  end
  close_handle(handle)
  return ok, err
end

local function direct_atomic_replace(path, data, policy, suffix)
  if type(policy) ~= "table" or vim.islist(policy)
      or policy.mode == nil and policy.preserve_mode ~= true
      or policy.preserve_mode == true and policy.new_mode == nil
      or policy.expected_content_fingerprint ~= nil
        and (type(policy.expected_content_fingerprint) ~= "string"
          or not policy.expected_content_fingerprint:match("^" .. string.rep("%x", 64) .. "$"))
      or type(suffix) ~= "string" or #suffix ~= 32
      or suffix:find("[^%x]") then
    return nil, WIN32.ERROR.INVALID_PARAMETER
  end
  local attributes, attributes_err = file_attributes(path)
  local target_identity
  if attributes then
    if bit.band(attributes, WIN32.FILE.ATTRIBUTE_REPARSE_POINT) ~= 0
        or bit.band(attributes, WIN32.FILE.ATTRIBUTE_DIRECTORY) ~= 0 then
      return nil, WIN32.ERROR.ACCESS_DENIED
    end
    target_identity, attributes_err = path_identity(path)
    if not target_identity then return nil, attributes_err end
  elseif attributes_err ~= WIN32.ERROR.FILE_NOT_FOUND
      and attributes_err ~= WIN32.ERROR.PATH_NOT_FOUND then
    return nil, attributes_err
  elseif policy.require_existing then
    return nil, WIN32.ERROR.FILE_NOT_FOUND
  end

  local temporary = path .. "." .. suffix .. ".tmp"
  local written, write_err = direct_write(temporary, data, "wx")
  if not written then
    K.DeleteFileW(wide(temporary))
    return nil, write_err
  end
  local current, current_err = file_attributes(path)
  local current_identity
  if current then
    if bit.band(current, WIN32.FILE.ATTRIBUTE_REPARSE_POINT) ~= 0
        or bit.band(current, WIN32.FILE.ATTRIBUTE_DIRECTORY) ~= 0 then
      K.DeleteFileW(wide(temporary))
      return nil, WIN32.ERROR.ACCESS_DENIED
    end
    current_identity, current_err = path_identity(path)
    if not current_identity then
      K.DeleteFileW(wide(temporary))
      return nil, current_err
    end
  elseif current_err ~= WIN32.ERROR.FILE_NOT_FOUND
      and current_err ~= WIN32.ERROR.PATH_NOT_FOUND then
    K.DeleteFileW(wide(temporary))
    return nil, current_err
  elseif policy.require_existing then
    K.DeleteFileW(wide(temporary))
    return nil, WIN32.ERROR.FILE_NOT_FOUND
  end
  local changed = attributes ~= current
    or attributes ~= nil and not same_identity(target_identity, current_identity)
  if changed then
    K.DeleteFileW(wide(temporary))
    return nil, WIN32.ERROR.ACCESS_DENIED
  end
  if policy.expected_content_fingerprint ~= nil then
    if not target_identity then
      K.DeleteFileW(wide(temporary))
      return nil, WIN32.ERROR.FILE_NOT_FOUND
    end
    local contents, read_err = direct_read(path)
    local latest, identity_err = path_identity(path)
    if not contents or not same_identity(target_identity, latest) then
      K.DeleteFileW(wide(temporary))
      return nil, read_err or identity_err or WIN32.ERROR.ACCESS_DENIED
    end
    if content_fingerprint(contents):lower()
        ~= policy.expected_content_fingerprint:lower() then
      K.DeleteFileW(wide(temporary))
      return nil, WIN32.ERROR.ACCESS_DENIED
    end
  end
  if K.MoveFileExW(wide(temporary), wide(path),
      bit.bor(WIN32.FILE.MOVE_REPLACE_EXISTING,
        WIN32.FILE.MOVE_WRITE_THROUGH)) == 0 then
    local err = last_error()
    K.DeleteFileW(wide(temporary))
    return nil, err
  end
  return true
end

local function direct_mkdirp(path)
  local existing, existing_err = file_attributes(path)
  if existing then
    return bit.band(existing, WIN32.FILE.ATTRIBUTE_DIRECTORY) ~= 0
        and true or nil, WIN32.ERROR.ALREADY_EXISTS
  end
  if existing_err ~= WIN32.ERROR.FILE_NOT_FOUND
      and existing_err ~= WIN32.ERROR.PATH_NOT_FOUND then
    return nil, existing_err
  end
  local missing = {}
  local current = path
  while true do
    local attributes, err = file_attributes(current)
    if attributes then
      if bit.band(attributes, WIN32.FILE.ATTRIBUTE_DIRECTORY) == 0 then
        return nil, WIN32.ERROR.ALREADY_EXISTS
      end
      break
    end
    if err ~= WIN32.ERROR.FILE_NOT_FOUND and err ~= WIN32.ERROR.PATH_NOT_FOUND then
      return nil, err
    end
    missing[#missing + 1] = current
    local parent = vim.fs.dirname(current)
    if parent == current or parent == "." or parent == "" then
      return nil, WIN32.ERROR.PATH_NOT_FOUND
    end
    current = parent
  end
  for index = #missing, 1, -1 do
    if K.CreateDirectoryW(wide(missing[index]), nil) == 0 then
      local err = last_error()
      if err ~= WIN32.ERROR.ALREADY_EXISTS then return nil, err end
    end
  end
  return true
end

local function fs_operation(spec, stdin, output_handle, token)
  local operation = spec.fs.operation
  local value, err = with_impersonation(token, function()
    if operation == "read" then
      return direct_read(spec.fs.path)
    elseif operation == "write_all" then
      return direct_write(spec.fs.path, stdin, spec.fs.flags)
    elseif operation == "atomic_replace" then
      return direct_atomic_replace(
        spec.fs.path, stdin, spec.fs.policy, spec.fs.suffix)
    else
      return direct_mkdirp(spec.fs.path)
    end
  end)
  send_event(output_handle, {
    v = RUNTIME.PROTOCOL_VERSION,
    type = "ready",
  })
  local output = output_sender(output_handle)
  if value then
    if operation == "read" then output("stdout", value) end
    send_event(output_handle, {
      v = RUNTIME.PROTOCOL_VERSION,
      type = "exit",
      code = 0,
      signal = 0,
    })
  else
    output("stderr", "win32=" .. tostring(err or 0))
    send_event(output_handle, {
      v = RUNTIME.PROTOCOL_VERSION,
      type = "exit",
      code = 1,
      signal = 0,
    })
  end
end

-- Probe mode checks observable sandbox behavior. Filesystem checks execute
-- under the restricted token, and the offline account verifies that WFP rejects
-- even a loopback connection attempt.
local function network_is_blocked()
  local data = ffi.new("WSADATA")
  local code = W.WSAStartup(0x0202, data)
  if code ~= 0 then failure("winsock-startup", code) end
  local socket = W.socket(WIN32.SOCKET.AF_INET, WIN32.SOCKET.STREAM, WIN32.SOCKET.TCP)
  if socket == WIN32.SOCKET.INVALID then
    local err = W.WSAGetLastError()
    W.WSACleanup()
    failure("winsock-socket", err)
  end
  local address = ffi.new("SOCKADDR_IN")
  address.sin_family = WIN32.SOCKET.AF_INET
  address.sin_port = W.htons(9)
  address.sin_addr.s_addr = 0x0100007f
  local connected = W.connect(socket, address, ffi.sizeof(address))
  local err = connected == 0 and 0 or W.WSAGetLastError()
  W.closesocket(socket)
  W.WSACleanup()
  return connected ~= 0 and err == WIN32.ERROR.WSA_ACCESS_DENIED
end

local function open_probe(path, access, flags)
  local handle = K.CreateFileW(wide(path), access,
    bit.bor(WIN32.FILE.SHARE_READ, WIN32.FILE.SHARE_WRITE, WIN32.FILE.SHARE_DELETE),
    nil, WIN32.FILE.OPEN_EXISTING, flags or WIN32.FILE.ATTRIBUTE_NORMAL, nil)
  if invalid_handle(handle) then return nil, last_error() end
  close_handle(handle)
  return true
end

local function run_probe(spec, output_handle, token)
  if type(spec.probe) ~= "table"
      or type(spec.probe.write) ~= "string"
      or type(spec.probe.deny_write) ~= "string"
      or type(spec.probe.deny_read) ~= "string" then
    failure("probe-specification", 0)
  end
  local ok, stage, code = with_impersonation(token, function()
    local written, write_err = direct_write(spec.probe.write, "probe", "wx")
    if not written then return nil, "probe-write", write_err end
    K.DeleteFileW(wide(spec.probe.write))
    local denied_write, denied_write_err =
      direct_write(spec.probe.deny_write, "probe", "w")
    if denied_write or denied_write_err ~= WIN32.ERROR.ACCESS_DENIED then
      return nil, "probe-deny-write", denied_write_err or 0
    end
    local denied_read, denied_read_err = open_probe(
      spec.probe.deny_read, WIN32.ACCESS.GENERIC_READ, WIN32.FILE.FLAG_BACKUP_SEMANTICS)
    if denied_read or denied_read_err ~= WIN32.ERROR.ACCESS_DENIED then
      return nil, "probe-deny-read", denied_read_err or 0
    end
    return true
  end)
  if not ok then failure(stage, code) end
  if spec.profile.network == "restricted" and not network_is_blocked() then
    failure("probe-network", 0)
  end
  send_event(output_handle, {
    v = RUNTIME.PROTOCOL_VERSION,
    type = "ready",
  })
  send_event(output_handle, {
    v = RUNTIME.PROTOCOL_VERSION,
    type = "exit",
    code = 0,
    signal = 0,
  })
end

-- Account runner -------------------------------------------------------------
--
-- The runner verifies its account SID and the named-pipe server PID, receives
-- the complete request and stdin stream, builds the restricted token, and owns
-- execution until one terminal event is sent.
local function runner_main(arguments)
  if #arguments ~= 6 then failure("runner-arguments", 0) end
  local input_name, output_name = arguments[2], arguments[3]
  local host_pid = tonumber(arguments[4])
  local account_sid_string, capability_sid_string =
    arguments[5], arguments[6]
  if not host_pid or current_user_sid_string() ~= account_sid_string then
    failure("runner-identity", WIN32.ERROR.ACCESS_DENIED)
  end
  local input = open_client_pipe(input_name, WIN32.ACCESS.GENERIC_READ, host_pid)
  local output = open_client_pipe(output_name, WIN32.ACCESS.GENERIC_WRITE, host_pid)
  local request, request_err = read_frame(input)
  if not request then
    close_handle(input)
    close_handle(output)
    failure("protocol-request", request_err)
  end
  local stdin_chunks = {}
  while true do
    local event, event_err = read_frame(input)
    if not event then
      close_handle(input)
      close_handle(output)
      failure("protocol-stdin", event_err)
    end
    if event.type == "stdin" and type(event.data) == "string" then
      stdin_chunks[#stdin_chunks + 1] = event.data
    elseif event.type == "stdin-end" then
      break
    else
      close_handle(input)
      close_handle(output)
      failure("protocol-stdin", 0)
    end
  end
  close_handle(input)
  if request.v ~= RUNTIME.PROTOCOL_VERSION
      or type(request.spec) ~= "table" then
    close_handle(output)
    failure("protocol-request", 0)
  end
  local token, logon_sid_string =
    restricted_token(account_sid_string, capability_sid_string)
  local stdin = table.concat(stdin_chunks)
  local ok, err = pcall(function()
    if request.spec.mode == "exec" then
      spawn_target(request.spec, stdin, output, token, logon_sid_string)
    elseif request.spec.mode == "fs" then
      fs_operation(request.spec, stdin, output, token)
    elseif request.spec.mode == "probe" then
      run_probe(request.spec, output, token)
    else
      failure("runner-mode", 0)
    end
  end)
  if not ok then emit_error(output, err) end
  close_handle(token)
  close_handle(output)
  if not ok then os.exit(125) end
end

-- Host runtime ---------------------------------------------------------------
--
-- The host bridges Neoagent's stdio protocol to the account runner. Request
-- data and stdin flow toward the runner; ready, output, and terminal events flow
-- back unchanged.
local function send_request(runner, spec, stdin)
  local ok, err = write_frame(runner.input, {
    v = RUNTIME.PROTOCOL_VERSION,
    spec = spec,
  })
  if not ok then failure("protocol-request-write", err) end
  local offset = 1
  while offset <= #stdin do
    local chunk = stdin:sub(offset, offset + 65535)
    ok, err = write_frame(runner.input, {
      v = RUNTIME.PROTOCOL_VERSION,
      type = "stdin",
      data = chunk,
    })
    if not ok then failure("protocol-stdin-write", err) end
    offset = offset + #chunk
  end
  ok, err = write_frame(runner.input, {
    v = RUNTIME.PROTOCOL_VERSION,
    type = "stdin-end",
  })
  if not ok then failure("protocol-stdin-write", err) end
  close_handle(runner.input)
  runner.input = nil
end

local function receive_events(runner)
  local terminal
  while not terminal do
    local event, err = read_frame(runner.output)
    if not event then failure("protocol-runner-read", err) end
    if event.v ~= RUNTIME.PROTOCOL_VERSION
        or event.type ~= "ready" and event.type ~= "output"
          and event.type ~= "exit" and event.type ~= "error" then
      failure("protocol-runner-event", 0)
    end
    if event.type == "ready" then
      if terminal then failure("protocol-runner-order", 0) end
      stdout_frame(event)
    elseif event.type == "output" then
      if event.stream ~= "stdout" and event.stream ~= "stderr"
          or type(event.seq) ~= "number"
          or type(event.data) ~= "string" then
        failure("protocol-runner-output", 0)
      end
      stdout_frame(event)
    else
      terminal = event
    end
  end
  return terminal
end

-- The host holds the state mutex for the entire ACL lease. Its protected call
-- records recovery, applies ACLs, launches the runner, and receives the result.
-- Cleanup runs after success or failure before the terminal event is emitted.
local function host_main(directory)
  local encoded = vim.uv.os_getenv(
    "NEOAGENT_SANDBOX_SPEC", 1024 * 1024 + 1)
  vim.uv.os_unsetenv("NEOAGENT_SANDBOX_SPEC")
  if type(encoded) ~= "string" or #encoded > 1024 * 1024 then
    failure("specification-environment", 0)
  end
  local decoded, spec = pcall(vim.json.decode, encoded)
  if not decoded then failure("specification-json", 0) end
  local stdin = read_standard_input()
  local mutex = acquire_mutex(directory)
  local state, runner, terminal, state_owned
  local ok, err = pcall(function()
    state = decode_state(directory)
    if state.owner_sid ~= current_user_sid_string() then
      failure("state-owner", WIN32.ERROR.ACCESS_DENIED)
    end
    state_owned = true
    recovery_cleanup(state)
    encode_state(directory, state)
    spec = validate_spec(spec, directory)
    spec.temp_root = canonical_existing(
      vim.fs.joinpath(directory, "shared-tmp"), "temporary-root")
    local kind = spec.profile.network == "restricted"
        and "offline" or "online"
    local account = state.accounts[kind]
    local actual, sid_err = account_sid(account.name)
    if not actual or actual ~= account.sid then
      failure("account-identity", sid_err or WIN32.ERROR.ACCESS_DENIED)
    end
    local capability = capability_sid()
    state.recovery = {
      account_sid = account.sid,
      capability_sid = capability,
      paths = {},
      placeholders = {},
    }
    encode_state(directory, state)
    materialize_protected(directory, state, spec)
    apply_runtime_acls(directory, state, spec, account.sid, capability)
    runner = spawn_runner(
      spec, account, account_password(account), capability)
    send_request(runner, spec, stdin)
    terminal = receive_events(runner)
  end)
  close_runner(runner, true)
  local cleaned, cleanup_err = pcall(function()
    if state_owned then finish_runtime_acls(directory, state) end
  end)
  release_mutex(mutex)
  if not cleaned then error(cleanup_err, 0) end
  if not ok then error(err, 0) end
  stdout_frame(terminal)
end

local function default_state_directory()
  local configured = vim.uv.os_getenv("NEOAGENT_WINDOWS_SANDBOX_STATE")
  if type(configured) == "string" and configured ~= "" then
    return vim.fs.normalize(configured)
  end
  return vim.fs.joinpath(
    vim.fn.stdpath("state"), "neoagent", "windows-sandbox")
end

-- Entrypoint -----------------------------------------------------------------
--
-- Setup emits a small JSON result for the manual provisioning command. Host
-- and runner modes use the framed runtime protocol described above.
local arguments = {}
for index = 1, #arg do arguments[index] = arg[index] end
if arguments[1] == "--" then table.remove(arguments, 1) end

if jit.arch ~= "x64" then
  if arguments[1] == "--runner" then
    os.exit(125)
  end
  emit_error(nil, {
    sandbox_runtime_error = true,
    stage = "architecture",
    errno = 0,
  })
  os.exit(125)
end

local directory = default_state_directory()
if arguments[1] == "--setup" then
  local mutex
  local ok, err = pcall(function()
    mutex = acquire_mutex(directory)
    setup(directory)
  end)
  release_mutex(mutex)
  if not ok then
    local value = error_value(err, "setup")
    io.stderr:write(vim.json.encode({
      v = RUNTIME.PROTOCOL_VERSION,
      ok = false,
      stage = value.stage,
      errno = value.errno,
    }))
    os.exit(1)
  end
elseif arguments[1] == "--runner" then
  local ok = pcall(runner_main, arguments)
  if not ok then os.exit(125) end
else
  local ok, err = pcall(host_main, directory)
  if not ok then
    emit_error(nil, err)
    os.exit(125)
  end
end
