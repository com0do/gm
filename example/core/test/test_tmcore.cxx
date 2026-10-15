// Unit tests for libtmcore: CRC-32 against its standard check value, the ring's overwrite
// order, and the generated build information.
#include <gtest/gtest.h>
#include <tm/core.h>

#include <cstring>
#include <memory>
#include <string>

TEST(Crc32, MatchesTheStandardCheckValue) {
    // The CRC-32 "check" value: the CRC of the ASCII digits 1 to 9.
    EXPECT_EQ(tm_crc32("123456789", 9), 0xCBF4'3926u);
    EXPECT_EQ(tm_crc32("", 0), 0u);
}

TEST(Crc32, UpdatingInPiecesEqualsOneShot) {
    const char *msg = "telemetry sample stream";
    const std::size_t n = std::strlen(msg);
    std::uint32_t crc = tm_crc32_update(0, msg, 9);
    crc = tm_crc32_update(crc, msg + 9, n - 9);
    EXPECT_EQ(crc, tm_crc32(msg, n));
}

TEST(Ring, RejectsABadCapacity) {
    auto r = std::make_unique<tm_ring>();
    EXPECT_EQ(tm_ring_init(r.get(), 0), -1);
    EXPECT_EQ(tm_ring_init(r.get(), TM_RING_MAX + 1), -1);
    EXPECT_EQ(tm_ring_init(r.get(), 3), 0);
}

TEST(Ring, KeepsTheNewestSamplesOldestFirst) {
    auto r = std::make_unique<tm_ring>();
    ASSERT_EQ(tm_ring_init(r.get(), 3), 0);
    for (int i = 1; i <= 5; ++i)
        tm_ring_push(r.get(), i);

    double out[3] = {};
    ASSERT_EQ(tm_ring_copy(r.get(), out, 3), 3u);
    EXPECT_DOUBLE_EQ(out[0], 3);
    EXPECT_DOUBLE_EQ(out[2], 5);
    EXPECT_EQ(r->total, 5u);

    double newest[2] = {};
    ASSERT_EQ(tm_ring_copy(r.get(), newest, 2), 2u);
    EXPECT_DOUBLE_EQ(newest[0], 4);
    EXPECT_DOUBLE_EQ(newest[1], 5);
}

TEST(Version, NamesTheLibraryAndItsBuild) {
    const std::string v = tm_core_version();
    EXPECT_EQ(v.rfind("libtmcore 1.4.0 (", 0), 0u) << v;
}
