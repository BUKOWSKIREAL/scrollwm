#include "inject.h"
#include <mach/mach.h>
#include <mach/thread_status.h>
#include <string.h>

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
    uint64_t bare = remote_dlopen_addr & 0x000000FFFFFFFFFFULL;
    uint32_t code[16];
    int idx = 0;
    emit_mov_imm64(code, &idx, 0, path_addr);
    code[idx++] = 0xD2800000 | ((uint32_t)rtld_now << 5) | 1; // movz x1,#RTLD_NOW
    emit_mov_imm64(code, &idx, 16, bare);
#if defined(__arm64e__) || __has_feature(ptrauth_calls)
    code[idx++] = 0xDAC123F0; // pacia x16, xzr
#endif
    code[idx++] = 0xD63F0200; // blr x16
    code[idx++] = 0xD65F03C0; // ret

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
    // arm64e：opaque 字段 + 让内核签 PC（实验路径，macOS 27 上仍可能 PAC 失败）
    state.__opaque_flags = 0x4; // KERNEL_SIGNED_PC
    state.__opaque_pc = (void *)(uintptr_t)(remote_mem & 0x000000FFFFFFFFFFULL);
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
