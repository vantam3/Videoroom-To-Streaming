# README — Janus VideoRoom → Streaming (RTP Forward)

Tài liệu này hướng dẫn bạn cấu hình hệ thống **Janus VideoRoom → RTP Forward → Janus Streaming** để người xem có thể xem một luồng WebRTC được phát trực tiếp trên mountpoint của Streaming.

---

## 1) Mục tiêu

* Publisher (trình duyệt/ứng dụng) **join/publish** vào **VideoRoom**.
* VideoRoom **rtp\_forward** audio/video sang **Streaming (mountpoint 7001)** qua UDP.
* Viewer **watch/start** mountpoint và xem luồng.

**Codec mặc định:** Opus (PT=111) + VP8 (PT=96).
**Cổng mặc định:** Audio **6004/6005**, Video **6006/6007** (RTP/RTCP).

---

## 2) Kiến trúc & luồng dữ liệu

```
Publisher(WebRTC) ──> Janus VideoRoom ── rtp_forward (UDP) ──> Janus Streaming (mountpoint 7001)
                                               |                    |  Audio RTP: 6004, RTCP: 6005
                                               |                    |  Video RTP: 6006, RTCP: 6007
                                               v                    v
                                           UDP packets           Viewer(WebRTC)
```

> Lưu ý mạng (Docker):
>
> * Nếu **mountpoint** bind `127.0.0.1` bên trong container Janus, thì **FWD.host** nên là `127.0.0.1` (khi VideoRoom gửi *từ trong cùng container*).
> * Nếu bạn chạy VideoRoom **ngoài container**, đặt **FWD.host** = **IP nội bộ của container** (ví dụ `172.17.0.2`) **hoặc** tạo mountpoint với `-RtpHost 0.0.0.0`.

---

## 3) Yêu cầu

* Docker (chạy image Janus Gateway, ví dụ `canyan/janus-gateway`).
* Node.js 16+ cho các ví dụ server (VideoRoom/Streaming) dựa trên Janode.
* PowerShell (Windows) để chạy script tạo mountpoint (**hoặc** dùng cURL thay thế).
* Các cổng UDP **6004–6007** phải **không bận** trên host/container Janus.

---

## 4) Cấu hình mặc định

* **Mountpoint**: `id = 7001`, `enabled = true`, `type = rtp`, `video=true`, `audio=true`.
* **Payload types**: `video_pt = 96 (VP8/90000)`, `audio_pt = 111 (opus/48000/2)`.
* **Cổng**: `audio_port=6004`, `audio_rtcp_port=6005`, `video_port=6006`, `video_rtcp_port=6007`.
* **Videoroom secret** (nếu phòng yêu cầu): ví dụ `adminpwd` (phải khớp khi gửi `rtp_forward`).

---

## 5) Quick Start (TL;DR)

1. **Chạy Janus** trong Docker.

   ```bash
   docker run -d --name janus \
     -p 8088:8088 -p 8188:8188 \
     -p 6004-6007:6004-6007/udp \
     canyan/janus-gateway
   ```

2. **Tạo mountpoint 7001** (Windows PowerShell):

   ```cd \tools chạy lệnh trên terminal
   .\create_mountpoint.ps1 `
     -JanusUrl "http://127.0.0.1:8088" `
     -Id 7001 -Force `
     -RtpHost "127.0.0.1" `              # hoặc "0.0.0.0"/IP container nếu cần
     -AudioPort 6004 -AudioRtcpPort 6005 `
     -VideoPort 6006 -VideoRtcpPort 6007
   ```

   Kỳ vọng: `Created OK.` và `list/info` thấy mountpoint **7001** với đúng codec/port.

3. **kiểm tra VideoRoom** (file server của bạn):

   ```js
   const FWD = {
     host: '127.0.0.1',     // hoặc '172.17.0.2' nếu gửi từ máy host vào container
     audio_pt: 111,
     video_pt: 96,
     audio_port: 6004, audio_rtcp_port: 6005,
     video_port: 6006, video_rtcp_port: 6007,
   };
   // ... trong body rtp_forward nhớ truyền secret nếu phòng yêu cầu
   ```

4. **Chạy server**:

   * cd vào thư mục VideoRoom server (Node): `node index.js` (hoặc script npm tương ứng).
   * cd vào thư mục Streaming server (Node): `node index.js`.
   * sau khi chạy thành công nếu có chạy tool check viewer thì truy cập: `http://localhost:4444/janode/check.html`.Điều chỉnh tham số rồi start

5. **Publish & Watch**:

   * Publisher join/publish vào room (VideoRoom UI/SDK).
   * Viewer mở trang Streaming UI, `watch id=7001` → nhận `offer` → `start`.

6. **Kiểm tra log**:

   * VideoRoom: thấy `webrtcup`, `sending raw rtp_forward: {...6004/6006...}`, sau đó `rtp_forward REPLY: {...}`.
   * Streaming: thấy `offer sent`, `start response sent`, `status: started`, `webrtcup`.

---

## 6) Chi tiết từng bước

### 6.1 Kiểm tra cổng (trước khi tạo mountpoint)

```bash
# Trên Linux/Container
ss -lun | grep -E ':6004|:6005|:6006|:6007' || echo 'All free'
```

### 6.2 Lấy IP container Janus (nếu cần)

```bash
docker inspect janus --format '{{ .NetworkSettings.IPAddress }}'
# ví dụ: 172.17.0.2
```
### 6.3 Chạy services & kỳ vọng log

* **VideoRoom**: `webrtcup` → `sending raw rtp_forward ... 6004/6006 ...` → `rtp_forward REPLY ...` → `media event receiving=true`.
* **Streaming**: `watch received` → `offer sent` → `start received` → `status: started` → `webrtcup`.

### 6.6 Xem stream

* UI Streaming: `watch({id:7001})` → nhận `offer` (JSEP) → tạo `answer` → `start({id:7001, jsep})` → video phát.
* Kiểm chứng dữ liệu đến mountpoint:

```bash
docker exec -it janus sh -lc 'tcpdump -ni any udp port 6004 or udp port 6006'
```

---
## Tham khảo lệnh nhanh

```powershell
# Tạo mountpoint 7001 (Windows)
.\create_mountpoint.ps1 -JanusUrl "http://127.0.0.1:8088" -Id 7001 -Force `
  -RtpHost "127.0.0.1" -AudioPort 6004 -AudioRtcpPort 6005 -VideoPort 6006 -VideoRtcpPort 6007
```

```bash
# Lấy IP container
docker inspect janus --format '{{ .NetworkSettings.IPAddress }}'

# Theo dõi log container
docker logs -f janus

# Kiểm tra gói RTP đến mountpoint
docker exec -it janus sh -lc 'tcpdump -ni any udp port 6004 or udp port 6006'
```

---

