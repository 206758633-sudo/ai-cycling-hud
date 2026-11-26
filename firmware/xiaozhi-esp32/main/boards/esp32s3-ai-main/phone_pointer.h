#pragma once

#include <cstddef>
#include <cstdint>

// Registers the AI-MAIN pointer tools and starts its BLE HID peripheral.
void InitializePhonePointer();
bool KnightPickupBleConnected();
bool SendKnightVoiceRelay(const uint8_t* packet, size_t size);
