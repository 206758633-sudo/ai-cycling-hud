#pragma once

#include <cstddef>
#include <cstdint>

void InitializeKnightOrders();
bool ReceiveKnightPickupFeedback(const uint8_t* packet, size_t size);
