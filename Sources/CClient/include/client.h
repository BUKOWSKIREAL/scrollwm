// 主进程侧的合成器 mach 客户端（C 实现，规避 Swift 无法导入的函数式 mach 宏）。
#ifndef SCROLLWM_CLIENT_H
#define SCROLLWM_CLIENT_H

#include <stdint.h>
#include "protocol.h"

// 查找 payload 的 mach 服务并 ping；1=已连接
int scrollwm_client_connect(void);
void scrollwm_client_disconnect(void);
int scrollwm_client_is_connected(void);

// 批量下发目标帧；1=发送成功
int scrollwm_client_apply(const scrollwm_frame_t *frames, uint32_t count, int settle);

#endif
