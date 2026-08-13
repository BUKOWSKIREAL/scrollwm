// 远程线程注入辅助（C，必须用 ptrauth 宏签名 arm64e pc/sp）。
#ifndef SCROLLWM_INJECT_H
#define SCROLLWM_INJECT_H
#include <mach/mach.h>
#include <stdint.h>

// 在目标 task 创建一个线程，pc 指向 remoteCode，sp 指向 remoteStackTop，
// 线程执行 dlopen(payloadPath) 的 arm64 stub。返回 KERN_SUCCESS 则成功。
kern_return_t scrollwm_create_remote_dlopen_thread(
    task_t target_task,
    vm_address_t remote_mem,
    vm_size_t total_size,
    uint64_t remote_dlopen_addr,
    uint64_t path_addr,
    uint64_t rtld_now
);
#endif
