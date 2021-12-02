#!/bin/bash

set -xe

MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
INSTALL_DIR=$1
PHPVER=$2
BLD_NUM=$3
ARCH=$4

PHPUNIT_VER=9.4.3

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
        case "$PHPVER" in
            7.*)
                ZTSARG='--enable-maintainer-zts'
                ;;
            *)
                ZTSARG='--enable-zts'
                ;;
        esac
    fi
    JSON_OPT=''
    case "$PHPVER" in
        7.*)
            JSON_OPT='--enable-json'
            ;;
        *)
            # always enabled since 8.0
            ;;
    esac

    PREFIX=$INSTALL_DIR/$OUTDIR
    mkdir -p $PREFIX
    # figure out which option enables libxml
    LIBXML_OPT=--with-libxml
    ./configure --help | grep disable-libxml && LIBXML_OPT=--enable-libxml
    ./configure --disable-all \
        --enable-option-checking=fatal \
        --enable-sockets \
        --enable-pcntl \
        --enable-phar \
        ${JSON_OPT} \
        --enable-cli \
        --with-zlib \
        ${LIBXML_OPT} --enable-xml \
        --with-pear \
        --prefix=$PREFIX $ZTSARG CFLAGS="-ggdb3 $CFLAGS"
    make -j8
    make install install-sapi install-headers
    popd
}

build_php_variant() {

    PHPVER=$1
    VARIANT=$2
    OUTDIR=php-$VARIANT-$PHPVER-cb$BLD_NUM

    echo "Installing $VARIANT"
    if [ ! -e $SRCDIR/$OUTDIR ]; then
      tar -xjf $DLDIR/php-src-$PHPVER.tar.bz2 -C $TMPDIR
      mv $TMPDIR/php-$PHPVER $SRCDIR/$OUTDIR
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
    FILEROOT=php-$VARIANT-linux-${ARCH}-$PHPVER-cb$BLD_NUM
    tar czf $FILEROOT.tgz -C $INSTALL_DIR $OUTDIR
    md5sum $FILEROOT.tgz | cut -c -32 > $FILEROOT.md5
}

echo "Downloading PHP $PHPVER"
[ ! -e  $DLDIR/php-src-$PHPVER.tar.bz2 ]  && curl -Lo $DLDIR/php-src-$PHPVER.tar.bz2 "http://php.net/get/php-$PHPVER.tar.bz2/from/this/mirror"
[ ! -e  $DLDIR/php-phpunit.phar ]         && curl -Lo $DLDIR/php-phpunit.phar "https://phar.phpunit.de/phpunit-$PHPUNIT_VER.phar"

build_php_variant $PHPVER zts
build_php_variant $PHPVER nts
