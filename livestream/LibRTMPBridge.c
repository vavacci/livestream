#include "LibRTMPBridge.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

#include "librtmp/log.h"
#include "librtmp/rtmp.h"

typedef struct {
    RTMP *rtmp;
    char *host;
    char *app;
    char *playpath;
    char *tcUrl;
    uint16_t port;
} LibRTMPContext;

// 全局日志回调指针，由 Swift 侧在 LibRTMPSessionOpen 里传入。
// 由于当前只存在单路推流，这里使用一个简单的全局指针即可。
static void (*g_LibRTMPLogCallback)(const char *) = NULL;

static void LibRTMPForwardLog(const char *message) {
    if (g_LibRTMPLogCallback != NULL && message != NULL) {
        g_LibRTMPLogCallback(message);
    }
}

// 适配 librtmp 的 RTMP_Log 回调，把格式化日志透传给上层 Swift。
static void LibRTMPLogAdapter(int level, const char *format, va_list args) {
    (void)level; // 当前忽略 level，由 Swift 决定是否展示
    if (g_LibRTMPLogCallback == NULL || format == NULL) {
        return;
    }

    char buffer[1024];
    vsnprintf(buffer, sizeof(buffer), format, args);
    buffer[sizeof(buffer) - 1] = '\0';
    g_LibRTMPLogCallback(buffer);
}

static char *LibRTMPDuplicateString(const char *value) {
    if (value == NULL) {
        return NULL;
    }
    size_t length = strlen(value) + 1;
    char *copy = (char *)malloc(length);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, value, length);
    return copy;
}

static AVal LibRTMPMakeAVal(char *value) {
    AVal result;
    result.av_val = value;
    result.av_len = value == NULL ? 0 : (int)strlen(value);
    return result;
}

static void LibRTMPFreeContext(LibRTMPContext *context) {
    if (context == NULL) {
        return;
    }
    if (context->rtmp != NULL) {
        RTMP_Close(context->rtmp);
        RTMP_Free(context->rtmp);
    }
    free(context->host);
    free(context->app);
    free(context->playpath);
    free(context->tcUrl);
    free(context);
}

void *LibRTMPSessionCreate(const char *host, uint16_t port, const char *app, const char *playpath, const char *tcUrl) {
    LibRTMPContext *context = (LibRTMPContext *)calloc(1, sizeof(LibRTMPContext));
    if (context == NULL) {
        return NULL;
    }

    context->host = LibRTMPDuplicateString(host);
    context->app = LibRTMPDuplicateString(app);
    context->playpath = LibRTMPDuplicateString(playpath);
    context->tcUrl = LibRTMPDuplicateString(tcUrl);
    context->port = port;
    if (context->host == NULL || context->app == NULL || context->playpath == NULL || context->tcUrl == NULL) {
        LibRTMPFreeContext(context);
        return NULL;
    }

    context->rtmp = RTMP_Alloc();
    if (context->rtmp == NULL) {
        LibRTMPFreeContext(context);
        return NULL;
    }
    RTMP_Init(context->rtmp);
    RTMP_EnableWrite(context->rtmp);
    // 具体日志级别与回调设置放到 LibRTMPSessionOpen 中，在真正建连前完成
    return context;
}

bool LibRTMPSessionOpen(void *session, void(*logCallback)(const char *)) {
    LibRTMPContext *context = (LibRTMPContext *)session;
    if (context == NULL || context->rtmp == NULL) {
        if (logCallback) logCallback("Context or RTMP handle is NULL");
        return false;
    }

    // 保存上层日志回调，并把 librtmp 的内部日志也转发到同一通道，方便排查 native 层问题
    g_LibRTMPLogCallback = logCallback;
    RTMP_LogSetCallback(LibRTMPLogAdapter);
    // 默认不要开 DEBUG，避免 RTMP_Write 等高频日志刷屏。
    RTMP_LogSetLevel(RTMP_LOGWARNING);

    AVal host = LibRTMPMakeAVal(context->host);
    AVal app = LibRTMPMakeAVal(context->app);
    AVal playpath = LibRTMPMakeAVal(context->playpath);
    AVal tcUrl = LibRTMPMakeAVal(context->tcUrl);

    if (logCallback) logCallback("Calling RTMP_SetupStream...");
    RTMP_SetupStream(context->rtmp,
                     RTMP_PROTOCOL_RTMP,
                     &host,
                     context->port,
                     NULL,
                     &playpath,
                     &tcUrl,
                     NULL,
                     NULL,
                     &app,
                     NULL,
                     NULL,
                     0,
                     NULL,
                     NULL,
                     NULL,
                     0,
                     0,
                     0, // bLiveStream
                     5);
    
    // 重新开启写模式，因为 RTMP_SetupStream 会将 r->Link.protocol 直接赋值为 RTMP_PROTOCOL_RTMP (0) 从而清除了 write 位
    RTMP_EnableWrite(context->rtmp);
    
    RTMP_SetBufferMS(context->rtmp, 200);

    if (logCallback) logCallback("Calling RTMP_Connect...");
    if (!RTMP_Connect(context->rtmp, NULL)) {
        if (logCallback) logCallback("RTMP_Connect failed");
        RTMP_Close(context->rtmp);
        return false;
    }
    
    // The key here: we must call RTMP_ConnectStream(r, 0)
    if (logCallback) logCallback("Calling RTMP_ConnectStream...");
    if (!RTMP_ConnectStream(context->rtmp, 0)) {
        if (logCallback) logCallback("RTMP_ConnectStream failed");
        RTMP_Close(context->rtmp);
        return false;
    }

    // Fix: We need to explicitly check m_stream_id in our external logic
    // Just to ensure RTMP_Write has the proper stream_id.
    // If not, RTMP_Write returns 0 immediately due to m_stream_id == 0 check inside it.
    {
        // 诊断：打印服务端分配的 message stream id。iOS15 发包日志里出现 stream=4294967295(=-1)，
        // 这是无效的 RTMP message stream id，会导致服务端拒收媒体并关闭连接。对比 iOS16 取值以确认是否为差异点。
        char sbuf[96];
        snprintf(sbuf, sizeof(sbuf), "m_stream_id after ConnectStream = %d (u=%u)",
                 (int)context->rtmp->m_stream_id, (unsigned)context->rtmp->m_stream_id);
        if (logCallback) logCallback(sbuf);
    }
    if (context->rtmp->m_stream_id == 0) {
        if (logCallback) logCallback("Warning: m_stream_id is still 0 after ConnectStream!");
    }

    if (logCallback) logCallback("LibRTMPSessionOpen completed successfully");
    return true;
}

