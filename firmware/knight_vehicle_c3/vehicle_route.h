#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

class VehicleRoute {
public:
    static constexpr size_t kMaxPoints = 56;
    struct Point {
        uint8_t x;
        uint8_t y;
    };
    enum class Update { None, Shape, Position, Heartbeat, Clear };

    size_t count = 0;
    uint32_t id = 0;
    Point points[kMaxPoints]{};
    Point position{};
    bool hasPosition = false;
    int32_t remainingMeters = -1;

    void clear() {
        count = 0;
        hasPosition = false;
        remainingMeters = -1;
    }

    Update accept(const char *message) {
        const size_t length = std::strlen(message);
        if (length < 10 || message[1] != ':') return Update::None;
        uint32_t version;
        if (!decodeHex(message + 2, 8, version)) return Update::None;
        if (message[0] == 'C' && length == 10 && count && version == id) {
            clear();
            return Update::Clear;
        }
        if (message[0] == 'K' && length == 10 && count && version == id) return Update::Heartbeat;
        if (length < 11 || message[10] != '|') return Update::None;
        if (message[0] == 'R') {
            const size_t payload = length - 11;
            if (payload < 8 || payload % 4 || payload / 4 > kMaxPoints) return Update::None;
            Point decoded[kMaxPoints]{};
            for (size_t i = 0; i < payload / 4; ++i) {
                if (!decodePoint(message + 11 + 4 * i, decoded[i])) return Update::None;
            }
            clear();
            id = version;
            count = payload / 4;
            std::memcpy(points, decoded, count * sizeof(Point));
            return Update::Shape;
        }
        if (message[0] != 'L' || !count || version != id || length < 17 || length > 22 || message[15] != '|') {
            return Update::None;
        }
        Point decoded;
        if (!decodePoint(message + 11, decoded)) return Update::None;
        int32_t distance = 0;
        for (const char *digit = message + 16; *digit; ++digit) {
            if (*digit < '0' || *digit > '9') return Update::None;
            distance = 10 * distance + (*digit - '0');
        }
        position = decoded;
        hasPosition = true;
        remainingMeters = distance;
        return Update::Position;
    }

private:
    static bool decodeHex(const char *text, size_t size, uint32_t &value) {
        value = 0;
        for (size_t i = 0; i < size; ++i) {
            const char digit = text[i];
            if (digit >= '0' && digit <= '9') value = (value << 4) | (digit - '0');
            else if (digit >= 'a' && digit <= 'f') value = (value << 4) | (digit - 'a' + 10);
            else return false;
        }
        return true;
    }

    static bool decodePoint(const char *text, Point &point) {
        uint32_t value;
        if (!decodeHex(text, 4, value)) return false;
        point = Point{static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value)};
        return true;
    }
};
