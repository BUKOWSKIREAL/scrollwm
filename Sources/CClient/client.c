#include "client.h"

#include <bootstrap.h>
#include <mach/mach.h>
#include <string.h>

static mach_port_t g_remote = MACH_PORT_NULL;
static int g_connected = 0;

int scrollwm_client_is_connected(void) { return g_connected; }

void scrollwm_client_disconnect(void) {
    g_remote = MACH_PORT_NULL;
    g_connected = 0;
}

static int send_request(const scrollwm_frame_t *frames, uint32_t count, int settle,
                        int32_t msg_id, int want_reply) {
    if (g_remote == MACH_PORT_NULL) return 0;

    scrollwm_request_t req;
    memset(&req, 0, sizeof(req));

    mach_port_t reply_port = MACH_PORT_NULL;
    if (want_reply) {
        if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &reply_port) != KERN_SUCCESS) {
            want_reply = 0;
        }
    }

    req.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
                                          want_reply ? MACH_MSG_TYPE_MAKE_SEND_ONCE : 0);
    req.header.msgh_size = sizeof(req);
    req.header.msgh_remote_port = g_remote;
    req.header.msgh_local_port = want_reply ? reply_port : MACH_PORT_NULL;
    req.header.msgh_id = 0x5357;
    req.msg_id = msg_id;
    req.settle = settle;

    if (count > SCROLLWM_SA_MAX_WINDOWS) count = SCROLLWM_SA_MAX_WINDOWS;
    req.count = count;
    if (frames && count) memcpy(req.frames, frames, count * sizeof(scrollwm_frame_t));

    // 动画帧单向发送、短超时，避免拖慢 tick；ping 才等回复
    mach_msg_timeout_t timeout = want_reply ? 200 : 20;
    mach_msg_option_t options = MACH_SEND_MSG | MACH_SEND_TIMEOUT | (want_reply ? MACH_RCV_MSG : 0);

    if (want_reply) {
        scrollwm_reply_t reply;
        memset(&reply, 0, sizeof(reply));
        // 复用 reply 的 header 作接收缓冲
        req.header.msgh_local_port = reply_port;
        kern_return_t kr = mach_msg(&req.header, options, sizeof(req), sizeof(reply),
                                    reply_port, timeout, MACH_PORT_NULL);
        // 只持有 receive right（send-once 已随消息交给对端），精确释放即可；
        // mach_port_destroy 已废弃且会连带销毁同名的其他权利。
        mach_port_mod_refs(mach_task_self(), reply_port, MACH_PORT_RIGHT_RECEIVE, -1);
        if (kr != KERN_SUCCESS) return 0;
        return 1;
    } else {
        kern_return_t kr = mach_msg(&req.header, options, sizeof(req), 0,
                                    MACH_PORT_NULL, timeout, MACH_PORT_NULL);
        return kr == KERN_SUCCESS;
    }
}

int scrollwm_client_connect(void) {
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, SCROLLWM_SA_SERVICE, &port);
    if (kr != KERN_SUCCESS || port == MACH_PORT_NULL) {
        g_connected = 0;
        return 0;
    }
    g_remote = port;
    g_connected = send_request(NULL, 0, 1, SCROLLWM_MSG_PING, 1);
    return g_connected;
}

int scrollwm_client_apply(const scrollwm_frame_t *frames, uint32_t count, int settle) {
    if (!g_connected) return 0;
    int ok = send_request(frames, count, settle, SCROLLWM_MSG_APPLY_FRAMES, 0);
    if (!ok) g_connected = 0;  // 断连则回退 AX
    return ok;
}
