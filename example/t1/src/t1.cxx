
#include <t1.hpp>
#include <t1_buildinfo.h>
#include <iostream>


int t1_cxx(int a) { return a; }

void t1_dump_buildinfo()
{
    using namespace std;
    cout << T1_TARGET << " v" << T1_VERSION
         << " by " << T1_VENDOR
         << " (" << T1_BUILD_MODE << "/" << T1_BUILD_ARCH << ")"
         << endl;
}
