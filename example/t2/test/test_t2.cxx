// Unit tests for libt2.  Wired through gm's test target type: no need
// for a main() -- gtest_main is auto-linked (target.c.mk's test
// branch).  Warnings from this file flow to the terminal like every
// other gm compile; there's no per-target .log redirection.

#include <gtest/gtest.h>
#include <t2.hpp>

// Component metadata baked into libt2's rpm via pkg-p2.  The header
// is auto-generated from pkg-p2's PackageStructure.src.xml +
// ComponentDescription.src.xml at build time -- consuming code
// doesn't care about the XML, it just sees the macros.
//
// The include uses the pkg-qualified form `<pkg-p2/component.h>`.
// target.c.mk adds `-I$(GM_GEN_DIR)` (the parent of every pkg's
// header dir) when it sees `PKG_HEADERS := pkg-p2` in this test's
// .mk (via depend.mk's `PKG_OF_test-t2 := pkg-p2` for the auto-
// inherit path).  Macros are PREFIXED with the pkg's derived prefix
// (P2_NAME, P2_MAJOR_VERSION, P2_PKG_VERSION, ...) -- multi-pkg
// consumers reference `P1_...` alongside `P2_...` with no collision.
#include <pkg-p2/component.h>

TEST(T2Basic, IdentityReturnsInput) {
    EXPECT_EQ(t2_cxx(0),  0);
    EXPECT_EQ(t2_cxx(42), 42);
    EXPECT_EQ(t2_cxx(-7), -7);
}

TEST(T2Basic, PackagedComponentMetadata) {
    // Values below are what the pkg-p2 XML currently declares.
    // Component-level (from <Description Name/MajorVersion/MinorVersion>):
    EXPECT_STREQ(P2_NAME, "gm/example/p2");
    EXPECT_EQ(P2_MAJOR_VERSION, 1);
    EXPECT_EQ(P2_MINOR_VERSION, 0);
    EXPECT_GT(P2_UNIQUE_COMPONENT_ID, 0LL);
    // RPM-level (from build .mk's PKG_VERSION / PackageStructure):
    EXPECT_STREQ(P2_PKG_NAME, "pkg-p2");
    EXPECT_STREQ(P2_PKG_VERSION, "1.0");
}

TEST(T2Basic, HandlesExtremes) {
    EXPECT_EQ(t2_cxx(std::numeric_limits<int>::min()),
              std::numeric_limits<int>::min());
    EXPECT_EQ(t2_cxx(std::numeric_limits<int>::max()),
              std::numeric_limits<int>::max());
}
