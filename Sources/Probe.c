//  Probe.c —— CPU-S2 内建频率探针（x86_64 + arm64 通用）
//
//  原理：计时一条有数据依赖的整数加法链，以每轮 8 个名义周期换算为频率估计。
//       结果受微架构、循环开销、抢占、迁核和动态调频影响，不等同于硬件计数器读数。
//       纯用户态：不需要 root、不读 MSR、不依赖 Intel Power Gadget，也不需要任何特权。
//
//  x86 使用寄存器操作数，避免依赖立即数加法在特定处理器上的优化行为。
//  指令链仍需在各微架构上用硬件计数器标定；这里不承诺跨架构固定误差。
//
//  探针本身会唤醒并占用 CPU，不能用于证明真正空闲时的频率或驻留状态。

#include <stdint.h>
#include <math.h>
#include <pthread.h>
#include <mach/mach_time.h>

#define NOMINAL_CYCLES_PER_ITER 8.0
#define PROBE_ITERS             200000ULL

static mach_timebase_info_data_t g_tb;
static pthread_once_t g_tb_once = PTHREAD_ONCE_INIT;

static void tb_initialize_once(void) {
    if (mach_timebase_info(&g_tb) != KERN_SUCCESS || g_tb.numer == 0 || g_tb.denom == 0) {
        g_tb.numer = 1;
        g_tb.denom = 1;
    }
}

static void tb_init(void) { pthread_once(&g_tb_once, tb_initialize_once); }

static inline double ns_since(uint64_t t0) {
    uint64_t d = mach_absolute_time() - t0;
    return (double)d * (double)g_tb.numer / (double)g_tb.denom;
}

// 8 条串行 add，禁止编译器折叠
static inline void spin(uint64_t iters, uint64_t *acc) {
    uint64_t x = *acc;

#if defined(__x86_64__)
    const uint64_t one = 1;
    __asm__ __volatile__(
        "1:\n\t"
        "addq %2, %0\n\t"
        "addq %2, %0\n\t"
        "addq %2, %0\n\t"
        "addq %2, %0\n\t"
        "addq %2, %0\n\t"
        "addq %2, %0\n\t"
        "addq %2, %0\n\t"
        "addq %2, %0\n\t"
        "decq %1\n\t"
        "jne 1b\n\t"
        : "+&r"(x), "+&r"(iters)
        : "r"(one)
        : "cc");
#elif defined(__aarch64__)
    const uint64_t one = 1;
    __asm__ __volatile__(
        "1:\n\t"
        "add %0, %0, %2\n\t"
        "add %0, %0, %2\n\t"
        "add %0, %0, %2\n\t"
        "add %0, %0, %2\n\t"
        "add %0, %0, %2\n\t"
        "add %0, %0, %2\n\t"
        "add %0, %0, %2\n\t"
        "add %0, %0, %2\n\t"
        "subs %1, %1, #1\n\t"
        "b.ne 1b\n\t"
        : "+&r"(x), "+&r"(iters)
        : "r"(one)
        : "cc");
#else
    // 不为未验证的架构提供可能被编译器折叠的 C 循环读数。
    (void)iters;
#endif

    *acc = x;
}

// 当前调度线程的频率估计（MHz）。ms = 采样时长（毫秒）。
// 每次调用限制为 100ms，便于上层在采样间隔处理取消；不保证线程固定在某颗核心。
double cpus2_measure_mhz(double ms) {
#if !defined(__x86_64__) && !defined(__aarch64__)
    (void)ms;
    return 0;
#else
    tb_init();
    if (!isfinite(ms) || ms <= 0) ms = 4.0;
    if (ms > 100.0) ms = 100.0;

    uint64_t acc = 0;
    uint64_t total = 0;
    uint64_t t0 = mach_absolute_time();
    double ns = 0;
    do {
        spin(PROBE_ITERS, &acc);
        total += PROBE_ITERS;
        ns = ns_since(t0);
    } while (ns < ms * 1e6);

    if (ns <= 0) return 0;
    return (double)total * NOMINAL_CYCLES_PER_ITER / (ns / 1e9) / 1e6;
#endif
}

// 纯烧 CPU 指定毫秒数（给 LoadManager 制造负载）。
void cpus2_burn(double ms) {
    tb_init();
    if (!isfinite(ms) || ms <= 0) ms = 10.0;
    if (ms > 100.0) ms = 100.0;
    uint64_t acc = 0;
    uint64_t t0 = mach_absolute_time();
    do {
        spin(PROBE_ITERS, &acc);
    } while (ns_since(t0) < ms * 1e6);
}

