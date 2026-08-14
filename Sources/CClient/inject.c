#include "inject.h"
#include <mach/mach.h>
#include <mach/thread_status.h>
#include <string.h>
#if defined(__arm64e__) || __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

/*
 * arm64e 远程 dlopen 线程创建。
 * 注意：默认 swift test / arm64 构建没有 ptrauth，struct 字段是 __pc/__sp 而非 __opaque_*。
 * 合成器注入需要 arm64e 构建（swift build --arch arm64e）；此处用宏兼容两种 ABI，
 * 保证 AX 动画主路径的日常构建不被注入实验代码拖垮。
 */

static void emit_mov_imm64(uint32_t *out, int *idx, uint32_t reg, uint64_t val) {
    uint32_t r = reg & 0x1F;
    out[(*idx)++] = 0xD2800000 | (((uint32_t)(val & 0xFFFF) ) << 5) | r;
    out[(*idx)++] = 0xF2800000 | (1 << 21) | (((uint32_t)((val >> 16) & 0xFFFF)) << 5) | r;
    out[(*idx)++] = 0xF2800000 | (2 << 21) | (((uint32_t)((val >> 32) & 0xFFFF)) << 5) | r;
    out[(*idx)++] = 0xF2800000 | (3 << 21) | (((uint32_t)((val >> 48) & 0xFFFF)) << 5) | r;
}

kern_return_t scrollwm_create_remote_dlopen_thread(
    task_t target_task,
    vm_address_t remote_mem,
    vm_size_t total_size,
    uint64_t remote_dlopen_addr,
    uint64_t path_addr,
    uint64_t rtld_now
) {
    // arm64e 下 dlsym 返回的是用本进程 A-key（function_pointer）签过的指针，
    // 裸 VA 才能交给远端 stub：stub 在 Dock 内用 Dock 自己的 A-key 重签再 blr。
    // 若把带签名的值直接 movz 进 x16，pacia 会签出垃圾签名导致 blr PAC 崩溃。
#if defined(__arm64e__) || __has_feature(ptrauth_calls)
    uint64_t bare = (uint64_t)ptrauth_strip((void *)(uintptr_t)remote_dlopen_addr,
                                            ptrauth_key_function_pointer);
#else
    uint64_t bare = remote_dlopen_addr;
#endif
    uint32_t code[16];
    int idx = 0;
    emit_mov_imm64(code, &idx, 0, path_addr);
    code[idx++] = 0xD2800000 | ((uint32_t)rtld_now << 5) | 1; // movz x1,#RTLD_NOW
    emit_mov_imm64(code, &idx, 16, bare);
#if defined(__arm64e__) || __has_feature(ptrauth_calls)
    code[idx++] = 0xDAC123F0; // pacia x16, xzr
#endif
    code[idx++] = 0xD63F0200; // blr x16
    // 线程不回程：ret 会触发内核签的 LR 与 retab 的 PAC 失配（Dock 崩溃，
    // 见 Dock-2026-08-14-175741.ips: FAR=0x2000000109b40000）。
    // dlopen 返回后停在 wfe 循环里，payload 自己的线程继续跑。
    code[idx++] = 0xD503205F; // wfe
    code[idx++] = 0x17FFFFFF; // b .-4（原地待命，不烧 CPU）

    kern_return_t kr = vm_write(target_task, remote_mem,
                                (vm_offset_t)code, (mach_msg_type_number_t)(idx * 4));
    if (kr != KERN_SUCCESS) return kr;

    vm_address_t stack = 0;
    vm_size_t stackSize = 16384;
    kr = vm_allocate(target_task, &stack, stackSize, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return kr;

    kr = vm_protect(target_task, remote_mem, total_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) return kr;

    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));

#if defined(__arm64e__) || __has_feature(ptrauth_calls)
    // macOS 27 语义（SDK mach/arm/_structs.h 的 get/set_pc 宏）：线程入口 PC 必须
    // 由调用方用 process-independent code key + 字符串 discriminator "pc" 预先签名，
    // 内核不再代签。给裸 PC 会在第一条指令取指时 PAC 失败
    //（Dock-2026-08-14-*.ips：FAR=代码页|0x2000...，寄存器全 0，PC=页首）。
    state.__opaque_flags = 0;
    state.__opaque_pc = ptrauth_sign_unauthenticated(
        (void *)(uintptr_t)remote_mem,
        ptrauth_key_process_independent_code,
        ptrauth_string_discriminator("pc"));
    state.__opaque_sp = (void *)(uintptr_t)(stack + stackSize);
    state.__opaque_fp = NULL;
    state.__opaque_lr = NULL;
#else
    state.__pc = (uint64_t)remote_mem;
    state.__sp = (uint64_t)(stack + stackSize);
    state.__fp = 0;
    state.__lr = 0;
#endif

    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    thread_act_t thread = MACH_PORT_NULL;
    kr = thread_create_running(target_task, ARM_THREAD_STATE64,
                               (thread_state_t)&state, count, &thread);
    return kr;
}
