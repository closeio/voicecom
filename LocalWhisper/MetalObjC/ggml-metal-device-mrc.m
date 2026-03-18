// Wrapper to compile ggml-metal-device.m without ARC
// The original file uses manual retain/release which is incompatible with ARC
#include "../vendor/ggml/src/ggml-metal/ggml-metal-device.m"
