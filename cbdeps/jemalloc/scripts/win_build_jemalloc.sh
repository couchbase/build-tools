set -x
set -e

root_dir=$1
configure_args=$2
install_dir=$3
install_suffix=$4
version=$5

cd "${root_dir}/jemalloc"

full_args="CC=cl CXX=cl ${configure_args} --prefix=${install_dir} --with-install-suffix=${install_suffix}"

# Create skeleton in install directory
mkdir -p ${install_dir}/{Release,Debug,ReleaseAssertions}/{bin,lib}/

# Hack the .vcxproj to honor the install_suffix.
vcxproj="./msvc/projects/vc2017/jemalloc/jemalloc${install_suffix}.vcxproj"
if [ -n "${install_suffix}" ]; then
    mv msvc/projects/vc2017/jemalloc/jemalloc.vcxproj "${vcxproj}"
fi

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
msbuild.exe "${vcxproj}" -property:Configuration=Release -maxcpucount

# Debug build
msbuild.exe "${vcxproj}" -property:Configuration=Debug -maxcpucount

# Copy the build output to the install directory
pushd msvc/projects/vc2017/jemalloc/x64
cp -f Release/jemalloc${install_suffix}.dll ${install_dir}/Release/bin/
cp -f Release/jemalloc${install_suffix}.lib ${install_dir}/Release/lib/
cp -f Release/jemalloc${install_suffix}.pdb ${install_dir}/Release/lib/
cp -f Debug/jemalloc${install_suffix}d.dll ${install_dir}/Debug/bin/
cp -f Debug/jemalloc${install_suffix}d.lib ${install_dir}/Debug/lib
cp -f Debug/jemalloc${install_suffix}d.pdb ${install_dir}/Debug/lib/
popd

# Debugging Assertions build - Built against the Release CRT so it can
# be dropped into a normal Release/RelWithDebInfo build.
./autogen.sh ${full_args} --enable-debug
msbuild.exe "${vcxproj}" -property:Configuration=Release -maxcpucount
pushd msvc/projects/vc2017/jemalloc/x64
cp -f Release/jemalloc${install_suffix}.dll ${install_dir}/ReleaseAssertions/bin/
cp -f Release/jemalloc${install_suffix}.lib ${install_dir}/ReleaseAssertions/lib/
cp -f Release/jemalloc${install_suffix}.pdb ${install_dir}/ReleaseAssertions/lib/
popd

# Create JemallocConfigVersion.cmake to go with our JemallocConfig.cmake
cmake -D OUTPUT=${install_dir}/cmake/ \
    -D VERSION=${version} \
    -D PACKAGE=Jemalloc${install_suffix} \
    -P "${root_dir}/build-tools/cbdeps/scripts/create_config_version.cmake"
