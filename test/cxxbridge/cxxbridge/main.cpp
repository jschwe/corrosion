#include <cxxbridge-cpp/foo/mod.h>
#include <cxxbridge-cpp/lib.h>

int main(int argc, char **argv)
{
    lib::fromLib();
    foo::fromFoo();
}
