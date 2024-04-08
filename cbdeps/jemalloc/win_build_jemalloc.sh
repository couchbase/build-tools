set -x
set -e

configure_args=$1
install_dir=$2
install_suffix=$3

full_args="CC=cl CXX=cl ${configure_args} --prefix=${install_dir} --with-install-suffix=${install_suffix}"

# Create skeleton in install directory
mkdir -p ${install_dir}/{Release,Debug,ReleaseAssertions}/{bin,lib}/

# Configure build
./autogen.sh ${full_args}

# Install headers and "bin" tools (scripts)
make install_include install_bin

# Fix up installed jemalloc.h if it got renamed
if [ ! -z "${install_suffix}" ]; then
    pushd ${install_dir}/include/jemalloc
    mv jemalloc${install_suffix}.h jemalloc.h
    popd
fi

# Need strings.h and more on Windows. Jemalloc supplies it, copy manually
cp -r include/msvc_compat ${install_dir}/include

# Perform actual builds with msbuild and jemalloc.vcxproj as this is now
# the supported build method on Windows.
# Release build
msbuild.exe ./msvc/projects/vc2017/jemalloc/jemalloc.vcxproj -property:Configuration=Release -maxcpucount

# Debug build
msbuild.exe ./msvc/projects/vc2017/jemalloc/jemalloc.vcxproj -property:Configuration=Debug -maxcpucount

# Copy the build output to the install directory
pushd msvc/projects/vc2017/jemalloc/x64
cp -f Release/jemalloc.dll ${install_dir}/Release/bin/jemalloc${install_suffix}.dll
cp -f Release/jemalloc.lib ${install_dir}/Release/lib/jemalloc${install_suffix}.lib
cp -f Release/jemalloc.pdb ${install_dir}/Release/lib/jemalloc${install_suffix}.pdb
cp -f Debug/jemallocd.dll ${install_dir}/Debug/bin/jemalloc${install_suffix}d.dll
cp -f Debug/jemallocd.lib ${install_dir}/Debug/lib/jemalloc${install_suffix}d.lib
cp -f Debug/jemallocd.pdb ${install_dir}/Debug/lib/jemalloc${install_suffix}d.pdb
popd

# Debugging Assertions build - Built against the Release CRT so it can
# be dropped into a normal Release/RelWithDebInfo build.
./autogen.sh ${full_args} --enable-debug
msbuild.exe ./msvc/projects/vc2017/jemalloc/jemalloc.vcxproj -property:Configuration=Release -maxcpucount
pushd msvc/projects/vc2017/jemalloc/x64
cp -f Release/jemalloc.dll ${install_dir}/ReleaseAssertions/bin/jemalloc${install_suffix}.dll
cp -f Release/jemalloc.lib ${install_dir}/ReleaseAssertions/lib/jemalloc${install_suffix}.lib
cp -f Release/jemalloc.pdb ${install_dir}/ReleaseAssertions/lib/jemalloc${install_suffix}.pdb
popd
