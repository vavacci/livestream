#ifndef LibRTMPBridge_h
#define LibRTMPBridge_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void *LibRTMPSessionCreate(const char *host, uint16_t port, const char *app, const char *playpath, const char *tcUrl);
bool LibRTMPSessionOpen(void *session, void(*logCallback)(const char *));
bool LibRTMPSessionWrite(void *session, const uint8_t *data, int32_t length);
bool LibRTMPSessionSendPacket(void *session, uint8_t packetType, uint32_t timestamp, uint32_t channelId, const uint8_t *data, int32_t length);
bool LibRTMPSessionIsConnected(void *session);
int32_t LibRTMPSessionGetStreamId(void *session);
void LibRTMPSessionDestroy(void *session);

#ifdef __cplusplus
}
#endif

#endif
