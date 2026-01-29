#include "audio_capture.h"
#include <iostream>
#include <cstring>
#include <algorithm>
#include <vector>
#include <Windows.h>
#include <ksmedia.h>
#include <Functiondiscoverykeys_devpkey.h>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")

namespace {

static bool IsFloatFormat(const WAVEFORMATEX* fmt) {
  if (!fmt) return false;
  if (fmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT && fmt->wBitsPerSample == 32) {
    return true;
  }
  if (fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(fmt);
    return ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT && fmt->wBitsPerSample == 32;
  }
  return false;
}

static bool IsPcm16Format(const WAVEFORMATEX* fmt) {
  if (!fmt) return false;
  if (fmt->wFormatTag == WAVE_FORMAT_PCM && fmt->wBitsPerSample == 16) {
    return true;
  }
  if (fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(fmt);
    return ext->SubFormat == KSDATAFORMAT_SUBTYPE_PCM && fmt->wBitsPerSample == 16;
  }
  return false;
}

static float ClampFloat(float v) {
  if (v < -1.0f) return -1.0f;
  if (v > 1.0f) return 1.0f;
  return v;
}

static int16_t FloatToPcm16(float v) {
  v = ClampFloat(v);
  const float scaled = v * 32767.0f;
  if (scaled < -32768.0f) return -32768;
  if (scaled > 32767.0f) return 32767;
  return static_cast<int16_t>(scaled);
}

// Convert interleaved input to mono float samples.
static bool ToMonoFloat(const WAVEFORMATEX* fmt,
                        const uint8_t* input,
                        uint32_t frames,
                        std::vector<float>& outMono) {
  outMono.clear();
  if (!fmt || !input || frames == 0) return false;
  const uint16_t channels = fmt->nChannels;
  if (channels == 0) return false;

  outMono.resize(frames);

  if (IsFloatFormat(fmt)) {
    const float* f = reinterpret_cast<const float*>(input);
    for (uint32_t i = 0; i < frames; i++) {
      float sum = 0.0f;
      for (uint16_t ch = 0; ch < channels; ch++) {
        sum += f[i * channels + ch];
      }
      outMono[i] = sum / static_cast<float>(channels);
    }
    return true;
  }

  if (IsPcm16Format(fmt)) {
    const int16_t* s = reinterpret_cast<const int16_t*>(input);
    for (uint32_t i = 0; i < frames; i++) {
      int32_t sum = 0;
      for (uint16_t ch = 0; ch < channels; ch++) {
        sum += s[i * channels + ch];
      }
      const float avg = static_cast<float>(sum) / static_cast<float>(channels) / 32768.0f;
      outMono[i] = avg;
    }
    return true;
  }

  // Unknown format; treat as silence.
  std::fill(outMono.begin(), outMono.end(), 0.0f);
  return true;
}

// Linear resample mono float from inRate to outRate.
static void ResampleLinear(const std::vector<float>& inMono,
                           uint32_t inRate,
                           uint32_t outRate,
                           std::vector<float>& outMono) {
  outMono.clear();
  if (inMono.empty() || inRate == 0 || outRate == 0) return;
  if (inRate == outRate) {
    outMono = inMono;
    return;
  }

  const double ratio = static_cast<double>(outRate) / static_cast<double>(inRate);
  const size_t outCount = static_cast<size_t>(std::max(1.0, std::floor(inMono.size() * ratio)));
  outMono.resize(outCount);

  for (size_t j = 0; j < outCount; j++) {
    const double pos = (static_cast<double>(j) * static_cast<double>(inRate)) / static_cast<double>(outRate);
    const size_t i0 = static_cast<size_t>(std::floor(pos));
    const size_t i1 = (i0 + 1 < inMono.size()) ? (i0 + 1) : i0;
    const double frac = pos - static_cast<double>(i0);
    const float s0 = inMono[i0];
    const float s1 = inMono[i1];
    outMono[j] = static_cast<float>((1.0 - frac) * s0 + frac * s1);
  }
}

static void MonoFloatToPcm16Bytes(const std::vector<float>& inMono,
                                  std::vector<uint8_t>& outBytes) {
  outBytes.clear();
  outBytes.resize(inMono.size() * 2);
  for (size_t i = 0; i < inMono.size(); i++) {
    const int16_t s = FloatToPcm16(inMono[i]);
    outBytes[i * 2 + 0] = static_cast<uint8_t>(s & 0xFF);
    outBytes[i * 2 + 1] = static_cast<uint8_t>((s >> 8) & 0xFF);
  }
}

}  // namespace

AudioCapture::AudioCapture() : is_capturing_(false), is_initialized_(false) {
}

AudioCapture::~AudioCapture() {
  StopSystemAudio();
  CleanupWASAPI();
}