bool LibRTMPSessionWrite(void *session, const uint8_t *data, int32_t length) {
    LibRTMPContext *context = (LibRTMPContext *)session;
    if (context == NULL || context->rtmp == NULL || data == NULL || length <= 0) {
        return false;
    }

    int written = RTMP_Write(context->rtmp, (const char *)data, (int)length);

    if (written != length) {
        char buf[160];
        snprintf(buf, sizeof(buf), "LibRTMPSessionWrite failed. Expected %d, wrote %d", length, written);
        LibRTMPForwardLog(buf);
        // Do not close it here, let the upper layer decide or let it timeout
        // RTMP_Close(context->rtmp);
        return false;
    }
    return true;
}

bool LibRTMPSessionSendPacket(void *session, uint8_t packetType, uint32_t timestamp, uint32_t channelId, const uint8_t *data, int32_t length) {
    LibRTMPContext *context = (LibRTMPContext *)session;
    if (context == NULL || context->rtmp == NULL || data == NULL || length <= 0) {
        return false;
    }

    if (!RTMP_IsConnected(context->rtmp)) {
        LibRTMPForwardLog("LibRTMPSessionSendPacket failed: RTMP disconnected");
        return false;
    }

    if (context->rtmp->m_stream_id == 0) {
        LibRTMPForwardLog("LibRTMPSessionSendPacket failed: m_stream_id is 0");
        return false;
    }

    RTMPPacket packet;
    RTMPPacket_Reset(&packet);

    if (!RTMPPacket_Alloc(&packet, length)) {
        LibRTMPForwardLog("LibRTMPSessionSendPacket failed: RTMPPacket_Alloc failed");
        return false;
    }

    memcpy(packet.m_body, data, (size_t)length);
    packet.m_packetType = packetType;
    packet.m_nBodySize = (uint32_t)length;
    packet.m_nTimeStamp = timestamp;
    // 我们从 Swift 侧传入的是已经归一化后的 RTMP 绝对时间戳（毫秒）。
    // 配合 fmt=0(LARGE) 按 absolute timestamp 编码，避免被 librtmp 当成 delta。
    packet.m_hasAbsTimestamp = 1;
    packet.m_nChannel = (int)channelId;
    // 这里不能对“新 channel 的首包”发送 fmt=1(MEDIUM)：
    // SRS 会报 fresh chunk starts with fmt=1，并把时间戳/stream id 解析坏，进一步出现异常的负 HLS 时间。
    // 直播场景下带宽损耗可接受，统一强制走 fmt=0(LARGE) 最稳。
    packet.m_headerType = RTMP_PACKET_SIZE_LARGE;
    packet.m_nInfoField2 = context->rtmp->m_stream_id;

    int ok = RTMP_SendPacket(context->rtmp, &packet, 1);
    RTMPPacket_Free(&packet);

    if (!ok) {
        char buf[192];
        snprintf(buf, sizeof(buf), "LibRTMPSessionSendPacket failed. type=%u ts=%u size=%d stream=%u", packetType, timestamp, length, context->rtmp->m_stream_id);
        LibRTMPForwardLog(buf);
        return false;
    }

    return true;
}

bool LibRTMPSessionIsConnected(void *session) {
    LibRTMPContext *context = (LibRTMPContext *)session;
    if (context == NULL || context->rtmp == NULL) {
        return false;
    }
    return RTMP_IsConnected(context->rtmp) != 0;
}

int32_t LibRTMPSessionGetStreamId(void *session) {
    LibRTMPContext *context = (LibRTMPContext *)session;
    if (context == NULL || context->rtmp == NULL) {
        return 0;
    }
    return (int32_t)context->rtmp->m_stream_id;
}

void LibRTMPSessionDestroy(void *session) {
    LibRTMPContext *context = (LibRTMPContext *)session;
    LibRTMPFreeContext(context);
}
