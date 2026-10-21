// 原始条目只通过结构化 API 读取；引擎不能自行决定写盘路径。
#include "CPP/Common/Common.h"
#include "CPP/Common/MyInitGuid.h"
#include "CPP/Common/MyCom.h"
#include "CPP/7zip/Archive/IArchive.h"
#include "CPP/7zip/IPassword.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <iostream>
#include <map>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#include <sys/stat.h>
#include <sys/mount.h>
#include <unistd.h>
#include <vector>

static void require(bool condition, const char *error) {
    if (!condition) throw std::runtime_error(error);
}
static std::string transcode(const void *bytes, size_t size, CFStringEncoding from, CFStringEncoding to) {
    CFStringRef string = CFStringCreateWithBytes(nullptr, (const UInt8 *)bytes, size, from, false);
    require(string != nullptr, "invalid_encoding");
    CFRange range = CFRangeMake(0, CFStringGetLength(string));
    CFIndex count = 0;
    CFStringGetBytes(string, range, to, 0, false, nullptr, 0, &count);
    std::string result((size_t)count, '\0');
    CFIndex converted = CFStringGetBytes(string, range, to, 0, false,
                                        (UInt8 *)result.data(), count, &count);
    CFRelease(string);
    require(converted == range.length, "invalid_encoding");
    return result;
}
static std::string utf8(const std::wstring &value) {
    return transcode(value.data(), value.size() * sizeof(wchar_t), kCFStringEncodingUTF32LE, kCFStringEncodingUTF8);
}
static std::wstring toWide(const std::string &value) {
    auto bytes = transcode(value.data(), value.size(), kCFStringEncodingUTF8, kCFStringEncodingUTF32LE);
    std::wstring result(bytes.size() / sizeof(wchar_t), L'\0');
    memcpy(result.data(), bytes.data(), bytes.size());
    return result;
}
static std::string json(const std::string &value) {
    std::ostringstream out;
    out << '"';
    const char hex[] = "0123456789abcdef";
    for (unsigned char c : value) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c < 32) out << "\\u00" << hex[c >> 4] << hex[c & 15];
        else out << c;
    }
    return out.str() + '"';
}
struct Property {
    PROPVARIANT value{};
    Property(IInArchive *archive, UInt32 index, PROPID key) {
        require(archive->GetProperty(index, key, &value) == S_OK, "invalid_property");
    }
    Property(IInArchive *archive, PROPID key) {
        require(archive->GetArchiveProperty(key, &value) == S_OK, "invalid_property");
    }
    ~Property() { VariantClear(&value); }
    bool present() const { return value.vt != VT_EMPTY; }
    std::string text() const {
        if (value.vt == VT_EMPTY) return "";
        require(value.vt == VT_BSTR, "invalid_property");
        return utf8(std::wstring(value.bstrVal, SysStringLen(value.bstrVal)));
    }
    uint64_t number() const {
        if (value.vt == VT_EMPTY) return 0;
        if (value.vt == VT_UI8) return value.uhVal.QuadPart;
        if (value.vt == VT_UI4) return value.ulVal;
        if (value.vt == VT_BOOL) return value.boolVal != 0;
        throw std::runtime_error("invalid_property");
    }
};

class Input final : public IInStream, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(ISequentialInStream, IInStream)
public:
    int fd;
    explicit Input(int descriptor) : fd(descriptor) {}
    ~Input() { close(fd); }
};
Z7_COM7F_IMF(Input::Read(void *data, UInt32 size, UInt32 *processed)) {
    ssize_t count;
    do { count = read(fd, data, size); } while (count < 0 && errno == EINTR);
    if (processed) *processed = count < 0 ? 0 : (UInt32)count;
    return count < 0 ? E_FAIL : S_OK;
}
Z7_COM7F_IMF(Input::Seek(Int64 offset, UInt32 origin, UInt64 *position)) {
    if (origin > 2) return E_INVALIDARG;
    off_t result = lseek(fd, offset, (int)origin);
    if (result < 0) return E_FAIL;
    if (position) *position = (UInt64)result;
    return S_OK;
}
class OpenCallback final : public IArchiveOpenCallback,
                           public ICryptoGetTextPassword, public IArchiveOpenVolumeCallback, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_3(IArchiveOpenCallback, ICryptoGetTextPassword, IArchiveOpenVolumeCallback)
