#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

class HudPacket {
public:
    static constexpr size_t kMaxMessageBytes = 240;

    void reset() {
        length_ = 0;
        next_ = 0;
    }

    const char *accept(const char *bytes, size_t length, uint32_t now) {
        if (length == 0 || length > 20 || std::memchr(bytes, '\0', length)) {
            reset();
            return nullptr;
        }
        if (bytes[0] != '#') {
            reset();
            std::memcpy(message_, bytes, length);
            message_[length] = '\0';
            return message_;
        }
        if (length < 5) {
            reset();
            return nullptr;
        }
        const int hi = hex(bytes[1]), lo = hex(bytes[2]);
        const bool last = bytes[3] == '!';
        const size_t header = last ? 5 : 4;
        if (hi < 0 || lo < 0 || length <= header || bytes[header - 1] != ',') {
            reset();
            return nullptr;
        }
        const uint8_t sequence = (hi << 4) | lo;
        if (sequence == 0) reset();
        if (sequence != next_ || (sequence && now - lastAt_ > 1000) ||
            length_ + length - header > kMaxMessageBytes) {
            reset();
            return nullptr;
        }
        std::memcpy(message_ + length_, bytes + header, length - header);
        length_ += length - header;
        lastAt_ = now;
        ++next_;
        if (!last) return nullptr;
        message_[length_] = '\0';
        reset();
        return message_;
    }

private:
    static int hex(char ch) {
        if (ch >= '0' && ch <= '9') return ch - '0';
        if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
        if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
        return -1;
    }

    char message_[kMaxMessageBytes + 1]{};
    size_t length_ = 0;
    uint8_t next_ = 0;
    uint32_t lastAt_ = 0;
};
