{ pkgs ? import <nixpkgs> {} }:

let
    bflat = pkgs.stdenv.mkDerivation rec {
        pname = "bflat";
        version = "10.0.0-rc.1";

        src = pkgs.fetchurl {
            url = "https://github.com/bflattened/bflat/releases/download/v${version}/bflat-${version}-linux-glibc-x64.tar.gz";
            sha256 = "sha256-Vy02v7unmoZBx3oj5+wQtKNmPTEWhzhWipBZFU80v8M=";
        };

        nativeBuildInputs = with pkgs; [
            autoPatchelfHook
            makeWrapper
        ];

        buildInputs = with pkgs; [
            glibc
            zlib
            stdenv.cc.cc.lib
        ];
        
        dontBuild = true;
        setSourceRoot = "sourceRoot=$PWD";

        installPhase = ''
            # BƯỚC 1: Tạo phân vùng cô lập tuyệt đối
            mkdir -p $out/bin
            mkdir -p $out/libexec/bflat

            # BƯỚC 2: Xả toàn bộ file nén gốc vào vùng biệt giam 'libexec'
            cp -r * $out/libexec/bflat/

            # BƯỚC 3: TẬN DIỆT TRIỆT ĐỂ toàn bộ đống glibc đồ cổ đi kèm ở mọi ngóc ngách
            find $out/libexec/bflat -type d -name "glibc" -exec rm -rf {} +

            # BƯỚC 4: Tạo lại thư mục glibc lõi và cắm symlink trỏ thẳng về glibc xịn của NixOS
            INTERNAL_GLIBC_DIR="$out/libexec/bflat/lib/linux/x64/glibc"
            mkdir -p "$INTERNAL_GLIBC_DIR"
            ln -s ${pkgs.glibc}/lib/libc.so.6 "$INTERNAL_GLIBC_DIR/libc.so.6"
            ln -s ${pkgs.glibc}/lib/libm.so.6 "$INTERNAL_GLIBC_DIR/libm.so.6"
            ln -s ${pkgs.glibc}/lib/librt.so.1 "$INTERNAL_GLIBC_DIR/librt.so.1"
            ln -s ${pkgs.glibc}/lib/libdl.so.2 "$INTERNAL_GLIBC_DIR/libdl.so.2"
            ln -s ${pkgs.glibc}/lib/libpthread.so.0 "$INTERNAL_GLIBC_DIR/libpthread.so.0"

            # BƯỚC 5: ĐƯA LỆNH RA NGOÀI VÙNG BIN
            # Tạo symlink cho file thực thi bflat chính ra $out/bin
            ln -s $out/libexec/bflat/bflat $out/bin/bflat

            # Nếu bflat có đống công cụ lld, llvm-objcopy đi kèm trong thư mục bin của nó,
            # ta lôi cổ tụi nó ra vùng $out/bin toàn cục luôn để script build.sh của mày gọi được luôn
            if [ -d "$out/libexec/bflat/bin" ]; then
                for tool in $out/libexec/bflat/bin/*; do
                if [ -f "$tool" ] && [ -x "$tool" ]; then
                    ln -s "$tool" "$out/bin/$(basename "$tool")"
                fi
                done
            fi

            # BƯỚC 6: TIÊM BIẾN MÔI TRƯỜNG RUNTIME (Bùa chú tối cao)
            # Ép toàn bộ các file thực thi trong vùng bin khi chạy phải ưu tiên ngửi thư viện xịn của NixOS
            for file in $out/bin/*; do
                if [ -L "$file" ] || [ -f "$file" ]; then
                # Đọc file gốc đứng sau symlink để wrap cho chuẩn
                actual_file=$(readlink -f "$file")
                wrapProgram "$file" \
                    --prefix LD_LIBRARY_PATH : "${pkgs.glibc}/lib:${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.zlib}/lib"
                fi
            done
        '';
    };
    fpc-win64 = pkgs.stdenv.mkDerivation rec {
        pname = "fpc-win64";
        version = pkgs.fpc.version;
        src = pkgs.fpc.src;

        nativeBuildInputs = with pkgs; [
            fpc
            gnumake
            binutils
            pkgsCross.mingwW64.stdenv.cc
        ];

        # Chỉ build RTL (Runtime Library) cho Win64 target
        # Dùng native compiler (fpc) để build RTL
        buildPhase = ''
          if [ -d "fpcsrc" ]; then cd fpcsrc; fi
          make -C rtl all \
            FPC=${pkgs.fpc}/bin/fpc \
            OS_TARGET=win64 \
            CPU_TARGET=x86_64
        '';

        installPhase = ''
          if [ -d "fpcsrc" ]; then cd fpcsrc; fi
          mkdir -p $out/lib/fpc/${version}/units/x86_64-win64

          # Install RTL units
          cp -r rtl/units/x86_64-win64/* $out/lib/fpc/${version}/units/x86_64-win64/
        '';
    };
in

pkgs.mkShell {
    buildInputs = with pkgs; [
        mtools
        python314
        python314Packages.pip
        openssl
        pkg-config
        bflat
        glibc
        gcc
        gnumake
        fpc
        fpc-win64
        # MinGW-w64 cross-compiler for Win64 target
        pkgsCross.mingwW64.stdenv.cc
        pkgsCross.mingwW64.windows.pthreads
        nasm
        yasm
        binutils
        gdb
    ];

    shellHook = ''
        export LD_LIBRARY_PATH="${pkgs.openssl.out}/lib:${pkgs.stdenv.cc.cc.lib}/lib:$LD_LIBRARY_PATH"
        # Tạo fpc.cfg config path cho current shell (đúng cú pháp FPC, không có wildcard)
        mkdir -p .fpc
        echo "-Fu${fpc-win64}/lib/fpc/${pkgs.fpc.version}/units/x86_64-win64" > .fpc/fpc.cfg
        echo "Project: $(basename $PWD)"
        echo "Compiler: $(bflat --version 2>/dev/null || echo 'bflat ready!')"
    '';
}