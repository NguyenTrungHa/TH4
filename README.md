# Bài thực hành 04 — Gửi dữ liệu qua MQTT

**Học phần:** CSE3069 — Phát triển ứng dụng IoT  
**Họ và tên:** Nguyễn Trung Hà  
**MSSV:** 23110323  

## 1. Mục tiêu và mô hình hệ thống

Bài TH04 triển khai giao tiếp MQTT giữa mô hình nhà kính sử dụng ESP32 và Mosquitto Broker trên máy tính. Firmware ESP32 được viết theo mô hình FreeRTOS, tách công việc đọc cảm biến, gửi dữ liệu MQTT, quản lý Wi-Fi và điều khiển an toàn. Broker chạy bằng Docker Compose; giao diện Web HTML/CSS/JavaScript là phần mở rộng để theo dõi trạng thái và gửi lệnh.

### Cấu trúc các file

| Đường dẫn | Vai trò |
|---|---|
| `broker/docker-compose.yml` | Khởi chạy Mosquitto trong Docker, publish TCP `1883` và WebSocket `9001` |
| `broker/mosquitto/config/mosquitto.conf` | Cấu hình listener và yêu cầu xác thực |
| `firmware/` | Mã nguồn PlatformIO/ESP32, FreeRTOS và các task |
| `README.md` | Báo cáo ngắn và trả lời câu hỏi 4.1–4.4 |

## 2. Trả lời 4 câu hỏi của bài thực hành

### 4.1. Payload thực tế

**Topic được định nghĩa trong `firmware/src/config.h`:**

```text
nhom01/node01/telemetry
```

Firmware hiện tại đặt chu kỳ gửi dữ liệu là **10.000 ms**. Nội dung JSON được xây dựng trong `firmware/src/mqtt_task.cpp`, gồm:

| Trường | Ý nghĩa | Đơn vị / cách hiểu |
|---|---|---|
| `device_id` | Mã định danh thiết bị phát | `node01` |
| `ts` | Thời điểm ghi nhận mẫu cảm biến | Số mili giây từ lúc ESP32 khởi động; **không phải** giờ Unix |
| `ts_unit` | Cách diễn giải `ts` | `uptime_ms` |
| `temp` | Nhiệt độ đo được | Độ C (`C`) |
| `humi` | Độ ẩm tương đối | Phần trăm (`%`) |
| `units` | Đơn vị của nhiệt độ và độ ẩm | `units.temp`, `units.humi` |
| `valid` | Mẫu nhiệt độ/độ ẩm có hợp lệ và còn mới hay không | `true` / `false` |
| `rain` | Dữ liệu cảm biến mưa | Hiện mã MQTT đặt `null` |
| `rain_valid` | Cờ chất lượng dữ liệu mưa | Hiện mã MQTT đặt `false` |

### 4.2. Task và queue

Firmware `mqtt-main/firmware/src/main.cpp` tạo **4 task FreeRTOS** bằng `xTaskCreatePinnedToCore()`:

| Task | Core / ưu tiên | Công việc chính | Chu kỳ xử lý |
|---|---|---|---|
| `Safety` (`fsmTask`) | Core 0 / 3 | Kiểm tra điều kiện an toàn, xử lý lệnh, cập nhật PWM cho LED1, LED2 và MOTOR1 | Khoảng 20 ms |
| `Sensors` (`sensorTask`) | Core 1 / 2 | Đọc dữ liệu nhiệt độ/độ ẩm từ UNO qua I²C, kiểm tra hợp lệ | Khoảng 2.000 ms |
| `MQTT` (`mqttTask`) | Core 1 / 1 | Kết nối Broker, subscribe lệnh, publish trạng thái và telemetry | Vòng lặp 50 ms; telemetry 10 s; state 1 s |
| `WiFi` (`wifiTask`) | Core 0 / 2 | Theo dõi và thử kết nối lại mạng Wi-Fi | Kiểm tra khoảng 10 s |

**Queue được khai báo và sử dụng như sau:**

1. **`sensorQueue` — dung lượng 1 `SensorData`:** Tạo bằng `xQueueCreate(1, sizeof(SensorData))`. Task `Sensors` gọi `xQueueOverwrite()` để giữ **mẫu mới nhất**; mẫu cũ có thể bị ghi đè khi có mẫu mới. Tuy nhiên, ở bản mã hiện tại, `mqttTask` **chưa đọc từ queue này** mà lấy một bản sao trạng thái cảm biến qua `readControl()`. Vì vậy, queue này chưa hình thành luồng truyền Sensors → MQTT qua `xQueueReceive()` như một phương án hoàn chỉnh.
2. **`commands` — dung lượng 8 `Command`:** Callback MQTT gọi `xQueueSend(..., 0)` để đưa lệnh bật/điều chỉnh công suất vào queue. `Safety` đọc bằng `xQueueReceive(..., 0)`; nếu đầy, thao tác gửi trả về thất bại ngay, **không chờ vô hạn**. Lệnh dừng (công suất 0) đi qua cờ `stops` riêng nhằm ưu tiên tắt tải ngay cả khi queue lệnh đang đầy.

