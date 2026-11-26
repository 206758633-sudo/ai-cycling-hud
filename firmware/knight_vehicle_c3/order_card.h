#pragma once

#include <cstdint>
#include <cstring>

class OrderCard {
public:
    static constexpr uint32_t kDurationMs = 3000;
    bool visible = false;
    bool timed = false;
    uint32_t shownAt = 0;
    char event[9]{};
    char title[49]{};
    char item[49]{};
    char detail[49]{};

    void hide() {
        visible = false;
        timed = false;
    }

    void reset() {
        hide();
        event[0] = '\0';
    }

    bool accept(const char *message, uint32_t now, bool hasRoute) {
        if (std::strncmp(message, "O:", 2) != 0 || std::strlen(message) < 16 || message[10] != '|') return false;
        for (size_t i = 2; i < 10; ++i) {
            if (!((message[i] >= '0' && message[i] <= '9') || (message[i] >= 'a' && message[i] <= 'f'))) return false;
        }
        if (!std::strncmp(event, message + 2, 8)) return false;
        const char *first = message + 11;
        const char *second = std::strchr(first, '|');
        const char *third = second ? std::strchr(second + 1, '|') : nullptr;
        if (!second || !third) return false;
        const size_t title_length = second - first;
        const size_t item_length = third - second - 1;
        if (!title_length || title_length >= sizeof(title) || !item_length || item_length >= sizeof(item) ||
            std::strlen(third + 1) >= sizeof(detail) || std::strchr(third + 1, '|')) return false;
        std::memcpy(event, message + 2, 8);
        event[8] = '\0';
        std::memcpy(title, first, title_length);
        title[title_length] = '\0';
        std::memcpy(item, second + 1, item_length);
        item[item_length] = '\0';
        std::strcpy(detail, third + 1);
        if (!visible || !timed) shownAt = now;
        visible = true;
        timed = hasRoute;
        return true;
    }

    bool expire(uint32_t now) {
        if (!visible || !timed || now - shownAt < kDurationMs) return false;
        hide();
        return true;
    }
};
