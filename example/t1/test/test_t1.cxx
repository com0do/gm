// Second test target -- exercises libt1 (static archive).  Deliberately
// contains an unused variable to confirm that gm does NOT suppress
// compiler warnings the way the a reference build remake system does; the -Wall
// diagnostic must appear directly on the terminal during `make test-t1`.

#include <gtest/gtest.h>
#include <t1.hpp>

TEST(T1Basic, Identity) {
    int unused_local = 42;      // triggers -Wunused-variable
    EXPECT_EQ(t1_cxx(0),   0);
    EXPECT_EQ(t1_cxx(100), 100);
}
