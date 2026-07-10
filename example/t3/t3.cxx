
#include <t1.hpp>
#include <t2.hpp>
#include <iostream>


int main()
{
    using namespace std;

    t1_dump_buildinfo();
    cout << t1_c(1) << endl;
    cout << t1_cxx(2) << endl;
    cout << t2_cxx(3) << endl;
    return 0;
}
