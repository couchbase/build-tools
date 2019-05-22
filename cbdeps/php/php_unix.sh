#!/bin/bash

set -xe

MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
INSTALL_DIR=$1
PHPVER=$2
BLD_NUM=$3

IGBINARY_VER=2.0.8

DLDIR=build/dl
mkdir -p $DLDIR

TMPDIR=build/tmp
mkdir -p $TMPDIR

SRCDIR=build/src
mkdir -p $SRCDIR

build_php() {

    PHPVER=$1
    VARIANT=$2
    OUTDIR=$3

    pushd $SRCDIR/$OUTDIR

    ZTSARG=''
    if [ "$VARIANT" = 'zts' ]; then
      ZTSARG='--enable-maintainer-zts'
    fi

    PREFIX=$INSTALL_DIR/$OUTDIR
    mkdir -p $PREFIX
    # depends on zlib, libxml2
    ./configure --disable-all --with-zlib --enable-libxml --enable-xml --with-pear --enable-sockets --enable-pcntl --enable-phar=shared --enable-json --enable-cli --prefix=$PREFIX $ZTSARG CFLAGS="-ggdb3
    $CFLAGS" && make -j8 && make install install-sapi install-headers
    (
      cd igbinary-${IGBINARY_VER}
      $PREFIX/bin/phpize
      ./configure --with-php-config=$PREFIX/bin/php-config $($PREFIX/bin/php-config --configure-options) --enable-igbinary CFLAGS="-ggdb3 $CFLAGS"
      make -j4 && make install install-sapi install-headers
    )

    popd
}

build_php_variant() {

    PHPVER=$1
    VARIANT=$2
    OUTDIR=php-$VARIANT-$PHPVER-cb$BLD_NUM

    echo "Installing $VARIANT"
    if [ ! -e $SRCDIR/$OUTDIR ]; then
      tar -xjvf $DLDIR/php-src-$PHPVER.tar.bz2 -C $TMPDIR
      mv $TMPDIR/php-$PHPVER $SRCDIR/$OUTDIR
    fi
    echo "Extracting IGBINARY extension sources for $VARIANT"
    if [ ! -e $SRCDIR/$OUTDIR/igbinary-${IGBINARY_VER} ]; then
      tar -xzvf $DLDIR/igbinary-${IGBINARY_VER}.tgz -C $TMPDIR
      mv $TMPDIR/igbinary-${IGBINARY_VER} $SRCDIR/$OUTDIR/igbinary-${IGBINARY_VER}
    fi
    echo "Building $VARIANT"
    if [ ! -e $INSTALL_DIR/$OUTDIR ]; then
      build_php $PHPVER $VARIANT $OUTDIR
      cp $DLDIR/php-phpunit.phar $INSTALL_DIR/$OUTDIR/
    fi
    echo "Adding $VARIANT Helpers"
    if [ ! -e $INSTALL_DIR/$OUTDIR/phpunit.phar ]; then
      cp $DLDIR/php-phpunit.phar $INSTALL_DIR/$OUTDIR/phpunit.phar
    fi

    # QQQ This step should be removed when this is integrated with cbdeps 2.0 system
    echo "Creating cbdep archive"
    FILEROOT=php-$VARIANT-linux-x86_64-$PHPVER-cb$BLD_NUM
    tar czf $FILEROOT.tgz -C $INSTALL_DIR $OUTDIR
    md5sum $FILEROOT.tgz | cut -c -32 > $FILEROOT.md5
}

echo "Downloading PHP $PHPVER"
[ ! -e  $DLDIR/php-src-$PHPVER.tar.bz2 ]  && curl -Lo $DLDIR/php-src-$PHPVER.tar.bz2 "http://php.net/get/php-$PHPVER.tar.bz2/from/this/mirror"
[ ! -e  $DLDIR/php-phpunit.phar ]         && curl -Lo $DLDIR/php-phpunit.phar "https://phar.phpunit.de/phpunit-5.7.phar"
[ ! -e  $DLDIR/igbinary-${IGBINARY_VER}.tgz ] && curl -Lo $DLDIR/igbinary-${IGBINARY_VER}.tgz "https://pecl.php.net/get/igbinary-${IGBINARY_VER}"

build_php_variant $PHPVER zts
build_php_variant $PHPVER nts
