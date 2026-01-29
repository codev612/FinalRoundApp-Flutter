#pragma once

#include <flutter/standard_method_codec.h>
#include <memory>
#include <vector>
#include <deque>
#include <thread>
#include <mutex>
#include <comdef.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>

class AudioCapture {
 public:
  AudioCapture();
  ~AudioCapture();

  bool StartSystemAudio();
  void StopSystemAudio();
  std::vector<uint8_t> GetSystemAudioFrame(size_t requested_bytes);

 private:
  bool is_capturing_ = false;
  bool is_initialized_ = false;
  bool com_initialized_ = false;
  
  // WASAPI components
  IMMDeviceEnumerator* device_enumerator_ = nullptr;
  IMMDevice* loopback_device_ = nullptr;
  IAudioClient* audio_client_ = nullptr;
  IAudioCaptureClient* capture_client_ = nullptr;
    WAVEFORMATEX* capture_format_ = nullptr;
  HANDLE audio_event_ = nullptr;
  std::thread* capture_thread_ = nullptr;
  
  // Audio byte buffer (16kHz mono PCM16)
  std::deque<uint8_t> audio_bytes_;
  std::mutex frames_mutex_;
  
  // Capture thread function
  void CaptureThreadProc();
  
  // Helper functions
  bool InitializeWASAPI();
  void CleanupWASAPI();
  HRESULT FindLoopbackDevice();
};