**Vì sao task an toàn không bị MQTT chặn?** `Safety` chạy độc lập với task mạng; các lần đọc queue đều có thời gian chờ bằng 0, không thực hiện lệnh kết nối MQTT. Điều kiện an toàn trong mã kiểm tra Broker/heartbeat, độ hợp lệ và tuổi của mẫu, đồng thời giới hạn mỗi lần bật tải tối đa 20 giây. Khi mất kết nối hoặc dữ liệu cảm biến lỗi/cũ, logic điều khiển đưa công suất về 0 và không tự bật lại tải sau khi mạng phục hồi. Đây là cách thiết kế nhằm tránh việc mạng chậm làm treo đường điều khiển an toàn; kết quả thực tế vẫn cần được kiểm chứng bằng log và thử nghiệm trên phần cứng.

### 4.3. Kết quả thí nghiệm ngắt kết nối

**Cách thí nghiệm theo đề:** Khi ESP32 và một máy subscriber đã nhận được dữ liệu ổn định, dừng Mosquitto khoảng 30 giây rồi khởi động lại. Đồng thời, ghi Serial Monitor, thời gian các vòng an toàn và log Broker. Mục tiêu là xác minh: (1) ESP32 phát hiện mất kết nối; (2) vòng an toàn không bị đứng; (3) ESP32 tự kết nối lại; (4) dữ liệu được gửi trở lại.

**Phân tích từ `log_disconnect.txt`:**

| Mốc thời gian, ngày 17/11/2026 | Sự kiện quan sát |
|---|---|
| **18:01:01** | Broker dừng |
| **18:01:02.221** | ESP32 báo `MQTT,...,disconnected` |
| **18:01:02.664 → 13:08:22.665** | `TIMER` tăng từ tick 5 lên tick 15, chu kỳ xấp xỉ 2 giây |
| **18:01:14.889 → 13:08:22.907** | Queue đầy; 5 mẫu mới bị bỏ |
| **18:01:31** | Broker khởi động lại, tổng thời gian tắt 30 giây |
| **18:01:33.235** | Mosquitto ghi nhận client `ESP32_a2D62C` kết nối lại, khoảng 2,2 giây sau khi Broker khởi động |

Nhật ký cho thấy các lần thử kết nối MQTT bị lỗi trong lúc Broker ngừng, nhưng dòng `TIMER` vẫn được xử lý đều. Điều đó **ủng hộ nhận định vòng phục vụ timer không bị khóa bởi tác vụ mạng trong đoạn đã ghi**. Tuy nhiên, đoạn serial dừng lúc 13:01:22.907, **trước thời điểm Broker được bật lại**, nên log serial không chứng minh toàn bộ 30 giây cũng như không ghi lại giá trị GPIO/tải sau khi hồi phục. Việc kết nối lại được xác nhận riêng bởi log Mosquitto, không phải bởi dòng serial sau khi khởi động lại.


## 3. Hướng dẫn chạy và kiểm tra

### Khởi chạy Broker

```powershell
cd broker
docker compose up -d
docker compose ps
docker compose logs -f mqtt-broker
```

Broker được cấu hình lắng nghe TCP `1883` cho ESP32 và WebSocket `9001` cho Web. Tài khoản MQTT được quản lý bằng password file nằm ngoài Git, không ghi mật khẩu thật vào repository.

### Nạp chương trình ESP32

Tạo `firmware/src/secrets.h` từ `secrets.example.h`, cấu hình Wi-Fi và địa chỉ IP LAN của laptop. Không commit file này. Chạy từ thư mục `firmware`:

```powershell
& "$env:USERPROFILE\.platformio\penv\Scripts\platformio.exe" run -e esp32dev
& "$env:USERPROFILE\.platformio\penv\Scripts\platformio.exe" run -e esp32dev -t upload --upload-port COM4
& "$env:USERPROFILE\.platformio\penv\Scripts\platformio.exe" device monitor -p COM4 -b 115200
```

### Mở Web Dashboard (phần mở rộng)

Từ thư mục gốc repository:

```powershell
python -m http.server 8084 --bind 127.0.0.1 --directory web
```

Mở `http://localhost:8084` và kết nối WebSocket `ws://localhost:9001` với tài khoản MQTT.