bool AudioCapture::StartSystemAudio() {
  // IMPORTANT:
  // The default render device can change during a meeting (headset unplug/replug),
  // which invalidates the existing loopback endpoint. To recover reliably, always
  // reinitialize WASAPI on (re)start so we bind to the current default device.
  StopSystemAudio();
  CleanupWASAPI();
  is_initialized_ = false;

  if (!InitializeWASAPI()) {
    std::cerr << "[AudioCapture] Failed to initialize WASAPI" << std::endl;
    return false;
  }
  is_initialized_ = true;
  
  if (!audio_event_) {
    std::cerr << "[AudioCapture] Audio event handle is missing" << std::endl;
    return false;
  }

  // Clear any buffered audio from a previous run.
  {
    std::lock_guard<std::mutex> lock(frames_mutex_);
    audio_bytes_.clear();
  }

  is_capturing_ = true;
  capture_thread_ = new std::thread(&AudioCapture::CaptureThreadProc, this);

  if (FAILED(audio_client_->Start())) {
    std::cerr << "[AudioCapture] Failed to start audio client" << std::endl;
    is_capturing_ = false;
    if (capture_thread_) {
      capture_thread_->join();
      delete capture_thread_;
      capture_thread_ = nullptr;
    }
    return false;
  }
  
  return true;
}

void AudioCapture::StopSystemAudio() {
  if (is_capturing_) {
    is_capturing_ = false;
    
    // Wake the capture thread immediately (it may be blocked waiting on the event).
    if (audio_event_) {
      SetEvent(audio_event_);
    }

    if (audio_client_) {
      audio_client_->Stop();
    }
    
    if (capture_thread_) {
      capture_thread_->join();
      delete capture_thread_;
      capture_thread_ = nullptr;
    }
  }
}

std::vector<uint8_t> AudioCapture::GetSystemAudioFrame(size_t requested_bytes) {
  if (requested_bytes == 0) {
    return std::vector<uint8_t>();
  }

  std::lock_guard<std::mutex> lock(frames_mutex_);

  const size_t available = audio_bytes_.size();
  if (available == 0) {
    return std::vector<uint8_t>();
  }

  const size_t to_copy = (std::min)(requested_bytes, available);
  std::vector<uint8_t> out;
  out.reserve(to_copy);
  for (size_t i = 0; i < to_copy; i++) {
    out.push_back(audio_bytes_.front());
    audio_bytes_.pop_front();
  }
  return out;
}

bool AudioCapture::InitializeWASAPI() {
  // Initialize COM library (may already be initialized by Flutter as STA).
  // If CoInitializeEx returns RPC_E_CHANGED_MODE, proceed but DO NOT call CoUninitialize.
  const HRESULT comHr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  com_initialized_ = (comHr == S_OK || comHr == S_FALSE);
  
  // Create device enumerator
  HRESULT hr = CoCreateInstance(
    __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
    __uuidof(IMMDeviceEnumerator), (void**)&device_enumerator_);
  
  if (FAILED(hr)) {
    std::cerr << "[AudioCapture] Failed to create device enumerator" << std::endl;
    if (com_initialized_) {
      CoUninitialize();
      com_initialized_ = false;
    }
    return false;
  }
  
  // Find the default render endpoint (speaker) for WASAPI loopback.
  if (FAILED(FindLoopbackDevice())) {
    std::cerr << "[AudioCapture] Failed to find default render device for loopback." << std::endl;
    if (com_initialized_) {
      CoUninitialize();
      com_initialized_ = false;
    }
    return false;
  }
  
  // Activate audio client
  hr = loopback_device_->Activate(
    __uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&audio_client_);
  
  if (FAILED(hr)) {
    std::cerr << "[AudioCapture] Failed to activate audio client" << std::endl;
    if (com_initialized_) {
      CoUninitialize();
      com_initialized_ = false;
    }
    return false;
  }
  
  // Loopback capture requires using the endpoint mix format.
  if (capture_format_) {
    CoTaskMemFree(capture_format_);
    capture_format_ = nullptr;
  }

  hr = audio_client_->GetMixFormat(&capture_format_);
  if (FAILED(hr) || capture_format_ == nullptr) {
    std::cerr << "[AudioCapture] Failed to get endpoint mix format" << std::endl;
    if (com_initialized_) {
      CoUninitialize();
      com_initialized_ = false;
    }
    return false;
  }

  std::cout << "[AudioCapture] Endpoint mix format: "
            << capture_format_->nChannels << " ch, "
            << capture_format_->nSamplesPerSec << " Hz, "
            << capture_format_->wBitsPerSample << " bits" << std::endl;

  hr = audio_client_->Initialize(
      AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
      0, 0, capture_format_, nullptr);
  
  if (FAILED(hr)) {
    std::cerr << "[AudioCapture] Failed to initialize audio client" << std::endl;
    if (com_initialized_) {
      CoUninitialize();
      com_initialized_ = false;
    }
    return false;
  }

  // Set audio event (used by AUDCLNT_STREAMFLAGS_EVENTCALLBACK)
  if (audio_event_ == nullptr) {
    audio_event_ = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  }
  
  hr = audio_client_->SetEventHandle(audio_event_);
  if (FAILED(hr)) {
    std::cerr << "[AudioCapture] Failed to set event handle" << std::endl;
    if (com_initialized_) {
      CoUninitialize();
      com_initialized_ = false;
    }
    return false;
  }
  
  // Get capture client
  hr = audio_client_->GetService(__uuidof(IAudioCaptureClient), (void**)&capture_client_);
  
  if (FAILED(hr)) {
    std::cerr << "[AudioCapture] Failed to get capture client" << std::endl;
    if (com_initialized_) {
      CoUninitialize();
      com_initialized_ = false;
    }
    return false;
  }

  return true;
}

