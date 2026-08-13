// scrollwm 主进程 <-> Dock 内 payload 的共享 mach IPC 协议。
// 主进程每个动画 tick 发一条消息，payload 在 Dock 内用一个 SLSTransaction
// 原子地把这一批窗口移动到目标帧 —— 所有窗口同帧一起动，这是平滑的关键。
#ifndef SCROLLWM_SA_PROTOCOL_H
#define SCROLLWM_SA_PROTOCOL_H

#include <mach/mach.h>
#include <stdint.h>

#define SCROLLWM_SA_SERVICE "com.scrollwm.sa"
#define SCROLLWM_SA_MAX_WINDOWS 64

enum {
    SCROLLWM_MSG_APPLY_FRAMES = 1,
    SCROLLWM_MSG_PING = 2,
};

typedef struct {
    uint32_t window_id;
    float x, y, w, h;
    float alpha;
} scrollwm_frame_t;

typedef struct {
    mach_msg_header_t header;
    int32_t msg_id;
    int32_t settle;
    uint32_t count;
    scrollwm_frame_t frames[SCROLLWM_SA_MAX_WINDOWS];
} scrollwm_request_t;

typedef struct {
    mach_msg_header_t header;
    int32_t ok;
    int32_t applied;
    mach_msg_trailer_t trailer;
} scrollwm_reply_t;

#endif