// ─────────────────────────────────────────────────────────────────────────────
//  SMC 温度读取（VirtualSMC / SMCProcessor 提供，免 root）
//
//  AppleSMC 的 user client 用结构体调用，经典接口：
//    data8 = 9 (READ_KEYINFO) → 拿 dataSize / dataType
//    data8 = 5 (READ_BYTES)   → 拿数据
//  ⚠️ 坑：第二次调用会**覆盖整个输出结构**，dataType 必须在第一次调用后先存下来，
//     否则拿到的 dataType 是 0，所有键都会被误判成"不可读"。
//  温度键是 'sp78'（有符号 7.8 定点）：raw / 256.0。
// ─────────────────────────────────────────────────────────────────────────────

#include <string.h>
#include <IOKit/IOKitLib.h>

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    uint32_t data32;
    char bytes[32];
} SMCKeyData;

static io_connect_t g_smc = 0;
// UI 实时温度与采样线程共享连接；一次完整的键查询/数据读取必须串行。
static pthread_mutex_t g_smc_mutex = PTHREAD_MUTEX_INITIALIZER;

// 以下 smc_* 辅助函数由持有 g_smc_mutex 的调用方使用。
static void smc_close_locked(void) {
    if (g_smc) {
        IOServiceClose(g_smc);
        g_smc = 0;
    }
}

static kern_return_t smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData), inSize = sizeof(SMCKeyData);
    memset(out, 0, sizeof(*out));
    kern_return_t status = IOConnectCallStructMethod(g_smc, 2 /* KERNEL_INDEX_SMC */, in, inSize, out, &outSize);
    if (status != kIOReturnSuccess) {
        // 驱动重载或睡眠唤醒后连接可能失效，下一次读取重新打开。
        smc_close_locked();
        return status;
    }
    if (outSize != sizeof(SMCKeyData)) return kIOReturnBadArgument;
    return kIOReturnSuccess;
}

static int smc_open(void) {
    if (g_smc) return 0;
    // MACH_PORT_NULL 让 IOKit 选择默认主端口，兼容部署目标 macOS 11。
    io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t status = IOServiceOpen(svc, mach_task_self(), 0, &g_smc);
    IOObjectRelease(svc);
    if (status != kIOReturnSuccess) { g_smc = 0; return -1; }
    return 0;
}

static int smc_read_sp78(const char *k, double *val) {
    if (smc_open() != 0) return -1;
    SMCKeyData in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = ((uint32_t)(unsigned char)k[0] << 24) | ((uint32_t)(unsigned char)k[1] << 16) |
             ((uint32_t)(unsigned char)k[2] << 8) | (uint32_t)(unsigned char)k[3];
    in.data8 = 9;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0 || out.keyInfo.dataSize != 2) return -2;

    uint32_t dtype = out.keyInfo.dataType;      // 必须在第二次调用前存下
    if (dtype != 0x73703738) return -4;         // 'sp78'，只解码已知的 2 字节格式
    in.keyInfo = out.keyInfo;
    in.data8 = 5;
    if (smc_call(&in, &out) != kIOReturnSuccess || out.result != 0) return -3;
    const unsigned char *p = (const unsigned char *)out.bytes;
    int16_t raw = (int16_t)((p[0] << 8) | p[1]);
    *val = raw / 256.0;
    return 0;
}

// 返回当前 CPU 温度（°C，取几个 CPU 温度键的最大值）；读不到返回 0。
double cpus2_cpu_temp(void) {
    static const char *keys[] = { "TC0D", "TC0P", "TC0E", "TC0F", "TC0H", "TC0C" };
    pthread_mutex_lock(&g_smc_mutex);
    double best = 0;
    for (int i = 0; i < (int)(sizeof(keys) / sizeof(keys[0])); i++) {
        double v = 0;
        if (smc_read_sp78(keys[i], &v) == 0 && v > 1 && v < 125 && v > best) best = v;
    }
    pthread_mutex_unlock(&g_smc_mutex);
    return best;
}

__attribute__((destructor)) static void cpus2_close_smc(void) {
    pthread_mutex_lock(&g_smc_mutex);
    smc_close_locked();
    pthread_mutex_unlock(&g_smc_mutex);
}