void AudioCapture::CleanupWASAPI() {
  StopSystemAudio();
  
  if (capture_client_) {
    capture_client_->Release();
    capture_client_ = nullptr;
  }
  
  if (audio_client_) {
    audio_client_->Release();
    audio_client_ = nullptr;
  }
  
  if (audio_event_) {
    CloseHandle(audio_event_);
    audio_event_ = nullptr;
  }

  if (capture_format_) {
    CoTaskMemFree(capture_format_);
    capture_format_ = nullptr;
  }

  if (loopback_device_) {
    loopback_device_->Release();
    loopback_device_ = nullptr;
  }
  
  if (device_enumerator_) {
    device_enumerator_->Release();
    device_enumerator_ = nullptr;
  }

  if (com_initialized_) {
    CoUninitialize();
    com_initialized_ = false;
  }
}

HRESULT AudioCapture::FindLoopbackDevice() {
  // Use default render endpoint (speakers/headphones). Loopback flag will capture
  // what is being played through this endpoint.
  if (loopback_device_) {
    loopback_device_->Release();
    loopback_device_ = nullptr;
  }
  HRESULT hr = device_enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, &loopback_device_);
  if (FAILED(hr)) {
    std::cerr << "[AudioCapture] Failed to get default render endpoint" << std::endl;
    return hr;
  }
  return S_OK;
}

void AudioCapture::CaptureThreadProc() {
  // COM must be initialized per-thread before using COM interfaces.
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  
  // Keep timeout short so StopSystemAudio doesn't block UI for seconds.
  const DWORD max_wait = 200; // ms
  
  while (is_capturing_) {
    DWORD wait_result = WaitForSingleObject(audio_event_, max_wait);
    
    if (wait_result == WAIT_OBJECT_0) {
      if (!is_capturing_) break;
      if (!capture_client_ || !capture_format_) {
        continue;
      }
      UINT32 next_packet_size = 0;
      
      while (SUCCEEDED(capture_client_->GetNextPacketSize(&next_packet_size)) && 
             next_packet_size > 0) {
        BYTE* buffer = nullptr;
        DWORD flags = 0;
        UINT32 frames_read = 0;
        
        HRESULT hr = capture_client_->GetBuffer(&buffer, &frames_read, &flags, nullptr, nullptr);
        
        if (SUCCEEDED(hr)) {
          if (!capture_format_) {
            capture_client_->ReleaseBuffer(frames_read);
            continue;
          }

          const size_t bytes_available = static_cast<size_t>(frames_read) * capture_format_->nBlockAlign;
          if (bytes_available > 0) {
            // Pull raw bytes
            std::vector<uint8_t> raw;
            raw.resize(bytes_available);
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
              memset(raw.data(), 0, bytes_available);
            } else {
              memcpy(raw.data(), buffer, bytes_available);
            }

            // Convert to 16kHz mono PCM16 so Dart can mix with mic audio safely.
            std::vector<float> mono;
            std::vector<float> mono16k;
            std::vector<uint8_t> outPcm16;

            if (ToMonoFloat(capture_format_, raw.data(), frames_read, mono)) {
              ResampleLinear(mono, capture_format_->nSamplesPerSec, 16000, mono16k);
              MonoFloatToPcm16Bytes(mono16k, outPcm16);
            }

            if (!outPcm16.empty()) {
              std::lock_guard<std::mutex> lock(frames_mutex_);
              // Append bytes.
              for (const auto b : outPcm16) {
                audio_bytes_.push_back(b);
              }

              // Cap buffer to ~2 seconds of audio at 16kHz mono PCM16.
              // 16000 samples/sec * 2 bytes/sample * 2 sec = 64000 bytes.
              while (audio_bytes_.size() > 64000) {
                audio_bytes_.pop_front();
              }
            }
          }

          capture_client_->ReleaseBuffer(frames_read);
        } else {
          // Common when device changes while capturing.
          // Just break and let the outer loop continue (StopSystemAudio or restart will handle reinit).
          break;
        }
      }
    }
  }
  
  CoUninitialize();
}
