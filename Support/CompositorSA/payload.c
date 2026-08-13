// scrollwm scripting addition —— 注入 Dock.app 后运行的 payload。
//
// 职责：在 Dock 进程内注册一个 mach 服务，接收主进程发来的批量帧，
// 用 Dock 的特权 WindowServer 连接（SLSMainConnectionID 在 Dock 内即为万能所有者连接）
// 通过一个 SLSTransaction 原子地移动/缩放这些窗口。
//
// 所有 SkyLight 符号用 dlsym 动态解析，避免对私有框架的链接期依赖，
// 也便于在不同 macOS 版本上探测函数是否存在。
//
// 注意：这是合成器方案的“执行端”，逻辑与 macOS 版本基本无关；
// 真正随版本变化的是“注入端”（见 Injector.swift）。

#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <servers/bootstrap.h>

#include "protocol.h"

// ---- SkyLight 私有 API（运行时解析）----
typedef int   CGSConnectionID;
typedef void *SLSTransactionRef;

static CGSConnectionID (*SLSMainConnectionID_f)(void);
static SLSTransactionRef (*SLSTransactionCreate_f)(CGSConnectionID);
static CGError (*SLSTransactionCommit_f)(SLSTransactionRef, int);
static CGError (*SLSTransactionMoveWindow_f)(SLSTransactionRef, uint32_t, CGPoint);
static CGError (*SLSTransactionSetWindowShape_f)(SLSTransactionRef, uint32_t, float, float, void *);
static CGError (*SLSSetWindowAlpha_f)(CGSConnectionID, uint32_t, float);
static CGError (*SLSMoveWindow_f)(CGSConnectionID, uint32_t, CGPoint *);

static void sa_log(const char *msg) {
    fprintf(stderr, "[scrollwm-sa] %s\n", msg);
}

static void resolve_symbols(void) {
    void *sls = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (!sls) { sa_log("无法 dlopen SkyLight"); return; }
    SLSMainConnectionID_f       = dlsym(sls, "SLSMainConnectionID");
    SLSTransactionCreate_f      = dlsym(sls, "SLSTransactionCreate");
    SLSTransactionCommit_f      = dlsym(sls, "SLSTransactionCommit");
    SLSTransactionMoveWindow_f  = dlsym(sls, "SLSTransactionMoveWindow");
    SLSTransactionSetWindowShape_f = dlsym(sls, "SLSTransactionSetWindowShape");
    SLSSetWindowAlpha_f         = dlsym(sls, "SLSSetWindowAlpha");
    SLSMoveWindow_f             = dlsym(sls, "SLSMoveWindow");
}

// 用一个事务批量应用所有帧（原子提交）
static int apply_frames(scrollwm_request_t *req) {
    if (!SLSMainConnectionID_f) return 0;
    CGSConnectionID cid = SLSMainConnectionID_f();

    int applied = 0;
    if (SLSTransactionCreate_f && SLSTransactionMoveWindow_f && SLSTransactionCommit_f) {
        SLSTransactionRef tx = SLSTransactionCreate_f(cid);
        for (uint32_t i = 0; i < req->count && i < SCROLLWM_SA_MAX_WINDOWS; i++) {
            scrollwm_frame_t *f = &req->frames[i];
            CGPoint p = CGPointMake(f->x, f->y);
            SLSTransactionMoveWindow_f(tx, f->window_id, p);
            if (SLSTransactionSetWindowShape_f) {
                SLSTransactionSetWindowShape_f(tx, f->window_id, f->w, f->h, NULL);
            }
            applied++;
        }
        SLSTransactionCommit_f(tx, 0);
    } else if (SLSMoveWindow_f) {
        // 退化路径：逐窗口移动（无批量原子性，仅保底）
        for (uint32_t i = 0; i < req->count && i < SCROLLWM_SA_MAX_WINDOWS; i++) {
            CGPoint p = CGPointMake(req->frames[i].x, req->frames[i].y);
            SLSMoveWindow_f(cid, req->frames[i].window_id, &p);
            applied++;
        }
    }

    if (SLSSetWindowAlpha_f) {
        for (uint32_t i = 0; i < req->count && i < SCROLLWM_SA_MAX_WINDOWS; i++) {
            if (req->frames[i].alpha > 0.0f && req->frames[i].alpha < 1.0f) {
                SLSSetWindowAlpha_f(cid, req->frames[i].window_id, req->frames[i].alpha);
            }
        }
    }
    return applied;
}

static mach_port_t g_service_port = MACH_PORT_NULL;

static void *service_thread(void *unused) {
    (void)unused;
    for (;;) {
        scrollwm_request_t req;
        memset(&req, 0, sizeof(req));
        req.header.msgh_local_port = g_service_port;
        req.header.msgh_size = sizeof(req);
        kern_return_t kr = mach_msg(&req.header, MACH_RCV_MSG, 0, sizeof(req),
                                    g_service_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) continue;

        int applied = 0, ok = 1;
        if (req.msg_id == SCROLLWM_MSG_APPLY_FRAMES) {
            applied = apply_frames(&req);
        } else if (req.msg_id == SCROLLWM_MSG_PING) {
            ok = (SLSMainConnectionID_f != NULL);
        }

        if (MACH_PORT_VALID(req.header.msgh_remote_port)) {
            scrollwm_reply_t reply;
            memset(&reply, 0, sizeof(reply));
            reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(req.header.msgh_bits), 0);
            reply.header.msgh_size = sizeof(reply);
            reply.header.msgh_remote_port = req.header.msgh_remote_port;
            reply.header.msgh_local_port = MACH_PORT_NULL;
            reply.header.msgh_id = req.header.msgh_id + 100;
            reply.ok = ok;
            reply.applied = applied;
            mach_msg(&reply.header, MACH_SEND_MSG, sizeof(reply), 0,
                     MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        }
    }
    return NULL;
}

// 注入后自动运行：解析符号 + 注册 mach 服务 + 起接收线程
__attribute__((constructor))
static void scrollwm_sa_init(void) {
    static int inited = 0;
    if (inited) return;
    inited = 1;

    resolve_symbols();

    mach_port_t bp = MACH_PORT_NULL;
    task_get_bootstrap_port(mach_task_self(), &bp);
    // 尝试注册服务名；已存在则复用
    kern_return_t kr = bootstrap_check_in(bp, SCROLLWM_SA_SERVICE, &g_service_port);
    if (kr != KERN_SUCCESS) {
        kr = bootstrap_register(bp, SCROLLWM_SA_SERVICE, g_service_port);
    }
    if (g_service_port == MACH_PORT_NULL) {
        sa_log("mach 服务注册失败");
        return;
    }

    pthread_t t;
    pthread_create(&t, NULL, service_thread, NULL);
    pthread_detach(t);
    sa_log("payload 就绪，服务已注册");
}
