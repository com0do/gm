// ASan self-test: each deliberate error must be reported (death tests match
// stderr, so no ASAN_OPTIONS=log_path).  Skipped unless SANITIZE=address.

#include <gtest/gtest.h>

#include <cstddef>
#include <cstdlib>

#if defined(__SANITIZE_ADDRESS__)
#define GM_TEST_ASAN 1
#endif

#ifdef GM_TEST_ASAN
#define REQUIRE_ASAN() (void)0
#else
#define REQUIRE_ASAN() GTEST_SKIP() << "not an ASan build (make SANITIZE=address)"
#endif

// volatile: hide the bug from the optimiser and from -Warray-bounds etc.
TEST(Asan, HeapBufferOverflowIsReported) {
    REQUIRE_ASAN();
    EXPECT_DEATH(
        {
            volatile std::size_t n = 8;
            volatile char *p = static_cast<volatile char *>(std::malloc(n));
            p[n] = 1;
        },
        "AddressSanitizer: heap-buffer-overflow");
}

TEST(Asan, HeapUseAfterFreeIsReported) {
    REQUIRE_ASAN();
    EXPECT_DEATH(
        {
            // opaque reload: gcc >= 13 would warn (-Wuse-after-free)
            char *volatile slot = static_cast<char *>(std::malloc(8));
            std::free(slot);
            slot[0] = 1;
        },
        "AddressSanitizer: heap-use-after-free");
}

TEST(Asan, StackBufferOverflowIsReported) {
    REQUIRE_ASAN();
    EXPECT_DEATH(
        {
            char buf[8];
            volatile char *p = buf;
            volatile int idx = 8;
            p[idx] = 1;
        },
        "AddressSanitizer: stack-buffer-overflow");
}

TEST(Asan, CleanAccessesPass) {
    REQUIRE_ASAN();
    char *p = static_cast<char *>(std::malloc(8));
    ASSERT_NE(p, nullptr);
    for (int i = 0; i < 8; ++i) p[i] = static_cast<char>(i);
    EXPECT_EQ(p[7], 7);
    std::free(p);
}
