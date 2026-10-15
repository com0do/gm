
# ASan self-test: each deliberate memory error must be reported.  Skips
# (never passes vacuously) unless built with SANITIZE=address.
#   make SANITIZE=address test TESTS=test-asan

CXXSOURCE += test_asan.cxx
