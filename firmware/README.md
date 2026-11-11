# Firmware

`common/` holds the noise analyzer in portable C: fixed point, no heap, constant time per reading.

- **Works today:** the sensor image compiles it and runs its unit tests during `docker build`
  (a failing test stops the build). The Python simulator calls it through `ctypes`.
- **Next:** the same file on an ESP32 (ESP-IDF + FreeRTOS). An I2S MEMS microphone task feeds
  `na_rms_dbfs_cdb()`, the analyzer task feeds a gatekeeper, and esp-mqtt publishes over mutual
  TLS with the board's own client certificate. Not tested on hardware yet.

Run the tests on your machine: `make -C firmware/common` (needs gcc and make).