public:
    std::wstring password;
    bool requested = false;
    int parent = -1;
    std::string name;
    uint64_t size = 0;
    uint64_t totalBytes = 0;
    std::set<std::string> opened;
    ~OpenCallback() { if (parent >= 0) close(parent); }
};
Z7_COM7F_IMF(OpenCallback::SetTotal(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(OpenCallback::SetCompleted(const UInt64 *, const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(OpenCallback::CryptoGetTextPassword(BSTR *value)) {
    requested = true;
    if (password.empty()) return E_ABORT;
    *value = SysAllocStringLen(password.data(), (UINT)password.size());
    return *value ? S_OK : E_OUTOFMEMORY;
}

static std::string volumeFamily(const std::string &name) {
    auto family = std::regex_replace(name, std::regex("\\.part[0-9]+\\.rar$", std::regex::icase), ".rar");
    family = std::regex_replace(family, std::regex("\\.r[0-9]+$", std::regex::icase), ".rar");
    family = std::regex_replace(family, std::regex("\\.z[0-9]+$", std::regex::icase), ".zip");
    return std::regex_replace(family, std::regex("\\.[0-9]{3,}$"), "");
}
Z7_COM7F_IMF(OpenCallback::GetProperty(PROPID key, PROPVARIANT *value)) {
    VariantClear(value);
    if (key == kpidName) {
        auto text = toWide(name);
        value->vt = VT_BSTR;
        value->bstrVal = SysAllocStringLen(text.data(), (UINT)text.size());
        if (!value->bstrVal) return E_OUTOFMEMORY;
    } else if (key == kpidSize) {
        value->vt = VT_UI8; value->uhVal.QuadPart = size;
    } else if (key == kpidIsDir) {
        value->vt = VT_BOOL; value->boolVal = VARIANT_FALSE;
    }
    return S_OK;
}
Z7_COM7F_IMF(OpenCallback::GetStream(const wchar_t *requestedName, IInStream **stream)) {
    *stream = nullptr;
    try {
        auto candidate = utf8(requestedName);
        if (candidate.empty() || candidate.find('/') != std::string::npos ||
            candidate.find('\\') != std::string::npos || candidate == "." || candidate == ".." ||
            volumeFamily(candidate) != volumeFamily(name)) return E_ABORT;
        int fd = openat(parent, candidate.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) return errno == ENOENT ? S_FALSE : E_FAIL;
        struct stat info;
        if (fstat(fd, &info) || !S_ISREG(info.st_mode)) { close(fd); return E_FAIL; }
        if (opened.insert(candidate).second) {
            if ((uint64_t)info.st_size > UINT64_MAX - totalBytes) { close(fd); return E_FAIL; }
            totalBytes += info.st_size;
        }
        CMyComPtr<IInStream> input = new Input(fd);
        *stream = input.Detach();
        return S_OK;
    } catch (...) { return E_FAIL; }
}

struct Entry {
    std::string path;
    bool directory;
    bool sizeKnown;
    uint64_t size;
    uint32_t mode;
    uint64_t modified;
};
static std::vector<std::string> components(const std::string &path) {
    require(!path.empty() && path[0] != '/' && path.find('\0') == std::string::npos, "unsafe_path");
    std::vector<std::string> parts;
    std::stringstream stream(path);
    std::string part;
    while (std::getline(stream, part, '/')) {
        require(!part.empty() && part != "." && part != "..", "unsafe_path");
        parts.push_back(part);
    }
    require(!parts.empty(), "unsafe_path");
    return parts;
}
static std::string collisionKey(const std::string &path) {
    CFStringRef original = CFStringCreateWithBytes(nullptr, (const UInt8 *)path.data(),
                                                 path.size(), kCFStringEncodingUTF8, false);
    require(original != nullptr, "invalid_name");
    CFMutableStringRef normalized = CFStringCreateMutableCopy(nullptr, 0, original);
    CFRelease(original);
    CFStringNormalize(normalized, kCFStringNormalizationFormC);
    CFStringFold(normalized, kCFCompareCaseInsensitive, nullptr);
    std::vector<char> bytes(CFStringGetMaximumSizeForEncoding(CFStringGetLength(normalized), kCFStringEncodingUTF8) + 1);
    bool ok = CFStringGetCString(normalized, bytes.data(), bytes.size(), kCFStringEncodingUTF8);
    CFRelease(normalized);
    require(ok, "invalid_name");
    return bytes.data();
}
static std::vector<Entry> entries(IInArchive *archive, const std::string &fallback, bool approved, uint64_t compressed) {
    UInt32 count = 0;
    require(archive->GetNumberOfItems(&count) == S_OK, "invalid_archive");
    require(count <= (approved ? 1000000U : 100000U), "expansion_confirmation");
    std::vector<Entry> result;
    std::map<std::string, bool> kinds;
    std::set<std::string> explicitPaths;
    std::map<std::string, std::string> spellings;
    uint64_t total = 0;
    for (UInt32 i = 0; i < count; ++i) {
        Property path(archive, i, kpidPath), size(archive, i, kpidSize);
        auto name = path.present() ? path.text() : fallback;
        bool directory = Property(archive, i, kpidIsDir).number() != 0;
        if (directory && !name.empty() && name.back() == '/') name.pop_back();
        auto parts = components(name);
        auto mode = (uint32_t)Property(archive, i, kpidPosixAttrib).number();
        if (!mode) mode = (uint32_t)(Property(archive, i, kpidAttrib).number() >> 16);
        auto type = mode & S_IFMT;
        require((type == 0 || type == S_IFREG || type == S_IFDIR) &&
                Property(archive, i, kpidSymLink).text().empty() &&
                Property(archive, i, kpidHardLink).text().empty(), "unsupported_entry");
        std::string prefix;
        for (size_t j = 0; j < parts.size(); ++j) {
            if (j) prefix += '/';
            prefix += parts[j];
            auto key = collisionKey(prefix);
            auto spelling = spellings.find(key);
            if (spelling != spellings.end()) require(spelling->second == prefix, "path_collision");
            spellings[key] = prefix;
            bool isDir = j + 1 < parts.size() || directory;
            auto found = kinds.find(key);
            if (found != kinds.end()) require(found->second && isDir, "path_collision");
            kinds[key] = isDir;
            if (j + 1 == parts.size()) require(explicitPaths.insert(key).second, "path_collision");
        }
        require(directory || size.present() || approved, "expansion_confirmation");
        uint64_t length = size.number();
        require(length <= UINT64_MAX - total, "expansion_confirmation");
        total += length;
        if (!approved) require(total <= (10ULL << 30) &&
            total / 1000 <= compressed && !(compressed == 0 && total != 0), "expansion_confirmation");
        Property time(archive, i, kpidMTime);
        uint64_t modified = time.value.vt == VT_FILETIME
            ? ((uint64_t)time.value.filetime.dwHighDateTime << 32) | time.value.filetime.dwLowDateTime : 0;
        result.push_back({name, directory, size.present(), length, mode, modified});
    }
    return result;
}

struct Budget { uint64_t written = 0; uint64_t limit; };
class Output final : public ISequentialOutStream, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_1(ISequentialOutStream)
public:
    int fd;
    Budget *budget;
    Output(int descriptor, Budget *b) : fd(descriptor), budget(b) {}
    ~Output() { close(fd); }
};
Z7_COM7F_IMF(Output::Write(const void *data, UInt32 size, UInt32 *processed)) {
    if (processed) *processed = 0;
    if (size > budget->limit - budget->written) return E_ABORT;
    struct statfs space;
    if (fstatfs(fd, &space) || (uint64_t)space.f_bavail * space.f_bsize < size + (16ULL << 20)) return E_FAIL;
    ssize_t count;
    do { count = write(fd, data, size); } while (count < 0 && errno == EINTR);
    if (count < 0) return E_FAIL;
    budget->written += count;
    if (processed) *processed = (UInt32)count;
    return S_OK;
}
// 使用目录句柄逐层打开，拒绝已存在的链接；不依赖字符串前缀判断安全。
static int outputFile(int root, const Entry &entry) {
    auto parts = components(entry.path);
    int parent = dup(root);
    require(parent >= 0, "output_failed");
    for (size_t i = 0; i < parts.size(); ++i) {
        bool dir = i + 1 < parts.size() || entry.directory;
        int next;
        if (dir) {
            if (mkdirat(parent, parts[i].c_str(), 0700) != 0 && errno != EEXIST) {
                close(parent); throw std::runtime_error("output_failed");
            }
            next = openat(parent, parts[i].c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        } else {
            next = openat(parent, parts[i].c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                          0600);
        }
        close(parent);
        require(next >= 0, "output_failed");
        parent = next;
    }
    return parent;
}
class ExtractCallback final : public IArchiveExtractCallback,
                              public ICryptoGetTextPassword, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
    Z7_IFACE_COM7_IMP(IProgress)
public:
    int root;
    std::vector<Entry> items;
    std::wstring password;
    Budget budget;
    bool failed = false;
    explicit ExtractCallback(int directory) : root(directory) {}
    ~ExtractCallback() { close(root); }
};
Z7_COM7F_IMF(ExtractCallback::SetTotal(UInt64)) { return S_OK; }
Z7_COM7F_IMF(ExtractCallback::SetCompleted(const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(ExtractCallback::PrepareOperation(Int32)) { return S_OK; }
Z7_COM7F_IMF(ExtractCallback::SetOperationResult(Int32 result)) {
    if (result != NArchive::NExtract::NOperationResult::kOK) failed = true;
    return failed ? E_FAIL : S_OK;
}
Z7_COM7F_IMF(ExtractCallback::CryptoGetTextPassword(BSTR *value)) {
    if (password.empty()) return E_ABORT;
    *value = SysAllocStringLen(password.data(), (UINT)password.size());
    return *value ? S_OK : E_OUTOFMEMORY;
}
Z7_COM7F_IMF(ExtractCallback::GetStream(UInt32 index, ISequentialOutStream **stream, Int32 mode)) {
    *stream = nullptr;
    if (mode != NArchive::NExtract::NAskMode::kExtract) return S_OK;
    try {
        require(index < items.size(), "invalid_index");
        int fd = outputFile(root, items[index]);
        if (items[index].directory) close(fd);
        else {
            CMyComPtr<ISequentialOutStream> output = new Output(fd, &budget);
            *stream = output.Detach();
        }
        return S_OK;
    } catch (...) { failed = true; return E_FAIL; }
}

static void run(int argc, char **argv) {
    require(argc >= 3 && argc <= 5, "invalid_arguments");
    bool extracting = argc >= 4;
    bool approved = argc == 5 && std::string(argv[4]) == "--approved";
    std::string password;
    char c;
    while (std::cin.get(c)) { require(password.size() < 65536, "password_too_long"); password += c; }
    auto secret = toWide(password);
    std::fill(password.begin(), password.end(), '\0');
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    require(library != nullptr, "engine_unavailable");
    auto create = (HRESULT (*)(const GUID *, const GUID *, void **))dlsym(library, "CreateObject");
    require(create != nullptr, "engine_unavailable");
    int descriptor = open(argv[2], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    require(descriptor >= 0, "input_unavailable");
    struct stat source;
    if (fstat(descriptor, &source) || !S_ISREG(source.st_mode)) {
        close(descriptor); throw std::runtime_error("input_unavailable");
    }
    CMyComPtr<IInStream> input = new Input(descriptor);
    CMyComPtr<IInArchive> archive;
    auto *open = new OpenCallback();
    open->password = secret;
    std::string inputPath = argv[2];
    auto separator = inputPath.find_last_of('/');
    open->name = separator == std::string::npos ? inputPath : inputPath.substr(separator + 1);
    std::string directory = separator == std::string::npos ? "." : inputPath.substr(0, separator);
    open->parent = ::open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    require(open->parent >= 0, "input_unavailable");
    open->size = source.st_size;
    open->totalBytes = source.st_size;
    open->opened.insert(open->name);
    std::smatch volume;
    if (std::regex_search(open->name, volume, std::regex("\\.part([0-9]+)\\.rar$", std::regex::icase))) {
        require(volume[1].str().find_first_not_of('0') != std::string::npos && std::stoull(volume[1]) == 1, "select_first_volume");
    }
    require(!std::regex_search(open->name, std::regex("\\.[rz][0-9]+$", std::regex::icase)), "select_first_volume");
    CMyComPtr<IArchiveOpenCallback> callback = open;
    CMyComPtr<IInArchive> split;
    if (std::regex_search(open->name, std::regex("\\.[0-9]{3,}$"))) {
        require(open->name.size() >= 4 && open->name.substr(open->name.size()-4) == ".001", "select_first_volume");
        GUID format = {0x23170F69, 0x40C1, 0x278A, {0x10, 0, 0, 1, 0x10, 0xEA, 0, 0}};
        require(create(&format, &IID_IInArchive, (void **)&split) == S_OK, "engine_unavailable");
        require(split->Open(input, nullptr, callback) == S_OK, "missing_or_damaged_volume");
        CMyComPtr<IInArchiveGetStream> streams;
        require(split->QueryInterface(IID_IInArchiveGetStream, (void **)&streams) == S_OK, "engine_unavailable");
        CMyComPtr<ISequentialInStream> joined;
        require(streams->GetStream(0, &joined) == S_OK, "missing_or_damaged_volume");
        input.Release();
        require(joined->QueryInterface(IID_IInStream, (void **)&input) == S_OK, "engine_unavailable");
    }
    for (unsigned id : {1U, 7U, 3U, 0xCCU, 0xEEU, 0xEFU}) {
        GUID format = {0x23170F69, 0x40C1, 0x278A, {0x10, 0, 0, 1, 0x10, (Byte)id, 0, 0}};
        archive.Release();
        require(input->Seek(0, 0, nullptr) == S_OK, "input_unavailable");
        if (create(&format, &IID_IInArchive, (void **)&archive) != S_OK) continue;
        UInt64 scan = 0;
        if (archive->Open(input, &scan, callback) == S_OK) break;
        archive.Release();
    }
    require(!!archive, open->requested ? "password_or_archive_invalid" : "unsupported_or_damaged_archive");
    require(Property(archive, kpidError).text().empty(), "missing_or_damaged_volume");
    require(Property(archive, kpidErrorFlags).number() == 0, "unsupported_or_damaged_archive");
    std::string fallback = argv[2];
    fallback = fallback.substr(fallback.find_last_of('/') + 1);
    if (fallback.size() > 3 && fallback.substr(fallback.size()-3) == ".gz") fallback.resize(fallback.size()-3);
    else fallback += ".out";
    UInt64 compressed = 0;
    require(input->Seek(0, 2, &compressed) == S_OK, "input_unavailable");
    auto items = entries(archive, fallback, approved, std::max<uint64_t>(compressed, open->totalBytes));
    if (extracting) {
        int root = ::open(argv[3], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        require(root >= 0, "output_unavailable");
        auto *extract = new ExtractCallback(root);
        extract->items = std::move(items);
        extract->password = secret;
        extract->budget.limit = approved ? UINT64_MAX : (10ULL << 30);
        CMyComPtr<IArchiveExtractCallback> extraction = extract;
        HRESULT result = archive->Extract(nullptr, (UInt32)-1, false, extraction);
        require(result == S_OK && !extract->failed, "extraction_failed");
        // 子项写完再恢复目录权限和时间，避免中途因只读目录而失败。
        for (auto item = extract->items.rbegin(); item != extract->items.rend(); ++item) {
            int fd = dup(root);
            require(fd >= 0, "metadata_failed");
            for (const auto &part : components(item->path)) {
                int next = openat(fd, part.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
                close(fd);
                require(next >= 0, "metadata_failed");
                fd = next;
            }
            if (item->modified) {
                timespec time = {(time_t)(item->modified / 10000000ULL) - 11644473600LL,
                                 (long)(item->modified % 10000000ULL) * 100};
                timespec times[] = {time, time};
                if (futimens(fd, times)) { close(fd); throw std::runtime_error("metadata_failed"); }
            }
            int mode = item->mode ? item->mode & 0777 : (item->directory ? 0755 : 0644);
            int status = fchmod(fd, mode);
            close(fd);
            require(status == 0, "metadata_failed");
        }
    }
    std::fill(secret.begin(), secret.end(), L'\0');
    if (extracting) {
        std::cout << "{\"ok\":true}\n";
    } else {
        std::cout << "{\"entries\":[";
        for (size_t i = 0; i < items.size(); ++i) {
            const auto &item = items[i];
            if (i) std::cout << ',';
            std::cout << "{\"path\":" << json(item.path) << ",\"directory\":" << (item.directory ? "true" : "false")
                      << ",\"size\":" << (item.sizeKnown ? std::to_string(item.size) : "null") << '}';
        }
        std::cout << "]}\n";
    }
    archive->Close();
    // 库保持加载至子进程退出，避免接口析构早于动态库卸载的生命周期错误。
}
int main(int argc, char **argv) {
    try { run(argc, argv); return 0; }
    catch (const std::exception &error) { std::cout << "{\"error\":" << json(error.what()) << "}\n"; return 2; }
    catch (...) { std::cout << "{\"error\":\"engine_failure\"}\n"; return 2; }
}
